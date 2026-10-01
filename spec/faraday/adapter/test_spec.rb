# frozen_string_literal: true

RSpec.describe Faraday::Adapter::Test do
  let(:stubs) do
    described_class::Stubs.new do |stub|
      stub.get('http://domain.test/hello') do
        [200, { 'Content-Type' => 'text/html' }, 'domain: hello']
      end

      stub.get('http://wrong.test/hello') do
        [200, { 'Content-Type' => 'text/html' }, 'wrong: hello']
      end

      stub.get('http://wrong.test/bait') do
        [404, { 'Content-Type' => 'text/html' }]
      end

      stub.get('/hello') do
        [200, { 'Content-Type' => 'text/html' }, 'hello']
      end

      stub.get('/method-echo') do |env|
        [200, { 'Content-Type' => 'text/html' }, env[:method].to_s]
      end

      stub.get(%r{\A/resources/\d+(?:\?|\z)}) do
        [200, { 'Content-Type' => 'text/html' }, 'show']
      end

      stub.get(%r{\A/resources/(specified)\z}) do |_env, meta|
        [200, { 'Content-Type' => 'text/html' }, "show #{meta[:match_data][1]}"]
      end
    end
  end

  let(:connection) do
    Faraday.new do |builder|
      builder.adapter :test, stubs
    end
  end

  let(:response) { connection.get('/hello') }

  context 'with simple path sets status' do
    subject { response.status }

    it { is_expected.to eq 200 }
  end

  context 'with simple path sets headers' do
    subject { response.headers['Content-Type'] }

    it { is_expected.to eq 'text/html' }
  end

  context 'with simple path sets body' do
    subject { response.body }

    it { is_expected.to eq 'hello' }
  end

  context 'with host points to the right stub' do
    subject { connection.get('http://domain.test/hello').body }

    it { is_expected.to eq 'domain: hello' }
  end

  describe 'can be called several times' do
    subject { connection.get('/hello').body }

    it { is_expected.to eq 'hello' }
  end

  describe 'can handle regular expression path' do
    subject { connection.get('/resources/1').body }

    it { is_expected.to eq 'show' }
  end

  describe 'can handle single parameter block' do
    subject { connection.get('/method-echo').body }

    it { is_expected.to eq 'get' }
  end

  describe 'can handle regular expression path with captured result' do
    subject { connection.get('/resources/specified').body }

    it { is_expected.to eq 'show specified' }
  end

  context 'with get params' do
    subject { connection.get('/param?a=1').body }

    before do
      stubs.get('/param?a=1') { [200, {}, 'a'] }
    end

    it { is_expected.to eq 'a' }
  end

  describe 'ignoring unspecified get params' do
    before do
      stubs.get('/optional?a=1') { [200, {}, 'a'] }
    end

    context 'with multiple params' do
      subject { connection.get('/optional?a=1&b=1').body }

      it { is_expected.to eq 'a' }
    end

    context 'with single param' do
      subject { connection.get('/optional?a=1').body }

      it { is_expected.to eq 'a' }
    end

    context 'without params' do
      subject(:request) { connection.get('/optional') }

      it do
        expect { request }.to raise_error(
          Faraday::Adapter::Test::Stubs::NotFound
        )
      end
    end
  end

  context 'with http headers' do
    before do
      stubs.get('/yo', 'X-HELLO' => 'hello') { [200, {}, 'a'] }
      stubs.get('/yo') { [200, {}, 'b'] }
    end

    context 'with header' do
      subject do
        connection.get('/yo') { |env| env.headers['X-HELLO'] = 'hello' }.body
      end

      it { is_expected.to eq 'a' }
    end

    context 'without header' do
      subject do
        connection.get('/yo').body
      end

      it { is_expected.to eq 'b' }
    end
  end

  describe 'different outcomes for the same request' do
    def make_request
      connection.get('/foo')
    end

    subject(:request) { make_request.body }

    before do
      stubs.get('/foo') { [200, { 'Content-Type' => 'text/html' }, 'hello'] }
      stubs.get('/foo') { [200, { 'Content-Type' => 'text/html' }, 'world'] }
    end

    context 'the first request' do
      it { is_expected.to eq 'hello' }
    end

    context 'the second request' do
      before do
        make_request
      end

      it { is_expected.to eq 'world' }
    end
  end

  describe 'yielding env to stubs' do
    subject { connection.get('http://foo.com/foo?a=1').body }

    before do
      stubs.get '/foo' do |env|
        expect(env[:url].path).to eq '/foo'
        expect(env[:url].host).to eq 'foo.com'
        expect(env[:params]['a']).to eq '1'
        expect(env[:request_headers]['Accept']).to eq 'text/plain'
        [200, {}, 'a']
      end

      connection.headers['Accept'] = 'text/plain'
    end

    it { is_expected.to eq 'a' }
  end

  describe 'params parsing' do
    subject { connection.get('http://foo.com/foo?a[b]=1').body }

    context 'with default encoder' do
      before do
        stubs.get '/foo' do |env|
          expect(env[:params]['a']['b']).to eq '1'
          [200, {}, 'a']
        end
      end

      it { is_expected.to eq 'a' }
    end

    context 'with nested encoder' do
      before do
        stubs.get '/foo' do |env|
          expect(env[:params]['a']['b']).to eq '1'
          [200, {}, 'a']
        end

        connection.options.params_encoder = Faraday::NestedParamsEncoder
      end

      it { is_expected.to eq 'a' }
    end

    context 'with flat encoder' do
      before do
        stubs.get '/foo' do |env|
          expect(env[:params]['a[b]']).to eq '1'
          [200, {}, 'a']
        end

        connection.options.params_encoder = Faraday::FlatParamsEncoder
      end

      it { is_expected.to eq 'a' }
    end
  end

  describe 'raising an error if no stub was found' do
    describe 'for request' do
      subject(:request) { connection.get('/invalid') { [200, {}, []] } }

      it { expect { request }.to raise_error described_class::Stubs::NotFound }
    end

    describe 'for specified host' do
      subject(:request) { connection.get('http://domain.test/bait') }

      it { expect { request }.to raise_error described_class::Stubs::NotFound }
    end

    describe 'for request without specified header' do
      subject(:request) { connection.get('/yo') }

      before do
        stubs.get('/yo', 'X-HELLO' => 'hello') { [200, {}, 'a'] }
      end

      it { expect { request }.to raise_error described_class::Stubs::NotFound }
    end
  end

  describe 'for request with non default params encoder' do
    let(:connection) do
      Faraday.new(request: { params_encoder: Faraday::FlatParamsEncoder }) do |builder|
        builder.adapter :test, stubs
      end
    end
    let(:stubs) do
      described_class::Stubs.new do |stubs|
        stubs.get('/path?a=x&a=y&a=z') { [200, {}, 'a'] }
      end
    end

    context 'when all flat param values are correctly set' do
      subject(:request) { connection.get('/path?a=x&a=y&a=z') }

      it { expect(request.status).to eq 200 }
    end

    shared_examples 'raise NotFound when params do not satisfy the flat param values' do |params|
      subject(:request) { connection.get('/path', params) }

      context "with #{params.inspect}" do
        it { expect { request }.to raise_error described_class::Stubs::NotFound }
      end
    end

    it_behaves_like 'raise NotFound when params do not satisfy the flat param values', { a: %w[x] }
    it_behaves_like 'raise NotFound when params do not satisfy the flat param values', { a: %w[x y] }
    it_behaves_like 'raise NotFound when params do not satisfy the flat param values', { a: %w[x z y] } # NOTE: The order of the value is also compared.
    it_behaves_like 'raise NotFound when params do not satisfy the flat param values', { b: %w[x y z] }
  end

  describe 'strict_mode' do
    let(:stubs) do
      described_class::Stubs.new(strict_mode: true) do |stubs|
        stubs.get('/strict?a=12&b=xy', 'Authorization' => 'Bearer m_ck', 'X-C' => 'hello') { [200, {}, 'a'] }
        stubs.get('/with_user_agent?a=12&b=xy', authorization: 'Bearer m_ck', 'User-Agent' => 'My Agent') { [200, {}, 'a'] }
      end
    end

    context 'when params and headers are exactly set' do
      subject(:request) { connection.get('/strict', { a: '12', b: 'xy' }, { authorization: 'Bearer m_ck', x_c: 'hello' }) }

      it { expect(request.status).to eq 200 }
    end

    context 'when params and headers are exactly set with a custom user agent' do
      subject(:request) { connection.get('/with_user_agent', { a: '12', b: 'xy' }, { authorization: 'Bearer m_ck', 'User-Agent' => 'My Agent' }) }

      it { expect(request.status).to eq 200 }
    end

    shared_examples 'raise NotFound when params do not satisfy the strict check' do |params|
      subject(:request) { connection.get('/strict', params, { 'Authorization' => 'Bearer m_ck', 'X-C' => 'hello' }) }

      context "with #{params.inspect}" do
        it { expect { request }.to raise_error described_class::Stubs::NotFound }
      end
    end

    it_behaves_like 'raise NotFound when params do not satisfy the strict check', { a: '12' }
    it_behaves_like 'raise NotFound when params do not satisfy the strict check', { b: 'xy' }
    it_behaves_like 'raise NotFound when params do not satisfy the strict check', { a: '123', b: 'xy' }
    it_behaves_like 'raise NotFound when params do not satisfy the strict check', { a: '12', b: 'xyz' }
    it_behaves_like 'raise NotFound when params do not satisfy the strict check', { a: '12', b: 'xy', c: 'hello' }
    it_behaves_like 'raise NotFound when params do not satisfy the strict check', { additional: 'special', a: '12', b: 'xy', c: 'hello' }

    shared_examples 'raise NotFound when headers do not satisfy the strict check' do |path, headers|
      subject(:request) { connection.get(path, { a: 12, b: 'xy' }, headers) }

      context "with #{headers.inspect}" do
        it { expect { request }.to raise_error described_class::Stubs::NotFound }
      end
    end

    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/strict', { authorization: 'Bearer m_ck' }
    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/strict', { 'X-C' => 'hello' }
    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/strict', { authorization: 'Bearer m_ck', 'x-c': 'Hi' }
    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/strict', { authorization: 'Basic m_ck', 'x-c': 'hello' }
    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/strict', { authorization: 'Bearer m_ck', 'x-c': 'hello', x_special: 'special' }
    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/with_user_agent', { authorization: 'Bearer m_ck' }
    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/with_user_agent', { authorization: 'Bearer m_ck', user_agent: 'Unknown' }
    it_behaves_like 'raise NotFound when headers do not satisfy the strict check', '/with_user_agent', { authorization: 'Bearer m_ck', user_agent: 'My Agent', x_special: 'special' }

    context 'when strict_mode is disabled' do
      before do
        stubs.strict_mode = false
      end

      shared_examples 'does not raise NotFound even when params do not satisfy the strict check' do |params|
        subject(:request) { connection.get('/strict', params, { 'Authorization' => 'Bearer m_ck', 'X-C' => 'hello' }) }

        context "with #{params.inspect}" do
          it { expect(request.status).to eq 200 }
        end
      end

      it_behaves_like 'does not raise NotFound even when params do not satisfy the strict check', { a: '12', b: 'xy' }
      it_behaves_like 'does not raise NotFound even when params do not satisfy the strict check', { a: '12', b: 'xy', c: 'hello' }
      it_behaves_like 'does not raise NotFound even when params do not satisfy the strict check', { additional: 'special', a: '12', b: 'xy', c: 'hello' }

      shared_examples 'does not raise NotFound even when headers do not satisfy the strict check' do |path, headers|
        subject(:request) { connection.get(path, { a: 12, b: 'xy' }, headers) }

        context "with #{headers.inspect}" do
          it { expect(request.status).to eq 200 }
        end
      end

      it_behaves_like 'does not raise NotFound even when headers do not satisfy the strict check', '/strict', { authorization: 'Bearer m_ck', 'x-c': 'hello' }
      it_behaves_like 'does not raise NotFound even when headers do not satisfy the strict check', '/strict', { authorization: 'Bearer m_ck', 'x-c': 'hello', x_special: 'special' }
      it_behaves_like 'does not raise NotFound even when headers do not satisfy the strict check', '/strict', { authorization: 'Bearer m_ck', 'x-c': 'hello', user_agent: 'Special Agent' }
      it_behaves_like 'does not raise NotFound even when headers do not satisfy the strict check', '/with_user_agent', { authorization: 'Bearer m_ck', user_agent: 'My Agent' }
      it_behaves_like 'does not raise NotFound even when headers do not satisfy the strict check', '/with_user_agent', { authorization: 'Bearer m_ck', user_agent: 'My Agent', x_special: 'special' }
    end

    describe 'body_match?' do
      let(:stubs) do
        described_class::Stubs.new do |stubs|
          stubs.post('/no_check') { [200, {}, 'ok'] }
          stubs.post('/with_string', 'abc') { [200, {}, 'ok'] }
          stubs.post(
            '/with_proc',
            ->(request_body) { JSON.parse(request_body, symbolize_names: true) == { x: '!', a: [{ m: [{ a: true }], n: 123 }] } },
            { content_type: 'application/json' }
          ) do
            [200, {}, 'ok']
          end
        end
      end

      context 'when trying without any args for body' do
        subject(:without_body) { connection.post('/no_check') }

        it { expect(without_body.status).to eq 200 }
      end

      context 'when trying with string body stubs' do
        subject(:with_string) { connection.post('/with_string', 'abc') }

        it { expect(with_string.status).to eq 200 }
      end

      context 'when trying with proc body stubs' do
        subject(:with_proc) do
          connection.post('/with_proc', JSON.dump(a: [{ n: 123, m: [{ a: true }] }], x: '!'), { 'Content-Type' => 'application/json' })
        end

        it { expect(with_proc.status).to eq 200 }
      end
    end
  end

  describe 'request timeout' do
    subject(:request) do
      connection.get('/sleep') do |req|
        req.options.timeout = timeout
      end
    end

    before do
      stubs.get('/sleep') do
        sleep(0.01)
        [200, {}, '']
      end
    end

    context 'when request is within timeout' do
      let(:timeout) { 1 }

      it { expect(request.status).to eq 200 }
    end

    context 'when request is too slow' do
      let(:timeout) { 0.001 }

      it 'raises an exception' do
        expect { request }.to raise_error(Faraday::TimeoutError)
      end
    end
  end

  describe 'informational responses' do
    def script(session, fail_after_hints: false)
      session.information(100, { 'Expect' => '100-continue' })
      session.information(103, { 'Link' => '</style.css>; rel=preload' })
      session.information(103, { 'Link' => '</script.js>; rel=modulepreload' })
      return session.fail(RuntimeError.new('boom')) if fail_after_hints

      session.respond(200, { 'Content-Type' => 'text/plain' }, 'done')
    end

    let(:events) { [] }

    let(:information_connection) do
      callbacks = events
      Faraday.new do |builder|
        builder.adapter :test, stubs
        builder.use(Class.new(Faraday::Middleware) do
          define_method(:on_request) do |env|
            env.request.on_informational_response = proc { |event| callbacks << event }
          end
        end)
      end
    end

    it 'delivers 100 and two 103 responses before the final response' do
      stubs.get('/hints') { |_env, _meta, session| script(session) }

      response = information_connection.get('/hints')

      expect(events.map(&:status)).to eq([100, 103, 103])
      expect(events.map { |event| event.headers.class }).to all(eq(Faraday::Utils::Headers))
      expect(events).to all(be_frozen)
      expect(events.first['expect']).to eq('100-continue')
      expect(events[1].headers['Link']).to eq('</style.css>; rel=preload')
      expect(events[2].headers['Link']).to eq('</script.js>; rel=modulepreload')
      expect(response.status).to eq(200)
      expect(response.body).to eq('done')
    end

    it 'keeps every header snapshot independent' do
      headers = { 'Link' => 'first' }
      stubs.get('/mutable') do |_env, _meta, session|
        session.information(103, headers)
        headers['Link'] = 'second'
        session.respond(200, {}, '')
      end

      information_connection.get('/mutable')

      expect(events.first.headers['Link']).to eq('first')
    end

    it 'does not invoke response middleware for informational responses' do
      completed = []
      information_events = []
      tracker = Class.new(Faraday::Middleware) do
        define_method(:on_complete) { |_env| completed << :complete }
      end
      connection = Faraday.new do |builder|
        builder.response :raise_error
        builder.response :json
        builder.use tracker
        builder.adapter :test, stubs
        builder.use(Class.new(Faraday::Middleware) do
          define_method(:on_request) do |env|
            env.request.on_informational_response = proc { |event| information_events << event.status }
          end
        end)
      end
      stubs.get('/middleware') do |_env, _meta, session|
        session.information(103, { 'Content-Type' => 'application/json', 'Link' => '</x>' })
        session.respond(200, { 'Content-Type' => 'application/json' }, '{"ok":true}')
      end

      response = connection.get('/middleware')

      expect(response.body).to eq('ok' => true)
      expect(information_events).to eq([103])
      expect(completed).to eq([:complete])
    end

    it 'fails synchronously between information and completion' do
      stubs.get('/failure') { |_env, _meta, session| script(session, fail_after_hints: true) }

      expect { information_connection.get('/failure') }.to raise_error(RuntimeError, 'boom')
      expect(events.map(&:status)).to eq([100, 103, 103])
    end

    it 'supports delayed completion and rejects late events' do
      session = nil
      started = Queue.new
      perform = Queue.new
      stubs.get('/delayed') do |_env, _meta, script_session|
        script_session.defer do |deferred|
          started << true
          perform.pop
          deferred.information(100)
          deferred.information(103, { 'Link' => '</style.css>; rel=preload' })
          deferred.information(103, { 'Link' => '</script.js>; rel=modulepreload' })
          deferred.respond(200, { 'Content-Type' => 'text/plain' }, 'done')
        end
        session = script_session
      end

      information_connection.get('/delayed')
      started.pop
      perform << true
      response = session.wait

      expect(events.map(&:status)).to eq([100, 103, 103])
      expect(response.status).to eq(200)
      expect(response.body).to eq('done')
      expect { session.information(103) }.to raise_error(Faraday::LateInformationResponseError)
    end

    it 'surfaces a delayed failure after informational responses' do
      session = nil
      started = Queue.new
      perform = Queue.new
      stubs.get('/delayed-failure') do |_env, _meta, script_session|
        script_session.defer do |deferred|
          started << true
          perform.pop
          deferred.information(100)
          deferred.information(103)
          deferred.fail(RuntimeError.new('late boom'))
        end
        session = script_session
      end

      information_connection.get('/delayed-failure')
      started.pop
      perform << true

      expect { session.wait }.to raise_error(RuntimeError, 'late boom')
      expect(session.response).to be_failed
      expect(events.map(&:status)).to eq([100, 103])
    end

    it 'has clear cancellation semantics for delayed requests' do
      session = nil
      started = Queue.new
      cancellation_gate = Queue.new
      stubs.get('/canceled') do |_env, _meta, script_session|
        script_session.defer do |deferred|
          started << true
          cancellation_gate.pop
          deferred.respond(200, {}, 'late')
        end
        session = script_session
      end

      information_connection.get('/canceled')
      started.pop
      session.cancel
      cancellation_gate << true

      expect(session.wait).to be_canceled
      expect(session.response.error).to be_a(Faraday::RequestCanceled)
      session.join_deferred
    end

    it 'requires an adapter capability declaration' do
      unsupported_adapter = Class.new(Faraday::Adapter) do
        def call(env)
          super
          save_information(env, 103)
          save_response(env, 200, '')
        end
      end
      env = Faraday::Env.from(
        method: :get,
        request: Faraday::RequestOptions.new,
        request_headers: Faraday::Utils::Headers.new,
        url: Faraday::Utils::URI('/')
      )

      expect { unsupported_adapter.new.call(env) }.to raise_error(NotImplementedError)
      expect(unsupported_adapter).not_to be_supports_informational_responses
      expect(described_class).to be_supports_informational_responses
    end
  end

  describe '#clear' do
    it 'removes pending stubs' do
      stubs.clear
      expect { connection.get('/hello') }.to raise_error(described_class::Stubs::NotFound)
    end

    it 'removes already consumed stubs' do
      expect(connection.get('/hello').body).to eq('hello')
      stubs.clear
      expect { connection.get('/hello') }.to raise_error(described_class::Stubs::NotFound)
    end

    it 'leaves the stubs empty' do
      stubs.clear
      expect(stubs).to be_empty
    end
  end
end
