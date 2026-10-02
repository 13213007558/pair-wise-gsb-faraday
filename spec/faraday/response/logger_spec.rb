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

  context 'when redacting sensitive data' do
    let(:captured_envs) { [] }

    let(:capture_adapter_class) do
      captured = captured_envs
      Class.new(Faraday::Adapter) do
        define_method(:call) do |env|
          # Snapshot the raw request exactly as it reaches the adapter,
          # before the response overwrites env.body.
          captured << {
            url: env.url.to_s,
            request_headers: env.request_headers.dup,
            body: env.body
          }
          env.response = Faraday::Response.new
          save_response(env, 200, '{"token":"response-secret","note":"ok"}',
                        { 'Content-Type' => 'application/json',
                          'X-Response-Token' => 'response-secret' })
        end
      end
    end

    let(:logger_options) do
      {
        bodies: true,
        redact: {
          request: {
            headers: %w[Authorization],
            query: %w[token],
            form: %w[password phones],
            json: ['$.password', '$.phones[*]']
          },
          response: {
            headers: %w[X-Response-Token],
            json: ['$.token']
          }
        }
      }
    end

    let(:conn) do
      adapter_class = capture_adapter_class
      options = logger_options
      log = logger
      Faraday.new(url: 'http://example.org') do |b|
        b.response :logger, log, options
        b.adapter adapter_class
      end
    end

    it 'redacts request and response headers by name' do
      conn.get('/hello', nil, 'Authorization' => 'Bearer s3cr3t')
      expect(string_io.string).to include('Authorization: "[REDACTED]"')
      expect(string_io.string).to include('X-Response-Token: "[REDACTED]"')
      expect(string_io.string).not_to include('s3cr3t')
      expect(string_io.string).not_to include('response-secret')
    end

    it 'keeps non-sensitive headers in the log' do
      conn.get('/hello', nil, 'Accept' => 'text/html')
      expect(string_io.string).to include('Accept: "text/html"')
      expect(string_io.string).to include('Content-Type: "application/json"')
    end

    it 'redacts query keys in the logged url' do
      conn.get('/callback?token=t1&keep=1')
      expect(string_io.string).to include('token=[REDACTED]')
      expect(string_io.string).to include('keep=1')
      expect(string_io.string).not_to include('t1')
    end

    it 'redacts form keys, repeated params and nested arrays in the request body' do
      conn.post('/submit',
                'password=hunter2&password=hunter3&phones[]=138&phones[]=139&name=Unagi',
                'Content-Type' => 'application/x-www-form-urlencoded')
      expect(string_io.string).to include('password=[REDACTED]&password=[REDACTED]')
      expect(string_io.string).to include('phones[]=[REDACTED]&phones[]=[REDACTED]')
      expect(string_io.string).to include('name=Unagi')
      expect(string_io.string).not_to include('hunter2')
      expect(string_io.string).not_to include('hunter3')
      expect(string_io.string).not_to include('138')
    end

    it 'applies request rules only to the request and response rules only to the response' do
      conn.post('/json',
                '{"password":"req-secret","phones":["138","139"],"token":"req-token"}',
                'Content-Type' => 'application/json')
      # request rules redact password and phones, but not token
      expect(string_io.string).to include('"password":"[REDACTED]"')
      expect(string_io.string).to include('"phones":["[REDACTED]","[REDACTED]"]')
      expect(string_io.string).to include('req-token')
      # response rules redact token, and keep the rest for debugging
      expect(string_io.string).to include('"token":"[REDACTED]"')
      expect(string_io.string).to include('"note":"ok"')
      expect(string_io.string).not_to include('req-secret')
      expect(string_io.string).not_to include('response-secret')
    end

    it 'logs a restricted notice instead of an unparsable body' do
      conn.post('/json', 'not json { req-secret', 'Content-Type' => 'application/json')
      expect(string_io.string).to include('[body omitted: could not parse JSON body for redaction]')
      expect(string_io.string).not_to include('req-secret')
    end

    it 'sends the exact original request to the adapter' do
      body = +'password=hunter2&phones[]=138&name=Unagi'
      original_bytes = body.bytes.dup
      conn.post('/submit?keep=1&token=t1', body,
                'Content-Type' => 'application/x-www-form-urlencoded',
                'Authorization' => 'Bearer s3cr3t',
                'X-Signature' => 'sig:abc123')

      captured = captured_envs.last
      expect(captured[:url]).to eq('http://example.org/submit?keep=1&token=t1')
      expect(captured[:request_headers]['Authorization']).to eq('Bearer s3cr3t')
      expect(captured[:request_headers]['X-Signature']).to eq('sig:abc123')
      expect(captured[:body]).to equal(body)
      expect(captured[:body].bytes).to eq(original_bytes)
      expect(captured[:body]).to eq('password=hunter2&phones[]=138&name=Unagi')
    end

    it 'produces identical adapter input with and without logging' do
      body = +'password=hunter2&name=Unagi'
      build = lambda do |with_logger|
        adapter_class = capture_adapter_class
        Faraday.new(url: 'http://example.org') do |b|
          b.response :logger, logger, logger_options if with_logger
          b.adapter adapter_class
        end
      end

      build.call(false).post('/submit?token=t1', body,
                             'Content-Type' => 'application/x-www-form-urlencoded',
                             'Authorization' => 'Bearer s3cr3t')
      without_logging = captured_envs.pop
      build.call(true).post('/submit?token=t1', body,
                            'Content-Type' => 'application/x-www-form-urlencoded',
                            'Authorization' => 'Bearer s3cr3t')
      with_logging = captured_envs.pop

      expect(with_logging[:url]).to eq(without_logging[:url])
      expect(with_logging[:request_headers].to_hash).to eq(without_logging[:request_headers].to_hash)
      expect(with_logging[:body]).to equal(without_logging[:body])
      expect(with_logging[:body].bytes).to eq(without_logging[:body].bytes)
    end

    context 'with a one-shot (IO-like) request body' do
      let(:counting_io_class) do
        Class.new do
          attr_reader :read_count

          def initialize(data)
            @data = data
            @read_count = 0
          end

          def read(*_args)
            @read_count += 1
            @data
          end
        end
      end

      it 'is never read for logging and reaches the adapter untouched' do
        io = counting_io_class.new('stream-bytes')
        conn.post('/upload', io, 'Content-Type' => 'application/octet-stream')

        expect(io.read_count).to eq(0)
        expect(captured_envs.last[:body]).to equal(io)
        expect(string_io.string).to include('[stream body omitted: not read for logging]')
        expect(string_io.string).not_to include('stream-bytes')
      end
    end

    context 'with rules that do not distinguish request and response' do
      let(:logger_options) do
        { bodies: true, redact: { headers: %w[Authorization X-Response-Token] } }
      end

      it 'applies the shared rules to both directions' do
        conn.get('/hello', nil, 'Authorization' => 'Bearer s3cr3t')
        expect(string_io.string).to include('Authorization: "[REDACTED]"')
        expect(string_io.string).to include('X-Response-Token: "[REDACTED]"')
        expect(string_io.string).not_to include('s3cr3t')
      end
    end
  end
end
