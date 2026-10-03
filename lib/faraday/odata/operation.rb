# frozen_string_literal: true

module Faraday
  module OData
    # Describes a single request inside an OData batch, either a plain
    # query or one operation of an atomic change set.
    #
    # @example
    #   Faraday::OData::Operation.new(
    #     method: :post,
    #     url: 'Customers',
    #     headers: { 'Content-Type' => 'application/json' },
    #     body: '{"Name":"ACME"}',
    #     content_id: '1'
    #   )
    class Operation
      # Matches Content-ID references such as "$1" in URLs or bodies.
      # Query options ($filter, $top, ...) are not matched because a
      # reference is always a dollar sign followed by digits only.
      REFERENCE_PATTERN = /\$(\d+)/.freeze

      # @return [String] HTTP method, upper-cased (e.g. "GET", "POST").
      attr_reader :method

      # @return [String] request URL, relative to the service root.
      attr_reader :url

      # @return [Hash] inner request headers.
      attr_reader :headers

      # @return [String, nil] inner request body, may be binary.
      attr_reader :body

      # @return [String, nil] Content-ID used for "$n" references.
      attr_reader :content_id

      def initialize(method:, url:, headers: {}, body: nil, content_id: nil)
        @method = method.to_s.upcase
        @url = url
        @headers = headers
        @body = body
        @content_id = content_id&.to_s
      end

      # Content-IDs referenced by this operation via "$n" tokens in the
      # URL or in a string body.
      #
      # @return [Array<String>]
      def references
        found = url.to_s.scan(REFERENCE_PATTERN).flatten
        found += body.scan(REFERENCE_PATTERN).flatten if body.is_a?(String)
        found.uniq
      end
    end
  end
end
