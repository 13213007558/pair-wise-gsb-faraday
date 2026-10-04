# frozen_string_literal: true

class Faraday::ResumableDownload
  # @api private
  class RangeSet
    def initialize(ranges = [], total_length: nil)
      @total_length = total_length
      @ranges = normalize(ranges)
    end

    attr_reader :ranges

    def add!(range)
      @ranges = normalize(@ranges + [range])
      self
    end

    def replace!(ranges)
      @ranges = normalize(ranges)
      self
    end

    def missing(chunk_size: nil)
      missing = gaps
      return missing unless chunk_size

      missing.flat_map { |start, finish| split(start, finish, chunk_size) }
    end

    def intersections(range_start, range_finish)
      @ranges.filter_map do |start, finish|
        intersection = [[start, range_start].max, [finish, range_finish].min]
        intersection if intersection.first <= intersection.last
      end
    end

    private

    def normalize(ranges)
      normalized = ranges.map { |range| validate(range) }.sort_by(&:first)
      normalized.each_with_object([]) do |(start, finish), merged|
        if merged.empty? || start > merged.last.last + 1
          merged << [start, finish]
        else
          merged[-1][1] = [merged.last.last, finish].max
        end
      end
    end

    def validate(range)
      if range.is_a?(::Range)
        start = range.begin
        finish = range.end
        finish -= 1 if range.exclude_end?
      else
        start, finish = range
      end
      start = start.to_i
      finish = finish.to_i
      raise ArgumentError, 'invalid byte range' if start.negative? || start > finish

      if @total_length && finish >= @total_length
        raise ArgumentError, 'byte range exceeds total length'
      end

      [start, finish]
    end

    def gaps
      return [] if @total_length&.zero?

      cursor = 0
      gaps = []
      @ranges.each do |start, finish|
        gaps << [cursor, start - 1] if cursor < start
        cursor = finish + 1
      end
      gaps << [cursor, @total_length - 1] if @total_length && cursor < @total_length
      gaps
    end

    def split(start, finish, chunk_size)
      chunk_size = chunk_size.to_i
      raise ArgumentError, 'chunk_size must be positive' if chunk_size <= 0

      [].tap do |pieces|
        while start <= finish
          piece_finish = [start + chunk_size - 1, finish].min
          pieces << [start, piece_finish]
          start = piece_finish + 1
        end
      end
    end
  end
end
