# frozen_string_literal: true

module Faraday
  class Adapter
    # Test adapter with named scenario support; see Stubs#scenario.
    class Test < Faraday::Adapter
      # A named scenario describes a stateful interaction with an API:
      # which requests each state accepts, and how a successful request
      # moves the scenario to the next state. Responses may reference
      # data captured by earlier requests of the same session, and
      # several sessions of the same scenario stay isolated from each
      # other. The first defined state is the initial one.
      #
      # @example
      #   stubs.scenario(:resource_lifecycle) do |scenario|
      #     scenario.state :empty do |state|
      #       state.on :post, '/resources', to: :pending do |_env, session|
      #         session[:id] = 'res-1'
      #         [201, {}, JSON.dump(id: session[:id], status: 'pending')]
      #       end
      #     end
      #     scenario.state :pending do |state|
      #       state.on :get, '/resources/{id}' do |_env, session|
      #         [200, {}, JSON.dump(id: session[:id], status: 'pending')]
      #       end
      #       state.on :delete, '/resources/{id}', to: :gone do
      #         [204, {}, '']
      #       end
      #     end
      #     scenario.state :gone, terminal: true
      #   end
      #
      # A step without a +to:+ transition keeps the session in its
      # current state, which makes repeated polling natural. A step
      # block may also call +session.transition_to+ to choose the next
      # state dynamically. Transitions only happen when the response
      # status is below 400; a failed step leaves the session in its
      # current state and is reported by the next mismatched request.
      class Scenario
        attr_reader :name, :sessions

        def initialize(name)
          @name = name.to_sym
          @states = {}
          @sessions = []
        end

        # Defines a state. The first defined state is the initial one.
        # States marked +terminal+ are the valid ending points checked
        # by Stubs#verify_stubbed_calls.
        def state(name, terminal: false)
          state = State.new(name, terminal: terminal)
          @states[state.name] = state
          yield state if block_given?
          state
        end

        def initial_state
          @states.keys.first
        end

        def terminal_states
          @states.values.select(&:terminal?).map(&:name)
        end

        def known_state?(name)
          @states.key?(name)
        end

        def validate!
          if @states.empty?
            raise ArgumentError, "scenario #{@name.inspect} defines no states"
          end

          @states.each_value do |state|
            state.steps.each do |step|
              next if step.transition.nil? || known_state?(step.transition)

              raise ArgumentError,
                    "scenario #{@name.inspect} step #{step.name.inspect} transitions " \
                    "to unknown state #{step.transition.inspect}"
            end
          end
        end

        # Forgets all sessions so the scenario can start over.
        def reset!
          @sessions.clear
        end

        # @param env [Faraday::Env]
        # @return [Array(MatchedRequest, Hash), nil] the matched request
        #   wrapper and its meta, or nil when the request does not
        #   belong to this scenario
        def match(env)
          @sessions.each do |session|
            found = find_step(session.state, env, session)
            return build_match(session, *found) if found
          end

          found = find_step(initial_state, env, nil)
          return build_match(start_session, *found) if found

          raise Stubs::ScenarioMismatch, mismatch_message(env) if claims?(env)

          nil
        end

        # @return [Array<String>] problems found by
        #   Stubs#verify_stubbed_calls
        def unfinished_messages
          messages = []
          if @sessions.empty?
            messages << "Scenario #{@name.inspect} never started; " \
                        "expected #{expected_description(initial_state)}."
          end
          @sessions.each do |session|
            next if terminal?(session.state) || terminal_states.empty?

            expected = terminal_states.map(&:inspect).join(' or ')
            messages << "Scenario #{@name.inspect} session ##{session.number} " \
                        "stopped in state #{session.state.inspect}; " \
                        "expected terminal state #{expected}."
          end
          messages
        end

        private

        def terminal?(state_name)
          @states[state_name]&.terminal?
        end

        def start_session
          Session.new(self, @sessions.size + 1).tap { |session| @sessions << session }
        end

        def find_step(state_name, env, session)
          @states[state_name].steps.each do |step|
            meta = step.matches?(env, session)
            return step, meta if meta
          end
          nil
        end

        def build_match(session, step, meta)
          block = ->(env, m) { execute(session, step, env, m) }
          [MatchedRequest.new(block), meta]
        end

        def execute(session, step, env, meta)
          captured = session.capture_new(meta[:match_data])
          result = call_step(step, env, session, meta)
          if result[0].to_i < 400
            session.complete_step(step)
          else
            session.rollback(captured)
            session.record_failure(step, result[0])
          end
          result
        end

        def call_step(step, env, session, meta)
          block = step.block
          arity = block.arity
          args = [env, session, meta]
          args = args.take(arity) if arity >= 0
          block.call(*args)
        end

        # Whether any step of any state accepts this request, ignoring
        # whether the current state allows it.
        def claims?(env)
          @states.each_value do |state|
            state.steps.each do |step|
              return true if step.matches?(env, nil)
            end
          end
          false
        end

        def mismatch_message(env)
          request = "#{env[:method].to_s.upcase} #{env[:url]}"
          parts = ["scenario #{@name.inspect} cannot accept #{request} yet"]
          active = @sessions.reject { |session| @states[session.state].steps.empty? }
          if active.empty?
            parts << "expected #{expected_description(initial_state)}"
          else
            active.each do |session|
              parts << "session ##{session.number} is in state " \
                       "#{session.state.inspect} and expects " + \
                       expected_description(session.state)
              if session.last_failure
                failure = session.last_failure
                parts << "session ##{session.number} step #{failure[:step]} " \
                         "responded #{failure[:status]} and did not advance"
              end
            end
          end
          parts << 'no later step was consumed'
          parts.join('; ')
        end

        def expected_description(state_name)
          steps = @states[state_name].steps
          return 'no further requests' if steps.empty?

          "one of: #{steps.map(&:name).join(', ')}"
        end

        # Wraps a matched step so the adapter can treat it like a Stub.
        MatchedRequest = Struct.new(:block)
      end
    end
  end
end

require 'faraday/adapter/test/scenario/state'
require 'faraday/adapter/test/scenario/step'
require 'faraday/adapter/test/scenario/session'

