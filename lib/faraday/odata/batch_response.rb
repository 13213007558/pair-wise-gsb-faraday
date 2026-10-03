# frozen_string_literal: true

module Faraday
  module OData
    # Decoded OData batch preserving batch/change-set/operation nesting.
    class BatchResponse
      attr_reader :status, :headers, :parts, :body

      def initialize(status:, headers:, parts: nil, body: nil)
        @status = status
        @headers = Faraday::Utils::Headers.new(headers)
        @parts = Array(parts)
        @body = body
      end

      # @return [Boolean] whether outer transport and every operation succeeded
      def success?
        outer_success? && parts.any? && parts.all?(&:success?)
      end

      # @return [Boolean] inverse of {#success?}
      def failure?
        !success?
      end

      # @return [Boolean] whether the outer response itself was 2xx
      def outer_success?
        status >= 200 && status < 300
      end

      # @return [Array<OperationResponse>] all operations in wire order
      def operations
        Array(parts).flat_map { |part| part.is_a?(ChangeSetResponse) ? Array(part.operations) : [part] }
      end

      # @param content_id [String, Integer] operation Content-ID
      # @return [OperationResponse, nil]
      def operation(content_id)
        operations.find { |operation| operation.content_id == content_id.to_s }
      end
    end
  end
end
