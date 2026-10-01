# frozen_string_literal: true

module Faraday
  class Request
    # Optional client-side circuit breaker.
    class CircuitBreaker < Faraday::Middleware
      # Raised when a request is rejected because the circuit is open or the
      # limited half-open probe capacity is already in use.
      class CircuitOpenError < Faraday::Error
        attr_reader :service_key, :state

        def initialize(service_key, state)
          @service_key = service_key
          @state = state
          super("circuit for #{service_key} is #{state}")
        end
      end

      DEFAULT_OPTIONS = {
        service_key: nil,
        failure_threshold: 5,
        rolling_window: 60,
        cooldown: 30,
        jitter: 0,
        max_probes: 1,
        error_statuses: [408, 429, (500...600)].freeze,
        exceptions: [
          Faraday::TimeoutError,
          Faraday::ConnectionFailed,
          Faraday::SSLError,
          Faraday::NilStatusError,
          Faraday::ServerError
        ].freeze,
        error_classifier: nil,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        random: Kernel,
        store: nil
      }.freeze

      def initialize(app, options = {})
        super
        validate_options!
        @store = @options[:store] || Store.new(
          failure_threshold: @options[:failure_threshold],
          rolling_window: @options[:rolling_window],
          cooldown: @options[:cooldown],
          jitter: @options[:jitter],
          max_probes: @options[:max_probes],
          clock: @options[:clock],
          random: @options[:random]
        )
      end

      def call(env)
        key = service_key(env)
        permit = @store.acquire(key)
        unless permit.allowed?
          raise CircuitOpenError.new(key, permit.state)
        end

        begin
          response = app.call(env)
        rescue StandardError => error
          classified, classification_failed = classify(error, env)
          classification_failed ? @store.release(permit) : @store.record(permit, failure: classified)
          raise
        else
          classified, classification_failed = classify(response, env)
          if classification_failed
            @store.release(permit)
            raise classified
          end
          @store.record(permit, failure: classified)
          response
        end
      end

      private

      def validate_options!
        unless positive?(@options[:failure_threshold])
          raise ArgumentError, ':failure_threshold must be greater than 0'
        end
        unless positive?(@options[:rolling_window])
          raise ArgumentError, ':rolling_window must be greater than 0'
        end
        unless positive?(@options[:cooldown])
          raise ArgumentError, ':cooldown must be greater than 0'
        end
        if negative?(@options[:jitter])
          raise ArgumentError, ':jitter must be greater than or equal to 0'
        end
        unless positive?(@options[:max_probes])
          raise ArgumentError, ':max_probes must be greater than 0'
        end
      end

      def positive?(value)
        value.is_a?(Numeric) && value > 0
      end

      def negative?(value)
        value.is_a?(Numeric) && value < 0
      end

      def service_key(env)
        key = @options[:service_key]
        key = key.call(env) if key.respond_to?(:call)
        key ||= env.url.host

        key = key.to_s
        return key unless key.empty?

        raise ArgumentError, 'unable to determine circuit breaker service key'
      end

      def failure?(result, env)
        classifier = @options[:error_classifier]
        return classifier_result(classifier.call(*classifier_arguments(classifier, result, env))) if classifier

        case result
        when Exception
          Array(@options[:exceptions]).any? { |klass| result.is_a?(klass) }
        else
          status = result.respond_to?(:status) ? result.status : nil
          status_matches?(status, @options[:error_statuses])
        end
      end

      def classify(result, env)
        [failure?(result, env), false]
      rescue StandardError => error
        [error, true]
      end

      def classifier_arguments(classifier, result, env)
        if classifier.respond_to?(:arity) && classifier.arity == 1
          [result]
        else
          [result, env]
        end
      end

      def classifier_result(value)
        !!value
      end

      def status_matches?(status, matchers)
        Array(matchers).flatten.any? do |matcher|
          case matcher
          when Range then status.is_a?(Integer) && matcher.include?(status)
          when Proc then matcher.call(status)
          else status == matcher
          end
        end
      end

      # Thread-safe per-key circuit breaker state.
      # @api private
      class Store
        CLOSED = :closed
        OPEN = :open
        HALF_OPEN = :half_open

        Permission = Struct.new(:key, :generation, :allowed, :state, :completed, keyword_init: true) do
          def allowed?
            allowed
          end
        end

        def initialize(failure_threshold:, rolling_window:, cooldown:, jitter:, max_probes:, clock:, random:)
          @failure_threshold = failure_threshold
          @rolling_window = rolling_window
          @cooldown = cooldown
          @jitter = jitter
          @max_probes = max_probes
          @clock = clock
          @random = random
          @mutex = Mutex.new
          @states = Hash.new { |states, key| states[key] = new_state }
        end

        def acquire(key)
          now = current_time
          @mutex.synchronize do
            state = @states[key]
            prune_failures(state, now)

            case state[:state]
            when CLOSED
              return permission(key, state, true)
            when OPEN
              if now >= state[:open_until]
                become_half_open(state)
                acquire_half_open_permission(key, state)
              else
                permission(key, state, false)
              end
            else
              acquire_half_open_permission(key, state)
            end
          end
        end

        def record(permit, failure:)
          return unless permit.allowed?

          @mutex.synchronize do
            state = @states[permit.key]
            return unless state[:generation] == permit.generation

            permit[:completed] = true
            case state[:state]
            when CLOSED
              record_closed_result(state, failure, current_time)
            when HALF_OPEN
              record_half_open_result(state, failure)
            end
          end
        end

        def release(permit)
          return unless permit.allowed?

          @mutex.synchronize do
            state = @states[permit.key]
            return unless state[:generation] == permit.generation && !permit[:completed]
            return unless state[:state] == HALF_OPEN

            permit[:completed] = true
            state[:active_probes] -= 1
          end
        end

        private

        def new_state
          {
            state: CLOSED,
            generation: 0,
            failures: [],
            opened_at: nil,
            open_until: nil,
            active_probes: 0
          }
        end

        def permission(key, state, allowed)
          Permission.new(
            key: key,
            generation: state[:generation],
            allowed: allowed,
            state: state[:state],
            completed: false
          )
        end

        def acquire_half_open_permission(key, state)
          if state[:active_probes] < @max_probes
            state[:active_probes] += 1
            permission(key, state, true)
          else
            permission(key, state, false)
          end
        end

        def become_half_open(state)
          state[:state] = HALF_OPEN
          state[:generation] += 1
          state[:active_probes] = 0
        end

        def become_open(state, now)
          state[:state] = OPEN
          state[:generation] += 1
          state[:failures].clear
          state[:opened_at] = now
          state[:open_until] = now + current_cooldown
          state[:active_probes] = 0
        end

        def become_closed(state)
          state[:state] = CLOSED
          state[:generation] += 1
          state[:failures].clear
          state[:opened_at] = nil
          state[:open_until] = nil
          state[:active_probes] = 0
        end

        def record_closed_result(state, failure, now)
          return unless failure

          state[:failures] << now
          prune_failures(state, now)
          become_open(state, now) if state[:failures].size >= @failure_threshold
        end

        def record_half_open_result(state, failure)
          state[:active_probes] -= 1
          if failure
            become_open(state, current_time)
          else
            become_closed(state)
          end
        end

        def prune_failures(state, now)
          state[:failures].reject! { |time| time + @rolling_window <= now }
        end

        def current_time
          if @clock.respond_to?(:now)
            @clock.now
          else
            @clock.call
          end
        end

        def current_cooldown
          return @cooldown if @jitter.zero?

          jitter = if @random.respond_to?(:rand)
                     @random.rand(@jitter)
                   else
                     @random.call
                   end
          @cooldown + jitter
        end
      end
    end
  end
end

Faraday::Request.register_middleware(circuit_breaker: Faraday::Request::CircuitBreaker)
