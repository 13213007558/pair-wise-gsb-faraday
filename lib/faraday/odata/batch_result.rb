# frozen_string_literal: true

module Faraday
  module OData
    # The decoded response of a whole batch. Preserves the three levels
    # of the protocol: batch, change set and operation.
    #
    # Note that the overall HTTP status of the batch response (usually
    # 200) says nothing about the individual operations; use {#success?}
    # or inspect the nested results instead.
    class BatchResult
      # @return [Array<OperationResult, ChangeSetResult>] results in the
      #   same order as the items of the original batch.
      attr_reader :items

      def initialize(items:)
        @items = items
      end

      # @return [Array<OperationResult>] results of top-level queries.
      def operations
        items.grep(OperationResult)
      end

      # @return [Array<ChangeSetResult>]
      def change_sets
        items.grep(ChangeSetResult)
      end

      # @return [Boolean] true only when every item succeeded.
      def success?
        items.all?(&:success?)
      end
    end
  end
end
