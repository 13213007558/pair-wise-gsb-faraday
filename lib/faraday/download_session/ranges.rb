# frozen_string_literal: true

module Faraday
  class DownloadSession
    # Immutable interval helpers. Intervals are represented as [start, last].
    module Ranges
      module_function

      def normalize(values, maximum)
        values = Array(values)
        intervals = values.map { |value| normalize_one(value, maximum) }
        union(intervals)
      end

      def union(intervals)
        intervals.sort_by(&:first).each_with_object([]) do |(start, last), merged|
          if merged.empty? || start > merged.last.last + 1
            merged << [start, last]
          else
            merged[-1] = [merged[-1].first, [merged[-1].last, last].max]
          end
        end
      end

      def subtract(intervals, removed)
        removed = normalize(removed, nil)
        intervals.flat_map do |start, last|
          subtract_one(start, last, removed)
        end.then { |result| normalize(result, nil) }
      end

      def chunks(intervals, chunk_size)
        raise ArgumentError, 'chunk_size must be positive' if chunk_size.nil? || chunk_size <= 0

        intervals.flat_map do |start, last|
          (start..last).step(chunk_size).map do |chunk_start|
            [chunk_start, [last, chunk_start + chunk_size - 1].min]
          end
        end
      end

      def cover?(intervals, position)
        intervals.any? { |start, last| position >= start && position <= last }
      end

      def to_header(intervals)
        encoded = intervals.map { |start, last| "#{start}-#{last}" }.join(', ')
        "bytes=#{encoded}"
      end

      def normalize_one(value, maximum)
        start, last =
          case value
          when Array
            validate_pair(value)
            [Integer(value[0]), Integer(value[1])]
          when Range
            range_bounds(value)
          else
            raise ArgumentError, %(invalid byte range: #{value.inspect})
          end

        validate_bounds(start, last, maximum)
        [start, last]
      end

      def validate_pair(value)
        return if value.length == 2

        raise ArgumentError, %(invalid byte range: #{value.inspect})
      end

      def range_bounds(value)
        [Integer(value.begin), Integer(value.end) - (value.exclude_end? ? 1 : 0)]
      end

      def validate_bounds(start, last, maximum)
        raise ArgumentError, 'byte ranges cannot start below zero' if start.negative?
        raise ArgumentError, 'byte ranges cannot be empty' if last < start
        return if maximum.nil? || last < maximum

        raise ArgumentError, 'byte range extends beyond target size'
      end

      def subtract_one(start, last, removed)
        pieces = []
        cursor = start

        removed.each do |removed_start, removed_last|
          next if removed_last < cursor
          break if removed_start > last

          overlap_start = [cursor, removed_start].max
          pieces << [cursor, overlap_start - 1] if cursor < overlap_start
          cursor = [cursor, removed_last + 1].max
          break if cursor > last
        end

        pieces << [cursor, last] if cursor <= last
        pieces
      end
    end
  end
end
