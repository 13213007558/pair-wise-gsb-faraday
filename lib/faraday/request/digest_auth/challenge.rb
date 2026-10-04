# frozen_string_literal: true

module Faraday
  class Request
    class DigestAuth < Faraday::Middleware
      # A parsed, usable WWW-Authenticate Digest challenge.
      class Challenge
        # Preference order used when a server offers several challenges.
        ALGORITHM_PREFERENCE = { 'SHA-512-256' => 0, 'SHA-256' => 1, 'MD5' => 2 }.freeze

        # A new challenge starts at the beginning of the header or after a
        # comma, as a scheme token followed by whitespace (auth-params are
        # always "token=" pairs, so a token directly followed by "=" never
        # opens a new challenge).
        CHALLENGE_BOUNDARY = /(?:\A|,)[ \t]*([A-Za-z][A-Za-z0-9!#$%&'*+.^_\x60|~-]*)[ \t]+/
        AUTH_PARAM = /([A-Za-z][A-Za-z0-9_-]*)[ \t]*=[ \t]*(?:"((?:[^"\\]|\\.)*)"|([^, \t]*))/

        attr_reader :realm, :nonce, :opaque, :algorithm, :qop, :stale

        def initialize(realm:, nonce:, opaque:, algorithm:, sess:, qop:, stale:)
          @realm = realm
          @nonce = nonce
          @opaque = opaque
          @algorithm = algorithm
          @sess = sess
          @qop = qop
          @stale = stale
        end

        def sess?
          @sess
        end

        def stale?
          @stale
        end

        class << self
          # Selects the strongest usable Digest challenge offered by a
          # WWW-Authenticate header, honouring the MD5 policy and preferring
          # qop=auth over qop=auth-int.
          #
          # @return [Challenge, nil]
          def select(header, allow_md5: false)
            parse_challenges(header).filter_map do |scheme, params|
              next unless scheme.casecmp?('digest')

              build(params, allow_md5: allow_md5)
            end.min_by { |challenge| ALGORITHM_PREFERENCE.fetch(challenge.algorithm) }
          end

          # @return [Hash] auth-param names (downcased) to unescaped values
          def auth_params(string)
            params = {}
            string.scan(AUTH_PARAM) do |key, quoted, token|
              params[key.downcase] = quoted ? quoted.gsub(/\\(.)/, '\\1') : token
            end
            params
          end

          private

          # @return [Array<Array(String, Hash)>] list of [scheme, auth-params]
          def parse_challenges(header)
            boundaries = []
            header.to_s.to_enum(:scan, CHALLENGE_BOUNDARY).each do
              match = Regexp.last_match
              boundaries << [match.begin(0), match.end(0), match[1]]
            end
            boundaries.each_with_index.map do |(_from, params_from, scheme), index|
              params_to = index + 1 < boundaries.size ? boundaries[index + 1][0] : header.length
              [scheme, auth_params(header[params_from...params_to])]
            end
          end

          # @return [Challenge, nil] nil when the challenge cannot be used
          def build(params, allow_md5: false)
            algorithm = (params['algorithm'] || 'MD5').upcase
            sess = algorithm.end_with?('-SESS')
            algorithm = algorithm.delete_suffix('-SESS') if sess
            return unless DigestAuth::ALGORITHMS.key?(algorithm)
            return if algorithm == 'MD5' && !allow_md5

            qop = select_qop(params['qop'])
            return if qop == :unsupported
            return if params['realm'].nil? || params['nonce'].nil?

            new(
              realm: params['realm'], nonce: params['nonce'], opaque: params['opaque'],
              algorithm: algorithm, sess: sess, qop: qop,
              stale: params['stale']&.casecmp?('true')
            )
          end

          # @return [String, nil, Symbol] 'auth', 'auth-int', nil (no qop) or
          #   :unsupported when none of the offered qop options can be used
          def select_qop(qop_param)
            return nil if qop_param.nil? || qop_param.empty?

            offered = qop_param.split(',').map { |token| token.strip.downcase }
            return 'auth' if offered.include?('auth')
            return 'auth-int' if offered.include?('auth-int')

            :unsupported
          end
        end
      end
    end
  end
end
