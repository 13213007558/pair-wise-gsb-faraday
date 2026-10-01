# frozen_string_literal: true

module Faraday
  class Request
    # Middleware that hedges slow requests: when the first copy of a request
    # does not complete within +threshold+ seconds, a duplicate copy is sent
    # (up to +max_copies+ in total). The first response satisfying
    # +success_policy+ is returned to the caller, so the caller always
    # observes exactly one result.
    #
    # Hedging is only applied to requests that are safe to repeat:
    #
    # * the HTTP method must be idempotent (see +:methods+ option);
    # * the request body must be independently replayable by every copy
    #   (+nil+ or a +String+; streaming/IO bodies are never hedged);
    # * the request must not stream its response or run in parallel mode.
    #
    # Requests that do not meet these criteria are sent once, as if the
    # middleware was not present.
    #
    # When the underlying adapter responds to +cancel(env)+, losing copies
    # are cancelled. Otherwise they are left to finish naturally in the
    # background; since every copy runs against its own duplicated env,
    # their bodies and errors can neither leak into nor overwrite the
    # winning response.
    #
    # @example
    #   Faraday.new do |f|
    #     f.request :hedging, threshold: 0.2, max_copies: 2, deadline: 2
    #     f.adapter :net_http
    #   end
    class Hedging < Faraday::Middleware
      # HTTP methods that are safe to repeat by default (idempotent).
      DEFAULT_METHODS = %i[get head options trace put delete].freeze

      DEFAULT_OPTIONS = {
        threshold: 0.5,
        max_copies: 2,
        deadline: nil,
        methods: DEFAULT_METHODS,
        success_policy: nil
      }.freeze

      # The result of a single hedged copy: either a response or an error.
      class Outcome
        attr_reader :response, :error

        def initialize(response: nil, error: nil)
          @response = response
          @error = error
        end

        def error?
          !@error.nil?
        end

        def satisfies?(policy)
          !error? && policy.call(@response.env)
        end
      end

      # Thread-safe mailbox collecting the outcomes of hedged copies.
      class Gate
        def initialize
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @outcomes = []
        end

        def push(outcome)
          @mutex.synchronize do
            @outcomes << outcome
            @condition.broadcast
          end
          self
        end

        # @param timeout [Numeric, nil] seconds to wait, +nil+ waits forever
        # @return [Outcome, nil] the next outcome, or +nil+ on timeout
        def take(timeout)
          @mutex.synchronize do
            if @outcomes.empty? && (timeout.nil? || timeout.positive?)
              @condition.wait(@mutex, timeout)
            end
            @outcomes.shift
          end
        end
      end

      # Tracks one in-flight copy of the request.
      Copy = Struct.new(:env, :thread)

      # @param app [#call] the next middleware or adapter
      # @param options [Hash]
      # @option options [Numeric] :threshold (0.5) seconds the first copy may
      #   take before a duplicate is launched
      # @option options [Integer] :max_copies (2) maximum number of copies,
      #   including the original request
      # @option options [Numeric, nil] :deadline (nil) overall time limit in
      #   seconds for the whole hedged request; raises
      #   {Faraday::TimeoutError} when exceeded
      # @option options [Array<Symbol>] :methods idempotent HTTP methods
      #   eligible for hedging
      # @option options [#call, nil] :success_policy callable receiving the
      #   response env and returning whether the response wins the race;
      #   defaults to 2xx success
      def initialize(app, options = {})
        super(app, options || {})
        @threshold = @options[:threshold]
        @max_copies = @options[:max_copies]
        @deadline = @options[:deadline]
        @methods = @options[:methods].map(&:to_sym)
        @success_policy = @options[:success_policy] || ->(env) { env.success? }
        validate_options!
      end

      def call(env)
        return @app.call(env) unless hedgeable?(env)

        race(env)
      end

      private

      def validate_options!
        unless @threshold.is_a?(Numeric) && @threshold.positive?
          raise ArgumentError, ':threshold must be a positive number'
        end
        unless @max_copies.is_a?(Integer) && @max_copies >= 1
          raise ArgumentError, ':max_copies must be an integer >= 1'
        end
        return if @deadline.nil? || (@deadline.is_a?(Numeric) && @deadline.positive?)

        raise ArgumentError, ':deadline must be a positive number or nil'
      end

      def hedgeable?(env)
        @methods.include?(env.method) &&
          !env.parallel? &&
          !env.stream_response? &&
          replayable?(env.request_body)
      end

      # A body can only be hedged when every copy is able to replay it
      # independently of the others.
      def replayable?(body)
        body.nil? || body.is_a?(String)
      end

      def race(env)
        gate = Gate.new
        copies = []
        failures = []
        deadline_at = @deadline && monotonic + @deadline
        last_launch_at = monotonic
        in_flight = 1
        copies << spawn_copy(env, gate)

        loop do
          outcome = gate.take(wait_timeout(in_flight, copies.size, last_launch_at, deadline_at))
          now = monotonic

          if outcome.nil?
            raise_timeout! if deadline_at && now >= deadline_at
            if in_flight.positive? && copies.size < @max_copies && now - last_launch_at >= @threshold
              last_launch_at = now
              in_flight += 1
              copies << spawn_copy(env, gate)
            end
            next
          end

          in_flight -= 1

          if outcome.satisfies?(@success_policy)
            cancel_losers(copies)
            return outcome.response
          end

          failures << outcome

          next unless in_flight.zero?

          if copies.size < @max_copies
            last_launch_at = now
            in_flight += 1
            copies << spawn_copy(env, gate)
          else
            return deliver(failures.first)
          end
        end
      end

      # Seconds to wait for the next outcome before either launching another
      # copy or hitting the overall deadline. +nil+ means wait indefinitely.
      def wait_timeout(in_flight, launched, last_launch_at, deadline_at)
        waits = []
        if in_flight.positive? && launched < @max_copies
          waits << (last_launch_at + @threshold) - monotonic
        end
        waits << deadline_at - monotonic if deadline_at
        return nil if waits.empty?

        [waits.min, 0].max
      end

      def spawn_copy(env, gate)
        copy = Copy.new(duplicate_env(env))
        copy.thread = Thread.new do
          Thread.current.report_on_exception = false
          begin
            gate.push(Outcome.new(response: @app.call(copy.env)))
          rescue StandardError => e
            gate.push(Outcome.new(error: e))
          end
        end
        copy
      end

      # Every copy runs against its own env so concurrent copies never share
      # mutable request/response state.
      def duplicate_env(env)
        Faraday::Env.new(
          env.method, env.request_body, env.url,
          env.request, env.request_headers.dup, env.ssl,
          env.parallel_manager
        ).tap do |copy|
          env.custom_members.each { |key, value| copy.custom_members[key] = value }
        end
      end

      # Adapters that support cancellation get a chance to abort the losing
      # copies; otherwise losers are left to finish naturally and their
      # outcomes are discarded once the gate is gone.
      def cancel_losers(copies)
        return unless @app.respond_to?(:cancel)

        copies.each do |copy|
          @app.cancel(copy.env) if copy.thread.alive?
        end
      end

      def deliver(outcome)
        raise outcome.error if outcome.error?

        outcome.response
      end

      def raise_timeout!
        raise Faraday::TimeoutError, 'hedged request exceeded its overall deadline'
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end

Faraday::Request.register_middleware(hedging: Faraday::Request::Hedging)
