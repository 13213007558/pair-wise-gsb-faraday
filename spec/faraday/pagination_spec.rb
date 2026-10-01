# frozen_string_literal: true

RSpec.describe Faraday::Pagination do
  let(:requests) { [] }
  let(:stubs) do
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/api/items/?per_page=1') do |env|
        requests << env.url.to_s
        link = '<2?per_page=1&cursor=1%2C2>; rel="next"; title="a,b"; data-filter="x,y"'
        [200, { 'Link' => link }, 'one']
      end

      stub.get('/api/items/2?per_page=1&cursor=1%2C2') do |env|
        requests << env.url.to_s
        [200, { 'Link' => '</api/items/?per_page=1>; rel="next"; title="a,b"' }, 'two']
      end

      stub.get('/api/start') do |env|
        requests << {
          url: env.url.to_s,
          authorization: env.request_headers['Authorization'],
          cookie: env.request_headers['Cookie'],
          trace: env.request_headers['X-Trace']
        }
        [200, { 'Link' => '<https://other.example/items>; rel="next"' }, 'start']
      end

      stub.get('https://other.example/items') do |env|
        requests << {
          url: env.url.to_s,
          authorization: env.request_headers['Authorization'],
          cookie: env.request_headers['Cookie'],
          trace: env.request_headers['X-Trace']
        }
        [200, {}, 'other']
      end
    end
  end
  let(:connection) do
    Faraday.new('http://example.com/api/') do |builder|
      builder.adapter(:test, stubs)
    end
  end

  it 'requests relative next addresses only while consuming pages' do
    pages = connection.paginate('items/', { per_page: 1 }).each

    expect(pages.next.body).to eq('one')
    expect(requests).to eq(['http://example.com/api/items/?per_page=1'])

    expect(pages.next.body).to eq('two')
    expect(requests).to eq(
      [
        'http://example.com/api/items/?per_page=1',
          'http://example.com/api/items/2?per_page=1&cursor=1%2C2'
      ]
    )
  end

  it 'does not request the next page when the consumer stops' do
    pages = connection.paginate('items/', { per_page: 1 }).each

    pages.next
    expect(requests).to eq(['http://example.com/api/items/?per_page=1'])
  end

  it 'does not request the next page when a block consumer breaks' do
    connection.paginate('items/', { per_page: 1 }) do |page|
      expect(page.body).to eq('one')
      break
    end

    expect(requests).to eq(['http://example.com/api/items/?per_page=1'])
  end

  it 'resolves relative next links against the Link anchor context' do
    stubs.clear
    stubs.get('/api/items') do |env|
      requests << env.url.to_s
      [200, { 'Link' => '<2>; rel="next"; anchor="/catalog/"' }, 'catalog']
    end
    stubs.get('/catalog/2') do |env|
      requests << env.url.to_s
      [200, {}, 'page-two']
    end

    pages = connection.paginate('items').each

    expect(pages.to_a.map(&:body)).to eq(%w[catalog page-two])
    expect(requests).to eq(
      [
        'http://example.com/api/items',
        'http://example.com/catalog/2'
      ]
    )
  end

  it 'detects the two-page cycle before requesting the first address a second time' do
    pages = connection.paginate('items/', { per_page: 1 }).each

    expect { pages.to_a }.to raise_error(described_class::PaginationCycleError)
    expect(requests).to eq(
      [
        'http://example.com/api/items/?per_page=1',
          'http://example.com/api/items/2?per_page=1&cursor=1%2C2'
      ]
    )
  end

  it 'enforces the page limit before requesting beyond it' do
    pages = connection.paginate('items/', { per_page: 1 }, nil, max_pages: 1).each

    expect { pages.to_a }.to raise_error(described_class::PaginationLimitError)
    expect(requests).to eq(['http://example.com/api/items/?per_page=1'])
  end

  it 'denies cross-origin following by default' do
    pages = connection.paginate('start').each

    expect { pages.to_a }.to raise_error(described_class::CrossOriginError)
    expect(requests.map { |request| request[:url] }).to eq(['http://example.com/api/start'])
  end

  it 'follows cross-origin links only with an explicit policy and strips sensitive headers' do
    policy_calls = []
    connection.headers['Authorization'] = 'Bearer token'
    connection.headers['Cookie'] = 'session=abc'
    connection.headers['X-Trace'] = 'trace-1'
    pages = connection.paginate(
      'start', nil, nil,
      cross_origin: ->(url, response) {
        policy_calls << [url.host, response.status]
        url.host == 'other.example'
      }
    ).each

    expect(pages.to_a.map(&:body)).to eq(%w[start other])
    expect(policy_calls).to eq([['other.example', 200]])
    expect(requests).to eq(
      [
        {
          url: 'http://example.com/api/start',
          authorization: 'Bearer token',
          cookie: 'session=abc',
          trace: 'trace-1'
        },
        {
          url: 'https://other.example/items',
          authorization: nil,
          cookie: nil,
          trace: 'trace-1'
        }
      ]
    )
  end

  it 'strips sensitive headers supplied explicitly on the first request across origins' do
    pages = connection.paginate(
      'start', nil, { 'Authorization' => 'Bearer per-request', 'X-Trace' => 'request-trace' },
      cross_origin: :follow
    ).each

    expect(pages.to_a.map(&:body)).to eq(%w[start other])
    expect(requests).to eq(
      [
        {
          url: 'http://example.com/api/start',
          authorization: 'Bearer per-request',
          cookie: nil,
          trace: 'request-trace'
        },
        {
          url: 'https://other.example/items',
          authorization: nil,
          cookie: nil,
          trace: 'request-trace'
        }
      ]
    )
  end

  it 'supports callable objects as cross-origin policies' do
    policy = Object.new
    def policy.call(url, _response)
      url.host == 'other.example'
    end

    pages = connection.paginate('start', nil, nil, cross_origin: policy).each

    expect(pages.to_a.map(&:body)).to eq(%w[start other])
  end
end
