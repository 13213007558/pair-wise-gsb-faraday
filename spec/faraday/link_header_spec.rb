# frozen_string_literal: true

RSpec.describe Faraday::LinkHeader do
  it 'parses multiple links without splitting quoted commas or semicolons' do
    header = '</first>; rel="next"; title="one, two; three", </second>; rel="last"; x="a;b"'
    links = described_class.parse(header)

    expect(links.map(&:target)).to eq(%w[/first /second])
    expect(links.first.title).to eq('one, two; three')
    expect(links.last['x']).to eq('a;b')
  end

  it 'preserves duplicate relations and extension parameters' do
    link = described_class.parse('</page>; rel="prev"; rel="next"; x_token="one"; x_token="two"').first

    expect(link.rels).to eq(%w[prev next])
    expect(link.parameters.count { |parameter| parameter.name == 'x_token' }).to eq(2)
    expect(link.extension_parameters.map(&:value)).to eq(%w[one two])
  end

  it 'keeps relative references until a base is supplied' do
    link = described_class.parse('<next/page>; rel="next"').first

    expect(link.target).to eq('next/page')
    expect(link.uri).to be_nil

    resolved = described_class.parse(
      '<next/page>; rel="next"', base: 'http://example.test/api/items'
    ).first
    expect(resolved.uri).to eq(URI('http://example.test/api/next/page'))
  end

  it 'resolves targets through RFC 8288 anchors' do
    link = described_class.parse(
      '<page/2>; rel="next"; anchor="http://other.test/collection/1"',
      base: 'http://example.test/items/1'
    ).first

    expect(link.context).to eq(URI('http://other.test/collection/1'))
    expect(link.uri).to eq(URI('http://other.test/collection/page/2'))
  end

  it 'accepts an array of header field values' do
    links = described_class.parse(['</a>; rel="next"', '</b>; rel="last"'])

    expect(links.map(&:target)).to eq(%w[/a /b])
  end

  it 'raises for malformed headers' do
    expect { described_class.parse('/a; rel="next"') }
      .to raise_error(Faraday::ParsingError)
  end
end
