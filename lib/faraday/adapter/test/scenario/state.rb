# frozen_string_literal: true

module Faraday
  class Adapter
    # Test adapter with named scenario support; see Stubs#scenario.
    class Test < Faraday::Adapter
      # Reopened to attach its nested class; see Scenario.
      class Scenario
        # A single state of a scenario, built by Scenario#state.
        class State
          attr_reader :name, :steps

          def initialize(name, terminal: false)
            @name = name.to_sym
            @terminal = terminal
            @steps = []
          end

          def terminal?
            @terminal
          end

          # Declares a request this state accepts. +path+ may be a
          # String, a String with +{capture}+ segments, or a Regexp.
          # Captured segments are stored on the session and constrain
          # later requests of the same session. +to:+ names the state
          # entered when the step succeeds; without it the session
          # stays in the current state.
          def on(method, path, to: nil, as: nil, &block)
            raise ArgumentError, 'a response block is required' unless block

            Step.new(method, path, to: to, name: as, &block).tap do |step|
              @steps << step
            end
          end
        end
      end
    end
  end
end

