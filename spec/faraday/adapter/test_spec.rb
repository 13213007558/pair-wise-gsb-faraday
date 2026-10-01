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

  describe 'stateful scenarios' do
    let(:stubs) do
      described_class::Stubs.new do |stubs|
        stubs.scenario(:job, initial_state: :creating) do
          state :creating do
            post '/jobs', ->(body) { JSON.parse(body)['type'] == 'report' }, to: :pending do |_env, session|
              session.data[:job_id] = 'job-123'
              [202, {}, { id: 'job-123' }]
            end
          end

          state :pending do
            get '/jobs/:id', to: ->(session, attempts) { attempts >= 2 ? :ready : :same } do |_env, session|
              [200, {}, { id: session.data[:job_id], status: 'pending' }]
            end
          end

          state :ready do
            get '/jobs/:id' do |_env, session|
              [200, {}, { id: session.data[:job_id], status: 'ready' }]
            end
            delete '/jobs/:id', to: :deleted do |_env, session|
              [204, {}, { id: session.data[:job_id] }]
            end
          end

          state :deleted do
            get '/jobs/:id' do |_env, session|
              [404, {}, { id: session.data[:job_id] }]
            end
          end
        end

        stubs.get('/ordinary') { [200, {}, 'ordinary'] }
      end
    end

    it 'creates, repeats polling, checks the terminal state, and deletes' do
      create_response = connection.post('/jobs', JSON.dump(type: 'report'))
      expect(create_response.status).to eq(202)

      pending_response = connection.get('/jobs/job-123')
      expect(pending_response.body[:status]).to eq('pending')

      second_pending_response = connection.get('/jobs/job-123')
      expect(second_pending_response.body[:status]).to eq('pending')

      ready_response = connection.get('/jobs/job-123')
      expect(ready_response.body[:status]).to eq('ready')

      delete_response = connection.delete('/jobs/job-123')
      expect(delete_response.status).to eq(204)

      terminal_response = connection.get('/jobs/job-123')
      expect(terminal_response.status).to eq(404)
    end

    it 'does not allow deleting before creation and reports the expected step' do
      expect { connection.delete('/jobs/job-123') }.to raise_error(
        described_class::Stubs::InvalidScenarioStep,
        %r{before a resource was created.*POST /jobs}m
      )

      expect(connection.get('/ordinary').body).to eq('ordinary')
    end

    it 'does not consume a later state stub when the current state does not allow the request' do
      connection.post('/jobs', JSON.dump(type: 'report'))

      expect { connection.delete('/jobs/job-123') }.to raise_error(
        described_class::Stubs::InvalidScenarioStep,
        %r{not allowed.*state :pending.*Allowed requests in this state: GET /jobs/:id}
      )
    end

    it 'isolates sessions' do
      scenario = stubs.scenario(:resource, initial_state: :creating) do
        state :creating do
          post '/resources', to: :ready do |env, session|
            id = JSON.parse(env.body)['id']
            session.id = id
            session.data[:resource_id] = id
            [201, {}, { id: id }]
          end
        end

        state :ready do
          get '/resources/:id' do |_env, session|
            [200, {}, { id: session.data[:resource_id] }]
          end
        end
      end

      first = connection.post('/resources', JSON.dump(id: 'one'))
      second = connection.post('/resources', JSON.dump(id: 'two'))
      expect(first.status).to eq(201)
      expect(second.status).to eq(201)
      expect(connection.get('/resources/one').body[:id]).to eq('one')
      expect(connection.get('/resources/two').body[:id]).to eq('two')
      expect(scenario.sessions.keys).to contain_exactly('one', 'two')
      expect(scenario.session_state('one')).to eq(:ready)
    end

    it 'keeps structurally similar scenarios isolated' do
      stubs.scenario(:second, initial_state: :new) do
        post('/second-jobs', to: :ready) { [201, {}, { id: 'second' }] }
        state(:ready) { get('/second-jobs/other') { [200, {}, 'second'] } }
      end

      connection.post('/jobs', JSON.dump(type: 'report'))
      second_create = connection.post('/second-jobs')
      expect(second_create.status).to eq(201)
      expect(connection.get('/jobs/job-123').body[:id]).to eq('job-123')
      expect(connection.get('/second-jobs/other').body).to eq('second')
    end

    context 'when creation fails' do
      let(:stubs) do
        described_class::Stubs.new do |stubs|
          stubs.scenario(:job, initial_state: :creating) do
            state :creating do
              post '/jobs/:id' do
                [409, {}, 'quota exceeded']
              end
            end

            state :ready do
              get '/jobs/job-123' do
                [200, {}, 'ready']
              end
            end
          end
        end
      end

      it 'reports that polling followed a failed creation' do
        failed_create = connection.post('/jobs/job-123')
        expect(failed_create.status).to eq(409)

        expect { connection.get('/jobs/job-123') }.to raise_error(
          described_class::Stubs::ScenarioCreationFailed,
          /creation failed with status 409.*before polling/m
        )
      end

      it 'reports that polling followed a creation exception' do
        stubs.scenario(:broken_job, initial_state: :creating) do
          state :creating do
            post('/broken-jobs') { raise Faraday::ConnectionFailed, 'boom' }
          end

          state :ready do
            get('/broken-jobs/:id') { [200, {}, 'ready'] }
          end
        end

        expect { connection.post('/broken-jobs') }.to raise_error(Faraday::ConnectionFailed, 'boom')

        expect { connection.get('/broken-jobs/job-123') }.to raise_error(
          described_class::Stubs::ScenarioCreationFailed,
          /creation failed with Faraday::ConnectionFailed.*before polling/
        )
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

    it 'removes scenarios and their session state' do
      stubs.scenario(:temporary, initial_state: :new) do
        post('/temporary', to: :ready) { [201, {}, { id: 't1' }] }
        state(:ready) { get('/temporary/:id') { [200, {}, 'ready'] } }
      end

      connection.post('/temporary')
      stubs.clear

      expect(stubs).to be_empty
      expect { connection.get('/temporary/t1') }.to raise_error(described_class::Stubs::NotFound)
    end
  end
end
