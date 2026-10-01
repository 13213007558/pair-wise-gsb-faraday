# frozen_string_literal: true

RSpec.describe Faraday::Pagination do
  def connection(stubs)
    Faraday.new('http://example.test') do |builder|
      builder.adapter(:test, stubs)
    end
  end

  it 'follows quoted, relative next links lazily and requests expected URLs' do
    requests = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/pages/1') do |env|
        requests << env.url.to_s
        [200, { 'Link' => '</pages/2>; rel="next"; title="one, two"; x="a;b"' }, '1']
      end
      stub.get('/pages/2') do |env|
        requests << env.url.to_s
        [200, {}, '2']
      end
    end

    pages = connection(stubs).paginate('/pages/1')

    expect(requests).to be_empty
    collected_pages = pages.to_a
    first_page = collected_pages.first
    expect(first_page.links.first.title).to eq('one, two')
    expect(first_page.links.first['x']).to eq('a;b')
    expect(collected_pages.map(&:body)).to eq(%w[1 2])
    expect(requests).to eq(%w[
      http://example.test/pages/1
      http://example.test/pages/2
    ])
  end

  it 'stops before requesting another page when the consumer stops' do
    requests = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/pages/1') do |env|
        requests << env.url.to_s
        [200, { 'Link' => '</pages/2>; rel="next"' }, '1']
      end
      stub.get('/pages/2') do |env|
        requests << env.url.to_s
        [200, {}, '2']
      end
    end

    body = connection(stubs).paginate('/pages/1').first.body

    expect(body).to eq('1')
    expect(requests).to eq(['http://example.test/pages/1'])
  end

  it 'detects a two-page cycle after requesting both pages once' do
    requests = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/pages/1') do |env|
        requests << env.url.to_s
        [200, { 'Link' => '</pages/2>; rel="next"' }, '1']
      end
      stub.get('/pages/2') do |env|
        requests << env.url.to_s
        [200, { 'Link' => '</pages/1>; rel="next"' }, '2']
      end
    end

    expect { connection(stubs).paginate('/pages/1').to_a }
      .to raise_error(described_class::CycleError)
    expect(requests).to eq(%w[
      http://example.test/pages/1
      http://example.test/pages/2
    ])
  end

  it 'enforces a page limit' do
    requests = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      (1..3).each do |number|
        headers = number < 3 ? { 'Link' => %(</pages/#{number + 1}>; rel="next") } : {}
        stub.get("/pages/#{number}") do |env|
          requests << env.url.to_s
          [200, headers, number.to_s]
        end
      end
    end

    pages = connection(stubs).paginate('/pages/1', nil, max_pages: 2)

    expect { pages.to_a }.to raise_error(described_class::PageLimitError)
    expect(requests).to eq(%w[
      http://example.test/pages/1
      http://example.test/pages/2
    ])
  end

  it 'refuses cross-origin links by default and strips sensitive headers when allowed' do
    denied_stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/start') do
        [200, { 'Link' => '<http://other.test/next>; rel="next"' }, 'start']
      end
    end
    allowed_stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/start') do
        [200, { 'Link' => '<http://other.test/next>; rel="next"' }, 'start']
      end
      stub.get('http://other.test/next') do |env|
        [200, {}, env.request_headers.to_json]
      end
    end

    build_connection = proc do |stubs|
      Faraday.new(
        'http://example.test',
        headers: { 'Authorization' => 'secret', 'Accept' => 'application/json' }
      ) do |builder|
        builder.adapter(:test, stubs)
      end
    end
    denied_connection = build_connection.call(denied_stubs)
    allowed_connection = build_connection.call(allowed_stubs)

    expect { denied_connection.paginate('/start').to_a }
      .to raise_error(described_class::CrossOriginError)

    response = allowed_connection.paginate('/start', cross_origin: :follow).to_a.last
    headers = JSON.parse(response.body)
    expect(headers).not_to have_key('authorization')
    expect(headers.fetch('Accept')).to eq('application/json')
  end

  it 'lets a callable explicitly allow a cross-origin link' do
    seen_context = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/start') do
        link = '<http://other.test/next>; rel="next"; anchor="http://example.test/"'
        [200, { 'Link' => link }, 'start']
      end
      stub.get('http://other.test/next') do |env|
        [200, {}, env.request_headers.to_json]
      end
    end
    connection = Faraday.new(
      'http://example.test',
      headers: { 'Authorization' => 'secret', 'X-Approved' => 'yes' }
    ) do |builder|
      builder.adapter(:test, stubs)
    end

    policy = proc do |context|
      seen_context = context
      { 'X-Policy' => 'allowed' }
    end
    pages = connection.paginate('/start', nil, cross_origin: policy)

    expect(pages.to_a.last.body).to include('X-Policy')
    expect(seen_context[:url]).to eq(URI('http://other.test/next'))
    expect(seen_context[:link].context).to eq(URI('http://example.test/'))
  end
end
