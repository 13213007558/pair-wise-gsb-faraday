# frozen_string_literal: true

RSpec.describe Faraday::Link do
  let(:base) { URI('http://example.com/api/items/') }

  it 'parses comma-separated links, repeated relations, and extension parameters' do
    links = described_class.parse(
      '<2?cursor=1,2>; rel="next collection"; title="a,b"; data-extra="x,y"; data-extra=z; rel="more", ' +
      '</items/3>; rel="next"; anchor="/catalog"; hreflang=en; hreflang="fr"; x-token="abc"',
      base: base
    )

    expect(links.size).to eq(2)
    expect(links.first.relations).to eq(%w[next collection more])
    expect(links.first.target_uri.to_s).to eq('http://example.com/api/items/2?cursor=1,2')
    expect(links.first.title).to eq('a,b')
    expect(links.first['data-extra']).to eq('x,y')
    expect(links.first.extension_parameters).to eq(
      'data-extra' => ['x,y', 'z']
    )
    expect(links.last.relations).to eq(['next'])
    expect(links.last.anchor).to eq('/catalog')
    expect(links.last.context_uri.to_s).to eq('http://example.com/catalog')
    expect(links.last.target_uri.to_s).to eq('http://example.com/items/3')
    expect(links.last.hreflang).to eq(%w[en fr])
    expect(links.last['x-token']).to eq('abc')
  end

  it 'preserves a duplicate relation as a separate link' do
    links = described_class.parse('<./a>; rel=next, <./b>; rel=next', base: base)

    expect(links.map { |link| link.target_uri.to_s }).to eq(
      %w[http://example.com/api/items/a http://example.com/api/items/b]
    )
  end

  it 'resolves an empty reference to the anchor context' do
    links = described_class.parse('<>; rel=up; anchor="/catalog?x=1"', base: base)

    expect(links.first.target_uri.to_s).to eq('http://example.com/catalog?x=1')
  end

  it 'raises ParsingError for malformed values' do
    expect { described_class.parse('broken', base: base) }
      .to raise_error(Faraday::ParsingError)
  end
end
