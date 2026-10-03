# frozen_string_literal: true

module Faraday
  module OData
    # Binary-safe parser for multipart/mixed and application/http payloads.
    class MultipartParser
      Part = Struct.new(:headers, :body, keyword_init: true)
      Message = Struct.new(:version, :status, :reason, :headers, :body, keyword_init: true)

      def self.parts(body, boundary)
        new.parts(body, boundary)
      end

      def self.http(message)
        new.http(message)
      end

      def self.content_type(content_type)
        new.content_type(content_type)
      end

      def parts(body, boundary)
        bytes = read_binary(body)
        delimiter = "--#{boundary}"
        positions = find_boundaries(bytes, delimiter)
        raise ProtocolError, "multipart response has no boundary #{boundary.inspect}" if positions.empty?

        positions.each_cons(2).filter_map do |start_position, end_position|
          start = start_position + delimiter.bytesize
          bytes.byteslice(start, 2) == "--".b ? nil : parse_part(bytes, start, end_position)
        end
      end

      def http(message)
        bytes = read_binary(message)
        separator = "\r\n\r\n".b
        header_end = bytes.index(separator)
        raise ProtocolError, 'application/http part is missing its header terminator' unless header_end

        header_block = bytes.byteslice(0, header_end).b
        body = bytes.byteslice(header_end + separator.bytesize, bytes.bytesize) || +''.b
        lines = header_block.split("\r\n".b)
        status_line = lines.shift.to_s
        match = status_line.match(%r{\AHTTP/(\d(?:\.\d)?)[ \t]+(\d{3})(?:[ \t]+([^\r]*))?\r?\z})
        raise ProtocolError, "invalid application/http status line: #{status_line.inspect}" unless match

        Message.new(
          version: match[1],
          status: Integer(match[2], 10),
          reason: match[3].to_s,
          headers: parse_headers(lines),
          body: body.b
        )
      end

      def content_type(value)
        result = { media_type: nil, params: Faraday::Utils::Headers.new }
        return result if value.nil? || value.to_s.strip.empty?

        segments = value.to_s.split(';').map(&:strip)
        result[:media_type] = segments.shift.to_s.downcase
        segments.each do |segment|
          name, parameter_value = segment.split('=', 2)
          next if name.nil? || name.empty?

          result[:params][name.strip.downcase] = unquote(parameter_value.to_s)
        end
        result
      end

      private

      def find_boundaries(bytes, delimiter)
        positions = []
        offset = 0

        while (position = bytes.index(delimiter.b, offset))
          after = position + delimiter.bytesize
          if valid_boundary?(bytes, position, after)
            positions << position
            offset = after
          else
            offset = position + 1
          end
        end
        positions
      end

      def valid_boundary?(bytes, position, after)
        starts_part = position.zero? || bytes.byteslice(position - 2, 2) == OData::CRLF.b
        suffix = bytes.byteslice(after, 2)
        starts_part && (suffix == OData::CRLF.b || suffix == '--'.b)
      end

      def parse_part(bytes, content_start, next_boundary)
        content = bytes.byteslice(content_start, next_boundary - content_start).to_s.b
        content = content.sub(%r{\A(?:\r\n|\n){0,2}}.freeze, ''.b)
        content = content.sub(%r{\r\n\z}.freeze, ''.b)
        separator = "\r\n\r\n".b
        header_end = content.index(separator)
        raise ProtocolError, 'multipart part is missing its header terminator' unless header_end

        Part.new(
          headers: parse_headers(content.byteslice(0, header_end).split("\r\n".b)),
          body: content.byteslice(header_end + separator.bytesize, content.bytesize).to_s.b
        )
      end

      def parse_headers(lines)
        headers = Faraday::Utils::Headers.new
        lines.each do |line|
          name, value = line.split(':'.b, 2)
          next if name.nil? || value.nil?

          value = value.sub(%r{\A[ \t]+}.freeze, ''.b).sub(%r{[ \t]+\z}.freeze, ''.b)
          headers[name.force_encoding(Encoding::UTF_8)] = value
        end
        headers
      end

      def unquote(value)
        return value[1...-1] if value.length >= 2 && value.start_with?('"') && value.end_with?('"')

        value
      end

      def read_binary(value)
        value.is_a?(IO) ? value.read.to_s.b : value.to_s.b
      end
    end
  end
end
