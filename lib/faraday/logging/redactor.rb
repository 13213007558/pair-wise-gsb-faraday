# frozen_string_literal: true

require 'json'
require 'uri'
require 'faraday/utils'

module Faraday
  module Logging
    # Redacts sensitive values from the data logged by
    # Faraday::Logging::Formatter.
    #
    # Rules can target header names, URL query keys, form-encoded body keys
    # and JSON paths, and can be scoped per direction (request/response).
    # Redaction is always applied to a copy of the logged data, never to the
    # objects stored in the Faraday environment, so the request and response
    # passed through the adapter are left untouched.
    #
    # @example
    #   redactor = Faraday::Logging::Redactor.new(
    #     headers: %w[Authorization],
    #     query: %w[token],
    #     form: %w[password],
    #     json: ['$.user.password', '$.phones[*]']
    #   )
    class Redactor
      DEFAULT_REPLACEMENT = '[REDACTED]'
      STREAM_BODY_NOTICE = '[stream body omitted: not read for logging]'
      UNPARSABLE_QUERY_NOTICE = '[query omitted: could not be parsed for redaction]'
      FORM_MIME = 'application/x-www-form-urlencoded'
      JSON_MIME = 'application/json'

      attr_reader :replacement

      # @param rules [Hash, nil] redaction rules. Supported keys:
      #   :headers [Array<#to_s>] header names (case-insensitive)
      #   :query [Array<#to_s>] URL query keys
      #   :form [Array<#to_s>] form-encoded body keys
      #   :json [Array<#to_s>] JSON paths (e.g. '$.user.password', '$.phones[*]')
      #   :replacement [String] replacement text, defaults to DEFAULT_REPLACEMENT
      def initialize(rules = nil)
        rules ||= {}
        @replacement = rules[:replacement] || DEFAULT_REPLACEMENT
        @header_names = Array(rules[:headers]).map { |name| name.to_s.downcase }
        @query_keys = Array(rules[:query]).map { |key| key_segments(key) }
        @form_keys = Array(rules[:form]).map { |key| key_segments(key) }
        @json_paths = Array(rules[:json]).map { |path| self.class.parse_json_path(path) }
      end

      # @return [Boolean] true when no redaction rule is configured
      def empty?
        @header_names.empty? && @query_keys.empty? &&
          @form_keys.empty? && @json_paths.empty?
      end

      # Returns redacted header pairs without mutating the given headers.
      #
      # @param headers [#each] header collection
      # @return [Array<Array>] array of [name, value] pairs
      def redact_headers(headers)
        return headers if headers.nil? || @header_names.empty?

        headers.map do |name, value|
          @header_names.include?(name.to_s.downcase) ? [name, @replacement] : [name, value]
        end
      end

      # Returns a copy of the URL with sensitive query values redacted.
      # Repeated keys and nested arrays (e.g. +phones[]=1&phones[]=2+) are
      # covered. When the query cannot be parsed, the query string is
      # replaced with a restricted notice instead of being logged raw.
      #
      # @param url [#to_s] the URL to redact
      # @return [String] the redacted URL
      def redact_url(url)
        str = url.to_s
        return str if @query_keys.empty?

        path, separator, rest = str.partition('?')
        return str if separator.empty?

        query, hash, fragment = rest.partition('#')
        path + separator + redact_query_string(query, @query_keys) + hash + fragment
      rescue StandardError
        "#{str.split('?', 2).first}?#{UNPARSABLE_QUERY_NOTICE}"
      end

      # Redacts form keys in an URL-encoded body string.
      #
      # @param body [String] the form-encoded body
      # @return [String, nil] the redacted body, or nil when parsing failed
      def redact_form_string(body)
        redact_query_string(body, @form_keys)
      rescue StandardError
        nil
      end

      # Redacts the configured JSON paths in a JSON body string.
      #
      # @param body [String] the JSON body
      # @return [String, nil] the redacted body, or nil when parsing failed
      def redact_json_string(body)
        data = JSON.parse(body)
        redact_json!(data)
        JSON.generate(data)
      rescue JSON::ParserError, TypeError
        nil
      end

      # Redacts a string body based on its content type. When the body
      # cannot be parsed, a restricted notice is returned instead of the
      # raw (potentially sensitive) content.
      #
      # @param body [String] the body to redact
      # @param content_type [String, nil] the body content type
      # @return [String] the redacted body or a restricted notice
      def redact_body_string(body, content_type)
        if !@form_keys.empty? && self.class.form_content_type?(content_type)
          redact_form_string(body) || unparsable_body_notice('form')
        elsif !@json_paths.empty? && self.class.json_content_type?(content_type)
          redact_json_string(body) || unparsable_body_notice('JSON')
        else
          body
        end
      end

      # Returns a redacted deep copy of a structured (Hash/Array) body,
      # applying both form keys and JSON paths. The given body is not
      # modified.
      #
      # @param body [Object] the structured body
      # @return [Object] the redacted copy
      def redact_structured(body)
        copy = deep_copy(body)
        redact_params!(copy, @form_keys) unless @form_keys.empty?
        redact_json!(copy) unless @json_paths.empty?
        copy
      end

      # Parses a limited JSONPath expression into segments.
      # Supported syntax: '$.key', 'key', '$.a.b', '$.a[0]', '$.a[*]',
      # '$.a[*].b'. A leading '$' is optional.
      #
      # @param path [#to_s] the JSONPath expression
      # @return [Array<String, Integer, Symbol>] the path segments
      def self.parse_json_path(path)
        str = path.to_s.strip.sub(/\A\$\.?/, '')
        return [] if str.empty?

        str.split('.').flat_map { |segment| parse_json_path_segment(segment) }
      end

      def self.form_content_type?(content_type)
        mime_type(content_type) == FORM_MIME
      end

      def self.json_content_type?(content_type)
        mime = mime_type(content_type)
        mime == JSON_MIME || (!mime.nil? && mime.end_with?('+json'))
      end

      def self.mime_type(content_type)
        mime = content_type.to_s.split(';', 2).first.to_s.strip.downcase
        mime.empty? ? nil : mime
      end

      def self.parse_json_path_segment(segment)
        match = segment.match(/\A([^\[\]]*)((?:\[[^\]]*\])*)\z/)
        return [segment] unless match

        parts = []
        parts << match[1] unless match[1].empty?
        match[2].scan(/\[([^\]]*)\]/).each do |(index)|
          parts << (index == '*' ? :* : index.to_i)
        end
        parts
      end

      private

      # Splits a key rule into segments, so both 'password' and
      # 'user[password]' style rules can be matched against nested keys.
      def key_segments(key)
        key.to_s.scan(/[^\[\]]+/)
      end

      # Redacts values of matching keys in an URL-encoded string, pair by
      # pair. Every bracket segment of a key is matched (e.g. +password+
      # matches +password+, +user[password]+ and +phones[]+ style keys), so
      # repeated keys and nested arrays are all covered while the rest of
      # the string (order, separators, encoding) is preserved for
      # debugging.
      def redact_query_string(query, keys)
        query.to_s.split(/([&;] *)/n).map do |pair|
          redact_query_pair(pair, keys)
        end.join
      end

      def redact_query_pair(pair, keys)
        return pair if pair.empty? || pair.start_with?('&', ';')

        key = pair.partition('=').first
        segments = Faraday::Utils.unescape(key).scan(/[^\[\]]+/)
        return pair unless keys.any? { |rule| (rule - segments).empty? }

        "#{key}=#{@replacement}"
      end

      def redact_params!(params, keys)
        case params
        when Hash
          params.each do |key, value|
            if keys.any? { |rule| rule.include?(key.to_s) }
              params[key] = redact_value(value)
            else
              redact_params!(value, keys)
            end
          end
        when Array
          params.each { |element| redact_params!(element, keys) }
        end
        params
      end

      def redact_json!(data)
        @json_paths.each { |segments| apply_json_path(data, segments) }
        data
      end

      def apply_json_path(node, segments)
        return if segments.empty?

        segment = segments.first
        rest = segments[1..]
        case node
        when Hash
          apply_json_path_to_hash(node, segment, rest)
        when Array
          apply_json_path_to_array(node, segment, rest)
        end
      end

      def apply_json_path_to_hash(hash, segment, rest)
        return unless segment.is_a?(String)

        key = hash.key?(segment) ? segment : segment.to_sym
        return unless hash.key?(key)

        if rest.empty?
          hash[key] = redact_value(hash[key])
        else
          apply_json_path(hash[key], rest)
        end
      end

      def apply_json_path_to_array(array, segment, rest)
        case segment
        when :*
          array.each_index do |index|
            if rest.empty?
              array[index] = redact_value(array[index])
            else
              apply_json_path(array[index], rest)
            end
          end
        when Integer
          return if segment >= array.length

          if rest.empty?
            array[segment] = redact_value(array[segment])
          else
            apply_json_path(array[segment], rest)
          end
        end
      end

      # Replaces every scalar leaf with the replacement, preserving the
      # shape of Hashes and Arrays so logs keep their debugging value.
      def redact_value(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), hash| hash[k] = redact_value(v) }
        when Array
          value.map { |element| redact_value(element) }
        else
          @replacement
        end
      end

      def deep_copy(object)
        case object
        when Hash
          object.each_with_object({}) { |(k, v), hash| hash[k] = deep_copy(v) }
        when Array
          object.map { |element| deep_copy(element) }
        else
          object
        end
      end

      def unparsable_body_notice(kind)
        "[body omitted: could not parse #{kind} body for redaction]"
      end
    end
  end
end
