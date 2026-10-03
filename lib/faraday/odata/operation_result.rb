# frozen_string_literal: true

module Faraday
  module OData
    # The decoded response of a single {Operation}.
    class OperationResult
      # @return [Operation, nil] the operation this result belongs to.
      attr_reader :operation

      # @return [Integer, nil] inner HTTP status, nil when aborted.
      attr_reader :status

      # @return [Hash] inner response headers (down-cased keys).
      attr_reader :headers

      # @return [String, nil] inner response body, binary safe.
      attr_reader :body

      def initialize(operation:, status: nil, headers: {}, body: nil, aborted: false)
        @operation = operation
        @status = status
        @headers = headers
        @body = body
        @aborted = aborted
      end

      # Result for an operation that never ran because its change set
      # failed before reaching it.
      def self.aborted(operation)
        new(operation: operation, aborted: true)
      end

      # @return [Boolean] true when the change set was rolled back before
      #   this operation was executed.
      def aborted?
        @aborted
      end

      # @return [Boolean] true only for an executed 2xx response.
      def success?
        !aborted? && !status.nil? && (200..299).cover?(status)
      end
    end
  end
end
