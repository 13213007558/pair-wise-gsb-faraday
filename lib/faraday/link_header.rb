# frozen_string_literal: true

require 'strscan'
require 'uri'

module Faraday
  # Parses RFC 8288 Link header fields without treating commas or semicolons
  # inside quoted strings as separators.
  module LinkHeader
    Parameter = Struct.new(:name, :value, :quoted, keyword_init: true) do
      def quoted?
        quoted
      end
    end

    Link = Struct.new(:target, :parameters, :base, keyword_init: true) do
      def uri
        resolve(target, context)
      end

      def context
        anchor ? resolve(anchor, base) : base
      end

      def anchor
        parameter(:anchor)&.value
      end

      def rel
        parameter(:rel)&.value
      end

      def rels
        parameters.select { |parameter_value| parameter_value.name.casecmp?('rel') }
                  .flat_map { |parameter_value| parameter_value.value.split(/[[:space:]]+/) }
                  .reject(&:empty?)
      end

      def rev
        parameter(:rev)&.value
      end

      def type
        parameter(:type)&.value
      end

      def title
        parameter(:title)&.value
      end

      def title_star
        parameter('title*')&.value
      end

      def parameter(name)
        parameters.find { |parameter_value| parameter_value.name.casecmp?(name.to_s) }
      end

      def [](name)
        parameter(name)&.value
      end

      def extension_parameters
        parameters.reject do |parameter_value|
          %w[rel rev anchor type title title* hreflang media].include?(
            parameter_value.name.downcase
          )
        end
      end

      def to_h
        {
          target: target,
          parameters: parameters.map { |parameter_value| [parameter_value.name, parameter_value.value] },
          uri: uri,
          context: context
        }
      end

      private

      def resolve(reference, context_uri)
        return if reference.nil? || context_uri.nil?

        URI.join(Utils.URI(context_uri), reference)
      end
    end

    module_function

    def parse(header_value, base: nil)
      return [] if header_value.nil?

      header_values = header_value.is_a?(Array) ? header_value : [header_value]
      base_uri = base.nil? ? nil : Utils.URI(base)
      header_values.flat_map { |value| parse_field(value.to_s, base_uri) }
    end

    def parse_field(header_value, base)
      links = []
      scanner = StringScanner.new(header_value)

      until scanner.eos?
        skip_whitespace(scanner)
        break if scanner.eos?

        target = parse_target(scanner)
        parameters = parse_parameters(scanner)
        links << Link.new(target: target, parameters: parameters, base: base)

        skip_whitespace(scanner)
        break if scanner.eos?
        raise Faraday::ParsingError, 'invalid Link header' unless scanner.scan(',')
      end

      links
    end

    def parse_target(scanner)
      raise Faraday::ParsingError, 'invalid Link header' unless scanner.scan('<')

      target = scanner.scan(/[^>]*/).to_s
      closing_bracket = scanner.get_byte
      raise Faraday::ParsingError, 'invalid Link header' unless closing_bracket == '>'

      target
    end

    def parse_parameters(scanner)
      parameters = []

      loop do
        skip_whitespace(scanner)
        break unless scanner.scan(';')

        skip_whitespace(scanner)
        name = scanner.scan(/[!#$%&'*+.^`|~0-9A-Za-z_-]+/)
        raise Faraday::ParsingError, 'invalid Link header' if name.nil? || name.empty?

        value, quoted = parse_parameter_value(scanner)
        parameters << Parameter.new(name: name, value: value, quoted: quoted)
      end

      parameters
    end

    def parse_parameter_value(scanner)
      skip_whitespace(scanner)
      return [nil, false] unless scanner.scan('=')

      skip_whitespace(scanner)
      if scanner.scan(/"/)
        [parse_quoted_value(scanner), true]
      else
        value = scanner.scan(/[^,;[:space:]]*/)
        [value, false]
      end
    end

    def parse_quoted_value(scanner)
      value = +''

      until scanner.scan(/"/)
        raise Faraday::ParsingError, 'invalid Link header' if scanner.eos?

        if scanner.scan(/\\/)
          character = scanner.get_byte
          raise Faraday::ParsingError, 'invalid Link header' if character.nil?

          value << character
        else
          value << scanner.scan(/[^\\"]+/).to_s
        end
      end

      value
    end

    def skip_whitespace(scanner)
      scanner.scan(/[[:space:]]*/)
    end

    private_class_method :parse_field, :parse_target, :parse_parameters,
                         :parse_parameter_value, :parse_quoted_value,
                         :skip_whitespace
  end
end
