# frozen_string_literal: true

module Faraday
  module OData
    # A single HTTP request represented inside an OData batch part.
    class Request
      READ_METHODS = %i[get head options trace].freeze
      CHANGE_METHODS = %i[post put patch delete].freeze
      VALID_METHODS = (READ_METHODS + CHANGE_METHODS).freeze

      attr_reader :method, :url, :headers, :body, :content_id

      # @param method [Symbol, String] HTTP method
      # @param url [String, URI] request target
      # @param headers [Hash] inner HTTP request headers
      # @param body [String, IO, Hash, Array, nil] request body
      # @param content_id [String, Integer, nil] OData Content-ID
      def initialize(method:, url:, headers: {}, body: nil, content_id: nil)
        @method = method.to_s.downcase.to_sym
        @url = url.to_s
        @headers = Faraday::Utils::Headers.new(headers)
        @body = body
        @content_id = content_id.nil? ? nil : content_id.to_s
      end

      # @return [Boolean] whether this is a safe/read-only request
      def read?
        READ_METHODS.include?(method)
      end

      # @return [Boolean] whether this is a data modification request
      def change?
        CHANGE_METHODS.include?(method)
      end

      # @param value [Hash, Request] request description
      # @return [Request]
      def self.from(value)
        return value.dup if value.is_a?(self)

        unless value.is_a?(Hash)
          raise ValidationError, "unsupported OData operation: #{value.inspect}"
        end

        hash = value.transform_keys(&:to_s)
        method = hash.fetch('method') { raise ValidationError, 'missing OData request method' }
        url = hash.fetch('url') { hash.fetch('path') { raise ValidationError, 'missing OData request url' } }
        new(
          method: method,
          url: url,
          headers: hash.fetch('headers', {}),
          body: hash.fetch('body', nil),
          content_id: hash.fetch('content_id', hash.fetch('content-id', nil))
        )
      end
    end
  end
end
