# frozen_string_literal: true

require 'digest'
require 'securerandom'

begin
  require 'openssl'
rescue LoadError
  # SHA-512-256 is unavailable without OpenSSL; SHA-256 and MD5 still work.
end

module Faraday
  class
    # placeholder
  end
end
