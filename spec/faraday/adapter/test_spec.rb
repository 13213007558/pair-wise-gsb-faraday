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
  describe 'named scenarios' do
    let(:stubs) do
      described_class::Stubs.new do |s|
        s.scenario(:resource_lifecycle) do |scenario|
          scenario.state :empty do |state|
            state.on :post, '/resources', to: :pending do |_env, session|
              session[:id] = "res-#{session.number}"
              [201, {}, JSON.dump(id: session[:id], status: 'pending')]
            end
          end
          scenario.state :pending do |state|
            state.on :get, '/resources/{id}' do |_env, session|
              [200, {}, JSON.dump(id: session[:id], status: 'pending')]
            end
            state.on :delete, '/resources/{id}', to: :gone do |_env, _session|
              [204, {}, '']
            end
          end
          scenario.state :gone, terminal: true
        end
      end
    end

    let(:connection) do
      Faraday.new do |builder|
        builder.adapter :test, stubs
      end
    end

    def create_resource
      connection.post('/resources')
    end

    it 'runs the create-poll-delete lifecycle' do
      expect(create_resource.status).to eq 201
      expect(connection.get('/resources/res-1').body).to include '"id":"res-1"'
      expect(connection.delete('/resources/res-1').status).to eq 204
      expect { stubs.verify_stubbed_calls }.not_to raise_error
    end

    it 'allows repeated polling and reuses the captured id in every response' do
      create_resource
      bodies = Array.new(3) { connection.get('/resources/res-1').body }
      expect(bodies.uniq).to eq [JSON.dump(id: 'res-1', status: 'pending')]
    end

    it 'keeps plain stubs working alongside scenarios' do
      stubs.get('/hello') { [200, {}, 'hello'] }
      expect(connection.get('/hello').body).to eq 'hello'
      expect(create_resource.status).to eq 201
    end

    it 'raises Stubs::NotFound for requests unrelated to any scenario' do
      expect { connection.get('/unrelated') }.to raise_error(described_class::Stubs::NotFound)
    end

    context 'when a request does not fit the current state' do
      it 'rejects delete-before-create without consuming the delete step' do
        expect { connection.delete('/resources/res-1') }.to raise_error(
          described_class::Stubs::ScenarioMismatch,
          %r{scenario :resource_lifecycle cannot accept DELETE .*/resources/res-1 yet.*POST /resources.*no later step was consumed}m,
        )

        expect(create_resource.status).to eq 201
        expect(connection.get('/resources/res-1').status).to eq 200
        expect(connection.delete('/resources/res-1').status).to eq 204
      end

      it 'reports the failed create when polling continues after a 500' do
        flaky = true
        stubs.scenario(:flaky_create) do |scenario|
          scenario.state :empty do |state|
            state.on :post, '/jobs', to: :ready do |_env, session|
              session[:id] = 'job-1'
              flaky ? [500, {}, 'boom'] : [201, {}, JSON.dump(id: session[:id])]
            end
          end
          scenario.state :ready, terminal: true do |state|
            state.on(:get, '/jobs/{id}') { |_env, session| [200, {}, "job #{session[:id]}"] }
          end
        end

        expect(connection.post('/jobs').status).to eq 500
        expect { connection.get('/jobs/job-1') }.to raise_error(
          described_class::Stubs::ScenarioMismatch,
          /state :empty.*POST \/jobs responded 500 and did not advance/m,
        )

        flaky = false
        expect(connection.post('/jobs').status).to eq 201
        expect(connection.get('/jobs/job-1').body).to eq 'job job-1'
      end

      it 'gives delete-before-create and poll-after-failure distinct messages' do
        delete_error = begin
          connection.delete('/resources/res-1')
        rescue described_class::Stubs::ScenarioMismatch => e
          e.message
        end

        stubs.scenario(:failing_create) do |scenario|
          scenario.state(:empty) do |state|
            state.on(:post, '/jobs', to: :ready) { [500, {}, 'boom'] }
          end
          scenario.state(:ready, terminal: true) do |state|
            state.on(:get, '/jobs/{id}') { [200, {}, 'ok'] }
          end
        end
        connection.post('/jobs')
        poll_error = begin
          connection.get('/jobs/job-1')
        rescue described_class::Stubs::ScenarioMismatch => e
          e.message
        end

        expect(delete_error).to include('DELETE')
        expect(delete_error).not_to include('did not advance')
        expect(poll_error).to include('responded 500 and did not advance')
        expect(poll_error).not_to eq delete_error
      end

      it 'raises a ScenarioMismatch that is also a Stubs::NotFound' do
        expect { connection.delete('/resources/res-1') }.to raise_error(described_class::Stubs::NotFound)
      end
    end

    context 'with several sessions of the same scenario' do
      it 'keeps sessions isolated and routes by captured data' do
        expect(create_resource.status).to eq 201
        expect(create_resource.status).to eq 201

        expect(connection.get('/resources/res-2').body).to include '"id":"res-2"'
        expect(connection.get('/resources/res-1').body).to include '"id":"res-1"'

        expect(connection.delete('/resources/res-1').status).to eq 204
        expect(connection.get('/resources/res-2').status).to eq 200
        expect(connection.delete('/resources/res-2').status).to eq 204
        expect { stubs.verify_stubbed_calls }.not_to raise_error
      end

      it 'rejects an id no session captured' do
        create_resource
        expect { connection.get('/resources/res-9') }.to raise_error(
          described_class::Stubs::ScenarioMismatch,
          %r{session #1 is in state :pending and expects one of: GET /resources/\{id\}, DELETE /resources/\{id\}},
        )
      end
    end

    describe 'terminal state checks' do
      it 'passes when every session reached a terminal state' do
        create_resource
        connection.delete('/resources/res-1')
        expect { stubs.verify_stubbed_calls }.not_to raise_error
      end

      it 'fails when a session stops before a terminal state' do
        create_resource
        connection.get('/resources/res-1')
        expect { stubs.verify_stubbed_calls }.to raise_error(
          /Scenario :resource_lifecycle session #1 stopped in state :pending; expected terminal state :gone/,
        )
      end

      it 'fails when the scenario never started' do
        expect { stubs.verify_stubbed_calls }.to raise_error(
          %r{Scenario :resource_lifecycle never started; expected one of: POST /resources},
        )
      end
    end

    describe 'dynamic transitions' do
      let(:stubs) do
        described_class::Stubs.new do |s|
          s.scenario(:job) do |scenario|
            scenario.state :idle do |state|
              state.on :post, '/jobs', to: :running do |_env, session|
                session[:id] = 'job-1'
                session[:polls] = 0
                [201, {}, 'created']
              end
            end
            scenario.state :running do |state|
              state.on :get, '/jobs/{id}' do |_env, session|
                session[:polls] += 1
                session.transition_to(:done) if session[:polls] >= 2
                [200, {}, 'running']
              end
            end
            scenario.state :done, terminal: true do |state|
              state.on(:get, '/jobs/{id}') { [200, {}, 'finished'] }
            end
          end
        end
      end

      it 'advances when the step block requests a transition' do
        connection.post('/jobs')
        expect(connection.get('/jobs/job-1').body).to eq 'running'
        expect(connection.get('/jobs/job-1').body).to eq 'running'
        expect(connection.get('/jobs/job-1').body).to eq 'finished'
        expect { stubs.verify_stubbed_calls }.not_to raise_error
      end
    end

    describe 'regexp steps' do
      let(:stubs) do
        described_class::Stubs.new do |s|
          s.scenario(:widgets) do |scenario|
            scenario.state :ready, terminal: true do |state|
              state.on :get, %r{\A/widgets/(\d+)\z} do |_env, _session, meta|
                [200, {}, "widget #{meta[:match_data][1]}"]
              end
            end
          end
        end
      end

      it 'yields the match data to the step block' do
        expect(connection.get('/widgets/42').body).to eq 'widget 42'
      end
    end

    describe '#clear' do
      it 'resets scenario sessions so the lifecycle can start over' do
        create_resource
        connection.delete('/resources/res-1')
        stubs.clear

        expect(create_resource.status).to eq 201
        expect(connection.get('/resources/res-1').status).to eq 200
        expect(connection.delete('/resources/res-1').status).to eq 204
        expect { stubs.verify_stubbed_calls }.not_to raise_error
      end
    end

    describe 'validation' do
      it 'rejects transitions to unknown states' do
        expect do
          described_class::Stubs.new do |s|
            s.scenario(:broken) do |scenario|
              scenario.state(:only) { |state| state.on(:get, '/x', to: :nowhere) { [200, {}, ''] } }
            end
          end
        end.to raise_error(ArgumentError, /unknown state :nowhere/)
      end

      it 'rejects scenarios without states' do
        expect do
          described_class::Stubs.new { |s| s.scenario(:empty_scenario) { |_scenario| nil } }
        end.to raise_error(ArgumentError, /defines no states/)
      end
    end
  end
end
