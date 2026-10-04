# frozen_string_literal: true

module Faraday
  class Request
    class DigestAuth < Faraday::Middleware
      # Tracks the server nonce and client nonce-count of one protection
      # space (origin + realm). Mutable state is guarded so that concurrent
      # requests never reuse a nonce-count.
      class ProtectionSpace
        attr_reader :origin, :realm, :algorithm, :qop, :opaque
        attr_reader :nonce, :cnonce, :nonce_count

        def initialize(origin:, challenge:)
          @origin = origin
          @realm = challenge.realm
          @nonce = challenge.nonce
          @opaque = challenge.opaque
          @algorithm = challenge.algorithm
          @sess = challenge.sess?
          @qop = challenge.qop
          @nonce_count = 0
          @cnonce = SecureRandom.hex(16)
          @lock = Mutex.new
        end

        def sess?
          @sess
        end

        # Atomically advances the nonce-count and returns the nonce, cnonce
        # and count that must be used together for one request.
        #
        # @return [Array(String, String, Integer)]
        def next_nonce_count
          @lock.synchronize do
            @nonce_count += 1
            [@nonce, @cnonce, @nonce_count]
          end
        end

        # Applies a server-provided nonce rotation (from a +stale+ challenge
        # or an Authentication-Info +nextnonce+ directive).
        def rotate_nonce(new_nonce)
          @lock.synchronize do
            return if new_nonce.nil? || new_nonce.empty? || new_nonce == @nonce

            @nonce = new_nonce
            @nonce_count = 0
            @cnonce = SecureRandom.hex(16)
          end
        end
      end
    end
  end
end
