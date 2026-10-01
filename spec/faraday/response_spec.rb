# frozen_string_literal: true

RSpec.describe Faraday::Response do
  subject { Faraday::Response.new(env) }

  let(:env) do
    Faraday::Env.from(status: 404, body: 'yikes', url: Faraday::Utils.URI('https://lostisland.github.io/faraday'),
                      response_headers: { 'Content-Type' => 'text/plain' })
  end

  it { expect(subject.finished?).to be_truthy }
  it { expect { subject.finish({}) }.to raise_error(RuntimeError) }
  it { expect(subject.success?).to be_falsey }
  it { expect(subject.status).to eq(404) }
  it { expect(subject.body).to eq('yikes') }
  it { expect(subject.url).to eq(URI('https://lostisland.github.io/faraday')) }
  it { expect(subject.headers['Content-Type']).to eq('text/plain') }
  it { expect(subject['content-type']).to eq('text/plain') }

  describe '#apply_request' do
    before { subject.apply_request(body: 'a=b', method: :post) }

    it { expect(subject.body).to eq('yikes') }
    it { expect(subject.env[:method]).to eq(:post) }
  end

  describe '#to_hash' do
    let(:hash) { subject.to_hash }

    it { expect(hash).to be_a(Hash) }
    it { expect(hash[:status]).to eq(subject.status) }
    it { expect(hash[:response_headers]).to eq(subject.headers) }
    it { expect(hash[:body]).to eq(subject.body) }
    it { expect(hash[:url]).to eq(subject.env.url) }

    context 'when response is not finished' do
      subject { Faraday::Response.new.to_hash }

      it { is_expected.to eq({ status: nil, body: nil, response_headers: {}, url: nil }) }
    end
  end

  describe 'marshal serialization support' do
    subject { Faraday::Response.new }
    let(:loaded) { Marshal.load(Marshal.dump(subject)) }

    before do
      subject.on_complete {}
      subject.finish(env.merge(params: 'moo'))
    end

    it { expect(loaded.env[:params]).to be_nil }
    it { expect(loaded.env[:body]).to eq(env[:body]) }
    it { expect(loaded.env[:response_headers]).to eq(env[:response_headers]) }
    it { expect(loaded.env[:status]).to eq(env[:status]) }
    it { expect(loaded.env[:url]).to eq(env[:url]) }
  end

  describe '#on_complete' do
    subject { Faraday::Response.new }

    it 'parse body on finish' do
      subject.on_complete { |env| env[:body] = env[:body].upcase }
      subject.finish(env)

      expect(subject.body).to eq('YIKES')
    end

    it 'can access response body in on_complete callback' do
      subject.on_complete { |env| env[:body] = subject.body.upcase }
      subject.finish(env)

      expect(subject.body).to eq('YIKES')
    end

    it 'can access response body in on_complete callback' do
      callback_env = nil
      subject.on_complete { |env| callback_env = env }
      subject.finish({})

      expect(subject.env).to eq(callback_env)
    end
  end

  describe 'informational responses' do
    subject { Faraday::Response.new }

    it 'delivers 1xx snapshots to subscribers in arrival order' do
      received = []
      subject.on_information { |info| received << info }

      subject.information!(100, {})
      subject.information!(103, 'Link' => '</a.css>; rel=preload')

      expect(received.map(&:status)).to eq([100, 103])
      expect(subject.informations.map(&:status)).to eq([100, 103])
    end

    it 'replays existing snapshots to new subscribers while in flight' do
      subject.information!(100, {})
      subject.information!(103, {})
      replayed = []

      subject.on_information { |info| replayed << info.status }

      expect(replayed).to eq([100, 103])
    end

    it 'returns independent snapshots arrays' do
      subject.information!(100, {})
      first = subject.informations
      first << :tampered

      expect(subject.informations.map(&:status)).to eq([100])
    end

    it 'requires a block' do
      expect { subject.on_information }.to raise_error(ArgumentError)
    end

    it 'rejects invalid status codes' do
      expect { subject.information!(200, {}) }
        .to raise_error(ArgumentError, /100-199/)
      expect { subject.information!(99, {}) }
        .to raise_error(ArgumentError, /100-199/)
    end

    it 'rejects late informational events after finish' do
      subject.finish(env)

      expect { subject.information!(103, {}) }
        .to raise_error(Faraday::Response::LateInformationError)
    end

    it 'does not invoke on_complete on informational events' do
      completed = false
      subject.on_complete { completed = true }

      subject.information!(103, {})

      expect(completed).to be(false)
      expect(subject.finished?).to be(false)
    end

    it 'does not accept new informational subscribers after finish' do
      subject.finish(env)
      delivered = []

      result = subject.on_information { |info| delivered << info }

      expect(result).to equal(subject)
      expect(delivered).to be_empty
    end

    it 'aborts with a callback error and rejects further events' do
      subject.on_information { raise 'boom' }

      expect { subject.information!(103, {}) }.to raise_error(RuntimeError, 'boom')
      expect(subject.aborted?).to be(true)
      expect(subject.abort_error.message).to eq('boom')
      expect(subject.finished?).to be(false)
      expect { subject.information!(100, {}) }
        .to raise_error(Faraday::Response::LateInformationError)
      expect { subject.finish(env) }.to raise_error(RuntimeError, 'boom')
      expect { subject.on_complete { } }.to raise_error(RuntimeError, 'boom')
    end

    it 'supports explicit cancellation with a clear end state' do
      subject.information!(100, {})
      error = Faraday::ConnectionFailed.new('cancelled')

      result = subject.abort(error)

      expect(result).to equal(error)
      expect(subject.aborted?).to be(true)
      expect(subject.abort_error).to equal(error)
      expect(subject.informations.map(&:status)).to eq([100])
      expect { subject.on_information { } }
        .to raise_error(Faraday::ConnectionFailed, 'cancelled')
    end

    it 'keeps abort idempotent' do
      first = subject.abort('one')
      second = subject.abort('two')

      expect(second).to equal(first)
      expect(subject.abort_error.message).to eq('one')
    end
  end
end
