# frozen_string_literal: true

RSpec.describe Faraday::Request::CircuitBreaker do
  class ControlledClock
    attr_reader :now

    def initialize(now = 0)
      @now = now
      @mutex = Mutex.new
    end

    def advance(seconds)
      @mutex.synchronize { @now += seconds }
    end
  end

  class DeterministicRandom
    def initialize(value)
      @value = value
    end

    def rand(_range)
      @value
    end
  end

  class ScriptedAdapter < Faraday::Adapter
    def initialize(app, script:, started: nil, upstream_calls: nil)
      super(app)
      @script = script
      @started = started
      @upstream_calls = upstream_calls
      @mutex = Mutex.new
    end

    def call(env)
      super

      action = @script.pop
      @mutex.synchronize { @upstream_calls&.push(action.fetch(:id, action[:status])) }
      @started&.push(action[:id]) if action[:started]

      if (release = action[:wait_on])
        action = release.pop
      end

      raise action[:error], 'scripted adapter failure' if action[:error]

      save_response(env, action[:status], action.fetch(:body, 'ok'), action.fetch(:headers, {}), nil)
      @app.call(env)
    end
  end

  def connection(options = {}, &stubs)
    Faraday.new do |f|
      f.request :circuit_breaker, **options
      f.adapter :test, &stubs
    end
  end

  it 'trips after enough failures in the rolling window and rejects adapter calls while open' do
    requests = 0
    conn = connection(
      service_key: 'example.com',
      failure_threshold: 2,
      rolling_window: 10
    ) do |stub|
      stub.get('/') { requests += 1; [500, {}, 'fail'] }
    end

    2.times { conn.get('/') }

    expect { conn.get('/') }.to raise_error(
      Faraday::CircuitBreakerOpenError,
      'circuit breaker is open for example.com'
    ) do |error|
      expect(error.service_key).to eq('example.com')
      expect(error.state).to eq(:open)
    end
    expect(requests).to eq(2)
  end

  it 'trips on upstream timeout exceptions without sending rejected requests downstream' do
    requests = 0
    conn = connection(service_key: 'example.com', failure_threshold: 1) do |stub|
      stub.get('/timeout') do
        requests += 1
        raise Faraday::TimeoutError
      end
    end

    expect { conn.get('/timeout') }.to raise_error(Faraday::TimeoutError)
    expect { conn.get('/timeout') }.to raise_error(Faraday::CircuitBreakerOpenError)
    expect(requests).to eq(1)
  end

  it 'expires failures at the rolling window boundary' do
    clock = ControlledClock.new
    requests = Queue.new
    conn = connection(
      service_key: 'example.com',
      failure_threshold: 2,
      rolling_window: 10,
      clock: clock
    ) do |stub|
      stub.get('/') do
        requests << 1
        [500, {}, 'fail']
      end
    end

    conn.get('/')
    clock.advance(10)
    conn.get('/')
    clock.advance(1)
    conn.get('/')

    expect(requests.size).to eq(3)
  end

  it 'allows only the configured number of concurrent probes after cooldown' do
    clock = ControlledClock.new
    script = Queue.new
    started = Queue.new
    probe_release = Queue.new
    upstream_calls = Queue.new
    store = described_class::Store.new
    conn = Faraday.new do |f|
      f.request :circuit_breaker,
                service_key: 'example.com',
                failure_threshold: 1,
                cooldown: 10,
                max_probe_requests: 1,
                clock: clock,
                store: store
      f.adapter ScriptedAdapter, script: script, started: started, upstream_calls: upstream_calls
    end

    script << { id: :initial_failure, status: 500, body: 'fail' }
    conn.get('/failed')
    expect(store.state_for('example.com')).to eq(:open)

    clock.advance(10)
    script << { id: :probe, started: true, wait_on: probe_release }
    probe = Thread.new { conn.get('/probe') }
    expect(started.pop).to eq(:probe)
    expect(store.state_for('example.com')).to eq(:half_open)

    expect { conn.get('/rejected') }.to raise_error(Faraday::CircuitBreakerOpenError) do |error|
      expect(error.state).to eq(:half_open)
    end

    probe_release << { status: 200, body: 'recovered' }
    expect(probe.value.body).to eq('recovered')
    expect(store.state_for('example.com')).to eq(:closed)
  end

  it 'releases a probe slot when the adapter raises a non-failure exception' do
    clock = ControlledClock.new
    store = described_class::Store.new
    script = Queue.new
    upstream_calls = Queue.new
    conn = Faraday.new do |f|
      f.request :circuit_breaker,
                service_key: 'example.com',
                failure_threshold: 1,
                cooldown: 10,
                clock: clock,
                store: store
      f.adapter ScriptedAdapter, script: script, upstream_calls: upstream_calls
    end

    script << { id: :failed, status: 500, body: 'fail' }
    conn.get('/failed')
    clock.advance(10)

    script << { id: :ignored, error: RuntimeError }
    expect { conn.get('/ignored') }.to raise_error(RuntimeError)
    expect(store.state_for('example.com')).to eq(:half_open)
    script << { id: :recovered, status: 200, body: 'recovered' }
    expect(conn.get('/recovered').body).to eq('recovered')
    expect(upstream_calls.size).to eq(3)
  end

  it 'isolates state by service key' do
    store = described_class::Store.new
    conn = connection(
      service_key: ->(env) { env.url.path },
      failure_threshold: 1,
      store: store
    ) do |stub|
      stub.get('/a') { [500, {}, 'fail'] }
      stub.get('/b') { [200, {}, 'ok'] }
    end

    conn.get('/a')

    expect(conn.get('/b').body).to eq('ok')
    expect(store.state_for('/a')).to eq(:open)
    expect(store.state_for('/b')).to eq(:closed)
  end

  it 'supports injected jitter and custom failure classification' do
    clock = ControlledClock.new
    requests = Queue.new
    conn = connection(
      service_key: 'example.com',
      failure_threshold: 1,
      cooldown: 10,
      cooldown_jitter: 0..5,
      clock: clock,
      random: DeterministicRandom.new(5),
      failure_statuses: [429]
    ) do |stub|
      stub.get('/') do
        requests << 1
        [429, {}, 'rate limited']
      end
    end

    conn.get('/')
    clock.advance(14)
    expect { conn.get('/') }.to raise_error(Faraday::CircuitBreakerOpenError)

    clock.advance(1)
    expect(conn.get('/').status).to eq(429)
    expect(requests.size).to eq(2)
  end

  it 'ignores a stale success from an old generation after a probe failure, then recovers upstream' do
    clock = ControlledClock.new
    script = Queue.new
    started = Queue.new
    old_request_release = Queue.new
    upstream_calls = Queue.new
    store = described_class::Store.new
    conn = Faraday.new do |f|
      f.request :circuit_breaker,
                service_key: 'example.com',
                failure_threshold: 2,
                rolling_window: 100,
                cooldown: 10,
                clock: clock,
                store: store
      f.adapter ScriptedAdapter, script: script, started: started, upstream_calls: upstream_calls
    end

    script << { id: :first_failure, status: 500, body: 'fail' }
    conn.get('/first-failure')

    script << { id: :old_request, started: true, wait_on: old_request_release }
    old_request = Thread.new { conn.get('/old-request') }
    expect(started.pop).to eq(:old_request)

    script << { id: :second_failure, status: 500, body: 'fail' }
    conn.get('/second-failure')
    expect(store.state_for('example.com')).to eq(:open)

    clock.advance(10)
    script << { id: :failed_probe, status: 500, body: 'fail' }
    conn.get('/failed-probe')
    expect(store.state_for('example.com')).to eq(:open)

    old_request_release << { id: :late_success, status: 200, body: 'late' }
    expect(old_request.value.body).to eq('late')
    expect(store.state_for('example.com')).to eq(:open)

    expect { conn.get('/rejected') }.to raise_error(Faraday::CircuitBreakerOpenError)

    clock.advance(10)
    script << { id: :recovery, status: 200, body: 'recovered' }
    response = conn.get('/recovery')

    expect(response.body).to eq('recovered')
    expect(store.state_for('example.com')).to eq(:closed)
    expect(upstream_calls.size).to eq(5)
    observed_calls = Array.new(upstream_calls.size) { upstream_calls.pop }
    expect(observed_calls).to eq(%i[first_failure old_request second_failure failed_probe recovery])
  end
end
