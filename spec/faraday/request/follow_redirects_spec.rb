# frozen_string_literal: true

require 'stringio'
require 'webrick'

RSpec.describe Faraday::Request::FollowRedirects do
  # A body that can be read only once: it offers #read but no #rewind.
  class OneShotBody
    def initialize(data)
      @data = data
    end

    def read(*)
      @data
    end
  end

  let(:conn_options) { {} }
  let(:requests) { [] }
  let(:conn) do
    captured = requests
    options = conn_options
    Faraday.new('http://example.org') do |builder|
      builder.request :follow_redirects, **options
      builder.adapter :test do |stub|
        snapshot = lambda do |env|
          body = env[:body]
          body = body.read if body.respond_to?(:read)
          captured << {
            method: env[:method],
            url: env[:url].to_s,
            body: body,
            headers: env[:request_headers].dup
          }
        end

        stub.get('/target') do |env|
          snapshot.call(env)
          [200, {}, 'landed']
        end
        stub.post('/target') do |env|
          snapshot.call(env)
          [200, {}, 'landed']
        end

        [301, 302, 303, 307, 308].each do |code|
          stub.get("/#{code}") do |env|
            snapshot.call(env)
            [code, { 'Location' => '/target' }, '']
          end
          stub.post("/#{code}") do |env|
            snapshot.call(env)
            [code, { 'Location' => '/target' }, '']
          end
        end

        stub.get('/dir/page') { [302, { 'Location' => 'target' }, ''] }
        stub.get('/dir/target') do |env|
          snapshot.call(env)
          [200, {}, 'relative landed']
        end

        stub.get('/no-location') { [302, {}, 'no location'] }

        stub.get('/loop') { [302, { 'Location' => '/loop2' }, ''] }
        stub.get('/loop2') { [302, { 'Location' => '/loop' }, ''] }

        (1..6).each do |n|
          stub.get("/chain/#{n}") { [302, { 'Location' => "/chain/#{n + 1}" }, ''] }
        end

        stub.get('/cross') { [302, { 'Location' => 'http://other.org/target' }, ''] }
        stub.get('/downgrade') { [302, { 'Location' => 'http://example.org/target' }, ''] }
      end
    end
  end

  def redirects_of(response)
    response.env[:redirects]
  end

  describe 'following redirects' do
    [301, 302, 303, 307, 308].each do |code|
      it "follows a #{code} redirect" do
        response = conn.get("/#{code}")
        expect(response.status).to eq(200)
        expect(response.body).to eq('landed')
        expect(redirects_of(response)).to eq(
          [{ status: code, from: "http://example.org/#{code}", to: 'http://example.org/target' }]
        )
      end
    end

    it 'resolves relative Location headers against the request URL' do
      response = conn.get('/dir/page')
      expect(response.body).to eq('relative landed')
      expect(redirects_of(response).last[:to]).to eq('http://example.org/dir/target')
    end

    it 'returns the response untouched when the redirect has no Location' do
      response = conn.get('/no-location')
      expect(response.status).to eq(302)
      expect(response.body).to eq('no location')
      expect(redirects_of(response)).to eq([])
    end

    it 're-traverses the middleware below on every hop' do
      paths = []
      counting = Class.new(Faraday::Middleware) do
        define_method(:call) do |env|
          paths << env.url.path
          app.call(env)
        end
      end
      connection = Faraday.new('http://example.org') do |builder|
        builder.request :follow_redirects
        builder.use counting
        builder.adapter :test do |stub|
          stub.get('/chain/1') { [302, { 'Location' => '/chain/2' }, ''] }
          stub.get('/chain/2') { [200, {}, 'done'] }
        end
      end
      connection.get('/chain/1')
      expect(paths).to eq(['/chain/1', '/chain/2'])
    end
  end

  describe 'method and body rewriting' do
    it 'rewrites POST into GET on 303 and clears entity headers' do
      response = conn.post('/303', 'payload',
                           'Content-Type' => 'text/plain', 'Content-Length' => '7')
      expect(response.status).to eq(200)
      last = requests.last
      expect(last[:method]).to eq(:get)
      expect(last[:body]).to be_nil
      expect(last[:headers]['Content-Type']).to be_nil
      expect(last[:headers]['Content-Length']).to be_nil
    end

    [301, 302].each do |code|
      it "rewrites POST into GET on #{code} by default" do
        conn.post("/#{code}", 'payload', 'Content-Type' => 'text/plain')
        expect(requests.last[:method]).to eq(:get)
        expect(requests.last[:body]).to be_nil
      end

      context "with convert_post_to_get_on_301_302 disabled (#{code})" do
        let(:conn_options) { { convert_post_to_get_on_301_302: false } }

        it 'keeps the POST method and body' do
          conn.post("/#{code}", 'payload')
          expect(requests.last[:method]).to eq(:post)
          expect(requests.last[:body]).to eq('payload')
        end
      end
    end

    [307, 308].each do |code|
      it "keeps method and body on #{code}" do
        conn.post("/#{code}", 'payload')
        expect(requests.last[:method]).to eq(:post)
        expect(requests.last[:body]).to eq('payload')
      end
    end

    it 'rewinds a rewindable body before sending it again' do
      response = conn.post('/307', StringIO.new('stream me'))
      expect(response.status).to eq(200)
      expect(requests.map { |req| req[:body] }).to eq(['stream me', 'stream me'])
    end

    it 'raises NonReplayableBodyError when a kept body cannot be replayed' do
      expect { conn.post('/307', OneShotBody.new('once')) }
        .to raise_error(Faraday::NonReplayableBodyError, /cannot be replayed/)
    end
  end

  describe 'limit and loop protection' do
    it 'raises RedirectLimitReached naming the hop it stopped at' do
      expect { conn.get('/chain/1') }
        .to raise_error(Faraday::RedirectLimitReached) do |error|
          expect(error.message).to include('redirect limit of 3 reached')
          expect(error.message).to include('http://example.org/chain/4')
          expect(error.redirects.size).to eq(3)
          expect(error.redirects.last[:to]).to eq('http://example.org/chain/4')
        end
    end

    context 'with a custom limit' do
      let(:conn_options) { { limit: 5 } }

      it 'follows up to the configured number of redirects' do
        expect { conn.get('/chain/1') }
          .to raise_error(Faraday::RedirectLimitReached) do |error|
            expect(error.redirects.size).to eq(5)
          end
      end
    end

    it 'detects redirect loops' do
      expect { conn.get('/loop') }
        .to raise_error(Faraday::RedirectLoopDetected) do |error|
          expect(error.message).to include('http://example.org/loop')
          expect(error.redirects).not_to be_empty
        end
    end
  end

  describe 'cross-origin redirects' do
    it 'drops credentials and manual Host headers' do
      conn.get('/cross') do |req|
        req.headers['Authorization'] = 'Bearer secret'
        req.headers['Host'] = 'example.org'
      end
      last = requests.last
      expect(last[:url]).to eq('http://other.org/target')
      expect(last[:headers]['Authorization']).to be_nil
      expect(last[:headers]['Host']).to be_nil
    end

    context 'with clear_authorization_header disabled' do
      let(:conn_options) { { clear_authorization_header: false } }

      it 'keeps the Authorization header' do
        conn.get('/cross') { |req| req.headers['Authorization'] = 'Bearer secret' }
        expect(requests.last[:headers]['Authorization']).to eq('Bearer secret')
      end
    end

    it 'keeps credentials on same-origin redirects' do
      conn.get('/301') { |req| req.headers['Authorization'] = 'Bearer secret' }
      expect(requests.last[:headers]['Authorization']).to eq('Bearer secret')
    end
  end

  describe 'HTTPS downgrades' do
    let(:conn) do
      options = conn_options
      Faraday.new('https://example.org') do |builder|
        builder.request :follow_redirects, **options
        builder.adapter :test do |stub|
          stub.get('/downgrade') { [302, { 'Location' => 'http://example.org/target' }, ''] }
          stub.get('/target') { [200, {}, 'landed'] }
        end
      end
    end

    it 'refuses to follow by default' do
      expect { conn.get('/downgrade') }
        .to raise_error(Faraday::InsecureRedirectError, /HTTPS to HTTP/)
    end

    context 'with allow_https_to_http enabled' do
      let(:conn_options) { { allow_https_to_http: true } }

      it 'follows the redirect' do
        expect(conn.get('/downgrade').body).to eq('landed')
      end
    end
  end

  describe 'against a live localhost server' do
    before(:all) do
      @requests_a = Queue.new
      @requests_b = Queue.new
      @server_a, @port_a = start_server do |req, res|
        @requests_a << [req.request_method, req.path, req.body]
        case req.path
        when '/chain/1' then redirect(res, 301, '/chain/2')
        when '/chain/2' then redirect(res, 302, '/chain/3')
        when '/chain/3' then redirect(res, 303, '/chain/4')
        when '/chain/4' then redirect(res, 307, '/chain/5')
        when '/chain/5' then redirect(res, 308, '/final')
        when '/final'
          res.status = 200
          res.body = 'landed'
        when '/cross'
          redirect(res, 302, "http://127.0.0.1:#{@port_b}/landing")
        when '/upload' then redirect(res, 307, '/uploaded')
        when '/uploaded'
          res.status = 200
          res.body = 'uploaded'
        else
          res.status = 404
        end
      end
      @server_b, @port_b = start_server do |req, res|
        @requests_b << [req.request_method, req.path,
                        { 'Authorization' => req['Authorization'], 'Host' => req['Host'] }]
        res.status = 200
        res.body = 'other port'
      end
    end

    after(:all) do
      @server_a.shutdown
      @server_b.shutdown
    end

    def start_server(&handler)
      server = WEBrick::HTTPServer.new(
        BindAddress: '127.0.0.1', Port: 0,
        Logger: WEBrick::Log.new(File::NULL), AccessLog: []
      )
      server.mount_proc('/', &handler)
      Thread.new { server.start }
      [server, server.listeners[0].addr[1]]
    end

    def redirect(response, status, location)
      response.status = status
      response['Location'] = location
    end

    def live_conn(**options)
      Faraday.new("http://127.0.0.1:#{@port_a}") do |builder|
        builder.request :follow_redirects, **options
        builder.adapter :net_http
      end
    end

    def drain(queue)
      Array.new(queue.size) { queue.pop(true) }
    end

    before do
      drain(@requests_a)
      drain(@requests_b)
    end

    it 'follows a mixed 301/302/303/307/308 chain and reports every hop' do
      response = live_conn(limit: 10).post('/chain/1', 'payload')

      expect(response.status).to eq(200)
      expect(response.body).to eq('landed')

      hops = response.env[:redirects]
      expect(hops.map { |hop| hop[:status] }).to eq([301, 302, 303, 307, 308])
      expect(hops.map { |hop| hop[:to] })
        .to eq((2..5).map { |n| "http://127.0.0.1:#{@port_a}/chain/#{n}" } +
               ["http://127.0.0.1:#{@port_a}/final"])

      # 301 converts the initial POST to GET, later hops stay GET.
      expect(drain(@requests_a).map(&:first))
        .to eq(%w[POST GET GET GET GET GET])
    end

    it 'follows redirects to another port and strips credentials' do
      response = live_conn.get('/cross') do |req|
        req.headers['Authorization'] = 'Bearer secret'
      end

      expect(response.status).to eq(200)
      expect(response.body).to eq('other port')

      _method, _path, headers = drain(@requests_b).last
      expect(headers['Authorization']).to be_nil
      expect(headers['Host']).to eq("127.0.0.1:#{@port_b}")
    end

    it 'replays a rewindable body across a 307 redirect' do
      payload = 'x' * 1024
      response = live_conn.post('/upload', StringIO.new(payload)) do |req|
        req.headers['Content-Type'] = 'application/octet-stream'
        req.headers['Content-Length'] = payload.bytesize.to_s
      end

      expect(response.status).to eq(200)
      bodies = drain(@requests_a).map(&:last)
      expect(bodies).to eq([payload, payload])
    end

    it 'raises NonReplayableBodyError for a body that can only be read once' do
      expect do
        live_conn.post('/upload', OneShotBody.new('once')) do |req|
          req.headers['Content-Length'] = '4'
        end
      end.to raise_error(Faraday::NonReplayableBodyError) do |error|
        expect(error.redirects.size).to eq(1)
        expect(error.redirects.last[:status]).to eq(307)
      end
    end

    it 'tells the user at which hop the chain failed' do
      expect { live_conn(limit: 2).post('/chain/1', 'payload') }
        .to raise_error(Faraday::RedirectLimitReached) do |error|
          expect(error.redirects.map { |hop| hop[:status] }).to eq([301, 302])
          expect(error.message).to include("/chain/#{3}")
        end
    end
  end
end
