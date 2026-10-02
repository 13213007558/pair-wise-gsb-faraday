# frozen_string_literal: true

require 'pp' # This require is necessary for Hash#pretty_inspect to work, do not remove it, people rely on it.
require 'faraday/logging/redactor'

module Faraday
  module Logging
    # Serves as an integration point to customize logging
    class Formatter
      extend Forwardable

      DEFAULT_OPTIONS = { headers: true, bodies: false, errors: false,
                          log_level: :info, redact: nil }.freeze

      def initialize(logger:, options:)
        @logger = logger
        @options = DEFAULT_OPTIONS.merge(options)
        unless %i[debug info warn error fatal].include?(@options[:log_level])
          @options[:log_level] = :info
        end
        @filter = []
        @redactors = build_redactors(@options[:redact])
      end

      def_delegators :@logger, :debug, :info, :warn, :error, :fatal

      def request(env)
        public_send(log_level) do
          "request: #{env.method.upcase} #{apply_filters(redacted_url(env.url))}"
        end

        log_headers('request', env.request_headers) if log_headers?(:request)
        if env[:body] && log_body?(:request)
          log_body('request', env[:body], content_type_from(env.request_headers))
        end
      end

      def response(env)
        public_send(log_level) { "response: Status #{env.status}" }

        log_headers('response', env.response_headers) if log_headers?(:response)
        if env[:body] && log_body?(:response)
          log_body('response', env[:body], content_type_from(env.response_headers))
        end
      end

      def exception(exc)
        return unless log_errors?

        public_send(log_level) { "error: #{exc.full_message}" }

        log_headers('error', exc.response_headers) if exc.respond_to?(:response_headers) && log_headers?(:error)
        return unless exc.respond_to?(:response_body) && exc.response_body && log_body?(:error)

        log_body('error', exc.response_body, content_type_from(exc.response_headers))
      end

      def filter(filter_word, filter_replacement)
        @filter.push([filter_word, filter_replacement])
      end

      private

      def dump_headers(headers)
        return if headers.nil?

        headers.map { |k, v| "#{k}: #{v.inspect}" }.join("\n")
      end

      def dump_body(body)
        if body.respond_to?(:to_str)
          body.to_str.encode(::Encoding::UTF_8, undef: :replace, invalid: :replace)
        else
          pretty_inspect(body)
        end
      end

      def pretty_inspect(body)
        body.pretty_inspect
      end

      def log_headers?(type)
        case @options[:headers]
        when Hash
          @options[:headers][type]
        else
          @options[:headers]
        end
      end

      def log_body?(type)
        case @options[:bodies]
        when Hash
          @options[:bodies][type]
        else
          @options[:bodies]
        end
      end

      def log_errors?
        @options[:errors]
      end

      def apply_filters(output)
        @filter.each do |pattern, replacement|
          output = output.to_s.gsub(pattern, replacement)
        end
        output
      end

      def log_level
        @options[:log_level]
      end

      def build_redactors(redact)
        return {} unless redact

        unless redact.is_a?(Hash)
          raise ArgumentError, ':redact must be a Hash of redaction rules'
        end

        if (redact.keys & %i[request response]).any?
          {
            request: Redactor.new(redact[:request]),
            response: Redactor.new(redact[:response])
          }
        else
          shared = Redactor.new(redact)
          { request: shared, response: shared }
        end
      end

      def redactor_for(type)
        @redactors[type.to_sym == :request ? :request : :response]
      end

      def redacted_url(url)
        redactor = redactor_for(:request)
        redactor ? redactor.redact_url(url) : url.to_s
      end

      def content_type_from(headers)
        return if headers.nil?

        headers['Content-Type'] ||
          headers.find { |name, _| name.to_s.casecmp?('content-type') }&.last
      end

      def log_headers(type, headers)
        redactor = redactor_for(type)
        headers = redactor.redact_headers(headers) if redactor
        public_send(log_level) { "#{type}: #{apply_filters(dump_headers(headers))}" }
      end

      def log_body(type, body, content_type = nil)
        public_send(log_level) { "#{type}: #{apply_filters(dump_loggable_body(type, body, content_type))}" }
      end

      # Renders a body for the log without ever reading one-shot (IO-like)
      # bodies and without mutating the logged object.
      def dump_loggable_body(type, body, content_type)
        return Redactor::STREAM_BODY_NOTICE if body.respond_to?(:read)

        redactor = redactor_for(type)
        if body.respond_to?(:to_str)
          string = dump_body(body)
          redactor ? redactor.redact_body_string(string, content_type) : string
        else
          pretty_inspect(redactor ? redactor.redact_structured(body) : body)
        end
      end
    end
  end
end
