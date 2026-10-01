# frozen_string_literal: true

module Faraday
  class Request
    # Middleware that hedges slow requests against a secondary target.
    #
    # The first copy of the request is sent immediately. If no response
    # satisfying the success policy arrives within +delay+ seconds, a
    # duplicate copy is issued (optionally against the next URL in
    # +targets+), up to +max_copies+ copies in total. The first response
    # satisfying the success policy is returned to the caller, so the
    # caller always observes exactly one result. Losing copies are left to
    # finish naturally (Faraday adapters do not support cancellation), but
    # each copy runs against its own duplicated env, so a loser's body,
    # headers or error can never leak into, or overwrite, the winner.
    #
    # Hedging duplicates a request, therefore it is restricted to safely
    # repeatable (idempotent) methods - GET, HEAD and OPTIONS by default -
    # and to request bodies that can be replayed independently for every
    # copy (nil, a String, or an IO that can be rewound and materialized).
    #
    # An overall +deadline+ (in seconds) can be set to bound the whole
    # operation; when it expires a {Faraday::TimeoutError} is raised and
    # any copy still in flight is abandoned (but never cancelled).
    #
    # @example Hedge GET requests against a second replica
    #   Faraday.new('http://one.internal') do |f|
    #     f.request :hedging, delay: 0.05, max_copies: 2,
    #                         targets: ['http://two.internal'],
    #                         deadline: 2
    #     f.adapter Faraday.default_adapter
    #   end
    class Hedging < Faraday::Middleware
      # Methods that are safe to repeat by default.
      SAFE_METHODS = %i[get head options].freeze

      # Default success policy: any response that is not a server error.
      DEFAULT_SUCCESS_IF = ->(response) { response.status.to_i < 500 }

      # Default timer, injectable so tests do not depend on real time.
      DEFAULT_SLEEPER = ->(seconds) { sleep(seconds) }

      DEFAULT_OPTIONS = {
        delay: 0.05,
        max_copies: 2,
        deadline: nil,
        methods: SAFE_METHODS,
        targets: [],
        success_if: DEFAULT_SUCCESS_IF,
        sleeper: DEFAULT_SLEEPER
      }.freeze

      # Tokens exchanged between the copy/timer threads and the caller.
      TOKEN_HEDGE = :hedge
      TOKEN_DEADLINE = :deadline

      # Mutable state of a single hedged request.
      State = Struct.new(:coordinator, :launched, :in_flight, :failures)

      def initialize(app = nil, options = {})
        super
        @delay = @options[:delay]
        @max_copies = @options[:max_copies]
        @deadline = @options[:deadline]
        @methods = Array(@options[:methods]).map(&:to_sym)
        @targets = Array(@options[:targets])
        @success_if = @options[:success_if]
        @sleeper = @options[:sleeper]
        validate_options!
      end

      # @param env [Faraday::Env]
      # @return [Faraday::Response] the first response satisfying the
      #   success policy, or the first failure once every copy has failed
      # @raise [Faraday::Error] if the request cannot be hedged safely
      # @raise [Faraday::TimeoutError] if the overall deadline expires
      def call(env)
        ensure_safe_method!(env)
        body = replayable_body(env)

        state = State.new(Queue.new, 0, 0, [])
        launch_copy(env, body, state)
        schedule(state, TOKEN_HEDGE, @delay) if @max_copies > 1
        schedule(state, TOKEN_DEADLINE, @deadline) if @deadline
        await_outcome(env, body, state)
      end

      private

      def await_outcome(env, body, state)
        pending = nil
        loop do
          token = pending || state.coordinator.pop
          pending = nil

          case token
          when TOKEN_HEDGE
            pending = hedge_or_drain(env, body, state)
          when TOKEN_DEADLINE
            raise Faraday::TimeoutError,
                  "hedged request did not complete within #{@deadline}s"
          else
            outcome = record_copy_result(token, state)
            return outcome if outcome
          end
        end
      end

      # A result that has already arrived when the threshold is reached
      # wins the race and suppresses the duplicate.
      def hedge_or_drain(env, body, state)
        return nil if state.launched >= @max_copies

        begin
          state.coordinator.pop(true)
        rescue ThreadError
          launch_copy(env, body, state)
          schedule(state, TOKEN_HEDGE, @delay) if state.launched < @max_copies
          nil
        end
      end

      # @return [Faraday::Response, nil] the winning response, the failure
      #   to surface once every copy has failed, or nil to keep waiting
      def record_copy_result(token, state)
        kind, payload = token
        state.in_flight -= 1
        return payload if kind == :result && @success_if.call(payload)

        state.failures << token
        return unless state.in_flight.zero?

        # Every copy finished without satisfying the success policy:
        # surface exactly one failure to the caller.
        kind, payload = state.failures.first
        raise payload if kind == :error

        payload
      end

      def launch_copy(env, body, state)
        state.launched += 1
        state.in_flight += 1
        copy_env = duplicate_env(env, body)
        retarget(copy_env, state.launched)
        Thread.new { run_copy(copy_env, state.coordinator) }
      end

      def validate_options!
        raise ArgumentError, 'delay must be positive' unless @delay&.positive?
        raise ArgumentError, 'max_copies must be >= 1' unless @max_copies.to_i >= 1

        return if @deadline.nil? || @deadline.positive?

        raise ArgumentError, 'deadline must be positive when set'
      end

      def ensure_safe_method!(env)
        return if @methods.include?(env.method.to_sym)

        allowed = @methods.map { |method| method.to_s.upcase }.join(', ')
        raise Faraday::Error,
              "#{self.class} only hedges safely repeatable methods " \
              "(#{allowed}), got #{env.method.to_s.upcase}"
      end

      # The entity must be independently replayable for every copy.
      # @return [nil, String] a body that can be handed to each copy
      def replayable_body(env)
        body = env.request_body
        return body if body.nil? || body.is_a?(String)
        return materialize(body) if body.respond_to?(:rewind) && body.respond_to?(:read)

        raise Faraday::Error,
              "#{self.class} cannot hedge a request whose body " \
              "(#{body.class}) cannot be replayed independently"
      end

      def materialize(body)
        body.rewind
        body.read
      end

      # Each copy gets its own env so that a losing copy can never mutate
      # the state observed by the winner or by the caller.
      def duplicate_env(env, body)
        env.dup.tap do |copy|
          copy.request_headers = env.request_headers.dup
          copy.response_headers = env.response_headers&.dup
          copy.request_body = body.is_a?(String) ? body.dup : body
          copy.response = nil
          copy.status = nil
          copy.reason_phrase = nil
          copy.response_body = nil
        end
      end

      # Copies after the first are sent to the next configured target.
      def retarget(copy_env, copy_number)
        return if copy_number < 2 || @targets.empty?

        target = Faraday::Utils.URI(@targets[(copy_number - 2) % @targets.size])
        url = copy_env.url.dup
        url.scheme = target.scheme if target.scheme
        url.host = target.host if target.host
        url.port = target.port if target.port
        copy_env.url = url
      end

      def run_copy(copy_env, coordinator)
        coordinator << [:result, app.call(copy_env)]
      rescue StandardError => e
        coordinator << [:error, e]
      end

      def schedule(state, token, after)
        Thread.new do
          @sleeper.call(after)
          state.coordinator << token
        end
      end
    end
  end
end

Faraday::Request.register_middleware(hedging: Faraday::Request::Hedging)
