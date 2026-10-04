# frozen_string_literal: true

module Faraday
  class DownloadSession
    # Incremental parser for multipart/byteranges responses.
    class MultipartParser
      CRLF = "\r\n".b.freeze
      DASHES = '--'.b.freeze

      Part = Struct.new(:on_headers_callback, :on_data_callback, :on_end_callback, :state) do
        def on_headers(&block)
          self.on_headers_callback = block
        end

        def on_data(&block)
          self.on_data_callback = block
        end

        def on_end(&block)
          self.on_end_callback = block
        end
      end

      def self.boundary(content_type)
        match = /(?:\A|;)\s*boundary="?([\x21-\x7e&&[^"]]+)"?\s*(?:;|\z)/n.match(content_type.to_s)
        raise Faraday::RangeError, 'missing multipart boundary' unless match

        match[1]
      end

      def initialize(boundary, &part_configurator)
        @boundary = "--#{boundary}".b
        @body_marker = CRLF + @boundary
        @part_configurator = part_configurator
        @buffer = +''.b
        @state = :preamble
        @part = nil
        @part_count = 0
      end

      def feed(chunk)
        return if chunk.nil? || chunk.empty?

        @buffer << chunk.to_s.b
        advance while drain
      end

      def finish
        feed(nil)
        raise Faraday::RangeError, 'truncated multipart/byteranges response' unless @state == :done
      end

      private

      def advance
        case @state
        when :preamble then parse_preamble
        when :headers then parse_headers
        when :body then parse_body
        when :epilogue then parse_epilogue
        else false
        end
      end

      def parse_preamble
        position = @buffer.index(@boundary)
        return false unless position

        kind = suffix_kind(position + @boundary.bytesize, allow_newline: true)
        return false if kind == :incomplete
        raise Faraday::RangeError, 'invalid multipart boundary' unless kind == :boundary

        consume(position + @boundary.bytesize + CRLF.bytesize)
        start_part
      end

      def parse_headers
        position = @buffer.index(CRLF + CRLF)
        return false unless position

        headers = @buffer.byteslice(0, position)
                      .split(CRLF)
                      .map(&:strip)
                      .reject(&:empty?)
                      .each_with_object({}) do |line, result|
                          match = /\A([\x21-\x39\x3b-\x7e]+):[ \t]*(.*?)[ \t]*\z/n.match(line)
                          raise Faraday::RangeError, %(invalid multipart header: #{line}) unless match

                          result[match[1].downcase] = match[2]
                        end
        consume(position + CRLF.bytesize * 2)
        @part.on_headers_callback.call(headers, @part)
        @state = :body
      end

      def parse_body
        position = @buffer.index(@body_marker)
        unless position
          safe = [@buffer.bytesize - @body_marker.bytesize + 1, 0].max
          emit(safe) if safe.positive?
          return false
        end

        kind = suffix_kind(position + @body_marker.bytesize, allow_newline: false)
        if kind == :incomplete
          emit(position)
          return false
        end

        if kind == :invalid
          emit(position + 1)
          return true
        end

        emit(position)
        if kind == :boundary
          consume(@body_marker.bytesize + CRLF.bytesize)
          @part.on_end_callback.call(@part)
          start_part
        else
          consume(@body_marker.bytesize + DASHES.bytesize)
          @part.on_end_callback.call(@part)
          @part = nil
          @state = :epilogue
        end
      end

      def parse_epilogue
        if @buffer.empty? || @buffer == CRLF
          @buffer.clear
          @state = :done
          return true
        end
        return false if @buffer == CRLF.byteslice(0, 1)

        raise Faraday::RangeError, 'invalid multipart epilogue' unless @buffer.start_with?(CRLF)

        consume(CRLF.bytesize)
        @state = :done if @buffer.empty?
        true
      end

      def suffix_kind(position, allow_newline:)
        suffix = @buffer[position..]
        return :incomplete if suffix.nil? || suffix.empty?
        return :incomplete if suffix == CRLF.byteslice(0, 1)
        return :incomplete if !allow_newline && (suffix == '-' || suffix == DASHES || suffix == DASHES + CRLF.byteslice(0, 1))
        return :boundary if suffix.start_with?(CRLF)
        return :close if suffix == DASHES || suffix.start_with?(DASHES + CRLF)

        :invalid
      end

      def start_part
        @part = Part.new
        @part_configurator.call(@part)
        @part_count += 1
        @state = :headers
      end

      def emit(length)
        return unless length.positive?

        @part.on_data_callback.call(@buffer.byteslice(0, length), @part)
        consume(length)
      end

      def consume(length)
        @buffer = length >= @buffer.bytesize ? +''.b : @buffer[length..]
      end
    end
  end
end
