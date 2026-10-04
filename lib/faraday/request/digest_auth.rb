# frozen_string_literal: true

require 'openssl'
require 'securerandom'

module Faraday
  class Request
    # Request middleware for HTTP Digest Access Authentication (RFC 7616).
    #
    # The middleware answers +WWW-Authenticate: Digest+ challenges on behalf of
    # the caller: it selects the strongest acceptable challenge when several
    # are offered, computes the +Authorization+ header (including the
    # +auth-int+ entity-body hash), keeps track of the nonce-count inside each
    # protection space, follows +stale+ and +nextnonce+ directives and verifies
    # +rspauth+ mutual authentication proofs.
    #
    # SHA-256 and SHA-512-256 (and their +-sess+ variants) are supported out of
    # the box. MD5 and MD5-sess are only accepted when the +allow_md5+ option
    # is explicitly enabled.
    #
    # @example
    #   Faraday.new('https://api.example.com') do |conn|
    #     conn.request :digest_auth, 'username', 'password', max_retries: 3
    #     conn.adapter Faraday.default_adapter
    #   end
    #
    # @note Place this middleware after any body-serializing middleware (JSON,
    #   url-encoded) and after redirect-following middleware, so that digests
    #   are computed over the exact entity bytes being sent and are never
    #   forwarded to a different origin.
    class DigestAuth < Faraday::Middleware
      KEY = 'Authorization'
      CHALLENGE_KEY = 'WWW-Authenticate'
      AUTH_INFO_KEY = 'Authentication-Info'

      # Maps a digest algorithm token (without the "-sess" suffix) to the
      # OpenSSL digest name.
      ALGORITHMS = {
        'SHA-512-256' => 'SHA512-256',
        'SHA-256' => 'SHA256',
        'MD5' => 'MD5'
      }.freeze

      DEFAULT_OPTIONS = {
        # MD5 digests are rejected unless explicitly allowed.
        allow_md5: false,
        # Maximum number of 401 retries for a single request.
        max_retries: 3,
        # Optional callable returning a fresh request body for retries, used
        # when the original body cannot be replayed (e.g. a one-shot IO).
        body_factory: nil
      }.freeze

      # Env custom members used to carry per-request state.
      CHAIN_ORIGIN_KEY = :digest_auth_chain_origin
      ADDED_HEADER_KEY = :digest_auth_added_header
      CONTEXT_KEY = :digest_auth_context

      # @param app [#call]
      # @param username [String]
      # @param password [String]
      # @param options [Hash]
      # @option options [Boolean] :allow_md5 (false) accept MD5/MD5-sess challenges
      # @option options [Integer] :max_retries (3) maximum number of 401 retries per request
      # @option options [#call] :body_factory (nil) factory returning a fresh
      #   request body when the original one cannot be replayed for a retry
      def initialize(app, username, password, options = {})
        @username = username
        @password = password
        @spaces = {}
        @spaces_lock = Mutex.new
        super(app, options)
      end

      # @param env [Faraday::Env]
      def call(env)
        raise Faraday::Error, 'Faraday::Request::DigestAuth does not support parallel requests' if env.parallel?

        origin = origin_of(env.url)
        cross_origin = (env[CHAIN_ORIGIN_KEY] ||= origin) != origin
        # A redirect led to a different origin: never forward credentials or
        # precomputed digests, and do not answer its challenges.
        env.request_headers.delete(KEY) if cross_origin && env[ADDED_HEADER_KEY]

        body_source = nil
        attempts = 0
        used_nonce = nil

        loop do
          space = cross_origin ? nil : prepare_request(env, origin)
          used_nonce = env[CONTEXT_KEY].nonce if space
          response = @app.call(env)
          response_env = response.env
          handle_authentication_info(response_env, space) if space

          challenge = retriable_challenge(response_env, cross_origin, used_nonce, attempts)
          return response unless challenge

          attempts += 1
          body_source ||= replayable_body_source(env)
          env.request_body = body_source.call
          register_space(origin, challenge)
          reset_response_state(response_env)
        end
      end

      private

      # Adds a proactive Authorization header when a protection space is
      # known for the origin.
      #
      # @return [ProtectionSpace, nil] the space used, if any
      def prepare_request(env, origin)
        space = space_for(origin)
        return unless space

        env[CONTEXT_KEY] = Authorization.new(
          username: @username, password: @password, space: space,
          http_method: env.method, uri: request_target(env.url),
          entity_body: -> { entity_body(env) }
        )
        env.request_headers[KEY] = env[CONTEXT_KEY].to_s
        env[ADDED_HEADER_KEY] = true
        space
      end

      # @return [Challenge, nil] the challenge to answer with a retry, or nil
      #   when the response must be returned to the caller as-is
      def retriable_challenge(response_env, cross_origin, used_nonce, attempts)
        return if response_env.status != 401 || cross_origin

        challenge = Challenge.select(response_env.response_headers[CHALLENGE_KEY],
                                     allow_md5: options[:allow_md5])
        return unless challenge
        # The server kept the nonce we already used and does not flag it as
        # stale: the credentials were rejected, retrying is pointless.
        return if used_nonce && challenge.nonce == used_nonce && !challenge.stale?
        return if attempts >= options[:max_retries]

        challenge
      end

      # @return [String] scheme, host and port identifying an origin
      def origin_of(url)
        "#{url.scheme}://#{url.host}:#{url.port}"
      end

      # @return [String] the request-target (path and query) sent to the server
      def request_target(url)
        path = url.path.to_s
        path = '/' if path.empty?
        url.query ? "#{path}?#{url.query}" : path
      end

      def space_for(origin)
        @spaces_lock.synchronize { @spaces[origin] }
      end

      def register_space(origin, challenge)
        @spaces_lock.synchronize do
          existing = @spaces[origin]
          # Concurrent requests may each receive the same challenge: keep the
          # existing protection space so the nonce-count keeps advancing
          # instead of being reset by every 401 response.
          if existing && existing.realm == challenge.realm && existing.nonce == challenge.nonce
            return existing
          end

          @spaces[origin] = ProtectionSpace.new(origin: origin, challenge: challenge)
        end
      end

      # @return [String] the exact entity bytes about to be sent
      def entity_body(env)
        body = env.request_body
        case body
        when nil then +''
        when String then body
        else
          return read_rewindable(body) if body.respond_to?(:read) && body.respond_to?(:rewind)

          raise Faraday::Error,
                "DigestAuth cannot compute the auth-int entity hash for a #{body.class} body. " \
                'Serialize the body before this middleware or provide a String body.'
        end
      end

      def read_rewindable(body)
        body.rewind
        data = body.read.to_s
        body.rewind
        data
      rescue IOError, SystemCallError => e
        raise Faraday::Error, "DigestAuth cannot read the request body for the auth-int hash: #{e.message}"
      end

      # @return [#call] a callable producing a fresh body for each retry
      def replayable_body_source(env)
        factory = options[:body_factory]
        return factory if factory

        body = env.request_body
        return -> { body } if body.nil? || body.is_a?(String)
        return -> { body.tap(&:rewind) } if body.respond_to?(:rewind)

        raise Faraday::Error,
              "DigestAuth cannot resend a #{body.class} request body after a 401 response. " \
              'Provide a rewindable body or the :body_factory option.'
      end

      # Processes the Authentication-Info response header: applies nextnonce
      # rotations and verifies the rspauth mutual authentication proof.
      def handle_authentication_info(env, space)
        header = env.response_headers[AUTH_INFO_KEY]
        return if header.nil? || header.empty?

        info = Challenge.auth_params(header)
        space.rotate_nonce(info['nextnonce']) if info['nextnonce']
        verify_rspauth(env, info) if info['rspauth']
      end

      def verify_rspauth(env, info)
        authorization = env[CONTEXT_KEY]
        return unless authorization&.rspauth_matches?(info)
        return if secure_compare(authorization.expected_rspauth, info['rspauth'])

        raise Faraday::Error, 'Digest Authentication-Info rspauth verification failed'
      end

      def secure_compare(left, right)
        left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
      end

      # Clears the response state so the env can be sent down the stack again.
      def reset_response_state(env)
        env.status = nil
        env.reason_phrase = nil
        env.response_body = nil
        env.response_headers = Utils::Headers.new
        env.response = nil
      end
    end
  end
end

require 'faraday/request/digest_auth/authorization'
require 'faraday/request/digest_auth/challenge'
require 'faraday/request/digest_auth/protection_space'

Faraday::Request.register_middleware(digest_auth: Faraday::Request::DigestAuth)
