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

  describe Faraday::InformationalResponse do
    subject(:information) { described_class.new(103, link_headers) }

    let(:link_headers) { { 'Link' => String.new('</style.css>; rel=preload') } }

    it 'keeps an immutable header snapshot' do
      expect(information.status).to eq(103)
      expect(information.headers).to be_frozen
      expect(information['LINK']).to eq('</style.css>; rel=preload')
      expect { information.headers['Link'] = 'changed' }.to raise_error(FrozenError)
    end

    it 'does not share later header changes' do
      information
      link_headers['Link'] = link_headers['Link'] + ', </script.js>'

      expect(information.headers['Link']).to eq('</style.css>; rel=preload')
    end

    it 'rejects non-informational statuses' do
      expect { described_class.new(200) }.to raise_error(ArgumentError)
    end
  end

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

  describe '#on_information' do
    subject(:response) { described_class.new }

    it 'delivers informational responses in registration order' do
      events = []
      response.on_information { |event| events << [:first, event.status] }
      response.on_information { |event| events << [:second, event.status] }

      response.information!(100)
      response.information!(103, { 'Link' => '</a>' })

      expect(events).to eq([[:first, 100], [:second, 100], [:first, 103], [:second, 103]])
    end

    it 'supports the short registration alias' do
      events = []
      response.on_information { |event| events << event.status }
      response.information!(100)

      expect(events).to eq([100])
    end

    it 'stops callbacks when a callback cancels the request' do
      events = []
      response.on_information { |event| events << event.status; response.cancel }
      response.on_information { |_| raise 'must not run' }

      expect { response.information!(103) }.to raise_error(Faraday::RequestCanceled)
      expect(response).to be_canceled
      expect(events).to eq([103])
    end

    it 'does not register callbacks after completion' do
      response.finish(env)

      expect { response.on_information { raise 'must not run' } }.not_to raise_error
      expect { response.information!(103) }.to raise_error(Faraday::LateInformationResponseError)
    end

    it 'marks the response failed when a callback raises' do
      error = StandardError.new('boom')
      response.on_information { raise error }

      expect { response.information!(103) }.to raise_error(error)
      expect(response).to be_failed
      expect(response.error).to eq(error)
      expect { response.information!(103) }.to raise_error(Faraday::LateInformationResponseError)
    end

    it 'supports explicit cancellation' do
      response.cancel

      expect(response).to be_canceled
      expect(response).to be_closed
      expect(response).not_to be_finished
      expect { response.finish(env) }.to raise_error(RuntimeError, 'response already closed')
      expect { response.information!(103) }.to raise_error(Faraday::LateInformationResponseError)
    end
  end
end
