# frozen_string_literal: true

require 'securerandom'

module Faraday
  module OData
    # Encodes a {Batch} into an OData 4.01 multipart/mixed request body.
    # Change sets become nested multipart/mixed sections with their own
    # boundary; every operation becomes an application/http part whose
    # payload is a plain HTTP/1.1 request message.
    #
    # The batch is validated before encoding, so a {ValidationError} is
    # raised before anything reaches the network.
    #
    # @example
    #   encoded = Faraday::OData::BatchEncoder.new(batch).encode
    #   connection.post('/$batch') do |request|
    #     request.headers['Content-Type'] = encoded.content_type
    #     request.body = encoded.body
    #   end
    class BatchEncoder
      CRLF = "\r\n"

      # @param batch [Batch] the batch to encode.
      # @param boundary [String, nil] outer boundary, mainly useful for
      #   tests. A random one is generated when omitted.
      def initialize(batch, boundary: nil)
        @batch = batch
        @boundary = boundary || "batch_#{SecureRandom.uuid}"
      end

      # @raise [ValidationError] when the batch description is invalid.
      # @return [EncodedRequest]
      def encode
        @batch.validate!
        EncodedRequest.new(content_type, encode_body)
      end

      # @return [String] Content-Type header value for the batch request.
      def content_type
        %(multipart/mixed; boundary="#{@boundary}")
      end

      private

      def encode_body
        segments = @batch.items.map do |item|
          if item.is_a?(ChangeSet)
            encode_change_set(item)
          else
            encode_operation(item)
          end
        end
        parts = segments.flat_map { |segment| ["--#{@boundary}", segment] }
        parts << "--#{@boundary}--"
        parts.map(&:b).join(CRLF) << CRLF
      end

      def encode_change_set(change_set)
        boundary = "changeset_#{SecureRandom.uuid}"
        segments = change_set.operations.map do |operation|
          ["--#{boundary}", encode_operation(operation)]
        end
        lines = [%(Content-Type: multipart/mixed; boundary="#{boundary}"), '']
        lines.concat(segments.flatten)
        lines << "--#{boundary}--"
        lines.map(&:b).join(CRLF)
      end

      def encode_operation(operation)
        lines = ['Content-Type: application/http',
                 'Content-Transfer-Encoding: binary']
        lines << "Content-ID: #{operation.content_id}" if operation.content_id
        lines.join(CRLF).b << CRLF << CRLF << http_request_message(operation)
      end

      def http_request_message(operation)
        lines = ["#{operation.method} #{operation.url} HTTP/1.1"]
        headers = operation.headers.dup
        body = operation.body
        headers['Content-Length'] ||= body.bytesize.to_s if body
        headers.each { |name, value| lines << "#{name}: #{value}" }
        message = lines.join(CRLF).b
        message << CRLF << CRLF
        message << body.to_s.b if body
        message
      end
    end
  end
end
