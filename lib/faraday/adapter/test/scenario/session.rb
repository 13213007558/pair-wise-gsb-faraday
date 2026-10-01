# frozen_string_literal: true

module Faraday
  class Adapter
    # Test adapter with named scenario support; see Stubs#scenario.
    class Test < Faraday::Adapter
      # Reopened to attach its nested class; see Scenario.
      class Scenario
        # One run through a scenario, with its own state and captured
        # data. Sessions of the same scenario are isolated from each
        # other. Step blocks receive the session and may read and
        # write captures on it.
        class Session
          attr_reader :number, :state, :captures, :last_failure

          def initialize(scenario, number)
            @scenario = scenario
            @number = number
            @state = scenario.initial_state
            @captures = {}
            @dynamic_transition = nil
            @last_failure = nil
          end

          def [](key)
            @captures[key.to_sym]
          end

          def []=(key, value)
            @captures[key.to_sym] = value
          end

          # Requests a transition from within a step block. Applied
          # only when the step succeeds, and takes precedence over
          # the static +to:+ transition of the step.
          def transition_to(state)
            @dynamic_transition = state.to_sym
          end

          # @return [Array<Symbol>] capture keys added by this call
          def capture_new(match_data)
            return [] unless match_data

            match_data.named_captures.each_with_object([]) do |(key, value), added|
              key = key.to_sym
              next if @captures.key?(key)

              @captures[key] = value
              added << key
            end
          end

          def rollback(keys)
            keys.each { |key| @captures.delete(key) }
          end

          def complete_step(step)
            target = @dynamic_transition || step.transition || @state
            unless @scenario.known_state?(target)
              raise ArgumentError,
                    "scenario #{@scenario.name.inspect} has no state #{target.inspect}"
            end

            @state = target
            @dynamic_transition = nil
            @last_failure = nil
          end

          def record_failure(step, status)
            @dynamic_transition = nil
            @last_failure = { step: step.name, status: status }
          end
        end
      end
    end
  end
end

