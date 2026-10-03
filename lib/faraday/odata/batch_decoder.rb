# frozen_string_literal: true

module Faraday
  module OData
    # Decodes OData 4.01 multipart batch responses into nested Ruby objects.
    class BatchDecoder
      # @param response [Faraday::Response, Faraday::Env, Hash, String]
      #   batch response
      # @param headers [Hash, nil] response headers when +response+ is a String
      # @param batch [EncodedBatch, nil] encoded request used to distinguish a
      #   single failed change set from a standalone query
      # @return [BatchResponse]
      def decode(response, headers = nil, batch: nil)
        status, response_headers, body = normalize_input(response, headers)
        content_type = MultipartParser.content_type(response_headers[Faraday::CONTENT_TYPE])

        unless status == 200 && content_type[:media_type]&.start_with?('multipart/')
          return BatchResponse.new(
            status: status,
            headers: response_headers,
            parts: [],
            body: body.to_s.b
          )
        end

        boundary = content_type[:params]['boundary']
        raise ProtocolError, 'multipart batch response is missing a boundary' if boundary.to_s.empty?

        request_index = index_requests(batch)
        raw_parts = MultipartParser.parts(body, boundary).map do |part|
          decode_outer_part(part, request_index)
        end
        parts = raw_parts.map(&:last)
        BatchResponse.new(status: status, headers: response_headers, parts: parts)
      end

      private

      def normalize_input(response, headers)
        case response
        when Faraday::Response, Faraday::Env
          [response.status.to_i, headers_from(response.headers), read_binary(response.body)]
        when Hash
          hash = response.transform_keys { |key| key.to_s.downcase }
          status = hash.fetch('status', 200)
          response_headers = headers || hash.fetch('headers', {})
          [status.to_i, headers_from(response_headers), read_binary(hash.fetch('body', ''))]
        else
          [200, headers_from(headers || {}), read_binary(response)]
        end
      end

      def index_requests(batch)
        index = {}
        return index unless batch

        batch.parts.each do |part|
          if part.is_a?(ChangeSet)
            part.requests.each { |request| index[request.content_id] = true }
          else
            index[part.content_id] = false
          end
        end
        index
      end

      def decode_outer_part(part, request_index)
        content_type = MultipartParser.content_type(part.headers['Content-Type'])
        case content_type[:media_type]
        when 'multipart/mixed'
          [:change_set, decode_change_set(part, content_type[:params]['boundary'])]
        when 'application/http'
          operation = decode_operation(part)
          classify_outer_operation(part, operation, request_index)
        else
          raise ProtocolError, "unexpected outer batch content type #{content_type[:media_type].inspect}"
        end
      end

      def decode_change_set(part, boundary)
        raise ProtocolError, 'nested change set response is missing a boundary' if boundary.to_s.empty?

        operations = MultipartParser.parts(part.body, boundary).map do |nested_part|
          nested_type = MultipartParser.content_type(nested_part.headers['Content-Type'])
          unless nested_type[:media_type] == 'application/http'
            raise ProtocolError, "unexpected change set content type #{nested_type[:media_type].inspect}"
          end

          decode_operation(nested_part)
        end
        ChangeSetResponse.new(parts: operations, headers: part.headers)
      end

      def classify_outer_operation(part, operation, request_index)
        return [:operation, operation] unless operation.failure?

        if request_index[operation.content_id] == true
          [:change_set_failure, ChangeSetResponse.new(parts: [operation], headers: part.headers)]
        elsif !request_index.empty? && operation.content_id && !request_index.key?(operation.content_id)
          raise ProtocolError, "response contains unknown Content-ID #{operation.content_id.inspect}"
        else
          [:operation, operation]
        end
      end

      def decode_operation(part)
        message = MultipartParser.http(part.body)
        merged_headers = Faraday::Utils::Headers.new
        part.headers.each do |name, value|
          merged_headers[name] = value unless name.casecmp?('Content-Type')
        end
        merged_headers.update(message.headers)
        content_id = merged_headers['Content-ID']
        OperationResponse.new(
          status: message.status,
          reason: message.reason,
          headers: merged_headers,
          body: message.body,
          content_id: content_id&.to_s
        )
      end

      def headers_from(headers)
        Faraday::Utils::Headers.new(headers)
      end

      def read_binary(body)
        (body.is_a?(IO) ? body.read : body.to_s).to_s.b
      end
    end
  end
end
