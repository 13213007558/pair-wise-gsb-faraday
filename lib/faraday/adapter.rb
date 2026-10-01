# frozen_string_literal: true

module Faraday
  # Base class for all Faraday adapters. Adapters are
  # responsible for fulfilling a Faraday request.
  class Adapter
    extend MiddlewareRegistry

    CONTENT_LENGTH = 'Content-Length'

    TIMEOUT_KEYS = {
      read: :read_timeout,
      open: :open_timeout,
      write: :write_timeout
    }.freeze

    # This module marks an Adapter as supporting parallel requests.
    module Parallelism
      attr_writer :supports_parallel

      def supports_parallel?
        @supports_parallel
      end

      def inherited(subclass)
        super
        subclass.supports_parallel = supports_parallel?
      end
    end

    extend Parallelism

    self.supports_parallel = false

    # This module marks an Adapter as supporting informational responses
    # (1xx status codes, such as 100 Continue and 103 Early Hints).
    #
    # Faraday::Adapter extends this module. Adapters opt in by setting
    # `self.supports_informational_responses = true` and promise to deliver
    # 1xx responses, in arrival order, through the {#informational_response}
    # helper. Adapters that leave the flag as false never emit informational
    # events.
    module InformationalResponses
      attr_writer :supports_informational_responses

      def supports_informational_responses?
        @supports_informational_responses
      end

      def inherited(subclass)
        super
        subclass.supports_informational_responses = supports_informational_responses?
      end
    end

    extend InformationalResponses

    self.supports_informational_responses = false

    def initialize(_app = nil, opts = {}, &block)
      @app = lambda(&:response)
      @connection_options = opts
      @config_block = block
    end

    # Yields or returns an adapter's configured connection. Depends on
    # #build_connection being defined on this adapter.
    #
    # @param env [Faraday::Env, Hash] The env object for a faraday request.
    #
    # @return The return value of the given block, or the HTTP connection object
    #         if no block is given.
    def connection(env)
      conn = build_connection(env)
      return conn unless block_given?

      yield conn
    end

    # Close any persistent connections. The adapter should still be usable
    # after calling close.
    def close
      # Possible implementation:
      #   @app.close if @app.respond_to?(:close)
    end

    def call(env)
      env.clear_body if env.needs_body?
      env.response = Response.new unless env.response.is_a?(Response)
      register_information_callback(env)
    end

    private

    # Registers the optional per-request `on_information` Proc provided via
    # the request options so callers can observe 1xx responses as they arrive.
    #
    # @param env [Faraday::Env] the request env
    # @return [void]
    def register_information_callback(env)
      callback = env.request&.on_information
      env.response.on_information(&callback) if callback.is_a?(Proc)
    end

    # Delivers an informational HTTP response (a 1xx status, such as 100
    # Continue or 103 Early Hints) to registered listeners before the final
    # response is saved.
    #
    # Each call provides listeners with an independent, immutable snapshot
    # of the given headers. Informational responses do not update the env's
    # status or headers, do not trigger on_complete callbacks and do not
    # affect JSON decoding or error-raising middleware. The final response
    # still determines the request status.
    #
    # Only available on adapters that declare the capability by setting
    # `self.supports_informational_responses = true`; calling it from an
    # adapter without the capability raises, since such an adapter must never
    # fabricate informational events.
    #
    # @param env [Faraday::Env] the request env
    # @param status [Integer, #to_i] informational HTTP status code (1xx)
    # @param headers [Hash, nil] headers received with the informational
    #   response
    #
    # @return [Faraday::Response::Information] the delivered, immutable
    #   snapshot
    def informational_response(env, status, headers = nil)
      unless self.class.supports_informational_responses?
        raise Faraday::Error,
              "#{self.class} does not support informational responses. " \
              'Set self.supports_informational_responses = true to enable them.'
      end

      env.response.information!(status, headers)
    end

    # Marks the response as aborted without a final response. Adapters should
    # call this when the request is cancelled or fails before the final
    # response arrives (after potentially delivering informational responses)
    # so that late 1xx events are rejected and pending callbacks released.
    #
    # @param env [Faraday::Env] the request env
    # @param error [Exception, String, nil] the reason for the abort
    #
    # @return [Exception] the stored abort error
    def abort_response(env, error = nil)
      env.response.abort(error)
    end

    def save_response(env, status, body, headers = nil, reason_phrase = nil, finished: true)
      env.status = status
      env.body = body
      env.reason_phrase = reason_phrase&.to_s&.strip
      env.response_headers = Utils::Headers.new.tap do |response_headers|
        response_headers.update headers unless headers.nil?
        yield(response_headers) if block_given?
      end

      env.response.finish(env) unless env.parallel? || !finished
      env.response
    end

    # Fetches either a read, write, or open timeout setting. Defaults to the
    # :timeout value if a more specific one is not given.
    #
    # @param type [Symbol] Describes which timeout setting to get: :read,
    #                      :write, or :open.
    # @param options [Hash] Hash containing Symbol keys like :timeout,
    #                       :read_timeout, :write_timeout, or :open_timeout
    #
    # @return [Integer, nil] Timeout duration in seconds, or nil if no timeout
    #                        has been set.
    def request_timeout(type, options)
      key = TIMEOUT_KEYS.fetch(type) do
        msg = "Expected :read, :write, :open. Got #{type.inspect} :("
        raise ArgumentError, msg
      end
      options[key] || options[:timeout]
    end
  end
end

require 'faraday/adapter/test'
