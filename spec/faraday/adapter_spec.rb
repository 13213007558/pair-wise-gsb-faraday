# frozen_string_literal: true

RSpec.describe Faraday::Adapter do
  let(:adapter) { Faraday::Adapter.new }
  let(:request) { {} }

  context '#request_timeout' do
    it 'gets :read timeout' do
      expect(timeout(:read)).to eq(nil)

      request[:timeout] = 5
      request[:write_timeout] = 1

      expect(timeout(:read)).to eq(5)

      request[:read_timeout] = 2

      expect(timeout(:read)).to eq(2)
    end

    it 'gets :open timeout' do
      expect(timeout(:open)).to eq(nil)

      request[:timeout] = 5
      request[:write_timeout] = 1

      expect(timeout(:open)).to eq(5)

      request[:open_timeout] = 2

      expect(timeout(:open)).to eq(2)
    end

    it 'gets :write timeout' do
      expect(timeout(:write)).to eq(nil)

      request[:timeout] = 5
      request[:read_timeout] = 1

      expect(timeout(:write)).to eq(5)

      request[:write_timeout] = 2

      expect(timeout(:write)).to eq(2)
    end

    it 'attempts unknown timeout type' do
      expect { timeout(:unknown) }.to raise_error(ArgumentError)
    end

    def timeout(type)
      adapter.send(:request_timeout, type, request)
    end
  end

  describe 'informational responses contract' do
    let(:env) do
      Faraday::Env.from(method: :get, url: Faraday::Utils.URI('http://example.com'))
    end

    before do
      env.response = Faraday::Response.new
    end

    it 'does not declare informational response support by default' do
      expect(Faraday::Adapter.supports_informational_responses?).to be(false)
    end

    it 'rejects informational events from a non-capable adapter' do
      expect { adapter.send(:informational_response, env, 103, {}) }
        .to raise_error(Faraday::Error, /does not support informational responses/)
    end

    it 'delivers events in order from a capable adapter with frozen snapshots' do
      capable = Class.new(Faraday::Adapter) do
        self.supports_informational_responses = true
      end.new
      received = []
      env.response.on_information { |info| received << info }

      capable.send(:informational_response, env, 100, {})
      capable.send(:informational_response, env, 103,
                           'Link' => '</a.css>; rel=preload')

      expect(received.map(&:status)).to eq([100, 103])
      expect(received.last['link']).to include('a.css')
      expect(received.last.headers).to be_frozen
    end

    it 'does not affect the final status when the response finishes' do
      capable = Class.new(Faraday::Adapter) do
        self.supports_informational_responses = true
      end.new
      capable.send(:informational_response, env, 103, {})

      env.status = 200
      env.response.finish(env)

      expect(env.response.status).to eq(200)
      expect(env.response.informations.map(&:status)).to eq([103])
    end

    it 'passes the per-request on_information Proc to the response' do
      captured = []
      env.request = Faraday::RequestOptions.new(
        on_information: proc { |info| captured << info.status }
      )
      adapter.send(:register_information_callback, env)
      env.response.information!(100, {})

      expect(captured).to eq([100])
    end

    it 'aborts the response on request cancellation' do
      error = Faraday::ConnectionFailed.new('gone')
      adapter.send(:abort_response, env, error)

      expect(env.response.aborted?).to be(true)
      expect(env.response.abort_error).to equal(error)
      expect { env.response.finish(env) }.to raise_error(Faraday::ConnectionFailed)
    end
  end
end
