# frozen_string_literal: true

require 'strscan'
require 'uri'

module Faraday
  # RFC 8288 Link header field value.
  class Link
    TOKEN = /[!#$%&'*+.^_`|~0-9A-Za-z-]+/.freeze

    attr_reader :href, :relations, :rev, :anchor, :type, :title,
                :title_star, :hreflang, :media, :attributes

    def initialize(
      href:, relations: [], rev: [], anchor: nil, type: nil, title: nil,
      title_star: nil, hreflang: [], media: nil, attributes: [], base: nil
    )
      @href = href
      @relations = relations
      @rev = rev
      @anchor = anchor
      @type = type
      @title = title
      @title_star = title_star
      @hreflang = hreflang
      @media = media
      @attributes = attributes
      @base = base
    end

    def self.parse(value, base: nil)
      return [] if value.nil? || value.to_s.empty?

      Parser.new(value, base).parse
    end

    def context_uri
      return unless @base

      @context_uri ||= begin
        base_uri = Utils.URI(@base)
        anchor ? self.class.resolve(base_uri, anchor) : base_uri
      end
    end

    def target_uri
      return unless context_uri

      @target_uri ||= self.class.resolve(context_uri, href)
    end

    alias uri target_uri
    alias rel relations
    alias relation_types relations

    def relation
      relations.first
    end

    def extension_attributes
      attributes.reject { |name, _| registered?(name) }.map(&:dup)
    end

    def extension_parameters
      extension_attributes.each_with_object({}) do |(name, value), parameters|
        if parameters.key?(name)
          parameters[name] = Array(parameters[name]) << value
        else
          parameters[name] = value
        end
      end
    end

    def [](name)
      attribute = attributes.find { |attribute_name, _| attribute_name.casecmp?(name.to_s) }
      attribute&.last
    end

    def self.resolve(base, reference)
      URI.join(Utils.URI(base), reference.to_s)
    rescue URI::Error => e
      error = Faraday::ParsingError.new("invalid Link URI reference: #{e.message}")
      raise error, cause: e
    end

    def registered?(name)
      %w[rel rev anchor type title title* hreflang media].any? do |registered|
        registered.casecmp?(name)
      end
    end

    private :registered?

    class Parser
      def initialize(value, base)
        @scanner = StringScanner.new(value.to_s)
        @base = base
      end

      def parse
        links = []

        until scanner.eos?
          skip_ows
          break if scanner.eos?

          links << parse_link
          skip_ows
          next if scanner.eos?

          separator = scanner.get_byte
          unless separator == ','
            raise Faraday::ParsingError, 'malformed Link header: expected comma'
          end
        end

        links
      end

      private

      attr_reader :scanner

      def parse_link
        expect_byte('<')
        href = scanner.scan(/[^>]*/).to_s
        expect_byte('>')

        attributes = []
        skip_ows

        while scanner.scan(';')
          skip_ows
          attributes << parse_parameter
          skip_ows
        end

        build_link(href, attributes)
      end

      def parse_parameter
        name = scanner.scan(Link::TOKEN)
        raise Faraday::ParsingError, 'malformed Link header parameter' unless name

        skip_bws
        value = nil
        if scanner.scan('=')
          skip_bws
          value = parse_value
        end

        [name, value]
      end

      def parse_value
        if scanner.peek_byte == '"'.ord
          parse_quoted_string
        else
          scanner.scan(Link::TOKEN).tap do |value|
            raise Faraday::ParsingError, 'malformed Link header parameter value' if value.nil?
          end
        end
      end

      def parse_quoted_string
        expect_byte('"')
        value = +''

        loop do
          character = scanner.get_byte
          raise Faraday::ParsingError, 'unterminated quoted string' if character.nil?

          case character
          when '"'
            return value
          when '\\'
            escaped = scanner.get_byte
            raise Faraday::ParsingError, 'unterminated quoted pair' if escaped.nil?

            value << escaped
          else
            value << character
          end
        end
      end

      def build_link(href, attributes)
        grouped = attributes.each_with_object({}) do |(name, value), result|
          (result[name.downcase] ||= []) << value
        end

        Link.new(
          href: href,
          relations: tokens(grouped, 'rel'),
          rev: tokens(grouped, 'rev'),
          anchor: first_value(grouped, 'anchor'),
          type: first_value(grouped, 'type'),
          title: first_value(grouped, 'title'),
          title_star: first_value(grouped, 'title*'),
          hreflang: values(grouped, 'hreflang'),
          media: first_value(grouped, 'media'),
          attributes: attributes,
          base: @base
        )
      end

      def tokens(grouped, name)
        values(grouped, name).flat_map { |value| value.to_s.split(/[ \t]+/) }
      end

      def values(grouped, name)
        grouped.fetch(name, []).compact
      end

      def first_value(grouped, name)
        grouped.fetch(name, []).first
      end

      def skip_ows
        scanner.skip(/[ \t]*/)
      end

      def skip_bws
        scanner.skip(/[ \t]*/)
      end

      def expect_byte(byte)
        actual = scanner.get_byte
        unless actual == byte
          raise Faraday::ParsingError, "malformed Link header: expected #{byte.inspect}"
        end
      end
    end
  end
end
