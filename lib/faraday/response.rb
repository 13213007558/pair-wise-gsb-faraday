# frozen_string_literal: true

require 'forwardable'
require 'monitor'

module Faraday
  # Response represents an HTTP response from making an HTTP request.
  class Response
    # Represents a provisional 1xx HTTP response. Informational responses do
    # not complete the request and do not run response middleware.
    class Information
      attr_reader :status, :headers, :reason_phrase

      def initialize(status, headers = nil, reason_phrase = nil)
        status = Integer(status)
        unless status >= 100 && status < 200
          raise ArgumentError, 'expected an informational status (100-199)'
        end

        @status = status
        @headers = Utils::Headers.new
        headers&.each do |key, value|
          @headers[key] = value.respond_to?(:dup) ? value.dup : value
        end
        @headers.each_value { |value| value.freeze if value.respond_to?(:freeze) }
        @headers.freeze
        @reason_phrase = reason_phrase&.to_s&.strip&.freeze
        freeze
      end

      def [](key)
        headers[key]
      end

      def to_hash
        { status: status, headers: headers.to_hash, reason_phrase: reason_phrase }
      end
    end

    extend Forwardable
    extend MiddlewareRegistry

    def initialize(env = nil)
      @monitor = Monitor.new
      @env = Env.from(env) if env
      @on_complete_callbacks = []
      @on_information_callbacks = []
      @state = @env ? :complete : :pending
      @error = nil
    end

    attr_reader :env, :error

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
      @state == :complete
    end

    def pending?
      @state == :pending
    end

    def failed?
      @state == :failed
    end

    def canceled?
      @state == :canceled
    end

    def closed?
      !pending?
    end

    def on_complete(&block)
      if finished?
        yield(env)
      elsif pending?
        @on_complete_callbacks << block
      end
      self
    end

    def on_informational_response(&block)
      @monitor.synchronize { @on_information_callbacks << block if pending? }
      self
    end
    alias on_information on_informational_response

    def informational_response!(status_or_information, headers = nil, reason_phrase = nil)
      information = build_information(status_or_information, headers, reason_phrase)

      callbacks = @monitor.synchronize do
        raise late_information_error unless pending?

        @on_information_callbacks.dup
      end

      callbacks.each do |callback|
        callback.call(information)
        raise error if closed? && error
      end

      information
    rescue Faraday::LateInformationResponseError
      raise
    rescue => error
      fail(error) if pending?
      raise
    end
    alias information! informational_response!

    def finish(env)
      callbacks = @monitor.synchronize do
        raise 'response already finished' if finished?
        raise 'response already closed' if closed?

        @env = env.is_a?(Env) ? env : Env.from(env)
        @state = :complete
        @on_complete_callbacks.dup
      end

      callbacks.each { |callback| callback.call(@env) }
      self
    end

    def fail(error)
      @monitor.synchronize do
        raise 'response already finished' if finished?
        raise 'response already closed' if closed?

        @error = error
        @state = :failed
      end
      self
    end

    def cancel(error = nil)
      @monitor.synchronize do
        raise 'response already finished' if finished?
        raise 'response already closed' if closed?

        @error = error || Faraday::RequestCanceled.new(nil, self)
        @state = :canceled
      end
      self
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
      @monitor = Monitor.new
      @env = Env.from(env)
      @on_complete_callbacks = []
      @on_information_callbacks = []
      @state = :complete
      @error = nil
    end

    # Expand the env with more properties, without overriding existing ones.
    # Useful for applying request params after restoring a marshalled Response.
    def apply_request(request_env)
      raise "response didn't finish yet" unless finished?

      @env = Env.from(request_env).update(@env)
      self
    end

    private

    def late_information_error
      Faraday::LateInformationResponseError.new(
        "cannot deliver informational response to a #{@state} response", self
      )
    end

    def build_information(status_or_information, headers, reason_phrase)
      if headers || reason_phrase || status_or_information.is_a?(Integer)
        return Information.new(status_or_information, headers, reason_phrase)
      end

      coerce_information(status_or_information)
    end

    def coerce_information(information)
      case information
      when Information
        information
      when Hash
        Information.new(
          information.fetch(:status),
          information[:headers],
          information[:reason_phrase]
        )
      when Array
        Information.new(*information)
      else
        if information.respond_to?(:status)
          Information.new(information.status, information.headers, information.reason_phrase)
        else
          Information.new(information)
        end
      end
    rescue KeyError => error
      raise ArgumentError, error.message
    end
  end
end

require 'faraday/response/json'
require 'faraday/response/logger'
require 'faraday/response/raise_error'
