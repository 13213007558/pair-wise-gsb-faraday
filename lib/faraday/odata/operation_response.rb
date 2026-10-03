# frozen_string_literal: true

module Faraday
  module OData
    # Decoded HTTP response for one OData operation.
    class OperationResponse
      attr_reader :status, :headers, :body, :reason, :content_id

      def initialize(status:, headers:, body:, reason: '', content_id: nil)
        @status = status
        @headers = headers
        @body = body
        @reason = reason
        @content_id = content_id
      end

      # @return [Boolean] whether the inner operation was 2xx
      def success?
        status >= 200 && status < 300
      end

      # @return [Boolean] inverse of {#success?}
      def failure?
        !success?
      end
    end
  end
end
