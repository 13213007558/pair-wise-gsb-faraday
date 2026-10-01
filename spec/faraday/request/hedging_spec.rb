# frozen_string_literal: true

# An adapter whose responses are fully controlled by the test: every call
# blocks until the test releases an action through #release, so specs never
# depend on real network speed or wall-clock timing.
class HedgingControlledAdapter < Faraday::Adapter
  def initialize(*)
    super
    @mutex = Mutex.new
    @envs = []
    @called = Queue.new
    @gate = Queue.new
    @finished = Queue.new
  end

  def call(env)
    super
    @mutex.synchronize { @envs << env }
    @called << true
    action = @gate.pop
    result = case action.first
             when :respond
               save_response(env, action[1], action[2], action[3] || {})
             when :raise
               raise action[1]
             end
    @finished << true
    result
  end

  def calls
    @mutex.synchronize { @envs.size }
  end

  def envs
    @mutex.synchronize { @envs.dup }
  end

  def wait_until_called
    @called.pop
  end

  def wait_until_finished
    @finished.pop
  end

  def release(action)
    @gate << action
  end
end

# A timer controlled by the test: each scheduled wait blocks until the test
# releases that specific delay, making hedge/deadline firing deterministic.
class HedgingControlledSleeper
  def initialize
    @armed = Hash.new { |hash, key| hash[key] = Queue.new }
    @released = Hash.new { |hash, key| hash[key] = Queue.new }
  end

  def call(seconds)
    @armed[seconds] << true
    @released[seconds].pop
  end

  def wait_until_armed(seconds)
    @armed[seconds].pop
  end

  def release(seconds)
    @released[seconds] << true
  end
end

