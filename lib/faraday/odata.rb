# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'stringio'

require 'faraday'
require 'faraday/odata/request'
require 'faraday/odata/change_set'
require 'faraday/odata/encoded_batch'
require 'faraday/odata/batch_encoder'
require 'faraday/odata/multipart_parser'
require 'faraday/odata/operation_response'
require 'faraday/odata/change_set_response'
require 'faraday/odata/batch_response'
require 'faraday/odata/batch_decoder'

module Faraday
  # OData 4.01 multipart batch encoding and decoding.
  module OData
    VERSION = '4.01'
    BATCH_PATH = '$batch'
    BATCH_CONTENT_TYPE = 'multipart/mixed'
    HTTP_CONTENT_TYPE = 'application/http'
    BINARY_ENCODING = 'binary'
    CRLF = "\r\n"

    class Error < Faraday::Error; end

    # Raised when a batch description violates an OData client-side rule.
    class ValidationError < Error; end

    # Raised when an OData batch response cannot be parsed.
    class ProtocolError < Error; end

    class << self
      # Encodes an OData batch request.
      #
      # @param operations [Array<Hash, Faraday::OData::Request,
      #   Faraday::OData::ChangeSet>] batch parts
      # @param options [Hash] encoder options
      # @return [Faraday::OData::EncodedBatch]
      def encode_batch(operations, **options)
        BatchEncoder.new(**options).encode(operations)
      end

      # Decodes an OData multipart batch response.
      #
      # @param response [Faraday::Response, Faraday::Env, Hash, String]
      #   response object, response headers/body Hash, or multipart body
      # @param headers [Hash, nil] multipart response headers when +response+
      #   is a String
      # @return [Faraday::OData::BatchResponse]
      def decode_batch(response, headers = nil, batch: nil)
        BatchDecoder.new.decode(response, headers, batch: batch)
      end
    end
  end
end
