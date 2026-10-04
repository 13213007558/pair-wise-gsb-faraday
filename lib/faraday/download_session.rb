# frozen_string_literal: true

require 'monitor'
require 'faraday/download_session/multipart_parser'
require 'faraday/download_session/ranges'
require 'faraday/download_session/response_writer'

module Faraday
  # Coordinates resumable byte-range downloads for one immutable response.
  class DownloadSession
    Request = Struct.new(:ranges, :headers, keyword_init: true)
    Result = Struct.new(:complete, :missing_ranges, keyword_init: true) do
      def complete?
        complete
      end
    end

    DEFAULT_CHUNK_SIZE = 1024 * 1024
    STRONG_ETAG = /\A"(?:[!#-<>-~\x80-\xff]|\\[\x00-\x7f])*"\z/n.freeze

    attr_reader :etag, :size

    def initialize(target_io, existing_ranges, strong_etag, size: nil, chunk_size: DEFAULT_CHUNK_SIZE)
      @io = target_io
      @mutex = Monitor.new
      @size = resolve_size(size)
      @etag = validate_etag(strong_etag).dup.freeze
      @completed = Ranges.normalize(existing_ranges, @size)
      @inflight = []
      @chunk_size = chunk_size
    end

    def complete?
      @mutex.synchronize { complete_locked? }
    end

    def missing_ranges
      @mutex.synchronize { missing_locked }
    end

    def completed_ranges
      @mutex.synchronize { @completed.map(&:dup) }
    end

    def build_request(ranges = nil, chunk_size: @chunk_size, max_ranges: 1)
      @mutex.synchronize do
        available = missing_locked
        selected = select_ranges(ranges, available, chunk_size, max_ranges)
        return nil if selected.empty?

        @inflight = Ranges.union(@inflight + selected)
        Request.new(
          ranges: selected,
          headers: {
            'Range' => Ranges.to_header(selected),
            'If-Match' => @etag
          }
        )
      end
    end

    def begin_response(request, status, headers)
      ResponseWriter.new(self, request, status, headers)
    rescue Faraday::UnsatisfiableRangeError
      raise
    rescue StandardError
      abort_request(request)
      raise
    end

    def process_response(response, request)
      writer = begin_response(request, response.status, response.headers)
      feed_response_body(writer, response.body)
      writer.finish
    rescue StandardError
      abort_request(request)
      raise
    end

    def download(connection, url, params = nil, headers = nil, chunk_size: @chunk_size, max_ranges: 1)
      loop do
        request = build_request(nil, chunk_size: chunk_size, max_ranges: max_ranges)
        break result unless request

        writer = nil
        response = connection.get(url, params, headers) do |req|
          yield(req) if block_given?
          request.headers.each { |name, value| req.headers[name] = value }
          req.options.on_data = proc do |chunk, _received, env|
            writer ||= begin_response(request, env.status, env.response_headers)
            writer.data(chunk)
          end
        end

        if writer.nil?
          writer = begin_response(request, response.status, response.headers)
          feed_response_body(writer, response.body)
        end
        writer.finish
      rescue StandardError
        abort_request(request)
        raise
      end
      result
    end

    def result
      @mutex.synchronize do
        Result.new(complete: complete_locked?, missing_ranges: missing_locked)
      end
    end

    # @private
    def validated_etag(value, required: true)
      if value.nil? || !strong_etag?(value)
        return value unless required

        raise Faraday::ValidatorMismatchError, 'response is missing a strong ETag'
      end

      value = value.strip
      unless value == @etag
        raise Faraday::ValidatorMismatchError,
              "expected ETag #{@etag.inspect}, received #{value.inspect}"
      end

      value
    end

    # @private
    def validator_mismatch!(value)
      validated_etag(value)
    rescue Faraday::ValidatorMismatchError
      raise
    else
      raise Faraday::ValidatorMismatchError, 'server rejected the expected strong ETag'
    end

    # @private
    def unsatisfiable_request!(request)
      @mutex.synchronize do
        @inflight = Ranges.subtract(@inflight, request.ranges)
        Faraday::UnsatisfiableRangeError.new('requested byte range is unsatisfiable')
      end
    end

    # @private
    def abort_request(request)
      @mutex.synchronize { @inflight = Ranges.subtract(@inflight, request.ranges) }
    end

    # @private
    def complete_request(request)
      @mutex.synchronize do
        @inflight = Ranges.subtract(@inflight, request.ranges)
        result
      end
    end

    # @private
    def release_request(request)
      @mutex.synchronize do
        @inflight = Ranges.subtract(@inflight, request.ranges)
      end
    end

    # @private
    def write_full(offset, chunk)
      @mutex.synchronize do
        raise Faraday::RangeError, 'complete response is longer than target size' if offset + chunk.bytesize > @size

        write_at(offset, chunk)
      end
    end

    # @private
      def commit_full(request)
        @mutex.synchronize do
          @io.truncate(@size) if @io.respond_to?(:truncate)
          raise Faraday::RangeError, 'complete response ended before target size' if @io.size != @size

        @completed = @size.zero? ? [] : [[0, @size - 1]]
        @inflight = []
      end
    end

    # @private
    def write_verified_bytes(start, last, chunk, request, writer_ranges)
      @mutex.synchronize do
        ensure_requested(start, last, request)
        verify_overlaps(start, chunk, writer_ranges)
        write_at(start, chunk)
        writer_ranges.replace(Ranges.union(writer_ranges + [[start, last]]))
      end
    end

    # @private
    def commit_range(start, last, request, writer_ranges)
      @mutex.synchronize do
        unless Ranges.cover?(@completed, start) || Ranges.cover?(request.ranges, start) && Ranges.cover?(request.ranges, last)
          raise Faraday::RangeError, 'range response is outside the request'
        end

        @completed = Ranges.union(@completed + [[start, last]])
        writer_ranges.replace(Ranges.subtract(writer_ranges, [[start, last]]))
      end
    end

    private

    def resolve_size(value)
      size = value || @io.size
      size = Integer(size)
      raise ArgumentError, 'size cannot be negative' if size.negative?

      size
    rescue NoMethodError
      raise ArgumentError, 'size is required when target IO does not respond to #size'
    end

    def validate_etag(value)
      unless value.is_a?(String) && strong_etag?(value.strip)
        raise ArgumentError, 'a strong ETag is required'
      end

      value.strip
    end

    def strong_etag?(value)
      STRONG_ETAG.match?(value.to_s)
    end

    def complete_locked?
      return true if @size.zero?

      @completed == [[0, @size - 1]]
    end

    def missing_locked
      return [] if @size.zero?

      covered = Ranges.union(@completed + @inflight)
      Ranges.subtract([[0, @size - 1]], covered)
    end

    def select_ranges(ranges, available, chunk_size, max_ranges)
      requested = if ranges.nil?
                    available
                  else
                    normalized = Ranges.normalize(ranges, @size)
                    validate_available(normalized, available)
                  end
      selected = Ranges.chunks(requested, chunk_size)
      return selected if max_ranges.nil?

      selected.first(max_ranges)
    end

    def validate_available(requested, available)
      requested.filter_map do |start, last|
        missing = Ranges.subtract([[start, last]], available)
        next if missing.empty?

        missing
      end.flatten(1).then { |ranges| Ranges.normalize(ranges, @size) }
    end

    def ensure_requested(start, last, request)
      return if Ranges.cover?(request.ranges, start) && Ranges.cover?(request.ranges, last)

      raise Faraday::RangeError, 'response contains an unrequested byte range'
    end

    def verify_overlaps(start, chunk, writer_ranges)
        writer_ranges.each do |range_start, range_last|
          chunk_last = start + chunk.bytesize - 1
          overlap_start = [start, range_start].max
          overlap_last = [chunk_last, range_last].min
          next unless range_start <= chunk_last && range_last >= start
          relative_start = overlap_start - range_start
          length = overlap_last - overlap_start + 1
          actual = chunk.byteslice(relative_start, length)
          existing = read_at(range_start + relative_start, length)
        next if actual == existing

        raise Faraday::RangeContentMismatchError, 'overlapping response content does not match'
    end

      each_completed_overlap(start, start + chunk.bytesize - 1) do |overlap_start, overlap_last, range_start|
        relative_start = overlap_start - start
        length = overlap_last - overlap_start + 1
        actual = chunk.byteslice(relative_start, length)
        existing = read_at(overlap_start, length)
        next if actual == existing

        raise Faraday::RangeContentMismatchError, 'response content conflicts with verified bytes'
      end
    end

    def each_completed_overlap(start, last)
        @completed.each do |range_start, range_last|
          overlap_start = [start, range_start].max
          overlap_last = [last, range_last].min
          yield(overlap_start, overlap_last) if overlap_start <= overlap_last
        end
    end

    def read_at(offset, length)
      @io.seek(offset)
      @io.read(length).tap { @io.seek(offset + length) }
    end

    def write_at(offset, data)
        extend_to(offset) if @io.respond_to?(:size) && @io.size < offset
        @io.seek(offset)
        written = @io.write(data)
        raise Faraday::RangeError, 'target IO wrote fewer bytes than supplied' unless written == data.bytesize
    end

    def extend_to(offset)
        @io.seek(@io.size)
        @io.write("\0".b * (offset - @io.size))
    end

    def feed_response_body(writer, body)
      body = body.to_s.dup.force_encoding(Encoding::BINARY)
      offset = 0
      while offset < body.bytesize
        writer.data(body.byteslice(offset, 16 * 1024))
        offset += 16 * 1024
      end
      writer.finish
    end
  end
end
