# frozen_string_literal: true

class Faraday::ResumableDownload
  # Streaming multipart/byteranges parser. It only retains bytes that can still
  # be a delimiter prefix, so delimiter-like bytes inside a part are emitted.
  #
  # @api private
  class MultipartParser
    def self.boundary(content_type)
      match = content_type&.match(/boundary=(?:"((?:[^"\\]|\\.)*)"|([^;]+))/i)
      raise InvalidResponse, 'multipart response is missing a boundary' unless match

      (match[1] || match[2]).strip.dup.force_encoding(Encoding::BINARY)
    end

    def initialize(boundary, on_headers:, on_body:)
      @boundary = boundary.dup.force_encoding(Encoding::BINARY)
      @on_headers = on_headers
      @on_body = on_body
      @buffer = +''.b
      @state = :start
      @finished = false
    end

    def call(chunk)
      @buffer << chunk.to_s.dup.force_encoding(Encoding::BINARY)
      drain
      self
    end

    def finish
      drain
      return if @finished

      raise InvalidResponse, 'multipart response ended before the closing boundary'
    end

    private

    def drain
      loop do
        previous_state = @state
        previous_size = @buffer.bytesize
        step
        break if @finished
        break if @state == previous_state && @buffer.bytesize >= previous_size
      end
    end

    def step
      case @state
      when :start then read_first_boundary
      when :after_first_boundary then read_first_suffix
      when :first_headers then read_headers
      when :body then read_body
      when :after_part_boundary then read_after_part_boundary
      when :part_headers then read_part_headers
      end
    end

    def read_first_boundary
      index = @buffer.index(first_delimiter)
      return unless index

      @buffer = @buffer.byteslice(index + first_delimiter.bytesize, @buffer.bytesize) || +''.b
      @state = :after_first_boundary
    end

    def read_first_suffix
      if @buffer.start_with?('--')
        @finished = true
        @buffer = +''.b
      elsif @buffer.start_with?("\r\n")
        @buffer = from(2)
        @state = :first_headers
      elsif suffix_possible?
        nil
      else
        raise InvalidResponse, 'invalid multipart boundary delimiter'
      end
    end

    def read_headers
      index = @buffer.index("\r\n\r\n")
      return unless index

      @on_headers.call(parse_headers(@buffer.byteslice(0, index)))
      @buffer = from(index + 4)
      @state = :body
    end

    def read_body
      index = @buffer.index(part_boundary)
      if index
        @on_body.call(@buffer.byteslice(0, index))
        @buffer = from(index + part_boundary.bytesize)
        @state = :after_part_boundary
        return
      end

      safe_size = [@buffer.bytesize - part_boundary.bytesize + 1, 0].max
      return if safe_size.zero?

      @on_body.call(@buffer.byteslice(0, safe_size))
      @buffer = from(safe_size)
    end

    def read_after_part_boundary
      if @buffer.start_with?('--')
        @finished = true
        @buffer = +''.b
      else
        return if @buffer.empty?
        return if @buffer == '-'

        index = @buffer.index(header_end)
        return unless index

        @state = :part_headers
      end
    end

    def read_part_headers
      index = @buffer.index(header_end)
      return unless index

      @on_headers.call(parse_headers(@buffer.byteslice(0, index)))
      @buffer = from(index + header_end.bytesize)
      @state = :body
    end

    def suffix_possible?
      return true if @buffer.empty?
      return true if @buffer == "\r" || @buffer == '-'

      false
    end

    def parse_headers(block)
      block.split("\r\n").each_with_object({}) do |line, headers|
        name, value = line.split(':', 2)
        next unless value

        headers[name.downcase] = value.strip
      end
    end

    def from(offset)
      @buffer.byteslice(offset, @buffer.bytesize - offset) || +''.b
    end

    def first_delimiter
      @first_delimiter ||= +"--#{@boundary}".b
    end

    def part_boundary
      @part_boundary ||= +"\r\n--#{@boundary}".b
    end

    def header_end
      @header_end ||= +"\r\n\r\n".b
    end

  end
end
