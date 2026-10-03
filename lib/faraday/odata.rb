# frozen_string_literal: true

require 'faraday/odata/errors'
require 'faraday/odata/operation'
require 'faraday/odata/change_set'
require 'faraday/odata/batch'
require 'faraday/odata/encoded_request'
require 'faraday/odata/batch_encoder'
require 'faraday/odata/operation_result'
require 'faraday/odata/change_set_result'
require 'faraday/odata/batch_result'
require 'faraday/odata/batch_decoder'

module Faraday
  # Standalone OData 4.01 multipart batch support for Faraday.
  #
  # Batches are described with plain Ruby objects ({Batch}, {ChangeSet}
  # and {Operation}), encoded into a multipart/mixed request by
  # {BatchEncoder} and the response is turned back into a three level
  # result tree (batch, change set, operation) by {BatchDecoder}.
  #
  # @example Create a customer and its first order atomically
  #   batch = Faraday::OData::Batch.new([
  #     Faraday::OData::ChangeSet.new([
  #       Faraday::OData::Operation.new(
  #         method: :post, url: 'Customers',
  #         headers: { 'Content-Type' => 'application/json' },
  #         body: '{"Name":"ACME"}', content_id: '1'
  #       ),
  #       Faraday::OData::Operation.new(
  #         method: :post, url: '$1/Orders',
  #         headers: { 'Content-Type' => 'application/json' },
  #         body: '{"Amount":42}', content_id: '2'
  #       )
  #     ])
  #   ])
  #   result = Faraday::OData.execute_batch(connection, batch)
  #   result.success? # => true only if every operation returned 2xx
  module OData
    # Encodes the batch, POSTs it to the service's $batch endpoint and
    # decodes the response.
    #
    # The batch is validated before anything is sent. The HTTP status of
    # the batch response itself is intentionally ignored: a 200 only
    # means the batch was well formed, inspect the returned {BatchResult}
    # for the per-operation outcome.
    #
    # @param connection [Faraday::Connection] connection pointed at the
    #   OData service root.
    # @param batch [Batch] the batch to execute.
    # @param path [String] path of the batch endpoint.
    # @param headers [Hash] extra headers for the batch request.
    # @raise [ValidationError] when the batch description is invalid.
    # @raise [ParseError] when the response cannot be decoded.
    # @return [BatchResult]
    def self.execute_batch(connection, batch, path: '/$batch', headers: {})
      encoded = BatchEncoder.new(batch).encode
      response = connection.post(path) do |request|
        request.headers['Content-Type'] = encoded.content_type
        request.headers['OData-Version'] = '4.01'
        headers.each { |name, value| request.headers[name] = value }
        request.body = encoded.body
      end
      BatchDecoder.new(batch).decode(
        content_type: response.headers['Content-Type'],
        body: response.body
      )
    end
  end
end
