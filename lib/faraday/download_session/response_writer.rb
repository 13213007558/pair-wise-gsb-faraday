# frozen_string_literal: true

module Faraday
  class DownloadSession
    # Validates and writes one HTTP response back into the target IO.
    class ResponseWriter
      CONTENT_RANGE = /\Abytes (\d+)-(\d+)\/(?:(\d+)|\*)\z/.freeze
      UNSATISFIABLE_TOTAL = /\Abytes \*\/(\d+)\z/.freeze
      BINARY = Encoding::BINARY

      def initialize(session, request, status, headers)
        @session = session
        @request = request
        @status = Integer(status)
        @headers = headers
        @finished = false
        @received = 0
        @content_length = nil
        @multipart = nil
        @part = nil
        @part_received = 0
        @part_written = 0
        @part_start = nil
        @part_last = nil
        @single_state = { start: 0, last: -1, written: 0 }
        @verified_ranges = []
        configure_response
      end

      def data(chunk)
        chunk = normalize_chunk(chunk)
        return if @finished

        if chunk.empty?
          finish
          return
        end

        @received += chunk.bytesize
        ensure_within_content_length
        if @multipart
          @multipart.feed(chunk)
        elsif @mode == :full
          @session.write_full(@received - chunk.bytesize, chunk)
        else
          write_part_data(chunk, @single_state)
        end
      end

      def finish
        return @result if @finished
        raise @unsatisfiable_error if @unsatisfiable_error

        @result = if @multipart
          ensure_multipart_content_length
          @multipart.finish
          @session.complete_request(@request)
        elsif @mode == :full
          @session.commit_full(@request)
        else
          finish_single_range
          @session.commit_range(@part_start, @part_last, @request, @verified_ranges)
        end

        @finished = true
        @result = @session.complete_request(@request)
      end

      private

      def configure_response
        etag = @status == 416 ? nil : @session.validated_etag(etag_header)
        case @status
        when 200
          configure_full(etag)
        when 206
          configure_partial(etag)
        when 412
          @session.validator_mismatch!(etag_header)
        when 416
          return handle_unsatisfiable
        else
          raise Faraday::Error, "unexpected response status #{@status}"
        end
      end

      def configure_full(etag)
        if etag != @session.etag
          raise Faraday::ValidatorMismatchError,
                "expected ETag #{@session.etag.inspect}, received #{etag.inspect}"
        end

        @mode = :full
        @content_length = integer_header('Content-Length')
        if @content_length && @content_length != @session.size
          raise Faraday::RangeError, 'complete response length differs from target size'
        end
      end

      def configure_partial(etag)
        if etag != @session.etag
          raise Faraday::ValidatorMismatchError,
                "expected ETag #{@session.etag.inspect}, received #{etag.inspect}"
        end

        if content_range_header
          configure_single_range
        else
          configure_multipart
        end
      end

      def configure_single_range
        @mode = :range
        start, last, total = parse_content_range(content_range_header)
        validate_total(total)
        @part_start = start
        @part_last = last
        @single_state = { start: start, last: last, written: 0 }
        @content_length = integer_header('Content-Length')
        @declared_length = last - start + 1
        if @content_length && @content_length != @declared_length
          raise Faraday::RangeError, 'Content-Length differs from Content-Range length'
        end
      end

      def configure_multipart
        content_type = header('Content-Type').to_s
        unless content_type.downcase.start_with?('multipart/byteranges')
          raise Faraday::RangeError, '206 response must include Content-Range or multipart/byteranges'
        end

        @mode = :multipart
        if content_length_header?
          @multipart_content_length = integer_header('Content-Length')
        end
        boundary = MultipartParser.boundary(content_type)
        @multipart = MultipartParser.new(boundary) { |part| configure_part_callbacks(part) }
      end

      def configure_part_callbacks(part)
        state = { start: nil, last: nil, written: 0 }
        part.state = state
        part.on_headers do |headers, callback_part|
          start, last, total = parse_content_range(headers['content-range'])
          validate_total(total)
          callback_part.state = { start: start, last: last, written: 0 }
        end
        part.on_data { |chunk, callback_part| write_part_data(chunk, callback_part.state) }
        part.on_end { |*args| finish_part((args.first || part).state) }
      end

      def handle_unsatisfiable
        content_range = content_range_header
        if content_range
          match = UNSATISFIABLE_TOTAL.match(content_range)
          validate_total(match && match[1] && Integer(match[1]))
        end

        @unsatisfiable_error = @session.unsatisfiable_request!(@request)
      end

      def write_part_data(chunk, state)
        start = state[:start].to_i + state[:written]
        last = start + chunk.bytesize - 1
        if state[:last].nil? || last > state[:last]
          raise Faraday::RangeError, 'part body is longer than its Content-Range'
        end

        @session.write_verified_bytes(start, last, chunk, @request, @verified_ranges)
        state[:written] += chunk.bytesize
      end

      def finish_single_range
        actual = @part_last - @part_start + 1
        return if @received == actual

        raise Faraday::RangeError, 'range response ended before declared Content-Range'
      end

      def finish_part(state = nil)
        state ||= {}
        return unless state[:start]

        actual = state[:last] - state[:start] + 1
        if state[:written] != actual
          raise Faraday::RangeError, 'multipart range part ended before declared Content-Range'
        end

        @session.commit_range(state[:start], state[:last], @request, @verified_ranges)
      end

      def ensure_within_content_length
        return unless @content_length && @received > @content_length

        raise Faraday::RangeError, 'response body is longer than Content-Length'
      end

      def ensure_multipart_content_length
        return unless defined?(@multipart_content_length) &&
                      @multipart_content_length &&
                      @received != @multipart_content_length

        raise Faraday::RangeError, 'multipart Content-Length differs from received body size'
      end

      def validate_total(total)
        return if total.nil? || total == @session.size

        raise Faraday::RangeError, 'Content-Range total differs from expected size'
      end

      def parse_content_range(value)
        match = CONTENT_RANGE.match(value.to_s)
        raise Faraday::RangeError, %(invalid Content-Range: #{value.inspect}) unless match

        start = Integer(match[1])
        last = Integer(match[2])
        raise Faraday::RangeError, 'invalid Content-Range interval' if last < start

        [start, last, match[3] && Integer(match[3])]
      end

      def integer_header(name)
        return nil unless header?(name)

        Integer(header(name))
      rescue ArgumentError
        raise Faraday::RangeError, %(invalid #{name} header)
      end

      def content_length_header?
        header?('Content-Length')
      end

      def content_range_header
        header('Content-Range')
      end

      def etag_header
        header('ETag')
      end

      def header?(name)
        !header(name).nil?
      end

      def header(name)
        @headers.each_pair.find { |key, _| key.downcase == name.downcase }&.last
      end

      def normalize_chunk(chunk)
        return +'' if chunk.nil?

        chunk.to_s.dup.force_encoding(BINARY)
      end
    end
  end
end
