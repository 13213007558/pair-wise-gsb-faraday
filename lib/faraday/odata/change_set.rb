# frozen_string_literal: true

module Faraday
  module OData
    # An atomic group of operations. Either all of them are applied or
    # none of them are. Operations inside a change set must carry a
    # Content-ID and may reference preceding operations of the same
    # change set via "$n" tokens.
    class ChangeSet
      # @return [Array<Operation>]
      attr_reader :operations

      def initialize(operations = [])
        @operations = operations
      end
    end
  end
end
