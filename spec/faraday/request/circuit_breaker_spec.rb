# frozen_string_literal: true

RSpec.describe Faraday::Request::CircuitBreaker do
  class ControlledClock
    attr_accessor :time

    def initialize(time = 0)
      @time = time
    end

    def advance(seconds)
      @time += seconds
    end

    def call
      @time
    end
  end

  class BlockingAdapter < Faraday::Adapter
    def self.instance
      @instance
    end

    attr_reader :arrivals

    def initialize(app = nil, opts = {}, &block)
      super
      self.class.instance_variable_set(:@instance, self)
      @arrivals = []
      @mutex = Mutex.new
      @queues = {}
    end

    def call(env)
      queue = queue_for(env.url.path)
      @mutex.synchronize { @arrivals << env.url.path }
      result = queue.pop
      raise result if result.is_a?(Exception)

      super
      status, headers, body = result
      save_response(env, status, body, headers, nil)
      @app.call(env)
    end

    def queue_for(path)
      @mutex.synchronize { queue(path) }
    end

    private

    def queue(path)
      @queues[path] ||= Queue.new
    end
  end

  let(:clock) { ControlledClock.new }

  def connection(clock:, **options)
    conn = Faraday.new(url: 'http://upstream.test') do |builder|
      builder.request :circuit_breaker, {
        failure_threshold: 2,
        rolling_window: 10,
        cooldown: 5,
        max_probes: 2,
        clock: clock,
        random: -> { 0 }
      }.merge(options)
      builder.adapter BlockingAdapter
    end
    conn.builder.app
    { connection: conn, adapter: BlockingAdapter.instance }
  end

  def respond(adapter, path, response = [200, {}, 'ok'], times: 1)
    queue = adapter.queue_for(path)
    times.times { queue.push(response) }
  end

  def fail(adapter, path, error = Faraday::TimeoutError.new('upstream timeout'), times: 1)
    queue = adapter.queue_for(path)
    times.times { queue.push(error) }
  end

  def wait_for(adapter, count)
    Timeout.timeout(1) do
      sleep 0.001 until adapter.arrivals.size >= count
    end
  end

  def basic_connection(clock:, status: 200, **options)
    Faraday.new(url: 'http://upstream.test') do |builder|
      builder.request :circuit_breaker, {
        failure_threshold: 2,
        rolling_window: 10,
        cooldown: 5,
        clock: clock
      }.merge(options)
      builder.adapter :test do |stub|
        stub.get('/failure') { [status, {}, 'failed'] }
        stub.get('/success') { [200, {}, 'ok'] }
      end
    end
  end

  it 'rejects requests before the adapter once the rolling failure threshold is reached' do
    result = connection(clock: clock)
    conn = result[:connection]
    adapter = result[:adapter]

    Thread.new { fail(adapter, '/first') }
    expect { conn.get('/first') }.to raise_error(Faraday::TimeoutError)
    clock.advance(1)

    Thread.new { fail(adapter, '/second') }
    expect { conn.get('/second') }.to raise_error(Faraday::TimeoutError)

    expect { conn.get('/rejected') }.to raise_error(described_class::CircuitOpenError)
    expect(adapter.arrivals).to eq(%w[/first /second])
  end

  it 'keeps state isolated by explicit service key' do
    clock = ControlledClock.new
    store = described_class::Store.new(
      failure_threshold: 1,
      rolling_window: 10,
      cooldown: 5,
      jitter: 0,
      max_probes: 1,
      clock: clock,
      random: Random.new(1)
    )
    one_result = connection(clock: clock, service_key: 'one', failure_threshold: 1, store: store)
    two_result = connection(clock: clock, service_key: 'two', failure_threshold: 1, store: store)
    one = one_result[:connection]
    two = two_result[:connection]
    one_adapter = one_result[:adapter]
    two_adapter = two_result[:adapter]

    Thread.new { fail(one_adapter, '/one') }
    expect { one.get('/one') }.to raise_error(Faraday::TimeoutError)

    Thread.new { respond(two_adapter, '/two') }
    expect(two.get('/two').body).to eq('ok')
  end

  it 'expires failures outside the rolling window' do
    result = connection(clock: clock)
    conn = result[:connection]
    adapter = result[:adapter]

    Thread.new { fail(adapter, '/old') }
    expect { conn.get('/old') }.to raise_error(Faraday::TimeoutError)
    clock.advance(10)

    Thread.new { fail(adapter, '/new') }
    expect { conn.get('/new') }.to raise_error(Faraday::TimeoutError)

    Thread.new { respond(adapter, '/success') }
    expect(conn.get('/success').body).to eq('ok')
  end

  it 'releases a half-open probe slot when an exception is not classified as failure' do
    local_error = Class.new(StandardError)
    result = connection(
      clock: clock,
      error_classifier: ->(result) { result.is_a?(Faraday::TimeoutError) }
    )
    conn = result[:connection]
    adapter = result[:adapter]

    Thread.new { fail(adapter, '/first') }
    expect { conn.get('/first') }.to raise_error(Faraday::TimeoutError)
    Thread.new { fail(adapter, '/second') }
    expect { conn.get('/second') }.to raise_error(Faraday::TimeoutError)
    clock.advance(5)

    Thread.new { fail(adapter, '/unclassified', local_error.new('bug')) }
    expect { conn.get('/unclassified') }.to raise_error(local_error)

    Thread.new { respond(adapter, '/probe') }
    expect(conn.get('/probe').body).to eq('ok')
    expect(adapter.arrivals).to eq(%w[/first /second /unclassified /probe])
  end

  it 'ignores a stale successful request when a new half-open probe has opened the circuit' do
    result = connection(clock: clock)
    conn = result[:connection]
    adapter = result[:adapter]

    capture_error = lambda do |block|
      begin
        block.call
      rescue StandardError => error
        error
      end
    end

    first = Thread.new { capture_error.call(-> { conn.get('/first') }) }
    second = Thread.new { capture_error.call(-> { conn.get('/second') }) }
    late_success = Thread.new { conn.get('/late-success') }

    wait_for(adapter, 3)
    Thread.new { fail(adapter, '/first') }
    Thread.new { fail(adapter, '/second') }
    expect(first.value).to be_a(Faraday::TimeoutError)
    expect(second.value).to be_a(Faraday::TimeoutError)

    clock.advance(5)
    failing_probe = Thread.new { capture_error.call(-> { conn.get('/failing-probe') }) }
    wait_for(adapter, 4)
    Thread.new { fail(adapter, '/failing-probe') }
    expect(failing_probe.value).to be_a(Faraday::TimeoutError)

    Thread.new { respond(adapter, '/late-success', [200, {}, 'stale']) }
    expect(late_success.value.body).to eq('stale')

    expect { conn.get('/still-blocked') }.to raise_error(described_class::CircuitOpenError)
    clock.advance(5)

    recovered = Thread.new { conn.get('/recovered') }
    wait_for(adapter, 5)
    Thread.new { respond(adapter, '/recovered') }
    expect(recovered.value.body).to eq('ok')
    expect(adapter.arrivals).to eq(%w[/first /second /late-success /failing-probe /recovered])
  end

  it 'classifies configured response statuses as failures' do
    conn = basic_connection(clock: clock, status: 503)

    2.times { expect(conn.get('/failure').status).to eq(503) }

    expect { conn.get('/success') }.to raise_error(described_class::CircuitOpenError)
  end

  it 'uses injected randomness to calculate the cooldown' do
    random = Object.new
    def random.rand(*)
      3
    end
    conn = basic_connection(clock: clock, status: 500, jitter: 4, random: random)

    2.times { expect(conn.get('/failure').status).to eq(500) }
    clock.advance(7)

    expect { conn.get('/success') }.to raise_error(described_class::CircuitOpenError)
    clock.advance(1)

    expect(conn.get('/success').body).to eq('ok')
  end

  it 'releases a probe slot when response classification raises' do
    classifier = lambda do |result|
      raise 'broken classifier' if result.status == 200

      result.status >= 500
    end
    conn = basic_connection(clock: clock, status: 503, error_classifier: classifier)

    2.times { expect(conn.get('/failure').status).to eq(503) }
    clock.advance(5)

    expect { conn.get('/success') }.to raise_error('broken classifier')
    expect { conn.get('/success') }.to raise_error('broken classifier')
  end

  it 'limits concurrent half-open probes and reopens when a probe fails' do
    result = connection(clock: clock, max_probes: 1)
    conn = result[:connection]
    adapter = result[:adapter]

    Thread.new { fail(adapter, '/first') }
    expect { conn.get('/first') }.to raise_error(Faraday::TimeoutError)
    Thread.new { fail(adapter, '/second') }
    expect { conn.get('/second') }.to raise_error(Faraday::TimeoutError)
    clock.advance(5)

    probe = Thread.new do
      begin
        conn.get('/probe')
      rescue StandardError => error
        error
      end
    end
    wait_for(adapter, 3)

    expect { conn.get('/rejected-probe') }.to raise_error(described_class::CircuitOpenError)
    Thread.new { fail(adapter, '/probe') }
    expect(probe.value).to be_a(Faraday::TimeoutError)
    expect { conn.get('/still-open') }.to raise_error(described_class::CircuitOpenError)
    expect(adapter.arrivals).to eq(%w[/first /second /probe])
  end
end
