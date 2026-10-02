# frozen_string_literal: true

require 'stringio'
require 'logger'

RSpec.describe Faraday::Response::Logger do
  let(:string_io) { StringIO.new }
  let(:logger) { Logger.new(string_io) }
  let(:logger_options) { {} }
  let(:conn) do
    rubbles = ['Barney', 'Betty', 'Bam Bam']

    Faraday.new do |b|
      b.response :logger, logger, logger_options do |logger|
        logger.filter(/(soylent green is) (.+)/, '\1 tasty')
        logger.filter(/(api_key:).*"(.+)."/, '\1[API_KEY]')
        logger.filter(/(password)=(.+)/, '\1=[HIDDEN]')
      end
      b.adapter :test do |stubs|
        stubs.get('/hello') { [200, { 'Content-Type' => 'text/html' }, 'hello'] }
        stubs.post('/ohai') { [200, { 'Content-Type' => 'text/html' }, 'fred'] }
        stubs.post('/ohyes') { [200, { 'Content-Type' => 'text/html' }, 'pebbles'] }
        stubs.get('/rubbles') { [200, { 'Content-Type' => 'application/json' }, rubbles] }
        stubs.get('/8bit') { [200, { 'Content-Type' => 'text/html' }, (+'café!').force_encoding(Encoding::ASCII_8BIT)] }
        stubs.get('/filtered_body') { [200, { 'Content-Type' => 'text/html' }, 'soylent green is people'] }
        stubs.get('/filtered_headers') { [200, { 'Content-Type' => 'text/html' }, 'headers response'] }
        stubs.get('/filtered_params') { [200, { 'Content-Type' => 'text/html' }, 'params response'] }
        stubs.get('/filtered_url') { [200, { 'Content-Type' => 'text/html' }, 'url response'] }
        stubs.get('/connection_failed') { raise Faraday::ConnectionFailed, 'Failed to open TCP connection' }
      end
    end
  end

  before do
    logger.level = Logger::DEBUG
  end

  it 'still returns output' do
    resp = conn.get '/hello', nil, accept: 'text/html'
    expect(resp.body).to eq('hello')
  end

  context 'without configuration' do
    let(:conn) do
      Faraday.new do |b|
        b.response :logger
        b.adapter :test do |stubs|
          stubs.get('/hello') { [200, { 'Content-Type' => 'text/html' }, 'hello'] }
        end
      end
    end

    it 'defaults to stdout' do
      expect(Logger).to receive(:new).with($stdout).and_return(Logger.new(nil))
      conn.get('/hello')
    end
  end

  context 'when logger with program name' do
    let(:logger) { Logger.new(string_io, progname: 'my_best_program') }

    it 'logs with program name' do
      conn.get '/hello'

      expect(string_io.string).to match('-- my_best_program: request:')
      expect(string_io.string).to match('-- my_best_program: response:')
    end
  end

  context 'when logger without program name' do
    it 'logs without program name' do
      conn.get '/hello'

      expect(string_io.string).to match('-- : request:')
      expect(string_io.string).to match('-- : response:')
    end
  end

  context 'with default formatter' do
    let(:formatter) { instance_double(Faraday::Logging::Formatter, request: true, response: true, filter: []) }

    before { allow(Faraday::Logging::Formatter).to receive(:new).and_return(formatter) }

    it 'delegates logging to the formatter' do
      expect(formatter).to receive(:request).with(an_instance_of(Faraday::Env))
      expect(formatter).to receive(:response).with(an_instance_of(Faraday::Env))
      conn.get '/hello'
    end

    context 'when no route' do
      it 'delegates logging to the formatter' do
        expect(formatter).to receive(:request).with(an_instance_of(Faraday::Env))
        expect(formatter).to receive(:exception).with(an_instance_of(Faraday::Adapter::Test::Stubs::NotFound))

        expect { conn.get '/noroute' }.to raise_error(Faraday::Adapter::Test::Stubs::NotFound)
      end
    end
  end

  context 'with custom formatter' do
    let(:formatter_class) do
      Class.new(Faraday::Logging::Formatter) do
        def request(_env)
          info 'Custom log formatter request'
        end

        def response(_env)
          info 'Custom log formatter response'
        end
      end
    end

    let(:logger_options) { { formatter: formatter_class } }

    it 'logs with custom formatter' do
      conn.get '/hello'

      expect(string_io.string).to match('Custom log formatter request')
      expect(string_io.string).to match('Custom log formatter response')
    end
  end

  it 'logs method and url' do
    conn.get '/hello', nil, accept: 'text/html'
    expect(string_io.string).to match('GET http:/hello')
  end

  it 'logs status' do
    conn.get '/hello', nil, accept: 'text/html'
    expect(string_io.string).to match('Status 200')
  end

  it 'does not log error message by default' do
    expect { conn.get '/noroute' }.to raise_error(Faraday::Adapter::Test::Stubs::NotFound)
    expect(string_io.string).not_to match(%(no stubbed request for get http:/noroute))
  end

  it 'logs request headers by default' do
    conn.get '/hello', nil, accept: 'text/html'
    expect(string_io.string).to match(%(Accept: "text/html))
  end

  it 'logs response headers by default' do
    conn.get '/hello', nil, accept: 'text/html'
    expect(string_io.string).to match(%(Content-Type: "text/html))
  end

  it 'does not log request body by default' do
    conn.post '/ohai', 'name=Unagi', accept: 'text/html'
    expect(string_io.string).not_to match(%(name=Unagi))
  end

  it 'does not log response body by default' do
    conn.post '/ohai', 'name=Toro', accept: 'text/html'
    expect(string_io.string).not_to match(%(fred))
  end

  it 'logs filter headers' do
    conn.headers = { 'api_key' => 'ABC123' }
    conn.get '/filtered_headers', nil, accept: 'text/html'
    expect(string_io.string).to match(%(api_key:))
    expect(string_io.string).to match(%([API_KEY]))
    expect(string_io.string).not_to match(%(ABC123))
  end

  it 'logs filter url' do
    conn.get '/filtered_url?password=hunter2', nil, accept: 'text/html'
    expect(string_io.string).to match(%([HIDDEN]))
    expect(string_io.string).not_to match(%(hunter2))
  end

  context 'when not logging request headers' do
    let(:logger_options) { { headers: { request: false } } }

    it 'does not log request headers if option is false' do
      conn.get '/hello', nil, accept: 'text/html'
      expect(string_io.string).not_to match(%(Accept: "text/html))
    end
  end

  context 'when not logging response headers' do
    let(:logger_options) { { headers: { response: false } } }

    it 'does not log response headers if option is false' do
      conn.get '/hello', nil, accept: 'text/html'
      expect(string_io.string).not_to match(%(Content-Type: "text/html))
    end
  end

  context 'when logging request body' do
    let(:logger_options) { { bodies: { request: true } } }

    it 'logs only request body' do
      conn.post '/ohyes', 'name=Tamago', accept: 'text/html'
      expect(string_io.string).to match(%(name=Tamago))
      expect(string_io.string).not_to match(%(pebbles))
    end
  end

  context 'when logging response body' do
    let(:logger_options) { { bodies: { response: true } } }

    it 'logs only response body' do
      conn.post '/ohyes', 'name=Hamachi', accept: 'text/html'
      expect(string_io.string).to match(%(pebbles))
      expect(string_io.string).not_to match(%(name=Hamachi))
    end
  end

  context 'when logging request and response bodies' do
    let(:logger_options) { { bodies: true } }

    it 'logs request and response body' do
      conn.post '/ohyes', 'name=Ebi', accept: 'text/html'
      expect(string_io.string).to match(%(name=Ebi))
      expect(string_io.string).to match(%(pebbles))
    end

    it 'logs response body object' do
      conn.get '/rubbles', nil, accept: 'text/html'
      expect(string_io.string).to match(%(["Barney", "Betty", "Bam Bam"]\n))
    end

    it 'logs filter body' do
      conn.get '/filtered_body', nil, accept: 'text/html'
      expect(string_io.string).to match(%(soylent green is))
      expect(string_io.string).to match(%(tasty))
      expect(string_io.string).not_to match(%(people))
    end
  end

  context 'when bodies are logged by default' do
    before do
      described_class.default_options = { bodies: true }
    end

    it 'logs response body' do
      conn.post '/ohai'
      expect(string_io.string).to match(%(fred))
    end

    it 'converts to UTF-8' do
      conn.get '/8bit'
      expect(string_io.string).to match(%(caf��!))
    end

    after do
      described_class.default_options = { bodies: false }
    end
  end

  context 'when logging errors' do
    let(:logger_options) { { errors: true } }

    it 'logs error message' do
      expect { conn.get '/noroute' }.to raise_error(Faraday::Adapter::Test::Stubs::NotFound)
      expect(string_io.string).to match(%(no stubbed request for get http:/noroute))
    end
  end

  context 'when logging headers and errors' do
    let(:logger_options) { { headers: true, errors: true } }

    it 'logs error message' do
      expect { conn.get '/connection_failed' }.to raise_error(Faraday::ConnectionFailed)
      expect(string_io.string).to match(%(Failed to open TCP connection))
    end
  end

  context 'when using log_level' do
    let(:logger_options) { { bodies: true, log_level: :debug } }

    it 'logs request/request body on the specified level (debug)' do
      logger.level = Logger::DEBUG
      conn.post '/ohyes', 'name=Ebi', accept: 'text/html'
      expect(string_io.string).to match(%(name=Ebi))
      expect(string_io.string).to match(%(pebbles))
    end

    it 'logs headers on the debug level' do
      logger.level = Logger::DEBUG
      conn.get '/hello', nil, accept: 'text/html'
      expect(string_io.string).to match(%(Content-Type: "text/html))
    end

    it 'does not log request/response body on the info level' do
      logger.level = Logger::INFO
      conn.post '/ohyes', 'name=Ebi', accept: 'text/html'
      expect(string_io.string).not_to match(%(name=Ebi))
      expect(string_io.string).not_to match(%(pebbles))
    end

    it 'does not log headers on the info level' do
      logger.level = Logger::INFO
      conn.get '/hello', nil, accept: 'text/html'
      expect(string_io.string).not_to match(%(Content-Type: "text/html))
    end
  end

  context 'with structured redaction' do
    let(:logger_options) { { bodies: true } }
    let(:captured_envs) { [] }
    let(:conn) do
      captured = captured_envs

      Faraday.new do |b|
        b.response :logger, logger, logger_options do |f|
          f.redact(:header, 'Authorization')
          f.redact(:header, 'x-api-token', on: :response)
          f.redact(:query, 'token')
          f.redact(:form, 'password')
          f.redact(:json, '$.users[*].phones[*]')
          f.redact(:json, '$.users[*].phone')
          f.redact(:json, '$.credentials.password')
          f.redact(:json, '$.token')
          f.redact(:json, '$..secret')
        end
        b.adapter :test do |stubs|
          stubs.get('/headers') do
            [200, { 'Content-Type' => 'text/plain', 'X-Api-Token' => 'resp-token-9' }, 'ok']
          end
          stubs.post('/echo') do |env|
            captured << env
            [200, { 'Content-Type' => 'application/json' },
                 '{"users":[{"phones":["13800000000","13900000000"],"name":"ada"}],' \
                 '"token":"resp-token-1","meta":{"secret":"s1"},"items":[{"secret":"s2"}]}']
          end
          stubs.get('/broken_json') do
            [200, { 'Content-Type' => 'application/json' }, '{not: valid json']
          end
          stubs.get('/hash_body') do
            [200, { 'Content-Type' => 'application/json' }, { 'users' => [{ 'phone' => '13800000000' }] }]
          end
        end
      end
    end

    # FlatParamsEncoder keeps repeated query params so the logger (and the
    # redaction rules) actually see every occurrence.
    let(:flat_conn) do
      captured = captured_envs

      Faraday.new(request: { params_encoder: Faraday::FlatParamsEncoder }) do |b|
        b.response :logger, logger, logger_options do |f|
          f.redact(:header, 'Authorization')
          f.redact(:query, 'token')
          f.redact(:form, 'password')
        end
        b.adapter :test do |stubs|
          stubs.get('/headers') { [200, {}, 'ok'] }
          stubs.post('/echo') do |env|
            captured << env
            [200, {}, 'ok']
          end
        end
      end
    end

    let(:read_counting_io_class) do
      Class.new do
        attr_reader :read_count

        def initialize(payload)
          @payload = payload
          @read_count = 0
        end

        def read(*_args)
          @read_count += 1
          @payload
        end
      end
    end

    it 'rejects invalid redaction configuration' do
      Faraday.new do |b|
        b.response :logger, logger do |f|
          expect { f.redact(:cookie, 'x') }.to raise_error(ArgumentError)
          expect { f.redact(:header, 'x', on: :sideways) }.to raise_error(ArgumentError)
          expect { f.redact(:json, 'users.phone') }.to raise_error(ArgumentError)
        end
        b.adapter :test
      end
    end

    it 'redacts configured header names case-insensitively' do
      conn.get('/headers', nil, 'Authorization' => 'Bearer req-token-9')
      expect(string_io.string).to include('Authorization: "[REDACTED]"')
      expect(string_io.string).to include('X-Api-Token: "[REDACTED]"')
      expect(string_io.string).not_to include('req-token-9')
      expect(string_io.string).not_to include('resp-token-9')
    end

   it 'redacts repeated query params in the logged URL only' do
      flat_conn.get('/headers?token=a1b2&token=c3d4&lang=zh')
      expect(string_io.string).to include('token=[REDACTED]&token=[REDACTED]')
      expect(string_io.string).to include('lang=zh')
      expect(string_io.string).not_to include('a1b2')
      expect(string_io.string).not_to include('c3d4')
    end

    it 'redacts repeated form keys in the request body' do
      conn.post('/echo', 'user=foo&password=pw1&password=pw2',
                'Content-Type' => 'application/x-www-form-urlencoded')
      expect(string_io.string).to include('user=foo&password=[REDACTED]&password=[REDACTED]')
      expect(string_io.string).not_to include('pw1')
      expect(string_io.string).not_to include('pw2')
    end

    it 'redacts JSON request bodies by path' do
      conn.post('/echo', '{"credentials":{"password":"pw9","user":"u1"}}',
                'Content-Type' => 'application/json')
      expect(string_io.string).not_to include('pw9')
      expect(string_io.string).to include('"user":"u1"')
    end

    it 'redacts phone numbers nested in JSON arrays in the response' do
      conn.post('/echo', 'user=foo')
      expect(string_io.string).not_to include('13800000000')
      expect(string_io.string).not_to include('13900000000')
      expect(string_io.string).not_to include('resp-token-1')
      expect(string_io.string).not_to include('s1')
      expect(string_io.string).not_to include('s2')
      expect(string_io.string).to include('[REDACTED]')
      expect(string_io.string).to include('"name":"ada"')
    end

    it 'redacts structured response bodies without mutating them' do
      resp = conn.get('/hash_body')
      expect(string_io.string).not_to include('13800000000')
      expect(resp.body['users'][0]['phone']).to eq('13800000000')
    end

    it 'logs a restricted notice instead of unparseable JSON' do
      conn.get('/broken_json')
      expect(string_io.string).to include(Faraday::Logging::Formatter::UNPARSEABLE_BODY_NOTICE)
      expect(string_io.string).not_to include('not: valid json')
    end

    it 'logs a restricted notice instead of unparseable form data' do
      conn.post('/echo', 'password=%ZZ', 'Content-Type' => 'application/x-www-form-urlencoded')
      expect(string_io.string).to include(Faraday::Logging::Formatter::UNPARSEABLE_BODY_NOTICE)
      expect(string_io.string).not_to include('%ZZ')
    end

    it 'never reads one-shot bodies and logs a notice instead' do
      io = read_counting_io_class.new('password=stream-secret')
      conn.post('/echo', io, 'Content-Type' => 'application/x-www-form-urlencoded')
      expect(io.read_count).to eq(0)
      expect(captured_envs.last.request_body).to equal(io)
      expect(string_io.string).to include(Faraday::Logging::Formatter::ONE_SHOT_BODY_NOTICE)
      expect(string_io.string).not_to include('stream-secret')
    end

    it 'does not change the request passed to the adapter' do
      raw_body = 'name=Unagi&password=hunter2&password=hunter3'
      resp = flat_conn.post('/echo?token=abc123&token=def456&lang=zh', raw_body,
                       'Content-Type' => 'application/x-www-form-urlencoded',
                       'Authorization' => 'Bearer sig%3Dabc')

      env = captured_envs.last
      expect(env.request_body).to equal(raw_body)
      expect(env.request_body).to eq('name=Unagi&password=hunter2&password=hunter3')
      expect(env.request_headers['Authorization']).to eq('Bearer sig%3Dabc')
      expect(env.url.to_s).to eq('http:/echo?lang=zh&token=abc123&token=def456')

      expect(string_io.string).not_to include('hunter2')
      expect(string_io.string).not_to include('abc123')
      expect(string_io.string).not_to include('sig%3Dabc')
    end

    it 'sends exactly the same request as a connection without logging' do
      captured = []
      build = lambda do |logging|
        Faraday.new do |b|
          if logging
            b.response :logger, logger, bodies: true do |f|
              f.redact(:header, 'Authorization')
              f.redact(:query, 'token')
              f.redact(:form, 'password')
            end
          end
          b.adapter :test do |stubs|
            stubs.post('/echo') do |env|
              captured << env
              [200, {}, 'ok']
            end
          end
        end
      end

      headers = { 'Content-Type' => 'application/x-www-form-urlencoded', 'Authorization' => 'Bearer tok' }
      build.call(false).post('/echo?token=a&x=1', 'name=Unagi&password=hunter2', headers)
      build.call(true).post('/echo?token=a&x=1', 'name=Unagi&password=hunter2', headers)

      expect(captured[1].request_body).to eq(captured[0].request_body)
      expect(captured[1].request_body.bytes).to eq(captured[0].request_body.bytes)
      expect(captured[1].request_headers).to eq(captured[0].request_headers)
      expect(captured[1].url).to eq(captured[0].url)
    end

    context 'with request-only rules' do
      let(:conn) do
        Faraday.new do |b|
          b.response :logger, logger, bodies: true do |f|
            f.redact(:form, 'password', on: :request)
          end
          b.adapter :test do |stubs|
            stubs.post('/phase') do
              [200, { 'Content-Type' => 'application/x-www-form-urlencoded' }, 'password=resp-secret&ok=1']
            end
          end
        end
      end

      it 'redacts only the request' do
        conn.post('/phase', 'password=req-secret&ok=1', 'Content-Type' => 'application/x-www-form-urlencoded')
        expect(string_io.string).not_to include('req-secret')
        expect(string_io.string).to include('resp-secret')
      end
    end

    context 'with response-only rules' do
      let(:conn) do
        Faraday.new do |b|
          b.response :logger, logger, bodies: true do |f|
            f.redact(:form, 'password', on: :response)
          end
          b.adapter :test do |stubs|
            stubs.post('/phase') do
              [200, { 'Content-Type' => 'application/x-www-form-urlencoded' }, 'password=resp-secret&ok=1']
            end
          end
        end
      end

      it 'redacts only the response' do
        conn.post('/phase', 'password=req-secret&ok=1', 'Content-Type' => 'application/x-www-form-urlencoded')
        expect(string_io.string).to include('req-secret')
        expect(string_io.string).not_to include('resp-secret')
      end
    end
  end
end
