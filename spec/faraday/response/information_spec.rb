# frozen_string_literal: true

RSpec.describe Faraday::Response::Information do
  subject do
    described_class.new(103, 'Link' => '</style.css>; rel=preload')
  end

  it { is_expected.to be_frozen }

  it 'exposes the status' do
    expect(subject.status).to eq(103)
  end

  it 'exposes frozen headers' do
    expect(subject.headers).to be_frozen
  end

  it 'looks up headers case-insensitively' do
    expect(subject['LINK']).to include('style.css')
  end

  it 'identifies early hints' do
    expect(subject.early_hints?).to be(true)
    expect(described_class.new(100).early_hints?).to be(false)
  end

  it 'isolates its snapshot from the source hash' do
    source = { 'Link' => 'a' }
    information = described_class.new(103, source)
    source['Link'] = 'b'

    expect(information['link']).to eq('a')
  end

  it 'handles nil headers' do
    information = described_class.new(100)

    expect(information.headers).to be_empty
    expect(information['link']).to be_nil
  end
end
