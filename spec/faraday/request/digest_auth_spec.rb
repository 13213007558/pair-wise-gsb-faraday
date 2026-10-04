# frozen_string_literal: true

require 'stringio'

# Test oracle emulating an RFC 7616 digest server. It verifies incoming
# Authorization headers with an independent OpenSSL-based implementation,
# tracks nonce-counts, and can rotate nonces and emit Authentication-Info
# headers.
class DigestAuthSpecServer
  OPENSSL_ALGORITHMS = {
    'SHA-256' => 'SHA256',
    'SHA-512-256' => 'SHA512-256',
    'MD5' => 'MD5'
  }.freeze

  Request = Struct.new(:authorization, :body, :params, keyword_init: true)

  attr_reader :password, :requests

  def initialize(password: 'Circle Of Life', realm: 'testrealm@host.com',
                 algorithm: 'SHA-256', qop: 'auth', nonce: 'server-nonce-1',
                 stale_after: nil, nextnonce: nil, rspauth: false,
                 rotate_on_401: false, offered_challenges: nil)
    @password = password
    @realm = realm
    @algorithm = algorithm
    @sess = algorithm.end_with?('-sess')
    @base = @sess ? algorithm.sub(/-sess\z/, '') : algorithm
    @qop = qop
    @nonce = nonce
    @nonce_seq = 1
    @stale_after = stale_after
    @nextnonce = nextnonce
    @rspauth = rspauth
    @rotate_on_401 = rotate_on_401
    @offered_challenges = offered_challenges
    @authenticated = 0
    @used_nc = Hash.new { |hash, key| hash[key] = [] }
    @requests = []
    @lock = Mutex.new
  end

  def challenge_header(stale: false)
    parts = [
      %(realm="#{@realm}"),
      %(nonce="#{@nonce}"),
      "algorithm=#{@algorithm}",
      'opaque="5ccc069c403ebaf9f0171e9517f40e41"'
    ]
    parts << %(qop="#{@qop}") if @qop
    parts << 'stale=true' if stale
    "Digest #{parts.join(', ')}"
  end

  def call(env)
    authorization = env.request_headers['Authorization']
    params = authorization && parse_authorization(authorization)
    entity = entity_string(env)

    @lock.synchronize do
      @requests << Request.new(authorization: authorization, body: entity, params: params)
      handle(params, env, entity)
    end
  end

  private

  def handle(params, env, entity)
    unless params && params['nonce'] == @nonce && register_nc(params) &&
           params['response'] == expected_response(params, env, entity)
      rotate_nonce if @rotate_on_401 && params
      return unauthorized
    end

    if @stale_after && @authenticated >= @stale_after
      rotate_nonce
      @authenticated = 0
      return unauthorized(stale: true)
    end

    @authenticated += 1
    headers = success_headers(params)
    @nonce = @nextnonce if @nextnonce
    [200, headers, 'OK']
  end

  def unauthorized(stale: false)
    [401, { 'WWW-Authenticate' => @offered_challenges || challenge_header(stale: stale) }, '']
  end

  def success_headers(params)
    parts = []
    parts << %(nextnonce="#{@nextnonce}") if @nextnonce
    if @rspauth
      value = @rspauth == :bogus ? 'bogus-rspauth-value' : compute_rspauth(params)
      parts << %(rspauth="#{value}")
      parts << %(qop=#{params['qop']}) if params['qop']
      parts << %(cnonce="#{params['cnonce']}") if params['cnonce']
      parts << %(nc=#{params['nc']}) if params['nc']
    end
    parts.empty? ? {} : { 'Authentication-Info' => parts.join(', ') }
  end

  def compute_rspauth(params)
    ha2 = hex(":#{params['uri']}")
    if params['qop']
      hex([ha1_for(params), params['nonce'], params['nc'], params['cnonce'], params['qop'], ha2].join(':'))
    else
      hex([ha1_for(params), params['nonce'], ha2].join(':'))
    end
  end

  def expected_response(params, env, entity)
    ha2 = if params['qop'] == 'auth-int'
            hex("#{env.method.to_s.upcase}:#{params['uri']}:#{hex(entity)}")
          else
            hex("#{env.method.to_s.upcase}:#{params['uri']}")
          end
    if params['qop']
      hex([ha1_for(params), params['nonce'], params['nc'], params['cnonce'], params['qop'], ha2].join(':'))
    else
      hex([ha1_for(params), params['nonce'], ha2].join(':'))
    end
  end

  def ha1_for(params)
    ha1 = hex("#{params['username']}:#{@realm}:#{@password}")
    @sess ? hex("#{ha1}:#{params['nonce']}:#{params['cnonce']}") : ha1
  end

  def register_nc(params)
    return true unless params['nc']

    used = @used_nc[params['nonce']]
    return false if used.include?(params['nc'])

    used << params['nc']
    true
  end

  def rotate_nonce
    @nonce_seq += 1
    @nonce = "server-nonce-#{@nonce_seq}"
  end

  def entity_string(env)
    body = env.request_body
    return '' if body.nil?
    return body if body.is_a?(String)
    return body.to_s unless body.respond_to?(:read)

    body.rewind if body.respond_to?(:rewind)
    data = body.read.to_s
    body.rewind if body.respond_to?(:rewind)
    data
  end

  def parse_authorization(header)
    params = {}
    header.sub(/\ADigest\s+/i, '').scan(/([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]*))/) do |key, quoted, token|
      params[key.downcase] = quoted || token
    end
    params
  end

  def hex(string)
    OpenSSL::Digest.new(OPENSSL_ALGORITHMS.fetch(@base)).hexdigest(string)
  end
end

# Minimal redirect-following middleware used to exercise cross-origin
# credential handling.
class DigestAuthSpecRedirector < Faraday::Middleware
  def call(env)
    response = @app.call(env)
    response_env = response.env
    return response unless response_env.status == 302

    env.url = URI(response_env.response_headers['Location'])
    env.status = nil
    env.reason_phrase = nil
    env.response_body = nil
    env.response_headers = Faraday::Utils::Headers.new
    env.response = nil
    @app.call(env)
  end
end

RSpec.describe Faraday::Request::DigestAuth do
  def build_connection(server, password: server.password, **options)
    Faraday.new('http://example.org') do |conn|
      conn.request :digest_auth, 'Mufasa', password, **options
      conn.adapter :test do |stub|
        stub.get(%r{\A/}) { |env| server.call(env) }
        stub.post(%r{\A/}) { |env| server.call(env) }
      end
    end
  end

  describe 'digest computation' do
    let(:server) do
      DigestAuthSpecServer.new(algorithm: algorithm, qop: qop,
                               nonce: '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v')
    end
    let(:qop) { 'auth' }

    before do
      allow(SecureRandom).to receive(:hex).and_return('f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZost')
    end

    def authorization_for(server, **options)
      yield build_connection(server, **options)
      server.requests.last.authorization
    end

    context 'with SHA-256' do
      let(:algorithm) { 'SHA-256' }

      it 'matches the RFC 7616 example computation' do
        auth = authorization_for(server) { |conn| conn.get('/dir/index.html') }
        expect(auth).to include('response="a3e77b3b2aa5583efb237eafb600a8cf33a0f12ec22ea9389f102f0872d4a2d5"')
        expect(auth).to include('algorithm=SHA-256')
        expect(auth).to include('qop=auth')
        expect(auth).to include('nc=00000001')
        expect(auth).to include('cnonce="f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZost"')
      end
    end

    context 'with SHA-512-256' do
      let(:algorithm) { 'SHA-512-256' }

      it 'matches the RFC 7616 example computation' do
        auth = authorization_for(server) { |conn| conn.get('/dir/index.html') }
        expect(auth).to include('response="b22903c853fe9e8c015e8fe9e4d1a7dafbb367b55766da00b3191bc461f10ab5"')
        expect(auth).to include('algorithm=SHA-512-256')
      end
    end

    context 'with SHA-256-sess' do
      let(:algorithm) { 'SHA-256-sess' }

      it 'extends HA1 with the nonce and cnonce' do
        auth = authorization_for(server) { |conn| conn.get('/dir/index.html') }
        expect(auth).to include('response="477406d78fa04126b0558d60b2d6ade45b61779fb2c80b50fd953c1617309124"')
        expect(auth).to include('algorithm=SHA-256-sess')
      end
    end

    context 'with SHA-512-256-sess' do
      let(:algorithm) { 'SHA-512-256-sess' }

      it 'extends HA1 with the nonce and cnonce' do
        auth = authorization_for(server) { |conn| conn.get('/dir/index.html') }
        expect(auth).to include('response="d0b565c4e315581b51b2054491f0881211e2cd886fe60652f2c2306f14aaaa2a"')
        expect(auth).to include('algorithm=SHA-512-256-sess')
      end
    end

    context 'with MD5 and the RFC 2617 example values' do
      let(:server) do
        DigestAuthSpecServer.new(algorithm: 'MD5', qop: 'auth,auth-int',
                                 nonce: 'dcd98b7102dd2f0e8b11d0f600bfb0c093')
      end

      before { allow(SecureRandom).to receive(:hex).and_return('0a4f113b') }

      it 'reproduces the RFC example Authorization header' do
        auth = authorization_for(server, allow_md5: true) { |conn| conn.get('/dir/index.html') }
        expect(auth).to eq(
          'Digest username="Mufasa", realm="testrealm@host.com", ' \
          'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", uri="/dir/index.html", ' \
          'response="6629fae49393a05397450978507c4ef1", algorithm=MD5, ' \
          'opaque="5ccc069c403ebaf9f0171e9517f40e41", qop=auth, nc=00000001, cnonce="0a4f113b"'
        )
      end
    end

    context 'with MD5-sess' do
      let(:algorithm) { 'MD5-sess' }

      it 'extends HA1 with the nonce and cnonce' do
        auth = authorization_for(server, allow_md5: true) { |conn| conn.get('/dir/index.html') }
        expect(auth).to include('response="624aac311178a4ea0f9edb0c2ab01e6e"')
        expect(auth).to include('algorithm=MD5-sess')
      end
    end

    context 'without qop (legacy)' do
      let(:algorithm) { 'SHA-256' }
      let(:qop) { nil }

      it 'computes the RFC 2069 style response' do
        auth = authorization_for(server) { |conn| conn.get('/dir/index.html') }
        expect(auth).to include('response="35521f05439109ecf8030cf73f24b4f77245e40be463d4375306d01507f6ba40"')
        expect(auth).not_to include('qop=')
        expect(auth).not_to include('nc=')
      end
    end

    context 'with qop=auth-int' do
      let(:algorithm) { 'SHA-256' }
      let(:qop) { 'auth-int' }

      it 'hashes the exact entity bytes being sent' do
        auth = authorization_for(server) { |conn| conn.post('/dir/index.html', 'Hello World!') }
        expect(auth).to include('response="e4aec2dd6c10ec1a55976580c3e389db7b466500c3d2c95c01c316c1b8221d80"')
        expect(auth).to include('qop=auth-int')
      end
    end
  end

  describe 'challenge selection' do
    it 'prefers the strongest supported algorithm among multiple challenges' do
      server = DigestAuthSpecServer.new(
        algorithm: 'SHA-512-256',
        offered_challenges: [
          'Basic realm="testrealm@host.com"',
          'Digest realm="testrealm@host.com", nonce="server-nonce-1", algorithm=MD5, qop="auth"',
          'Digest realm="testrealm@host.com", nonce="server-nonce-1", algorithm=SHA-256, qop="auth"',
          'Digest realm="testrealm@host.com", nonce="server-nonce-1", algorithm=SHA-512-256, qop="auth"'
        ].join(', ')
      )
      response = build_connection(server).get('/dir/index.html')
      expect(response.status).to eq(200)
      expect(server.requests.last.authorization).to include('algorithm=SHA-512-256')
    end

    it 'rejects MD5 challenges unless explicitly allowed' do
      server = DigestAuthSpecServer.new(algorithm: 'MD5')
      response = build_connection(server).get('/dir/index.html')
      expect(response.status).to eq(401)
      expect(server.requests.size).to eq(1)
      expect(server.requests.first.authorization).to be_nil
    end

    it 'accepts MD5 when allow_md5 is set' do
      server = DigestAuthSpecServer.new(algorithm: 'MD5')
      response = build_connection(server, allow_md5: true).get('/dir/index.html')
      expect(response.status).to eq(200)
    end

    it 'prefers qop=auth over auth-int' do
      server = DigestAuthSpecServer.new(qop: 'auth,auth-int')
      response = build_connection(server).get('/dir/index.html')
      expect(response.status).to eq(200)
      expect(server.requests.last.params['qop']).to eq('auth')
    end

    it 'uses auth-int when it is the only offered qop' do
      server = DigestAuthSpecServer.new(qop: 'auth-int')
      response = build_connection(server).post('/dir/index.html', 'payload')
      expect(response.status).to eq(200)
      expect(server.requests.last.params['qop']).to eq('auth-int')
    end

    it 'ignores challenges without a usable qop' do
      server = DigestAuthSpecServer.new(qop: 'auth-conf')
      response = build_connection(server).get('/dir/index.html')
      expect(response.status).to eq(401)
      expect(server.requests.size).to eq(1)
    end

    it 'ignores challenges missing a nonce' do
      server = DigestAuthSpecServer.new(
        offered_challenges: 'Digest realm="testrealm@host.com", qop="auth", algorithm=SHA-256'
      )
      response = build_connection(server).get('/dir/index.html')
      expect(response.status).to eq(401)
      expect(server.requests.size).to eq(1)
    end
  end

  describe 'nonce count' do
    it 'authenticates proactively and increments nc within the protection space' do
      server = DigestAuthSpecServer.new
      conn = build_connection(server)
      3.times { expect(conn.get('/dir/index.html').status).to eq(200) }

      authorizations = server.requests.map(&:authorization)
      expect(authorizations.first).to be_nil
      expect(authorizations.drop(1)).to all(be_a(String))
      expect(server.requests.filter_map { |request| request.params && request.params['nc'] })
        .to eq(%w[00000001 00000002 00000003])
    end

    it 'never reuses a nonce-count across concurrent requests' do
      server = DigestAuthSpecServer.new
      conn = build_connection(server)
      statuses = Queue.new
      Array.new(4) do
        Thread.new { 5.times { statuses << conn.get('/dir/index.html').status } }
      end.each(&:join)

      results = Array.new(20) { statuses.pop }
      expect(results.uniq).to eq([200])
      pairs = server.requests.filter_map { |request| request.params && [request.params['nonce'], request.params['nc']] }
      expect(pairs.size).to eq(20)
      expect(pairs.uniq.size).to eq(20)
      expect(pairs.map { |(_nonce, nc)| nc.to_i(16) }.sort).to eq((1..20).to_a)
    end
  end

  describe 'stale nonce rotation' do
    it 'transparently re-authenticates when the server rotates its nonce' do
      server = DigestAuthSpecServer.new(stale_after: 2)
      conn = build_connection(server)
      3.times { expect(conn.get('/dir/index.html').status).to eq(200) }

      authenticated = server.requests.filter_map(&:params)
      expect(authenticated.map { |params| params['nonce'] })
        .to eq(['server-nonce-1', 'server-nonce-1', 'server-nonce-1', 'server-nonce-2'])
      expect(authenticated.map { |params| params['nc'] })
        .to eq(%w[00000001 00000002 00000003 00000001])
    end
  end

  describe 'Authentication-Info handling' do
    it 'applies nextnonce to subsequent requests' do
      server = DigestAuthSpecServer.new(nextnonce: 'rotated-nonce', rspauth: true)
      conn = build_connection(server)
      expect(conn.get('/dir/index.html').status).to eq(200)
      expect(conn.get('/dir/index.html').status).to eq(200)

      authenticated = server.requests.filter_map(&:params)
      expect(authenticated.map { |params| params['nonce'] }).to eq(['server-nonce-1', 'rotated-nonce'])
      expect(authenticated.map { |params| params['nc'] }).to eq(%w[00000001 00000001])
    end

    it 'accepts a valid rspauth proof' do
      server = DigestAuthSpecServer.new(rspauth: true)
      expect(build_connection(server).get('/dir/index.html').status).to eq(200)
    end

    it 'rejects an invalid rspauth proof' do
      server = DigestAuthSpecServer.new(rspauth: :bogus)
      expect { build_connection(server).get('/dir/index.html') }
        .to raise_error(Faraday::Error, /rspauth/)
    end
  end

  describe 'wrong credentials' do
    it 'does not retry when the server keeps rejecting the same nonce' do
      server = DigestAuthSpecServer.new
      response = build_connection(server, password: 'wrong').get('/dir/index.html')
      expect(response.status).to eq(401)
      expect(server.requests.size).to eq(2)
    end

    it 'is bounded by max_retries when the server rotates nonces' do
      server = DigestAuthSpecServer.new(rotate_on_401: true)
      response = build_connection(server, password: 'wrong', max_retries: 2).get('/dir/index.html')
      expect(response.status).to eq(401)
      expect(server.requests.size).to eq(3)
    end
  end

  describe 'request body replay' do
    it 'refuses to resend a non-replayable body' do
      server = DigestAuthSpecServer.new
      conn = build_connection(server)
      body = Object.new
      def body.read(*_args)
        'payload'
      end

      expect { conn.post('/dir/index.html', body) }.to raise_error(Faraday::Error, /cannot resend/)
    end

    it 'rebuilds the body with the body_factory option' do
      server = DigestAuthSpecServer.new
      factory_calls = 0
      factory = lambda do
        factory_calls += 1
        StringIO.new('payload')
      end
      conn = build_connection(server, body_factory: factory)
      expect(conn.post('/dir/index.html', StringIO.new('payload')).status).to eq(200)
      expect(factory_calls).to eq(1)
      expect(server.requests.last.body).to eq('payload')
    end

    it 'rewinds rewindable bodies before resending' do
      server = DigestAuthSpecServer.new
      conn = build_connection(server)
      expect(conn.post('/dir/index.html', StringIO.new('payload')).status).to eq(200)
      expect(server.requests.last.body).to eq('payload')
    end

    it 'computes the auth-int hash over rewindable IO bodies' do
      server = DigestAuthSpecServer.new(qop: 'auth-int')
      conn = build_connection(server)
      expect(conn.post('/dir/index.html', StringIO.new('payload')).status).to eq(200)
    end

    it 'raises when the auth-int entity bytes are unavailable' do
      server = DigestAuthSpecServer.new(qop: 'auth-int')
      conn = build_connection(server, body_factory: -> { 42 })
      expect { conn.post('/dir/index.html', 42) }.to raise_error(Faraday::Error, /auth-int/)
    end
  end

  describe 'cross-origin redirects' do
    it 'does not forward credentials or precomputed digests to another origin' do
      seen_by_a = []
      seen_by_b = []
      conn = Faraday.new('http://a.example') do |builder|
        builder.use DigestAuthSpecRedirector
        builder.request :digest_auth, 'Mufasa', 'Circle Of Life'
        builder.adapter :test do |stub|
          stub.get('http://a.example/start') do |env|
            auth = env.request_headers['Authorization']
            seen_by_a << auth
            if auth
              [302, { 'Location' => 'http://b.example/landing' }, '']
            else
              [401, { 'WWW-Authenticate' => DigestAuthSpecServer.new.challenge_header }, '']
            end
          end
          stub.get('http://b.example/landing') do |env|
            seen_by_b << env.request_headers['Authorization']
            [401, { 'WWW-Authenticate' => DigestAuthSpecServer.new.challenge_header }, '']
          end
        end
      end

      response = conn.get('http://a.example/start')
      expect(response.status).to eq(401)
      expect(seen_by_a.first).to be_nil
      expect(seen_by_a.last).to be_a(String)
      expect(seen_by_b).to eq([nil])
    end
  end

  describe 'parallel requests' do
    it 'raises a clear error' do
      middleware = described_class.new(->(env) { env }, 'user', 'pass')
      env = Faraday::Env.new
      env.parallel_manager = Object.new
      expect { middleware.call(env) }.to raise_error(Faraday::Error, /parallel/)
    end
  end
end
