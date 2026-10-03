# frozen_string_literal: true

module Faraday
  module OData
    # Wire representation of an encoded batch request.
    class EncodedBatch
      attr_reader :body, :headers, :boundary, :parts, :path

      # @param body [String] multipart request body
      # @param headers [Hash] outer HTTP request headers
      # @param boundary [String] outer multipart boundary
      # @param parts [Array<Request, ChangeSet>] normalized batch parts
      def initialize(body:, headers:, boundary:, parts:, path: OData::BATCH_PATH)
        @body = body
        @headers = headers
        @boundary = boundary
        @parts = parts
        @path = path
      end

      # @return [Array<Request>] every operation in request order
      def requests
        parts.flat_map { |part| part.is_a?(ChangeSet) ? part.requests : [part] }
      end
    end
  end
end
