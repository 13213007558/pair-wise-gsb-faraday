# frozen_string_literal: true

module Faraday
  class ResumableDownload
    # Base error for resumable download protocol failures.
    class Error < Faraday::Error
      def initialize(message = nil, response: nil)
        super(message, response)
      end
    end

    # Raised when a response is syntactically invalid or does not match the
    # advertised byte ranges.
    class InvalidResponse < Error
    end

    # Raised when bytes received for an already verified range differ.
    class ContentMismatch < InvalidResponse
    end

    # Raised when the response validator differs from the session validator.
    class ValidatorMismatch < Error
    end

    # Raised for response statuses that cannot describe a resumable response.
    class UnexpectedStatus < Error
    end

    # Raised by #finish! when verified bytes do not cover the whole file.
    class IncompleteDownload < Error
    end
  end
end
