# frozen_string_literal: true

module Faraday
  class Request
    # FollowRedirects is a Faraday middleware that transparently follows HTTP
    # redirects (301, 302, 303, 307 and 308) before returning the response.
    #
    # Every hop re-traverses the middleware stacked *below* this one, so place
    # it early in the stack (e.g. before encoding or authentication middleware)
    # if later middleware should see each redirected request.
    #
    # The hops followed are recorded on the final env as +env[:redirects]+,
    # an array of { status:, from:, to: } hashes. When following fails, the
    # raised error (a Faraday::RedirectError subclass) names the failing hop
    # and carries the hops completed so far in +error.redirects+.
    #
    # @example
    #   Faraday.new(...) do |conn|
    #     conn.request :follow_redirects, limit: 5
    #   end
    class FollowRedirects < Faraday::Middleware
      # HTTP status codes this middleware follows.
      REDIRECT_CODES = [301, 302, 303, 307, 308].freeze

      # Headers tied to the request entity. They are removed together with
      # the body when a redirect rewrites the request into a body-less one.
      ENTITY_HEADERS = ['Content-Type', 'Content-Length', 'Content-Encoding', 'Content-MD5'].freeze

      # Headers carrying credentials. They are dropped on cross-origin
      # redirects when the +clear_authorization_header+ option is enabled.
      CREDENTIAL_HEADERS = %w[Authorization Proxy-Authorization].freeze

      # @!attribute default_options
      #
      # @option options [Integer] :limit (3)
      #   maximum number of redirects to follow before raising
      #   Faraday::RedirectLimitReached.
      # @option options [Boolean] :convert_post_to_get_on_301_302 (true)
      #   rewrite POST (but not other methods) into GET on 301/302, matching
      #   widespread browser behaviour. 303 always rewrites to GET.
      #   307/308 never rewrite the method.
      # @option options [Boolean] :allow_https_to_http (false)
      #   allow redirects that downgrade from HTTPS to HTTP. Refused by
      #   default with Faraday::InsecureRedirectError.
      # @option options [Boolean] :clear_authorization_header (true)
      #   remove credential headers when a redirect crosses origins.
      DEFAULT_OPTIONS = {
        limit: 3,
        convert_post_to_get_on_301_302: true,
        allow_https_to_http: false,
        clear_authorization_header: true
      }.freeze

      def call(env)
        env[:redirects] ||= []
        perform_with_redirection(env, [env.url.to_s])
      end

      private

      def perform_with_redirection(env, visited)
        app.call(env).on_complete do |response_env|
          follow_redirect(response_env, visited) if redirect_with_location?(response_env)
        end
      end

      def redirect_with_location?(env)
        REDIRECT_CODES.include?(env.status) && env.response_headers['Location']
      end

      def follow_redirect(env, visited)
        from_url = env.url
        to_url = resolve_location(from_url, env.response_headers['Location'], env)
        hops = env[:redirects]

        check_limit!(env, to_url, hops)
        check_https_downgrade!(from_url, to_url, hops)
        check_loop!(to_url, visited, hops)

        hops << { status: env.status, from: from_url.to_s, to: to_url.to_s }
        visited << to_url.to_s

        rewrite_request(env, to_url, hops)
        reset_response(env)
        perform_with_redirection(env, visited)
      end

      # Resolves a possibly relative Location header against the request URL.
      def resolve_location(from_url, location, env)
        from_url.merge(location)
      rescue URI::Error => e
        raise RedirectError.new(
          "invalid redirect Location #{location.inspect}: #{e.message}",
          env[:redirects].dup
        )
      end

      def check_limit!(env, to_url, hops)
        return unless hops.size >= options[:limit]

        raise RedirectLimitReached.new(
          "redirect limit of #{options[:limit]} reached; " \
            "not following #{env.status} redirect from #{env.url} to #{to_url}",
          hops.dup
        )
      end

      def check_https_downgrade!(from_url, to_url, hops)
        return if options[:allow_https_to_http]
        return unless from_url.scheme == 'https' && to_url.scheme == 'http'

        raise InsecureRedirectError.new(
          "refusing to follow HTTPS to HTTP downgrade from #{from_url} to #{to_url}",
          hops.dup
        )
      end

      def check_loop!(to_url, visited, hops)
        return unless visited.include?(to_url.to_s)

        raise RedirectLoopDetected.new(
          "redirect loop detected: #{to_url} was already visited in this chain",
          hops.dup
        )
      end

      # Rewrites the request part of the env for the next hop: converts the
      # method when required, drops credentials on cross-origin redirects and
      # makes sure a kept body can be replayed.
      def rewrite_request(env, to_url, hops)
        clear_sensitive_headers(env) unless same_origin?(env.url, to_url)

        if convert_to_get?(env.status, env.method)
          env.method = :get
          env.request_body = nil
          ENTITY_HEADERS.each { |header| env.request_headers.delete(header) }
        else
          prepare_body_for_replay(env, hops)
        end
        env.url = to_url
      end

      # A body kept across a redirect must be sent again. Strings are
      # inherently replayable, IO-like bodies are rewound, anything else
      # cannot be sent a second time.
      def prepare_body_for_replay(env, hops)
        body = env.request_body
        return if body.nil? || body.is_a?(String)

        if body.respond_to?(:rewind)
          body.rewind
        else
          raise NonReplayableBodyError.new(
            "cannot follow #{env.status} redirect to #{env.url}: " \
              "request body (#{body.class}) cannot be replayed",
            hops.dup
          )
        end
      end

      def clear_sensitive_headers(env)
        env.request_headers.delete('Host')
        return unless options[:clear_authorization_header]

        CREDENTIAL_HEADERS.each { |header| env.request_headers.delete(header) }
      end

      def same_origin?(from_url, to_url)
        from_url.scheme == to_url.scheme &&
          from_url.host == to_url.host &&
          from_url.port == to_url.port
      end

      def convert_to_get?(status, method)
        return false if %i[get head].include?(method)
        return true if status == 303

        [301, 302].include?(status) && method == :post &&
          options[:convert_post_to_get_on_301_302]
      end

      # Clears the response part of the env so the next hop starts clean.
      def reset_response(env)
        env.status = nil
        env.reason_phrase = nil
        env.response = nil
        env.response_body = nil
        env.response_headers = Utils::Headers.new
      end
    end
  end
end

Faraday::Request.register_middleware(follow_redirects: Faraday::Request::FollowRedirects)
