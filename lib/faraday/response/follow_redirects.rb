# frozen_string_literal: true

module Faraday
  class Response
    # FollowRedirects is a middleware that follows HTTP redirect responses
    # (301, 302, 303, 307 and 308 by default) and returns the final response
    # to the caller.
    #
    # Every hop is performed by re-entering the middleware stack below this
    # middleware with an updated env, so each redirect goes through the same,
    # clearly defined middleware order (e.g. logging, authorization and the
    # adapter). Middleware stacked above FollowRedirects only runs once per
    # logical request.
    #
    # The redirect chain is recorded on the final env under
    # +env[:redirects]+: an array of hashes with the +:method+, +:url+,
    # +:status+ and +:location+ of every hop, so callers can inspect where
    # the request has been. Errors raised while following redirects mention
    # the failing hop and the chain walked so far, instead of a generic
    # "request failed".
    #
    # @example
    #   Faraday.new('http://example.com') do |conn|
    #     conn.response :follow_redirects, limit: 5
    #     conn.adapter Faraday.default_adapter
    #   end
    #
    # @option options [Integer] :limit (3) maximum number of redirects to
    #   follow before raising {RedirectLimitReached}.
    # @option options [Array<Integer>] :statuses ([301, 302, 303, 307, 308])
    #   response statuses that are treated as redirects when they carry a
    #   Location header.
    # @option options [Boolean] :standards_compliant (false) when false, a
    #   301/302 response to a POST request is rewritten to a body-less GET
    #   for compatibility with common server expectations; when true, the
    #   original method and body are preserved as RFC 7231 allows.
    # @option options [Boolean] :allow_https_to_http (false) allow redirects
    #   that downgrade from HTTPS to HTTP. Disabled by default because it
    #   would silently drop transport security.
    class FollowRedirects < Faraday::Middleware
      # Raised when the configured redirect limit is reached.
      class RedirectLimitReached < Faraday::ClientError; end

      # Raised when a redirect points to an already visited URL.
      class RedirectLoopError < Faraday::ClientError; end

      # Raised when a redirect would downgrade from HTTPS to HTTP.
      class InsecureRedirectError < Faraday::ClientError; end

      # Raised when a redirect keeps the request body, but the body cannot
      # be sent a second time.
      class NonReplayableBodyError < Faraday::ClientError; end

      LOCATION = 'Location'
      AUTHORIZATION = 'Authorization'
      HOST = 'Host'

      # HTTP status codes treated as redirects by default.
      REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

      # Entity headers removed together with the request body when a
      # redirect rewrites the request into a body-less one.
      ENTITY_HEADERS = %w[Content-Type Content-Length Content-Encoding Content-MD5].freeze

      DEFAULT_OPTIONS = {
        limit: 3,
        statuses: REDIRECT_STATUSES,
        standards_compliant: false,
        allow_https_to_http: false
      }.freeze

      def call(env)
        perform_with_redirection(env, options[:limit], [], [])
      end

      private

      def perform_with_redirection(env, remaining, redirects, visited)
        visited += [env.url.to_s]

        @app.call(env).on_complete do |response_env|
          next unless follow_redirect?(response_env)

          target = redirect_target(response_env)
          redirects += [hop(response_env, target)]
          response_env[:redirects] = redirects

          check_redirect_allowed!(response_env, target, remaining, redirects, visited)

          follow_redirect(response_env, target)
          perform_with_redirection(response_env, remaining - 1, redirects, visited)
        end
      end

      def follow_redirect?(env)
        allowed_statuses.include?(env.status) && !env.response_headers[LOCATION].nil?
      end

      def allowed_statuses
        Array(options[:statuses])
      end

      # Resolves the Location header against the current URL, so relative
      # locations (e.g. "/next" or "next?a=1") are supported.
      def redirect_target(env)
        env.url + env.response_headers[LOCATION].to_s.strip
      end

      def check_redirect_allowed!(env, target, remaining, redirects, visited)
        if remaining <= 0
          raise RedirectLimitReached.new(
            "redirect limit of #{options[:limit]} reached; " \
            "stopped at #{describe_chain(redirects)}",
            response_values(env)
          )
        end

        if visited.include?(target.to_s)
          raise RedirectLoopError.new(
            "redirect loop detected: #{target} was already visited; " \
            "chain: #{describe_chain(redirects)}",
            response_values(env)
          )
        end

        return unless insecure_downgrade?(env.url, target) && !options[:allow_https_to_http]

        raise InsecureRedirectError.new(
          "refusing to follow redirect from HTTPS to HTTP: #{env.url} -> #{target}",
          response_values(env)
        )
      end

      def follow_redirect(env, target)
        clear_sensitive_headers(env) unless same_origin?(env.url, target)

        if convert_to_get?(env)
          env.method = :get
          env.request_body = nil
          clear_entity_headers(env)
        else
          replay_body(env, target)
        end

        env.url = target
        reset_response_state(env)
      end

      # 303 always turns the follow-up request into a body-less GET (unless
      # it was a HEAD). 301/302 only do so for POST, and only when the
      # explicit compatibility rewrite is enabled.
      def convert_to_get?(env)
        return false if env.method == :head

        env.status == 303 ||
          (!options[:standards_compliant] && env.method == :post && [301, 302].include?(env.status))
      end

      # Bodies preserved across a redirect must be replayable: strings can
      # be sent again as-is, IO-like bodies are rewound. Anything else
      # (e.g. a one-shot stream) cannot be sent a second time.
      def replay_body(env, target)
        body = env.request_body
        return if body.nil? || body.respond_to?(:to_str)
        return if body.respond_to?(:rewind) && rewind_body(body)

        raise NonReplayableBodyError.new(
          "cannot follow #{env.status} redirect to #{target}: " \
          "#{body.class} request body cannot be replayed; " \
          'use a String or a rewindable IO',
          response_values(env)
        )
      end

      def rewind_body(body)
        body.rewind
        true
      rescue StandardError
        false
      end

      def clear_entity_headers(env)
        ENTITY_HEADERS.each { |header| env.request_headers.delete(header) }
      end

      # Credentials and a manually set Host header must not leak into a
      # different origin.
      def clear_sensitive_headers(env)
        env.request_headers.delete(AUTHORIZATION)
        env.request_headers.delete(HOST)
      end

      def same_origin?(from, to)
        from.scheme == to.scheme && from.host == to.host && from.port == to.port
      end

      def insecure_downgrade?(from, to)
        from.scheme == 'https' && to.scheme == 'http'
      end

      # Each hop starts as a fresh request: response state from the previous
      # hop must not leak into the next trip through the stack.
      def reset_response_state(env)
        env.status = nil
        env.reason_phrase = nil
        env.response_body = nil
        env.response_headers = Utils::Headers.new
      end

      def hop(env, target)
        {
          method: env.method,
          url: env.url.to_s,
          status: env.status,
          location: target.to_s
        }
      end

      def describe_chain(redirects)
        chain = redirects.map { |hop| "#{hop[:method].to_s.upcase} #{hop[:url]} [#{hop[:status]}]" }
        chain << redirects.last[:location]
        chain.join(' -> ')
      end

      def response_values(env)
        {
          status: env.status,
          headers: env.response_headers,
          body: env.response_body,
          request: {
            method: env.method,
            url: env.url,
            headers: env.request_headers,
            body: env.request_body
          },
          redirects: env[:redirects]
        }
      end
    end
  end
end

Faraday::Response.register_middleware(follow_redirects: Faraday::Response::FollowRedirects)
