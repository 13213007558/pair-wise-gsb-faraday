# frozen_string_literal: true

require 'set'

require 'faraday/link_header'

module Faraday
  # Lazily follows RFC 8288 `rel="next"` links.
  module Pagination
    DEFAULT_SENSITIVE_HEADERS = %w[
      Authorization
      Cookie
      Proxy-Authorization
      WWW-Authenticate
    ].freeze

    class CrossOriginError < Faraday::Error; end
    class PageLimitError < Faraday::Error; end
    class CycleError < Faraday::Error; end

    # @param connection [Faraday::Connection] connection used for every request
    # @param url [String, URI, nil] URL of the first page
    # @param headers [Hash, nil] headers to send on the first request
    # @param max_pages [Integer, nil] maximum number of pages to request
    # @param cross_origin [:deny, :follow, true, false, #call] policy for links
    #   whose target origin differs from the current response
    # @param sensitive_headers [Array<String>] headers removed before following
    #   an explicitly allowed cross-origin link
    # @param method [Symbol] HTTP method to use
    # @param body [Object, nil] request body to send on each page
    # @param params [Hash, nil] extra query params for the first request
    # @return [Enumerator::Lazy] responses, fetched only as consumed
    def self.paginate(connection, url = nil, headers = nil,
                     max_pages: 100,
                     cross_origin: :deny,
                     sensitive_headers: DEFAULT_SENSITIVE_HEADERS,
                     method: :get,
                     body: nil,
                     params: nil)
      Enumerator.new do |yielder|
        Paginator.new(
          connection,
          max_pages: max_pages,
          cross_origin: cross_origin,
          sensitive_headers: sensitive_headers,
          method: method,
          body: body,
          params: params
        ).each(url, headers) { |response| yielder << response }
      end.lazy
    end

    class Paginator
      def initialize(connection, max_pages:, cross_origin:, sensitive_headers:,
                     method:, body:, params:)
        @connection = connection
        @max_pages = max_pages
        @cross_origin = cross_origin
        @sensitive_headers = sensitive_headers.map(&:downcase)
        @method = method
        @body = body
        @params = params
      end

      def each(url, headers)
        visited = Set.new
        request_url = url
        request_headers = headers
        cross_origin_request = false
        pages = 0

        while request_url
          pages += 1
          raise PageLimitError, "pagination limit of #{@max_pages} pages exceeded" if @max_pages && pages > @max_pages

          response = request_page(request_url, request_headers, cross_origin_request, pages == 1)
          yield response

          visited.add?(cycle_key(response.url))

          next_link = next_link(response)
          break unless next_link

          next_url = next_link.uri
          unless visited.add?(cycle_key(next_url))
            raise CycleError, "pagination cycle detected at #{next_url}"
          end

          request_url = next_url
          request_headers, cross_origin_request =
            next_request_headers(response, next_link, next_url)
        end
      end

      private

      def request_page(url, headers, cross_origin_request, first_page)
        request_connection = cross_origin_request ? connection_for_cross_origin : @connection
        run_request(request_connection, url, headers) do |request|
          if first_page
            request.params.update(@params) if @params
          else
            query = Utils.URI(url).query
            encoder = request.options.params_encoder || Utils.default_params_encoder
            request.params.replace(encoder.decode(query) || {})
          end
        end
      end

      def run_request(connection, url, headers, &block)
        connection.run_request(@method, url, @body, headers, &block)
      end

      def connection_for_cross_origin
        @connection.dup.tap do |connection|
          @sensitive_headers.each do |name|
            connection.headers.delete(name)
          end
        end
      end

      def next_link(response)
        base = response.url
        Faraday::LinkHeader.parse(response.headers['Link'], base: base)
          .find { |link| link.rels.any? { |rel| rel.casecmp?('next') } }
      end

      def next_request_headers(response, link, next_url)
        current_headers = response.env.request_headers.dup
        return [current_headers, false] if same_origin?(response.url, next_url)

        decision = cross_origin_decision(response, link, next_url, current_headers)
        return [filter_sensitive_headers(current_headers), true] if decision == true
        return [decision, true] if decision.is_a?(::Hash)
        return [filter_sensitive_headers(current_headers), true] if decision

        raise(CrossOriginError, "refusing to follow cross-origin link to #{next_url}")
      end

      def cross_origin_decision(response, link, url, headers)
        case @cross_origin
        when :deny
          false
        when false
          false
        when :follow
          true
        when true
          true
        when ->(policy) { policy.respond_to?(:call) }
          call_cross_origin_policy(response, link, url, headers)
        else
          raise ArgumentError, "unknown cross-origin policy #{@cross_origin.inspect}"
        end
      end

      def filter_sensitive_headers(headers)
        headers.reject { |name, _| @sensitive_headers.include?(name.downcase) }
      end

      def call_cross_origin_policy(response, link, url, headers)
        if @cross_origin.arity.zero?
          @cross_origin.call
        else
          @cross_origin.call(response: response, link: link, url: url, headers: headers)
        end
      end

      def same_origin?(left, right)
        origin(left) == origin(right)
      end

      def origin(uri)
        normalized = Utils.URI(uri)
        scheme = normalized.scheme&.downcase
        port = normalized.port || { 'http' => 80, 'https' => 443 }.fetch(scheme, nil)
        [scheme, normalized.host&.downcase, port]
      end

      def cycle_key(uri)
        normalized = Utils.URI(uri).dup
        normalized.fragment = nil
        normalized.to_s
      end
    end
  end

  class Connection
    # Lazily requests pages linked through RFC 8288 `rel="next"` headers.
    #
    # @return [Enumerator::Lazy]
    def paginate(url = nil, headers = nil, **options)
      Faraday::Pagination.paginate(self, url, headers, **options)
    end
  end
end
