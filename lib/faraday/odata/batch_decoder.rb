# frozen_string_literal: true

module Faraday
  module OData
    # Decodes an OData 4.01 multipart/mixed batch response back into a
    # {BatchResult} that mirrors the structure of the original {Batch}.
    #
    # Response parts are matched to operations by their Content-ID
    # header whenever one is present, so a service is free to return the
    # parts in any order. Parts without a Content-ID are matched to the
    # remaining operations in document order.
    #
    # A change set that fails is reported as a single error response for
    # the whole group; operations without a matching response part are
    # marked as aborted.
    class BatchDecoder
      CRLF = "\r\n"

      # One MIME part of a multipart message.
      class Part
        # @return [Hash] part headers with down-cased names.
        attr_reader :headers

        # @return [String] part body, binary safe.
        attr_reader :body

        def initialize(headers, body)
          @headers = headers
          @body = body
        end

        def content_type
          headers['content-type']
        end

        def content_id
          headers['content-id']
        end

        def multipart?
          content_type&.start_with?('multipart/') || false
        end
      end

      # @param batch [Batch] the batch this response belongs to.
      def initialize(batch)
        @batch = batch
      end

      # @param content_type [String] Content-Type of the batch response.
      # @param body [String] raw response body, may be binary.
      # @raise [ParseError] when the response cannot be parsed.
      # @return [BatchResult]
      def decode(content_type:, body:)
        boundary = extract_boundary(content_type)
        parts = split_multipart(body.to_s.b, boundary)
        BatchResult.new(items: build_items(parts))
      end

      private

      def build_items(parts)
        query_results = {}
        unmatched_queries = @batch.operations.dup
        change_set_parts = {}
        pending_change_sets = @batch.change_sets.dup

        parts.each do |part|
          if part.multipart?
            change_set = pending_change_sets.shift
            raise ParseError, 'more change set responses than change sets' unless change_set

            change_set_parts[change_set] = part
          else
            match_query_part(part, query_results, unmatched_queries)
          end
        end

        @batch.items.map do |item|
          if item.is_a?(ChangeSet)
            part = change_set_parts[item]
            raise ParseError, 'missing change set response' unless part

            decode_change_set(item, part)
          else
            query_results.fetch(item) { OperationResult.aborted(item) }
          end
        end
      end

      def match_query_part(part, query_results, unmatched_queries)
        status, headers, body = parse_http_response(part.body)
        operation = part.content_id && unmatched_queries.find { |op| op.content_id == part.content_id }
        operation ||= unmatched_queries.first
        raise ParseError, 'more query responses than queries' unless operation

        unmatched_queries.delete(operation)
        query_results[operation] = OperationResult.new(
          operation: operation, status: status, headers: headers, body: body
        )
      end

      def decode_change_set(change_set, part)
        boundary = extract_boundary(part.content_type)
        inner_parts = split_multipart(part.body, boundary)
        parsed = inner_parts.map { |inner| [inner, parse_http_response(inner.body)] }

        results = {}
        orphans = []
        parsed.each do |inner, (status, headers, body)|
          operation = inner.content_id &&
                      change_set.operations.find { |op| op.content_id == inner.content_id }
          if operation
            results[operation] = OperationResult.new(
              operation: operation, status: status, headers: headers, body: body
            )
          else
            orphans << OperationResult.new(operation: nil, status: status, headers: headers, body: body)
          end
        end

        failure = nil
        if parsed.size == 1 && orphans.size == 1 && orphans.first.status.to_i >= 400
          failure = orphans.first
        else
          assign_orphans(orphans, change_set, results)
        end

        results_list = change_set.operations.map do |operation|
          results.fetch(operation) { OperationResult.aborted(operation) }
        end
        ChangeSetResult.new(change_set: change_set, operations: results_list, failure: failure)
      end

      def assign_orphans(orphans, change_set, results)
        orphans.each do |orphan|
          operation = change_set.operations.find { |op| !results.key?(op) }
          break unless operation

          results[operation] = OperationResult.new(
            operation: operation, status: orphan.status, headers: orphan.headers, body: orphan.body
          )
        end
      end

      def extract_boundary(content_type)
        match = content_type.to_s.match(/boundary="?([^";]+)"?/i)
        raise ParseError, "no boundary found in Content-Type: #{content_type.inspect}" unless match

        match[1]
      end

      def split_multipart(body, boundary)
        segments = body.split("--#{boundary}".b)
        segments.shift # preamble
        segments.pop if segments.last&.start_with?('--')
        segments.map { |segment| parse_part(segment) }
      end

      def parse_part(segment)
        segment = segment.sub(/\A\r\n/, '').sub(/\r\n\z/, '')
        header_blob, separator, rest = segment.partition("#{CRLF}#{CRLF}".b)
        raise ParseError, 'malformed MIME part: missing header separator' if separator.empty?

        Part.new(parse_headers(header_blob), rest)
      end

      def parse_http_response(data)
        head, separator, body = data.partition("#{CRLF}#{CRLF}".b)
        raise ParseError, 'malformed application/http part' if separator.empty?

        lines = head.split(CRLF.b)
        status_line = lines.shift.to_s
        match = status_line.match(%r{\AHTTP/\d(?:\.\d+)?\s+(\d{3})}i)
        raise ParseError, "invalid HTTP status line: #{status_line.inspect}" unless match

        [match[1].to_i, parse_headers(lines.join(CRLF.b)), body]
      end

      def parse_headers(blob)
        blob.split(CRLF.b).each_with_object({}) do |line, headers|
          name, _, value = line.partition(':')
          headers[name.strip.downcase] = value.strip
        end
      end
    end
  end
end
