# frozen_string_literal: true

module Faraday
  module OData
    # The decoded response of one atomic {ChangeSet}.
    #
    # When any operation of a change set fails, the service rolls the
    # whole change set back and typically returns a single error response
    # for the entire group. In that case {#failure} carries that response
    # and every operation without a matching response part is reported
    # as aborted.
    class ChangeSetResult
      # @return [ChangeSet]
      attr_reader :change_set

      # @return [Array<OperationResult>] one entry per change set operation.
      attr_reader :operations

      # @return [OperationResult, nil] change set level failure, if any.
      attr_reader :failure

      def initialize(change_set:, operations:, failure: nil)
        @change_set = change_set
        @operations = operations
        @failure = failure
      end

      # @return [Boolean] true only when every operation succeeded.
      def success?
        failure.nil? && !operations.empty? && operations.all?(&:success?)
      end
    end
  end
end
