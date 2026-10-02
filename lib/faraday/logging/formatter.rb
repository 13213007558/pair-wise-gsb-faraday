# frozen_string_literal: true

require 'pp' # This require is necessary for Hash#pretty_inspect to work, do not remove it, people rely on it.
require 'json'
require 'uri'

module Faraday
  module Logging
    # Serves as an integration point to customize logging
    class Formatter
      extend Forwardable

      DEFAULT_OPTIONS = { headers: true, bodies: false, errors: false,
                          log_level: :info }.freeze

      # Placeholder written in place of any redacted value.
      DEFAULT_REDACTED = '[REDACTED]'
      # Logged instead of a body that cannot be safely inspected.
      ONE_SHOT_BODY_NOTICE = '[body not logged: one-shot stream]'
      UNPARSEABLE_BODY_NOTICE = '[body not logged: unparseable, withheld for safety]'
      REDACT_KINDS = %i[header query form json].freeze
      REDACT_PHASES = %i[request response].freeze
      INVALID_PERCENT_ENCODING = /%(?![0-9A-Fa-f]{2})/.freeze

      def initialize(logger:, options:)
        @logger = logger
        @options = DEFAULT_OPTIONS.merge(options)
        unless %i[debug info warn error fatal].include?(@options[:log_level])
          @options[:log_level] = :info
        end
        @filter = []
        @redactions = REDACT_PHASES.to_h do |phase|
          [phase, REDACT_KINDS.to_h { |kind| [kind, []] }]
        end
      end

      def_delegators :@logger, :debug, :info, :warn, :error, :fatal

      def request(env)
        public_send(log_level) do
          "request: #{env.method.upcase} #{apply_filters(redact_url(env.url.to_s, :request))}"
        end

        log_headers('request', env.request_headers) if log_headers?(:request)
        log_body('request', env[:body], content_type_from(env.request_headers)) if env[:body] && log_body?(:request)
      end

      def response(env)
        public_send(log_level) { "response: Status #{env.status}" }

        log_headers('response', env.response_headers) if log_headers?(:response)
        log_body('response', env[:body], content_type_from(env.response_headers)) if env[:body] && log_body?(:response)
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

      # Registers a structured redaction rule. Redaction is applied to log
      # copies only; the env, headers, URL and body passed to the adapter are
      # never mutated.
      #
      # kind:    :header (header name), :query (URL query key),
      #          :form (urlencoded body key) or :json (JSON path like
      #          '$.users[*].phone' or '$..token')
      # on:      :request, :response or an array of both (default: both)
      # pattern: the header name, key or JSON path to match
      def redact(kind, pattern, on: REDACT_PHASES, replacement: DEFAULT_REDACTED)
        kind = kind.to_sym
        unless REDACT_KINDS.include?(kind)
          raise ArgumentError, "unknown redaction kind #{kind.inspect}, expected one of: #{REDACT_KINDS.join(', ')}"
        end

        phases = Array(on).map(&:to_sym)
        unknown = phases - REDACT_PHASES
        raise ArgumentError, "unknown redaction phase(s): #{unknown.join(', ')}" unless unknown.empty?

        pattern = tokenize_json_path(pattern) if kind == :json
        phases.each { |phase| @redactions[phase][kind] << [pattern, replacement] }
        self
      end

      private

      def phase_for(type)
        type.to_s == 'error' ? :response : type.to_s.to_sym
      end

      def content_type_from(headers)
        return nil unless headers

        headers['Content-Type'] || headers['content-type'] ||
          headers.find { |key, _| key.to_s.casecmp('content-type').zero? }&.last
      end

      def dump_headers(headers, phase)
        return if headers.nil?

        rules = @redactions[phase][:header]
        headers.map do |key, value|
          rule = rules.find { |name, _| name.to_s.casecmp(key.to_s).zero? }
          "#{key}: #{(rule ? rule[1] : value).inspect}"
        end.join("\n")
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

      def log_headers(type, headers)
        public_send(log_level) { "#{type}: #{apply_filters(dump_headers(headers, phase_for(type)))}" }
      end

      def log_body(type, body, content_type = nil)
        log_copy = redact_body_copy(phase_for(type), body, content_type)
        public_send(log_level) { "#{type}: #{apply_filters(dump_body(log_copy))}" }
      end

      # Builds a redacted copy of the body for logging. The original body
      # object is never mutated or, in the case of one-shot streams, read.
      def redact_body_copy(phase, body, content_type)
        return ONE_SHOT_BODY_NOTICE if stream_like?(body)

        json_rules = @redactions[phase][:json]
        form_rules = @redactions[phase][:form]
        return body if json_rules.empty? && form_rules.empty?

        if body.is_a?(Hash) || body.is_a?(Array)
          return json_rules.empty? ? body : redact_json_structure(body, json_rules)
        end

        return body unless body.respond_to?(:to_str)

        text = body.to_str
        if !json_rules.empty? && json_body?(content_type, text)
          redact_json_text(text, json_rules)
        elsif !form_rules.empty? && form_body?(content_type, text)
          redact_form_text(text, form_rules)
        else
          body
        end
      end

      def stream_like?(body)
        body.respond_to?(:read) && !body.respond_to?(:to_str)
      end

      def json_body?(content_type, text)
        return content_type.include?('json') if content_type

        text.lstrip.start_with?('{', '[')
      end

      def form_body?(content_type, text)
        return content_type.include?('x-www-form-urlencoded') if content_type

        text.include?('=') && !text.lstrip.start_with?('{', '[')
      end

      def redact_url(url, phase)
        rules = @redactions[phase][:query]
        return url if rules.empty?

        query_start = url.index('?')
        return url unless query_start

        fragment_start = url.index('#', query_start)
        query = url[(query_start + 1)...(fragment_start || url.length)]
        redacted = redact_query_string(query, rules)
        return url if redacted == query

        fragment = fragment_start ? url[fragment_start..] : ''
        "#{url[0...query_start]}?#{redacted}#{fragment}"
      end

      def redact_form_text(text, rules)
        return UNPARSEABLE_BODY_NOTICE if text.match?(INVALID_PERCENT_ENCODING)

        redact_query_string(text, rules)
      end

      # Redacts every pair whose key matches a rule, preserving repeated
      # keys, order and the original encoding of untouched pairs.
      def redact_query_string(data, rules)
        data.split('&').map do |pair|
          key, separator, = pair.partition('=')
          rule = rules.find { |name, _| name.to_s == decode_component(key) }
          rule ? "#{key}#{separator}#{rule[1]}" : pair
        end.join('&')
      end

      def decode_component(str)
        URI.decode_www_form_component(str)
      rescue ArgumentError
        str
      end

      def redact_json_text(text, rules)
        parsed = JSON.parse(text)
        JSON.generate(apply_json_rules(parsed, rules))
      rescue JSON::ParserError, EncodingError
        UNPARSEABLE_BODY_NOTICE
      end

      def redact_json_structure(body, rules)
        apply_json_rules(deep_dup(body), rules)
      end

      def apply_json_rules(node, rules)
        rules.each do |tokens, replacement|
          if tokens.empty?
            node = replacement
          else
            apply_json_path(node, tokens, replacement)
          end
        end
        node
      end

      def deep_dup(node)
        case node
        when Hash
          node.each_with_object({}) { |(key, value), copy| copy[key] = deep_dup(value) }
        when Array
          node.map { |element| deep_dup(element) }
        else
          node
        end
      end

      # Supports a small JSONPath subset: $.key, $.key[0], $.key[*],
      # $..key (recursive descent) and $ (root).
      def tokenize_json_path(path)
        unless path.is_a?(String) && path.start_with?('$')
          raise ArgumentError, "invalid JSON path #{path.inspect}: must start with '$'"
        end

        tokens = []
        rest = path[1..]
        until rest.empty?
          case rest
          when /\A\.\.([A-Za-z0-9_-]+)/
            tokens << [:descendant, Regexp.last_match(1)]
          when /\A\.([A-Za-z0-9_-]+)/
            tokens << [:key, Regexp.last_match(1)]
          when /\A\[\*\]/
            tokens << [:wildcard]
          when /\A\[(\d+)\]/
            tokens << [:index, Regexp.last_match(1).to_i]
          else
            raise ArgumentError, "unsupported JSON path syntax in #{path.inspect}"
          end
          rest = Regexp.last_match.post_match
        end
        tokens
      end

      def apply_json_path(node, tokens, replacement)
        token = tokens.first
        rest = tokens[1..]

        case token[0]
        when :key
          apply_to_hash_key(node, token[1], rest, replacement)
        when :wildcard
          return unless node.is_a?(Array)

          node.each_index do |index|
            rest.empty? ? node[index] = replacement : apply_json_path(node[index], rest, replacement)
          end
        when :index
          return unless node.is_a?(Array) && node[token[1]]

          rest.empty? ? node[token[1]] = replacement : apply_json_path(node[token[1]], rest, replacement)
        when :descendant
          redact_descendant(node, token[1], rest, replacement)
        end
      end

      def apply_to_hash_key(node, key, rest, replacement)
        return unless node.is_a?(Hash)

        match = node.keys.find { |candidate| candidate.to_s == key }
        return if match.nil?

        rest.empty? ? node[match] = replacement : apply_json_path(node[match], rest, replacement)
      end

      def redact_descendant(node, key, rest, replacement)
        case node
        when Hash
          node.each do |node_key, value|
            if node_key.to_s == key
              rest.empty? ? node[node_key] = replacement : apply_json_path(value, rest, replacement)
            else
              redact_descendant(value, key, rest, replacement)
            end
          end
        when Array
          node.each { |element| redact_descendant(element, key, rest, replacement) }
        end
      end
    end
  end
end
