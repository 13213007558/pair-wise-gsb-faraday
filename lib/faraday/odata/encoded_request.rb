# frozen_string_literal: true

module Faraday
  module OData
    # The wire representation of a batch: a Content-Type header value
    # (including the outer boundary) and the multipart body.
    #
    # @!attribute content_type
    #   @return [String] value for the Content-Type request header.
    # @!attribute body
    #   @return [String] binary encoded multipart/mixed request body.
    EncodedRequest = Struct.new(:content_type, :body)
  end
end
