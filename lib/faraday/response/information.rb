# frozen_string_literal: true

module Faraday
  class Response
    # Information represents an informational HTTP response (a 1xx status,
    # such as 100 Continue or 103 Early Hints) received before the final
    # response.
    #
    # Every notification is an independent, immutable snapshot: later
    # informational responses or the final response never mutate a previously
    # delivered Information object.
    class Information
      # @return [Integer] the informational HTTP status code (1xx)
      attr_reader :status

      # @return [Faraday::Utils::Headers] frozen header snapshot
      attr_reader :headers

      # @param status [Integer, #to_i] the informational HTTP status code (1xx)
      # @param headers [Hash, nil] the headers received with this response
      def initialize(status, headers = nil)
        @status = status.to_i
        @headers = Utils::Headers.new.tap do |snapshot|
          snapshot.update(headers) unless headers.nil?
        end
        @headers.freeze
        freeze
      end

      # @return [Object] value of the given header, looked up case-insensitively
      def [](key)
        headers[key]
      end

      # @return [Boolean] true if this is a 103 Early Hints response
      def early_hints?
        status == 103
      end

      def inspect
        "#<#{self.class} status=#{status} headers=#{headers.inspect}>"
      end
    end
  end
end
