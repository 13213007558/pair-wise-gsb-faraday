# frozen_string_literal: true

module Faraday
  module OData
    # Decoded atomicity group in an OData batch response.
    class ChangeSetResponse
      attr_reader :parts, :headers

      def initialize(parts: nil, headers: {})
        @parts = Array(parts)
        @headers = Faraday::Utils::Headers.new(headers)
      end

      # @return [Array<OperationResponse>] operation responses
      def operations
        parts
      end

      # @return [Integer] status of the first failed operation, or 200
      def status
        failed = parts.find(&:failure?)
        failed ? failed.status : 200
      end

      # @return [Boolean] whether every operation in the change set succeeded
      def success?
        parts.any? && parts.all?(&:success?)
      end

      # @return [Boolean] inverse of {#success?}
      def failure?
        !success?
      end
    end
  end
end
