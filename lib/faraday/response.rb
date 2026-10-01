# frozen_string_literal: true

require 'forwardable'
require 'monitor'

module Faraday
  # Response represents an HTTP response from making an HTTP request.
  class Response
    extend Forwardable
    extend MiddlewareRegistry

    # Raised when an informational response (1xx) is delivered after the
    # response has already finished or been aborted.
    class LateInformationError < Error
      # @param status [Integer] the status of the rejected informational response
      def initialize(status = nil)
        suffix = status ? " (status #{status})" : ''
        super("informational response received after the response ended" \
              "#{suffix}")
      end
    end

    # Raised when the response is finished or otherwise used after the request
    # has been aborted (e.g. through a callback error or request cancellation).
    class AbortedError < Error
      def initialize(message = 'response was aborted before it finished')
        super
      end
    end

    def initialize(env = nil)
      @env = Env.from(env) if env
      initialize_information_state
    end

    attr_reader :env

    def status
      finished? ? env.status : nil
    end

    def reason_phrase
      finished? ? env.reason_phrase : nil
    end

    def headers
      finished? ? env.response_headers : {}
    end

    def_delegator :headers, :[]

    def body
      finished? ? env.body : nil
    end

    def url
      finished? ? env.url : nil
    end

    def finished?
      !!env
    end

    # @return [Boolean] true if the request was aborted before a final
    #   response was received (e.g. callback error or cancellation)
    def aborted?
      @mutex.synchronize { @aborted }
    end

    # @return [Exception, nil] the error that aborted the request, if any
    def abort_error
      @mutex.synchronize { @abort_error }
    end

    # @return [Array<Faraday::Response::Information>] independent, immutable
    #   snapshots of the informational responses (1xx) received so far, in
    #   arrival order
    def informations
      @mutex.synchronize { @informations.dup }
    end

    def on_complete(&block)
      @mutex.synchronize do
        raise @abort_error if @aborted

        if finished?
          block.call(env)
        else
          @on_complete_callbacks << block
        end
      end
      self
    end

    # Registers a block to be called, in arrival order, for every
    # informational response (1xx, e.g. 100 Continue or 103 Early Hints)
    # received before the final response.
    #
    # Informational responses never trigger {#on_complete}, JSON decoding or
    # error-raising middleware, and they do not affect the final status.
    #
    # If informational responses have already been received, the block is
    # immediately replayed their snapshots in order. The block is not invoked
    # once the response has finished or been aborted.
    #
    # @yield [information] handles an informational response
    # @yieldparam information [Faraday::Response::Information] independent,
    #   immutable snapshot of the informational response
    #
    # @return [self]
    def on_information(&block)
      raise ArgumentError, 'a block is required' unless block

      replay = @mutex.synchronize do
        raise @abort_error if @aborted
        return self if finished?

        @on_information_callbacks << block
        @informations.dup
      end

      replay.each { |information| block.call(information) }
      self
    end

    def finish(env)
      @mutex.synchronize do
        raise @abort_error if @aborted
        raise 'response already finished' if finished?

        @env = env.is_a?(Env) ? env : Env.from(env)
        callbacks = @on_complete_callbacks
        @on_complete_callbacks = []
        @on_information_callbacks = []
        callbacks
      end.each { |callback| callback.call(@env) }
      self
    end

    # Delivers an informational response (1xx) to registered callbacks, in
    # arrival order, and stores an independent, immutable snapshot.
    #
    # Used by adapters that support informational responses. Late events
    # received after {#finish} or {#abort} are rejected.
    #
    # @param status [Integer, #to_i] informational HTTP status code (1xx)
    # @param headers [Hash, nil] headers received with the response
    #
    # @return [Faraday::Response::Information] the delivered snapshot
    # @raise [Faraday::Response::LateInformationError] if the response already
    #   ended
    # @raise [ArgumentError] unless status is a 1xx code
    def information!(status, headers = nil)
      information = build_information(status, headers)

      callbacks = @mutex.synchronize do
        raise LateInformationError.new(information.status) if finished? || @aborted

        @informations << information
        @on_information_callbacks.dup
      end

      callbacks.each do |callback|
        callback.call(information)
      rescue StandardError => e
        abort(e)
        raise
      end

      information
    end

    # Marks the response as terminated without a final response. This is the
    # end-state for request cancellation or a failure (including a failing
    # informational callback) that happens before the final response arrives.
    #
    # Subsequent {#information!} or {#finish} calls raise the stored error,
    # and no further callbacks are invoked.
    #
    # @param error [Exception, String, nil] the reason for the abort
    # @return [Exception] the stored abort error
    def abort(error = nil)
      error = case error
              when Exception then error
              when nil then AbortedError.new
              else AbortedError.new(error.to_s)
              end

      @mutex.synchronize do
        return @abort_error if @aborted || finished?

        @aborted = true
        @abort_error = error
        @on_complete_callbacks = []
        @on_information_callbacks = []
        @abort_error
      end
    end

    def success?
      finished? && env.success?
    end

    def to_hash
      {
        status: status, body: body,
        response_headers: headers,
        url: url
      }
    end

    # because @on_complete_callbacks cannot be marshalled
    def marshal_dump
      finished? ? to_hash : nil
    end

    def marshal_load(env)
      initialize_information_state
      @env = Env.from(env)
    end

    # Expand the env with more properties, without overriding existing ones.
    # Useful for applying request params after restoring a marshalled Response.
    def apply_request(request_env)
      raise "response didn't finish yet" unless finished?

      @env = Env.from(request_env).update(@env)
      self
    end

    private

    # Sets up monitor and callback/snapshot storage. Called by both
    # #initialize and #marshal_load so deserialized responses stay usable.
    def initialize_information_state
      @on_complete_callbacks = []
      @on_information_callbacks = []
      @informations = []
      @aborted = false
      @abort_error = nil
      @mutex = Monitor.new
    end

    def build_information(status, headers = nil)
      code = status.to_i
      unless (100...200).include?(code)
        raise ArgumentError,
              "expected an informational HTTP status (100-199), got #{status.inspect}"
      end

      Information.new(code, headers)
    end
  end
end

require 'faraday/response/information'
require 'faraday/response/json'
require 'faraday/response/logger'
require 'faraday/response/raise_error'
