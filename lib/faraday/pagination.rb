# frozen_string_literal: true

require 'set'
require 'uri'

module Faraday
  # Lazily enumerates RFC 8288 Link rel="next" responses.
  class Pagination
    DEFAULT_MAX_PAGES = 100
    DEFAULT_SENSITIVE_HEADERS = %w[authorization proxy-authorization cookie].freeze

    def initialize(
      connection, url, params = nil, headers = nil,
      max_pages: DEFAULT_MAX_PAGES, cross_origin: :deny,
      sensitive_headers: DEFAULT_SENSITIVE_HEADERS
    )
      @connection = connection
      @url = url
      @params = params
      @headers = headers
      @max_pages = max_pages
      @cross_origin = cross_origin
      @sensitive_headers = sensitive_headers.map(&:downcase)

      validate!
    end

    def each
      return enum_for(:each) unless block_given?

      visited = Set.new
      current_origin = nil
      default_headers = @connection.headers
      url = @url
      params = @params
      headers = @headers
      page_count = 0

      loop do
        response = request_first_page(url, params, headers) if page_count.zero?
        response ||= request_next_page(url, default_headers, headers)
        page_count += 1

        current_origin ||= origin_for(response.url)

        yield response

        next_link = response.links.find { |link| link.relations.include?('next') }
        break unless next_link

        next_url = next_link.target_uri
        if page_count >= @max_pages
          raise PaginationLimitError, "pagination limit of #{@max_pages} pages reached"
        end
        if visited.include?(cycle_key(next_url))
          raise PaginationCycleError, "pagination cycle detected at #{next_url}"
        end

        next_origin = origin_for(next_url)
        if next_origin != current_origin && !follow_cross_origin?(next_url, response)
          raise CrossOriginError, "cross-origin pagination to #{next_origin} is not allowed"
        end

        if next_origin != current_origin
          default_headers = safe_headers(@connection.headers)
          headers = safe_headers(headers || {})
          current_origin = next_origin
        end

        visited << cycle_key(response.url)
        response = nil
        url = next_url
        params = nil
      end
    end

    private

    def request_first_page(url, params, headers)
      @connection.get(url, params, headers)
    end

    def request_next_page(url, default_headers, headers)
      request = Faraday::Request.create(:get) do |page_request|
        page_request.path = Utils.URI(url)
        page_request.headers = build_page_headers(default_headers, headers)
        page_request.options = @connection.options.dup
      end

      @connection.builder.build_response(@connection, request)
    end

    def build_page_headers(default_headers, headers)
      Utils::Headers.new.update(default_headers).update(headers || {})
    end

    def follow_cross_origin?(next_url, response)
      case @cross_origin
      when :deny
        false
      when :follow
        true
      else
        !!@cross_origin.call(next_url, response)
      end
    end

    def safe_headers(headers)
      headers.each_with_object(Utils::Headers.new) do |(name, value), safe|
        safe[name] = value unless @sensitive_headers.include?(name.to_s.downcase)
      end
    end

    def origin_for(uri)
      normalized = Utils.URI(uri)
      unless normalized.scheme && normalized.host
        raise ArgumentError, "pagination URL must have an origin: #{uri}"
      end

      port = normalized.port == normalized.default_port ? nil : normalized.port
      origin = URI::Generic.build(scheme: normalized.scheme, host: normalized.host, port: port)
      origin.to_s.downcase
    end

    def cycle_key(uri)
      normalized = Utils.URI(uri).dup
      normalized.fragment = nil
      normalized.to_s
    end

    def validate!
      unless @max_pages.is_a?(Integer) && @max_pages.positive?
        raise ArgumentError, 'max_pages must be positive'
      end
      return if %i[deny follow].include?(@cross_origin) || @cross_origin.respond_to?(:call)

      raise ArgumentError, 'cross_origin must be :deny, :follow, or callable'
    end

    class PaginationError < Faraday::Error
    end

    class PaginationCycleError < PaginationError
    end

    class PaginationLimitError < PaginationError
    end

    class CrossOriginError < PaginationError
    end
  end
end
