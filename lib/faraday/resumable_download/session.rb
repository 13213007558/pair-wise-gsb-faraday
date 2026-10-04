# frozen_string_literal: true

require_relative 'error'
require_relative 'multipart_parser'
require_relative 'range_set'
require 'monitor'

class Faraday::ResumableDownload
  # Description of one byte-range request generated from current gaps.
  Request = Struct.new(:headers, :ranges, :multipart, keyword_init: true)

  # Snapshot returned after applying a response or asking for completion.
  Result = Struct.new(:status, :missing_ranges, keyword_init: true) do
    def complete?
      status == :complete
    end

    def range_not_satisfiable?
      status == :range_not_satisfiable
    end
  end

  # Verifies and writes one satisfied Content-Range to the target IO.
  #
  # @api private
  class PartWriter
    def initialize(session, start, finish, candidate_ranges = [])
      @session = session
      @start = start
      @finish = finish
      @candidate_ranges = candidate_ranges
      @offset = start
    end

    attr_reader :start, :finish

    def call(chunk)
      return if chunk.empty?

      next_offset = @offset + chunk.bytesize
      if next_offset > @finish + 1
        raise InvalidResponse, 'part body is longer than Content-Range'
      end

      verify_overlap(chunk)
      @session.write_bytes(@offset, chunk)
      @offset = next_offset
    end

    def finalize
      return if @offset == @finish + 1

      raise InvalidResponse, 'part body is shorter than Content-Range'
    end

    private

    def verify_overlap(chunk)
      chunk_finish = @offset + chunk.bytesize - 1
      ranges = @session.current_verified_ranges + @candidate_ranges
      intersections(ranges, @offset, chunk_finish).each do |start, finish|
        existing = @session.read_bytes(start, finish - start + 1)
        received_start = [start, @offset].max
        received = chunk.byteslice(received_start - @offset, finish - received_start + 1)
        unless existing == received
          raise ContentMismatch, "overlapping bytes #{start}-#{finish} do not match"
        end
      end
    end

    def intersections(ranges, start, finish)
      ranges.filter_map do |range_start, range_finish|
        overlap_start = [range_start, start].max
        overlap_finish = [range_finish, finish].min
        [overlap_start, overlap_finish] if overlap_start <= overlap_finish
      end
    end
  end

  # Creates a download session backed by a seekable, writable IO.
  #
  # @param target_io [#seek, #read, #write] destination IO
  # @param etag [String] strong representation validator
  # @param total_length [Integer, nil] complete file size, defaults to target size
  # @param existing_ranges [Array<Range, Array(Integer, Integer)>] verified byte ranges
  def initialize(target_io, etag:, total_length: nil, existing_ranges: [])
    @target_io = target_io
    @etag = validate_etag(etag)
    @total_length = Integer(total_length || target_io.size)
    raise ArgumentError, 'total_length cannot be negative' if @total_length.negative?

    @verified = RangeSet.new(existing_ranges, total_length: @total_length)
    @mutex = Monitor.new
  end

  attr_reader :etag, :total_length

  def verified_ranges
    synchronize { @verified.ranges.dup }
  end

  def missing_ranges(chunk_size: nil)
    synchronize { @verified.missing(chunk_size: chunk_size) }
  end

  # Builds one Range request per missing interval, split when chunk_size is set.
  def requests(chunk_size: nil)
    missing_ranges(chunk_size: chunk_size).map { |range| request_for([range]) }
  end

  # Builds a request whose Range header asks for every currently missing gap.
  def multipart_request
    gaps = missing_ranges
    raise Error, 'download is already complete' if gaps.empty?

    request_for(gaps, multipart: true)
  end

  # Applies a Faraday response or any object responding to status, headers,
  # and body. Out-of-order responses are safe; only verified bytes are added.
  def ingest(response, _request = nil)
    synchronize do
      status = Integer(response.status)
      validate_validator!(response_headers(response))

      case status
      when 200 then apply_full_response(response)
      when 206 then apply_partial_response(response)
      when 412 then raise ValidatorMismatch, 'server rejected the strong ETag validator'
      when 416 then apply_range_not_satisfiable(response)
      else
        raise UnexpectedStatus, "unexpected response status #{status}"
      end
    end
  end

  def result
    synchronize do
      missing = @verified.missing
      build_result(missing)
    end
  end

  def finish
    result
  end

  def finish!
    result = finish
    return result if result.complete?

    raise IncompleteDownload, "download is missing #{result.missing_ranges.inspect}"
  end

  def read_bytes(offset, length)
    @target_io.seek(offset)
    @target_io.read(length).to_s.dup.force_encoding(Encoding::BINARY)
  end

  # @api private
  def current_verified_ranges
    @verified.ranges
  end

  def write_bytes(offset, bytes)
    @target_io.seek(offset)
    @target_io.write(bytes)
  end

  private

  STRONG_ETAG = /\A"(?:[^"\\]|\\.)*"\z/.freeze

  def request_for(ranges, multipart: false)
    bytes = ranges.map { |start, finish| "#{start}-#{finish}" }.join(',')
    Request.new(
      headers: { 'Range' => "bytes=#{bytes}", 'If-Match' => @etag },
      ranges: ranges,
      multipart: multipart
    )
  end

  def validate_etag(value)
    value = value.to_s
    unless value.match?(STRONG_ETAG)
      raise ArgumentError, 'a strong ETag validator is required'
    end

    value.dup.freeze
  end

  def validate_validator!(headers)
    response_etag = headers['etag'] || headers['ETag']
    if response_etag.nil?
      raise InvalidResponse, 'response is missing an ETag validator'
    end
    unless response_etag == @etag && response_etag.match?(STRONG_ETAG)
      raise ValidatorMismatch, "expected ETag #{@etag}, got #{response_etag.inspect}"
    end
  end

  def apply_full_response(response)
    headers = response_headers(response)
    if headers.key?('content-range')
      raise InvalidResponse, '200 response must not include Content-Range'
    end

    offset = 0
    stream_body(response) do |chunk|
      next_offset = offset + chunk.bytesize
      if next_offset > @total_length
        raise InvalidResponse, '200 response is longer than the representation'
      end

      verify_bytes(offset, chunk)
      write_bytes(offset, chunk)
      offset = next_offset
    end

    unless offset == @total_length
      raise InvalidResponse, '200 response is shorter than the representation'
    end

    @target_io.truncate(@total_length) if @target_io.respond_to?(:truncate)
    @verified.replace!(@total_length.zero? ? [] : [[0, @total_length - 1]])
    validate_content_length!(headers, offset)
    result
  end

  def apply_partial_response(response)
    headers = response_headers(response)
    content_type = headers['content-type'] || headers['Content-Type'] || ''
    if content_type.downcase.include?('multipart/byteranges')
      apply_multipart_response(response, headers, content_type)
    else
      apply_single_part_response(response, headers)
    end
  end

  def apply_single_part_response(response, headers)
    content_range = headers['content-range']
    if content_range.nil?
      raise InvalidResponse, '206 response is missing Content-Range'
    end

    start, finish, total_length = parse_content_range(content_range)
    validate_total_length!(total_length)
    writer = PartWriter.new(self, start, finish)
    received = stream_body(response) { |chunk| writer.call(chunk) }
    writer.finalize
    validate_content_length!(headers, received)
    @verified.add!([start, finish])
    result
  end

  def apply_multipart_response(response, headers, content_type)
    boundary = MultipartParser.boundary(content_type)
    writers = []
    candidates = RangeSet.new(total_length: @total_length)
    current_writer = nil
    received = 0
    parser = MultipartParser.new(
      boundary,
      on_headers: lambda { |part_headers|
        commit_part!(current_writer, candidates) if current_writer
        current_writer = start_part(part_headers, candidates.ranges)
        writers << current_writer
      },
      on_body: ->(chunk) { current_writer&.call(chunk) }
    )
    stream_body(response) do |chunk|
      received += chunk.bytesize
      parser.call(chunk)
    end
    parser.finish
    raise InvalidResponse, 'multipart response contains no parts' if writers.empty?
    commit_part!(current_writer, candidates)
    validate_content_length!(headers, received)
    candidates.ranges.each { |range| @verified.add!(range) }
    result
  end

  def start_part(headers, candidate_ranges)
    start, finish, total_length = parse_content_range(headers['content-range'])
    validate_total_length!(total_length)
    PartWriter.new(self, start, finish, candidate_ranges)
  end

  def commit_part!(writer, candidates)
    writer.finalize
    candidates.add!([writer.start, writer.finish])
  end

  def apply_range_not_satisfiable(response)
    headers = response_headers(response)
    content_range = headers['content-range']
    match = content_range.to_s.match(/\Abytes \*\/(\d+)\z/i)
    raise InvalidResponse, '416 response must include Content-Range total length' unless match

    validate_total_length!(Integer(match[1]))

    Result.new(status: :range_not_satisfiable, missing_ranges: @verified.missing)
  end

  def parse_content_range(value)
    match = value.to_s.match(/\Abytes (\d+)-(\d+)\/(\d+)\z/i)
    raise InvalidResponse, "invalid Content-Range: #{value.inspect}" unless match

    start = Integer(match[1])
    finish = Integer(match[2])
    raise InvalidResponse, 'invalid Content-Range' if start > finish
    total_length = Integer(match[3])
    raise InvalidResponse, 'invalid Content-Range total length' if finish >= total_length

    [start, finish, total_length]
  end

  def validate_total_length!(value)
    return if value.nil? || value == @total_length

    raise InvalidResponse, "Content-Range total length #{value} does not match #{@total_length}"
  end

  def validate_content_length!(headers, received)
    expected = headers['content-length'] || headers['Content-Length']
    return if expected.nil?
    return if Integer(expected) == received

    raise InvalidResponse, "Content-Length #{expected} does not match #{received} body bytes"
  end

  def verify_bytes(offset, chunk)
    finish = offset + chunk.bytesize - 1
    @verified.intersections(offset, finish).each do |start, range_finish|
      existing = read_bytes(start, range_finish - start + 1)
      relative_start = start - offset
      received = chunk.byteslice(relative_start, range_finish - start + 1)
      unless existing == received
        raise ContentMismatch, "overlapping bytes #{start}-#{range_finish} do not match"
      end
    end
  end

  def response_headers(response)
    headers = response.headers || {}
    headers.each_with_object({}) do |(key, value), normalized|
      normalized[key.to_s.downcase] = value
    end
  end

  def stream_body(response)
    received = 0
    each_body_chunk(response.body) do |chunk|
      chunk = chunk.to_s.dup.force_encoding(Encoding::BINARY)
      received += chunk.bytesize
      yield(chunk)
    end
    received
  end

  def each_body_chunk(body)
    if body.respond_to?(:read)
      read_body_chunks(body) { |chunk| yield(chunk) }
    elsif body.respond_to?(:each)
      body.each { |chunk| yield(chunk.to_s.dup.force_encoding(Encoding::BINARY)) }
    else
      yield(body.to_s.dup.force_encoding(Encoding::BINARY))
    end
  end

  def read_body_chunks(body)
    until (chunk = body.read(16_384)).nil?
      break if chunk.empty?

      yield(chunk)
    end
  end

  def build_result(missing)
    if missing.empty?
      Result.new(status: :complete, missing_ranges: [])
    else
      Result.new(status: :incomplete, missing_ranges: missing)
    end
  end

  def synchronize(&block)
    @mutex.synchronize(&block)
  end
end
