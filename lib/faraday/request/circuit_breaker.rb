# frozen_string_literal: true

require 'monitor'

module Faraday
  class Request
    # Optional circuit breaker middleware.
    class CircuitBreaker < Faraday::Middleware
      class CircuitOpenError < Faraday::CircuitBreakerOpenError; end

      DEFAULT_FAILURE_STATUSES = (500...600).freeze
      DEFAULT_FAILURE_ERRORS = [
        Faraday::TimeoutError,
        Faraday::ConnectionFailed,
        Faraday::NilStatusError,
        Faraday::ServerError
      ].freeze

      DEFAULT_OPTIONS = {
        service_key: nil,
        failure_threshold: 5,
        rolling_window: 60,
        cooldown: 30,
        cooldown_jitter: 0,
        max_probe_requests: 1,
        successful_probe_requests: 1,
        failure_statuses: DEFAULT_FAILURE_STATUSES,
        failure_errors: DEFAULT_FAILURE_ERRORS,
        failure_classifier: nil,
        clock: nil,
        random: nil,
        store: nil
      }.freeze

      class MonotonicClock
        def call
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      class Store
        def initialize
          @circuits = {}
          @monitor = Monitor.new
        end

        def circuit(service_key, options)
          @monitor.synchronize do
            @circuits[service_key] ||= Circuit.new(service_key, options)
          end
        end

        def state_for(service_key)
          @monitor.synchronize do
            @circuits[service_key]&.state || :closed
          end
        end

      end

      class Circuit
        attr_reader :state, :open_until

        def initialize(service_key, options)
          @service_key = service_key
          @failure_threshold = options.fetch(:failure_threshold)
          @rolling_window = options.fetch(:rolling_window)
          @cooldown = options.fetch(:cooldown)
          @cooldown_jitter = options.fetch(:cooldown_jitter)
          @max_probe_requests = options.fetch(:max_probe_requests)
          @successful_probe_requests = options.fetch(:successful_probe_requests)
          @clock = options.fetch(:clock)
          @random = options.fetch(:random)

          @monitor = Monitor.new
          @state = :closed
          @failures = []
          @generation = 0
          @available_probes = 0
          @successful_probes = 0
          @open_until = nil
        end

        def acquire
          @monitor.synchronize do
            transition_to_half_open_if_ready

            case @state
            when :closed
              permission(false)
            when :half_open
              acquire_probe
            else
              raise CircuitOpenError.new(@service_key, @state)
            end
          end
        end

        def record_success(permission)
          @monitor.synchronize do
            return unless current_permission?(permission)

            if permission.probe?
              permission.outcome = :success
              @successful_probes += 1
              close if @successful_probes >= @successful_probe_requests
            end
          end
        end

        def record_failure(permission, now = current_time)
          @monitor.synchronize do
            return unless current_permission?(permission)
            permission.outcome = :failure

            if permission.probe?
              open(now)
            else
              prune_failures(now)
              @failures << now
              open(now) if @failures.size >= @failure_threshold
            end
          end
        end

        def release(permission)
          @monitor.synchronize do
            return unless current_permission?(permission) && permission.probe?
            return unless permission.outcome.nil?

            @available_probes += 1 if @state == :half_open
          end
        end

        private

        def transition_to_half_open_if_ready
          return unless @state == :open && current_time >= @open_until

          @state = :half_open
          @available_probes = @max_probe_requests
          @successful_probes = 0
        end

        def acquire_probe
          if @available_probes.positive?
            @available_probes -= 1
            permission(true)
          else
            raise CircuitOpenError.new(@service_key, @state)
          end
        end

        def current_permission?(permission)
          permission.generation == @generation
        end

        def close
          @state = :closed
          @failures.clear
          @generation += 1
          @available_probes = 0
          @successful_probes = 0
          @open_until = nil
        end

        def open(now)
          @state = :open
          @failures.clear
          @generation += 1
          @available_probes = 0
          @successful_probes = 0
          @open_until = now + cooldown_duration
        end

        def prune_failures(now)
          @failures.reject! { |failure_at| now - failure_at >= @rolling_window }
        end

        def cooldown_duration
          jitter = @cooldown_jitter
          return @cooldown if jitter.nil?
          return @cooldown + random_in(jitter) if jitter.is_a?(Range)

          return @cooldown if jitter.to_f.zero?

          @cooldown + random_in(-jitter.to_f..jitter.to_f)
        end

        def random_in(range)
          if @random.respond_to?(:rand)
            @random.rand(range)
          else
            @random.call(range)
          end
        end

        def current_time
          @clock.respond_to?(:now) ? @clock.now : @clock.call
        end

        def permission(probe)
          Permission.new(
            circuit: self,
            service_key: @service_key,
            generation: @generation,
            probe: probe
          )
        end

        class Permission
          attr_reader :service_key, :generation, :probe
          attr_accessor :outcome

          def initialize(circuit:, service_key:, generation:, probe:, outcome: nil)
            @circuit = circuit
            @service_key = service_key
            @generation = generation
            @probe = probe
            @outcome = outcome
            @released = false
          end

          def probe?
            @probe
          end

          def record_success!
            @circuit.record_success(self)
          end

          def record_failure!
            @circuit.record_failure(self)
          end

          def release!
            return if @released

            @released = true
            @circuit.release(self)
          end
        end
      end

      def initialize(app, options = {})
        super
        validate_options!
        @service_key = self.options[:service_key]
        @failure_threshold = self.options[:failure_threshold]
        @rolling_window = self.options[:rolling_window]
        @cooldown = self.options[:cooldown]
        @max_probe_requests = self.options[:max_probe_requests]
        @successful_probe_requests = self.options[:successful_probe_requests]
        @failure_statuses = self.options[:failure_statuses]
        @failure_errors = self.options[:failure_errors]
        @failure_classifier = self.options[:failure_classifier]
        @clock = self.options[:clock] || MonotonicClock.new
        @random = self.options[:random] || Random.new
        @store = self.options[:store] || Store.new
      end

      def call(env)
        service_key = resolve_service_key(env)
        permission = circuit(service_key).acquire
        response = nil

        response = @app.call(env)
        response.on_complete do |response_env|
          begin
            if failure?(response_env, nil)
              permission.record_failure!
            else
              permission.record_success!
            end
          ensure
            permission.release!
          end
        end
      rescue StandardError => error
        if failure?(env, error)
          permission&.record_failure!
        end
        raise
      ensure
        permission&.release! unless response && !response.finished?
      end

      def state(service_key = nil)
        service_key ||= @service_key
        @store.state_for(service_key.to_s)
      end

      private

      def validate_options!
        [
          :failure_threshold,
          :rolling_window,
          :cooldown,
          :max_probe_requests,
          :successful_probe_requests
        ].each do |key|
          value = options[key]
          next if value.is_a?(Numeric) && value.positive?

          raise ArgumentError, ":#{key} must be a positive number, got #{value.inspect}"
        end

        if options[:successful_probe_requests] > options[:max_probe_requests]
          raise ArgumentError,
                ':successful_probe_requests cannot be greater than :max_probe_requests'
        end
      end

      def resolve_service_key(env)
        key = @service_key
        key = key.call(env) if key.respond_to?(:call)
        key ||= env.url.host

        raise ArgumentError, 'could not resolve circuit breaker service key' if key.nil?

        key.to_s
      end

      def circuit(service_key)
        @store.circuit(service_key, circuit_options)
      end

      def circuit_options
        {
          failure_threshold: @failure_threshold,
          rolling_window: @rolling_window,
          cooldown: @cooldown,
          cooldown_jitter: options[:cooldown_jitter],
          max_probe_requests: @max_probe_requests,
          successful_probe_requests: @successful_probe_requests,
          clock: @clock,
          random: @random
        }
      end

      def failure?(env, error)
        return @failure_classifier.call(env, error) if @failure_classifier

        if error
          Array(@failure_errors).any? { |error_class| error.is_a?(error_class) }
        else
          status_failure?(env.status)
        end
      end

      def status_failure?(status)
        case @failure_statuses
        when nil, false
          false
        when Range, Array
          @failure_statuses.include?(status)
        else
          @failure_statuses === status
        end
      end
    end
  end
end

Faraday::Request.register_middleware(circuit_breaker: Faraday::Request::CircuitBreaker)
