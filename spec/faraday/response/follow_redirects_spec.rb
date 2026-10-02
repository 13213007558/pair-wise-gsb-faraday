# frozen_string_literal: true

RSpec.describe Faraday::Response::FollowRedirects do
  let(:middleware_options) { {} }

  let(:conn) do
    options = middleware_options
    Faraday.new('http://example.com') do |builder|
      builder.response :follow_redirects, **options
      builder.adapter :test do |stub|
        stub.get('/redirect') { [301, { 'Location' => '/landing' }, ''] }
        stub.get('/found') { [200, { 'Content-Type' => 'text/plain' }, 'found'] }
        stub.get('/landing') { [200, { 'Content-Type' => 'text/plain' }, 'landing'] }
      end
    end
  end

  def conn_with(&block)
    options = middleware_options
    Faraday.new('http://example.com') do |builder|
      builder.response :follow_redirects, **options
      builder.adapter :test, &block
    end
  end

  it 'is registered as :follow_redirects' do
    expect(Faraday::Response.lookup_middleware(:follow_redirects)).to eq(described_class)
  end

  [301, 302, 303, 307, 308].each do |status|
    it "follows #{status} redirects" do
      conn = conn_with do |stub|
        stub.get('/start') { [status, { 'Location' => '/landing' }, ''] }
        stub.get('/landing') { [200, {}, 'landing'] }
      end

      response = conn.get('/start')
      expect(response.status).to eq(200)
      expect(response.body).to eq('landing')
    end
  end

  it 'does not follow responses without a Location header' do
    conn = conn_with do |stub|
      stub.get('/start') { [301, {}, ''] }
    end

    expect(conn.get('/start').status).to eq(301)
  end

  it 'does not follow statuses outside the configured list' do
    conn = conn_with do |stub|
      stub.get('/start') { [304, { 'Location' => '/landing' }, ''] }
    end

    expect(conn.get('/start').status).to eq(304)
  end

  context 'with a custom :statuses list' do
    let(:middleware_options) { { statuses: [302] } }

    it 'only follows the listed statuses' do
      conn = conn_with do |stub|
        stub.get('/start') { [301, { 'Location' => '/landing' }, ''] }
        stub.get('/other') { [302, { 'Location' => '/landing' }, ''] }
        stub.get('/landing') { [200, {}, 'landing'] }
      end

      expect(conn.get('/start').status).to eq(301)
      expect(conn.get('/other').status).to eq(200)
    end
  end

  describe 'method and body rewriting' do
    it 'rewrites POST to GET on 303 and drops the body and entity headers' do
      conn = conn_with do |stub|
        stub.post('/start') { [303, { 'Location' => '/landing' }, ''] }
        stub.get('/landing') do |env|
          [200, {}, "method=#{env.method} body=#{env.request_body.inspect} " \
                    "type=#{env.request_headers['Content-Type'].inspect} " \
                    "length=#{env.request_headers['Content-Length'].inspect}"]
        end
      end

      response = conn.post('/start', 'payload') do |req|
        req.headers['Content-Type'] = 'text/plain'
      end
      expect(response.body).to eq('method=get body=nil type=nil length=nil')
    end

    it 'keeps HEAD as HEAD on 303' do
      conn = conn_with do |stub|
        stub.head('/start') { [303, { 'Location' => '/landing' }, ''] }
        stub.head('/landing') { [200, {}, ''] }
        stub.get('/landing') { [500, {}, 'should not be a GET'] }
      end

      expect(conn.head('/start').status).to eq(200)
    end

    [301, 302].each do |status|
      it "rewrites POST to GET on #{status} by default" do
        conn = conn_with do |stub|
          stub.post('/start') { [status, { 'Location' => '/landing' }, ''] }
          stub.get('/landing') { |env| [200, {}, env.method.to_s] }
        end

        response = conn.post('/start', 'payload')
        expect(response.body).to eq('get')
      end

      context 'with standards_compliant: true' do
        let(:middleware_options) { { standards_compliant: true } }

        it "keeps the POST method and body on #{status}" do
          conn = conn_with do |stub|
            stub.post('/start') { [status, { 'Location' => '/landing' }, ''] }
            stub.post('/landing') { |env| [200, {}, "#{env.method}:#{env.request_body}"] }
          end

          response = conn.post('/start', 'payload')
          expect(response.body).to eq('post:payload')
        end
      end
    end

    [307, 308].each do |status|
      it "keeps the method and body on #{status}" do
        conn = conn_with do |stub|
          stub.put('/start') { [status, { 'Location' => '/landing' }, ''] }
          stub.put('/landing') { |env| [200, {}, "#{env.method}:#{env.request_body}"] }
        end

        response = conn.put('/start', 'payload')
        expect(response.body).to eq('put:payload')
      end
    end
  end

  describe 'Location resolution' do
    it 'resolves relative locations against the current URL' do
      conn = conn_with do |stub|
        stub.get('/dir/start') { [302, { 'Location' => 'next' }, ''] }
        stub.get('/dir/next') { [200, {}, 'relative'] }
      end

      expect(conn.get('/dir/start').body).to eq('relative')
    end

    it 'resolves query-only locations' do
      conn = conn_with do |stub|
        stub.get('/start') { [302, { 'Location' => '?page=2' }, ''] }
        stub.get('/start?page=2') { [200, {}, 'paged'] }
      end

      expect(conn.get('/start').body).to eq('paged')
    end

    it 'follows absolute locations' do
      conn = conn_with do |stub|
        stub.get('/start') { [302, { 'Location' => 'http://other.com/landing' }, ''] }
        stub.get('http://other.com/landing') { [200, {}, 'elsewhere'] }
      end

      expect(conn.get('/start').body).to eq('elsewhere')
    end
  end

  describe 'redirect limit' do
    let(:middleware_options) { { limit: 2 } }

    it 'raises RedirectLimitReached and reports the hop it stopped at' do
      conn = conn_with do |stub|
        stub.get('/a') { [302, { 'Location' => '/b' }, ''] }
        stub.get('/b') { [302, { 'Location' => '/c' }, ''] }
        stub.get('/c') { [302, { 'Location' => '/d' }, ''] }
        stub.get('/d') { [200, {}, 'end'] }
      end

      expect { conn.get('/a') }.to raise_error(described_class::RedirectLimitReached) do |error|
        expect(error.message).to include('redirect limit of 2 reached')
        expect(error.message).to include('http://example.com/c')
        expect(error.response[:status]).to eq(302)
        expect(error.response[:request][:url].to_s).to eq('http://example.com/c')
        expect(error.response[:redirects].size).to eq(3)
      end
    end

    it 'is a Faraday::ClientError' do
      conn = conn_with do |stub|
        stub.get('/a') { [302, { 'Location' => '/b' }, ''] }
        stub.get('/b') { [302, { 'Location' => '/c' }, ''] }
        stub.get('/c') { [302, { 'Location' => '/d' }, ''] }
      end

      expect { conn.get('/a') }.to raise_error(Faraday::ClientError)
    end
  end

  describe 'loop detection' do
    let(:middleware_options) { { limit: 10 } }

    it 'raises RedirectLoopError when a URL is visited twice' do
      conn = conn_with do |stub|
        stub.get('/x') { [302, { 'Location' => '/y' }, ''] }
        stub.get('/y') { [302, { 'Location' => '/x' }, ''] }
      end

      expect { conn.get('/x') }.to raise_error(described_class::RedirectLoopError) do |error|
        expect(error.message).to include('http://example.com/x')
        expect(error.message).to include('loop')
      end
    end

    it 'detects redirects to self' do
      conn = conn_with do |stub|
        stub.get('/x') { [302, { 'Location' => '/x' }, ''] }
      end

      expect { conn.get('/x') }.to raise_error(described_class::RedirectLoopError)
    end
  end

  describe 'cross-origin redirects' do
    it 'removes Authorization and manual Host headers' do
      conn = conn_with do |stub|
        stub.get('/start') { [302, { 'Location' => 'http://other.com/landing' }, ''] }
        stub.get('http://other.com/landing') do |env|
          [200, {}, "auth=#{env.request_headers['Authorization'].inspect} " \
                    "host=#{env.request_headers['Host'].inspect}"]
        end
      end

      response = conn.get('/start') do |req|
        req.headers['Authorization'] = 'Token secret'
        req.headers['Host'] = 'example.com'
      end
      expect(response.body).to eq('auth=nil host=nil')
    end

    it 'removes credentials when only the port changes' do
      conn = conn_with do |stub|
        stub.get('/start') { [302, { 'Location' => 'http://example.com:8080/landing' }, ''] }
        stub.get('http://example.com:8080/landing') do |env|
          [200, {}, "auth=#{env.request_headers['Authorization'].inspect}"]
        end
      end

      response = conn.get('/start') { |req| req.headers['Authorization'] = 'Token secret' }
      expect(response.body).to eq('auth=nil')
    end

    it 'keeps Authorization on same-origin redirects' do
      conn = conn_with do |stub|
        stub.get('/start') { [302, { 'Location' => '/landing' }, ''] }
        stub.get('/landing') do |env|
          [200, {}, "auth=#{env.request_headers['Authorization'].inspect}"]
        end
      end

      response = conn.get('/start') { |req| req.headers['Authorization'] = 'Token secret' }
      expect(response.body).to eq('auth="Token secret"')
    end
  end

  describe 'HTTPS downgrade' do
    it 'refuses to follow a redirect from HTTPS to HTTP by default' do
      conn = Faraday.new('https://example.com') do |builder|
        builder.response :follow_redirects
        builder.adapter :test do |stub|
          stub.get('/start') { [302, { 'Location' => 'http://example.com/landing' }, ''] }
        end
      end

      expect { conn.get('/start') }.to raise_error(described_class::InsecureRedirectError) do |error|
        expect(error.message).to include('https://example.com/start')
        expect(error.message).to include('http://example.com/landing')
      end
    end

    context 'with allow_https_to_http: true' do
      let(:middleware_options) { { allow_https_to_http: true } }

      it 'follows the redirect' do
        conn = Faraday.new('https://example.com') do |builder|
          builder.response :follow_redirects, allow_https_to_http: true
          builder.adapter :test do |stub|
            stub.get('/start') { [302, { 'Location' => 'http://example.com/landing' }, ''] }
            stub.get('http://example.com/landing') { [200, {}, 'insecure'] }
          end
        end

        expect(conn.get('/start').body).to eq('insecure')
      end
    end
  end

  describe 'body replayability' do
    it 'rewinds a rewindable body before re-sending it' do
      body = StringIO.new('streamed payload')
      conn = conn_with do |stub|
        stub.post('/start') { [307, { 'Location' => '/landing' }, ''] }
        stub.post('/landing') { |env| [200, {}, env.request_body.read] }
      end

      response = conn.post('/start', body)
      expect(response.body).to eq('streamed payload')
    end

    it 'raises NonReplayableBodyError when the body can only be read once' do
      one_shot = Class.new do
        def initialize(content)
          @io = StringIO.new(content)
        end

        def read(*args)
          @io.read(*args)
        end
      end.new('one shot')

      conn = conn_with do |stub|
        stub.post('/start') { [307, { 'Location' => '/landing' }, ''] }
      end

      expect { conn.post('/start', one_shot) }
        .to raise_error(described_class::NonReplayableBodyError) do |error|
          expect(error.message).to include('307')
          expect(error.message).to include('http://example.com/landing')
        end
    end
  end

  describe 'redirect chain recording' do
    it 'exposes every hop status and destination on the final env' do
      conn = conn_with do |stub|
        stub.post('/start') { [301, { 'Location' => '/second' }, ''] }
        stub.get('/second') { [303, { 'Location' => '/third' }, ''] }
        stub.get('/third') { [307, { 'Location' => '/final' }, ''] }
        stub.get('/final') { [200, {}, 'done'] }
      end

      response = conn.post('/start', 'payload')
      expect(response.status).to eq(200)
      expect(response.env[:redirects]).to eq(
        [
          { method: :post, url: 'http://example.com/start', status: 301,
            location: 'http://example.com/second' },
          { method: :get, url: 'http://example.com/second', status: 303,
            location: 'http://example.com/third' },
          { method: :get, url: 'http://example.com/third', status: 307,
            location: 'http://example.com/final' }
        ]
      )
    end

    it 'leaves env[:redirects] unset when no redirect happens' do
      conn = conn_with do |stub|
        stub.get('/landing') { [200, {}, 'landing'] }
      end

      expect(conn.get('/landing').env[:redirects]).to be_nil
    end
  end

  describe 'middleware order' do
    it 'runs middleware below follow_redirects once per hop' do
      responses = []
      spy = Class.new(Faraday::Middleware) do
        define_method(:on_complete) do |env|
          responses << env.status
        end
      end

      conn = Faraday.new('http://example.com') do |builder|
        builder.response :follow_redirects
        builder.use spy
        builder.adapter :test do |stub|
          stub.get('/start') { [302, { 'Location' => '/landing' }, ''] }
          stub.get('/landing') { [200, {}, 'landing'] }
        end
      end

      conn.get('/start')
      expect(responses).to eq([302, 200])
    end
  end
end
