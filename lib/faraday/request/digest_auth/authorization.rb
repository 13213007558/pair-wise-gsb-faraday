# frozen_string_literal: true

module Faraday
  class Request
    class DigestAuth < Faraday::Middleware
      # Computes the Authorization header value for a single request, along
      # with the expected rspauth proof used to verify the server's
      # Authentication-Info header.
      class Authorization
        attr_reader :nonce

        # @param username [String]
        # @param password [String]
        # @param space [ProtectionSpace] the protection space to draw from
        # @param http_method [Symbol] the request HTTP method
        # @param uri [String] the request-target
        # @param entity_body [#call] callable returning the exact entity
        #   bytes being sent (only invoked for qop=auth-int)
        def initialize(username:, password:, space:, http_method:, uri:, entity_body:)
          @username = username
          @realm = space.realm
          @opaque = space.opaque
          @algorithm = space.algorithm
          @sess = space.sess?
          @qop = space.qop
          @uri = uri
          @nonce, @cnonce, nonce_count = space.next_nonce_count
          @nc = format('%08x', nonce_count)
          @entity_hash = @qop == 'auth-int' ? digest(entity_body.call) : nil
          @ha1 = digest("#{username}:#{space.realm}:#{password}")
          @ha1 = digest("#{@ha1}:#{@nonce}:#{@cnonce}") if @sess
          @response = compute_response(http_method)
        end

        # @return [String] the full Authorization header value
        def to_s
          parts = [
            %(username="#{quote @username}"),
            %(realm="#{quote @realm}"),
            %(nonce="#{quote @nonce}"),
            %(uri="#{quote @uri}"),
            %(response="#{@response}"),
            "algorithm=#{@algorithm}#{'-sess' if @sess}"
          ]
          parts << %(opaque="#{quote @opaque}") if @opaque
          if @qop
            parts << "qop=#{@qop}"
            parts << "nc=#{@nc}"
            parts << %(cnonce="#{@cnonce}")
          end
          "Digest #{parts.join(', ')}"
        end

        # @return [Boolean] whether the given Authentication-Info params
        #   belong to this request and can therefore be verified
        def rspauth_matches?(info)
          return true unless @qop

          info['cnonce'] == @cnonce && info['nc'] == @nc
        end

        # @return [String] the expected rspauth mutual authentication proof
        def expected_rspauth
          ha2 = digest([+'', @uri, (@entity_hash if @qop == 'auth-int')].compact.join(':'))
          if @qop
            digest([@ha1, @nonce, @nc, @cnonce, @qop, ha2].join(':'))
          else
            digest([@ha1, @nonce, ha2].join(':'))
          end
        end

        private

        def compute_response(http_method)
          ha2 = digest([http_method.to_s.upcase, @uri, @entity_hash].compact.join(':'))
          if @qop
            digest([@ha1, @nonce, @nc, @cnonce, @qop, ha2].join(':'))
          else
            digest([@ha1, @nonce, ha2].join(':'))
          end
        end

        # @return [String] hex digest of the given string
        def digest(string)
          OpenSSL::Digest.new(DigestAuth::ALGORITHMS.fetch(@algorithm)).hexdigest(string)
        end

        def quote(string)
          string.to_s.gsub(/(["\\])/, '\\\\\1')
        end
      end
    end
  end
end

