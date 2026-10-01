# frozen_string_literal: true

RSpec.describe Faraday::Request::Hedging do
  # A controlled adapter that plays back scripted responses (or errors) in
  # order of arrival. Scripts can block on queues, so tests orchestrate
  # timing explicitly instead of relying on real network speed.
  class ScriptedAdapter < Faraday::Adapter
    def initialize(app = nil, opts = {}, &block)
      super
      @scripts = opts.fetch(:scripts)
      @calls = opts.fetch(:calls)
      @mutex = Mutex.new
    end

    def call(env)
      super
      script = @mutex.synchronize do
        @calls << env
        @scripts[@calls.size - 1] || @scripts.last
      end
      status, headers, body = script.call(env)
      save_response(env, status, body, headers)
    end
  end

  let(:threshold) { 0.05 }
  let(:hedging_options) { { threshold: threshold, max_copies: 2 } }
  let(:calls) { [] }
  let(:conn) do
    Faraday.new do |f|
      f.request :hedging, hedging_options
      f.adapter ScriptedAdapter, scripts: scripts, calls: calls
    end
  end

  it 'has safe defaults' do
    defaults = described_class.default_options
    expect(defaults[:threshold]).to eq(0.5)
    expect(defaults[:max_copies]).to eq(2)
    expect(defaults[:deadline]).to be_nil
    expect(defaults[:methods]).to include(:get, :head, :put, :delete)
    expect(defaults[:methods]).not_to include(:post, :patch)
  end

  it 'validates its options' do
    expect { described_class.new(nil, threshold: 0) }.to raise_error(ArgumentError, /threshold/)
    expect { described_class.new(nil, max_copies: 0) }.to raise_error(ArgumentError, /max_copies/)
    expect { described_class.new(nil, deadline: -1) }.to raise_error(ArgumentError, /deadline/)
  end

  context 'when the first copy is fast enough' do
    let(:threshold) { 60 }
    let(:scripts) { [->(_env) { [200, {}, 'fast'] }] }

    it 'returns it without launching another copy' do
      expect(conn.get('/').body).to eq('fast')
      expect(calls.size).to eq(1)
    end
  end

  context 'when the first copy completes exactly as the threshold is reached' do
    let(:hedge_started) { Queue.new }
    let(:release_second) { Queue.new }
    let(:second_finished) { Queue.new }
    let(:scripts) do
      [
        # The first copy only completes once the hedge timer has fired and
        # the second copy has started, i.e. exactly at the threshold.
        lambda do |_env|
          hedge_started.pop
          [200, {}, 'first']
        end,
        lambda do |_env|
          hedge_started << true
          release_second.pop
          second_finished << true
          [200, {}, 'second']
        end
      ]
    end

    it 'returns a single result and never leaks the losing copy' do
      response = conn.get('/')
      expect(response.body).to eq('first')
      expect(calls.size).to eq(2)

      # The adapter does not support cancellation, so the loser finishes
      # naturally; its body must not leak into or overwrite the winner.
      release_second << true
      second_finished.pop
      expect(response.body).to eq('first')
      expect(response.status).to eq(200)
    end
  end

  context 'when the hedged copy wins the race' do
    let(:release_first) { Queue.new }
    let(:first_finished) { Queue.new }
    let(:scripts) do
      [
        lambda do |_env|
          release_first.pop
          first_finished << true
          [200, {}, 'slow']
        end,
        ->(_env) { [200, {}, 'hedged'] }
      ]
    end

    it 'returns the hedged response as the single result' do
      response = conn.get('/')
      expect(response.body).to eq('hedged')
      expect(calls.size).to eq(2)

      release_first << true
      first_finished.pop
      expect(response.body).to eq('hedged')
    end
  end

  context 'when both copies fail' do
    let(:scripts) do
      [
        ->(_env) { raise Faraday::ConnectionFailed, 'first boom' },
        ->(_env) { raise Faraday::ConnectionFailed, 'second boom' }
      ]
    end

    it 'raises the first error only' do
      expect { conn.get('/') }.to raise_error(Faraday::ConnectionFailed, 'first boom')
      expect(calls.size).to eq(2)
    end
  end

  context 'when the first copy does not satisfy the success policy' do
    let(:scripts) do
      [
        ->(_env) { [500, {}, 'server error'] },
        ->(_env) { [200, {}, 'recovered'] }
      ]
    end

    it 'keeps racing until a copy satisfies the policy' do
      expect(conn.get('/').body).to eq('recovered')
      expect(calls.size).to eq(2)
    end
  end

  context 'with a custom success policy' do
    let(:hedging_options) do
      { threshold: threshold, max_copies: 2, success_policy: ->(env) { env.status == 201 } }
    end
    let(:scripts) do
      [
        ->(_env) { [200, {}, 'ok'] },
        ->(_env) { [201, {}, 'created'] }
      ]
    end

    it 'waits for a response matching the policy' do
      expect(conn.get('/').body).to eq('created')
      expect(calls.size).to eq(2)
    end
  end

  context 'when a losing copy fails after the winner was chosen' do
    let(:hedge_started) { Queue.new }
    let(:release_second) { Queue.new }
    let(:second_finished) { Queue.new }
    let(:scripts) do
      [
        lambda do |_env|
          hedge_started.pop
          [200, {}, 'winner']
        end,
        lambda do |_env|
          hedge_started << true
          release_second.pop
          second_finished << true
          raise Faraday::ConnectionFailed, 'loser boom'
        end
      ]
    end

    it 'does not leak the loser error into the winning result' do
      response = conn.get('/')
      expect(response.body).to eq('winner')

      release_second << true
      second_finished.pop
      expect(response.body).to eq('winner')
      expect(response.status).to eq(200)
    end
  end

  context 'when the overall deadline is exceeded' do
    let(:hedging_options) { { threshold: 0.05, max_copies: 2, deadline: 0.1 } }
    let(:release) { Queue.new }
    let(:finished) { Queue.new }
    let(:scripts) do
      blocking = lambda do |_env|
        release.pop
        finished << true
        [200, {}, 'late']
      end
      [blocking, blocking]
    end

    it 'raises Faraday::TimeoutError and lets losers finish naturally' do
      expect { conn.get('/') }.to raise_error(Faraday::TimeoutError, /deadline/)
      expect(calls.size).to eq(2)

      2.times { release << true }
      2.times { finished.pop }
    end
  end

  context 'with a non-idempotent method' do
    let(:threshold) { 0.01 }
    let(:scripts) do
      [lambda do |_env|
        sleep 0.2
        [200, {}, 'posted']
      end]
    end

    it 'sends the request only once' do
      expect(conn.post('/', 'a=1').body).to eq('posted')
      expect(calls.size).to eq(1)
    end
  end

  context 'with a body that cannot be replayed independently' do
    let(:threshold) { 0.01 }
    let(:scripts) do
      [lambda do |_env|
        sleep 0.2
        [200, {}, 'ok']
      end]
    end

    it 'sends the request only once' do
      response = conn.get('/') { |req| req.body = StringIO.new('stream') }
      expect(response.body).to eq('ok')
      expect(calls.size).to eq(1)
    end
  end
end