RSpec.describe Faraday::Request::Hedging do
  let(:adapter_one) { HedgingControlledAdapter.new }
  let(:adapter_two) { HedgingControlledAdapter.new }
  let(:sleeper) { HedgingControlledSleeper.new }

  let(:router) do
    one = adapter_one
    two = adapter_two
    lambda do |env|
      case env.url.host
      when 'one.test' then one.call(env)
      when 'two.test' then two.call(env)
      else raise "unexpected host: #{env.url.host}"
      end
    end
  end

  let(:delay) { 30 }
  let(:deadline) { nil }
  let(:extra_options) { {} }
  let(:middleware) do
    described_class.new(router, { delay: delay, max_copies: 2, deadline: deadline,
                                  targets: ['http://two.test'], sleeper: sleeper }.merge(extra_options))
  end

  let(:env) { build_env(:get, 'http://one.test/resource') }

  def build_env(method, url, body = nil)
    Faraday::Env.from(
      method: method,
      url: Faraday::Utils.URI(url),
      request_body: body,
      request: Faraday::RequestOptions.new,
      request_headers: Faraday::Utils::Headers.new,
      response_headers: Faraday::Utils::Headers.new,
      ssl: Faraday::SSLOptions.new
    )
  end

  def run_hedged(env)
    Thread.new { middleware.call(env) }.tap do |worker|
      worker.report_on_exception = false
    end
  end

  def await(worker)
    raise 'hedged request did not return in time' unless worker.join(10)

    worker.value
  end

  describe 'options' do
    it 'defaults to safe methods, two copies and no deadline' do
      default = described_class.new(->(env) { env })
      expect(default.options[:methods]).to eq(%i[get head options])
      expect(default.options[:max_copies]).to eq(2)
      expect(default.options[:deadline]).to be_nil
      expect(default.options[:delay]).to be_positive
    end

    it 'validates its options' do
      expect { described_class.new(nil, delay: 0) }.to raise_error(ArgumentError, /delay/)
      expect { described_class.new(nil, max_copies: 0) }.to raise_error(ArgumentError, /max_copies/)
      expect { described_class.new(nil, deadline: -1) }.to raise_error(ArgumentError, /deadline/)
    end
  end

  describe 'method safety' do
    it 'rejects methods that are not safely repeatable' do
      post_env = build_env(:post, 'http://one.test/resource', 'payload')
      expect { middleware.call(post_env) }
        .to raise_error(Faraday::Error, /safely repeatable/)
      expect(adapter_one.calls).to eq(0)
      expect(adapter_two.calls).to eq(0)
    end

    context 'when the method is explicitly allowed' do
      let(:extra_options) { { methods: %i[get post] } }

      it 'replays the entity independently for every copy' do
        post_env = build_env(:post, 'http://one.test/resource', 'payload')
        worker = run_hedged(post_env)
        adapter_one.wait_until_called
        sleeper.wait_until_armed(delay)
        sleeper.release(delay)
        adapter_two.wait_until_called
        adapter_two.release([:respond, 201, 'created'])

        response = await(worker)
        expect(response.status).to eq(201)

        bodies = [adapter_one, adapter_two].map { |adapter| adapter.envs.first.request_body }
        expect(bodies).to eq(%w[payload payload])
        expect(bodies.first).not_to equal(bodies.last)
      ensure
        adapter_one.release([:respond, 201, 'late'])
      end
    end
  end

  describe 'entity replayability' do
    it 'rejects a body that cannot be replayed independently' do
      env_with_body = build_env(:get, 'http://one.test/resource', Object.new)
      expect { middleware.call(env_with_body) }
        .to raise_error(Faraday::Error, /cannot be replayed/)
      expect(adapter_one.calls).to eq(0)
    end

    it 'materializes a rewindable body once and replays it' do
      env_with_io = build_env(:get, 'http://one.test/resource', StringIO.new('stream-body'))
      worker = run_hedged(env_with_io)
      adapter_one.wait_until_called
      adapter_one.release([:respond, 200, 'ok'])

      expect(await(worker).body).to eq('ok')
      expect(adapter_one.envs.first.request_body).to eq('stream-body')
    ensure
      sleeper.release(delay)
    end
  end

  describe 'racing' do
    it 'returns the first response without duplicating when it arrives as the threshold is reached' do
      worker = run_hedged(env)
      adapter_one.wait_until_called
      sleeper.wait_until_armed(delay)

      # The first copy completes exactly when the threshold is reached:
      # the hedge timer has not fired yet, so no duplicate is sent.
      adapter_one.release([:respond, 200, 'from-one'])

      response = await(worker)
      expect(response.status).to eq(200)
      expect(response.body).to eq('from-one')
      expect(adapter_one.calls).to eq(1)
      expect(adapter_two.calls).to eq(0)
    ensure
      sleeper.release(delay)
    end

    it 'duplicates the request to the second target once the threshold is exceeded' do
      worker = run_hedged(env)
      adapter_one.wait_until_called
      sleeper.wait_until_armed(delay)
      sleeper.release(delay)

      adapter_two.wait_until_called
      expect(adapter_two.envs.first.url.host).to eq('two.test')

      adapter_two.release([:respond, 200, 'from-two'])
      response = await(worker)
      expect(response.body).to eq('from-two')
      expect(response.env.url.host).to eq('two.test')

      # The loser is left to finish naturally; its body must not leak
      # into, or overwrite, the winning response.
      adapter_one.release([:respond, 200, 'late-from-one'])
      adapter_one.wait_until_finished
      expect(response.body).to eq('from-two')
      expect(response.env.response_body).to eq('from-two')
    end

    it 'does not let a loser error leak into the winning response' do
      worker = run_hedged(env)
      adapter_one.wait_until_called
      sleeper.wait_until_armed(delay)
      sleeper.release(delay)

      adapter_two.wait_until_called
      adapter_two.release([:respond, 200, 'from-two'])
      response = await(worker)

      adapter_one.release([:raise, Faraday::ConnectionFailed.new('loser boom')])
      expect(response.status).to eq(200)
      expect(response.body).to eq('from-two')
    end

    it 'keeps waiting when the first response does not satisfy the success policy' do
      worker = run_hedged(env)
      adapter_one.wait_until_called
      sleeper.wait_until_armed(delay)
      sleeper.release(delay)

      adapter_two.wait_until_called
      adapter_one.release([:respond, 500, 'broken'])
      adapter_two.release([:respond, 200, 'healthy'])

      response = await(worker)
      expect(response.status).to eq(200)
      expect(response.body).to eq('healthy')
    end

    it 'surfaces a single failure when every copy fails' do
      worker = run_hedged(env)
      adapter_one.wait_until_called
      sleeper.wait_until_armed(delay)
      sleeper.release(delay)

      adapter_two.wait_until_called
      adapter_one.release([:raise, Faraday::ConnectionFailed.new('boom-one')])
      adapter_two.release([:raise, Faraday::ConnectionFailed.new('boom-two')])

      expect { await(worker) }.to raise_error(Faraday::ConnectionFailed, /boom/)
      expect(adapter_one.calls).to eq(1)
      expect(adapter_two.calls).to eq(1)
    end
  end

  describe 'overall deadline' do
    let(:deadline) { 60 }

    it 'raises a timeout error when the deadline expires' do
      worker = run_hedged(env)
      adapter_one.wait_until_called
      sleeper.wait_until_armed(delay)
      sleeper.wait_until_armed(deadline)
      sleeper.release(delay)
      adapter_two.wait_until_called

      sleeper.release(deadline)
      expect { await(worker) }.to raise_error(Faraday::TimeoutError, /60/)
    ensure
      adapter_one.release([:respond, 200, 'late-one'])
      adapter_two.release([:respond, 200, 'late-two'])
    end
  end
end
