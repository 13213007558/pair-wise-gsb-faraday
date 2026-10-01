# frozen_string_literal: true

RSpec.describe Faraday::Adapter do
  let(:adapter) { Faraday::Adapter.new }
  let(:request) { {} }

  describe 'informational response capability' do
    it 'defaults to unsupported' do
      expect(described_class).not_to be_supports_informational_responses
    end

    it 'propagates an opt-in capability to subclasses' do
      supported = Class.new(described_class) do
        self.supports_informational_responses = true
      end
      unsupported = Class.new(described_class)

      expect(supported).to be_supports_informational_responses
      expect(unsupported).not_to be_supports_informational_responses
      expect(Faraday::Adapter::Test).to be_supports_informational_responses
    end
  end

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
end
