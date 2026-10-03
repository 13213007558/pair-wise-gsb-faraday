# frozen_string_literal: true

module Faraday
  module OData
    # Base error for all OData batch related failures.
    class Error < Faraday::Error; end

    # Raised when a batch description is invalid (e.g. duplicated
    # Content-IDs or references to operations that do not precede the
    # referencing one). Raised before anything is sent over the wire.
    class ValidationError < Error; end

    # Raised when a multipart batch response cannot be parsed.
    class ParseError < Error; end
  end
end
