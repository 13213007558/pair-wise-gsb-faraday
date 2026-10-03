# frozen_string_literal: true

RSpec.describe Faraday::OData::BatchDecoder do
  let(:json_headers) { { 'Content-Type' => 'application/json' } }

  def query(url, content_id: nil)
    Faraday::OData::Operation.new(method: :get, url: url, content_id: content_id)
  end

  def change(url, content_id:, body: nil)
    Faraday::OData::Operation.new(
      method: :post, url: url, headers: json_headers, body: body, content_id: content_id
    )
  end

  def multipart(boundary, parts)
    "--#{boundary}\r\n#{parts.join("\r\n--#{boundary}\r\n")}\r\n--#{boundary}--\r\n"
  end

  def http_part(status:, headers: {}, body: '', content_id: nil)
    lines = ['Content-Type: application/http', 'Content-Transfer-Encoding: binary']
    lines << "Content-ID: #{content_id}" if content_id
    inner = +"HTTP/1.1 #{status} Reason\r\n"
    headers.each { |name, value| inner << "#{name}: #{value}\r\n" }
    inner << "\r\n" << body
    "#{lines.join("\r\n")}\r\n\r\n#{inner}"
  end

  def change_set_part(boundary, parts)
    "Content-Type: multipart/mixed; boundary=#{boundary}\r\n\r\n#{multipart(boundary, parts)}"
  end

  def decode(batch, body, boundary: 'batch_resp')
    described_class.new(batch).decode(
      content_type: %(multipart/mixed; boundary="#{boundary}"), body: body
    )
  end

  it 'decodes query responses with status line, headers and body' do
    batch = Faraday::OData::Batch.new([query('Customers')])
    body = multipart('batch_resp', [
                       http_part(status: 200,
                                 headers: { 'Content-Type' => 'application/json', 'OData-Version' => '4.01' },
                                 body: '{"value":[]}')
                     ])

    result = decode(batch, body)

    expect(result).to be_a(Faraday::OData::BatchResult)
    expect(result.items.size).to eq(1)
    operation = result.operations.first
    expect(operation.status).to eq(200)
    expect(operation.headers['content-type']).to eq('application/json')
    expect(operation.headers['odata-version']).to eq('4.01')
    expect(operation.body).to eq('{"value":[]}')
    expect(operation).to be_success
    expect(result).to be_success
  end

  it 'decodes nested change set responses into a three level result' do
    batch = Faraday::OData::Batch.new([
                                        query('Customers'),
                                        Faraday::OData::ChangeSet.new([
                                                                        change('Customers', content_id: '1', body: '{}'),
                                                                        change('$1/Orders', content_id: '2', body: '{}')
                                                                      ])
                                      ])
    change_set = change_set_part('changeset_resp', [
                                   http_part(status: 201, content_id: '1',
                                             headers: { 'Location' => "Customers('abc')" }, body: '{}'),
                                   http_part(status: 204, content_id: '2')
                                 ])
    body = multipart('batch_resp', [http_part(status: 200, body: '{}'), change_set])

    result = decode(batch, body)

    expect(result.items.map(&:class)).to eq(
      [Faraday::OData::OperationResult, Faraday::OData::ChangeSetResult]
    )
    change_set_result = result.change_sets.first
    expect(change_set_result.operations.map(&:status)).to eq([201, 204])
    expect(change_set_result.operations.first.headers['location']).to eq("Customers('abc')")
    expect(change_set_result).to be_success
    expect(result).to be_success
  end

  it 'matches reordered parts by Content-ID instead of document order' do
    batch = Faraday::OData::Batch.new([
                                        query('Customers', content_id: '10'),
                                        query('Orders', content_id: '11')
                                      ])
    body = multipart('batch_resp', [
                       http_part(status: 200, content_id: '11', body: 'orders'),
                       http_part(status: 200, content_id: '10', body: 'customers')
                     ])

    result = decode(batch, body)

    expect(result.operations.map(&:body)).to eq(%w[customers orders])
  end

  it 'matches reordered change set parts by Content-ID' do
    batch = Faraday::OData::Batch.new([
                                        Faraday::OData::ChangeSet.new([
                                                                        change('Customers', content_id: '1', body: '{}'),
                                                                        change('$1/Orders', content_id: '2', body: '{}')
                                                                      ])
                                      ])
    change_set = change_set_part('changeset_resp', [
                                   http_part(status: 201, content_id: '2', body: 'order'),
                                   http_part(status: 201, content_id: '1', body: 'customer')
                                 ])
    body = multipart('batch_resp', [change_set])

    result = decode(batch, body)

    expect(result.change_sets.first.operations.map(&:body)).to eq(%w[customer order])
  end

  it 'keeps binary response bodies intact' do
    binary = "\x89PNG\r\n\x1A\n\x00\xFF".b
    batch = Faraday::OData::Batch.new([query('Media(1)/$value')])
    body = multipart('batch_resp', [
                       http_part(status: 200, headers: { 'Content-Type' => 'image/png' }, body: binary)
                     ]).b

    result = decode(batch, body)

    expect(result.operations.first.body.bytes).to eq(binary.bytes)
  end

  it 'reports a single failure response for a rolled back change set' do
    batch = Faraday::OData::Batch.new([
                                        Faraday::OData::ChangeSet.new([
                                                                        change('Customers', content_id: '1', body: '{}'),
                                                                        change('$1/Orders', content_id: '2', body: '{}')
                                                                      ])
                                      ])
    change_set = change_set_part('changeset_resp', [
                                   http_part(status: 400, content_id: '1',
                                             headers: { 'Content-Type' => 'application/json' },
                                             body: '{"error":{"code":"bad"}}')
                                 ])
    body = multipart('batch_resp', [change_set])

    result = decode(batch, body)

    change_set_result = result.change_sets.first
    expect(change_set_result).not_to be_success
    failed, aborted = change_set_result.operations
    expect(failed.status).to eq(400)
    expect(failed).not_to be_success
    expect(aborted).to be_aborted
    expect(aborted.status).to be_nil
    expect(result).not_to be_success
  end

  it 'exposes a change set level failure when the error part has no Content-ID' do
    batch = Faraday::OData::Batch.new([
                                        Faraday::OData::ChangeSet.new([
                                                                        change('Customers', content_id: '1', body: '{}'),
                                                                        change('$1/Orders', content_id: '2', body: '{}')
                                                                      ])
                                      ])
    change_set = change_set_part('changeset_resp', [
                                   http_part(status: 500, body: 'boom')
                                 ])
    body = multipart('batch_resp', [change_set])

    result = decode(batch, body)

    change_set_result = result.change_sets.first
    expect(change_set_result.failure.status).to eq(500)
    expect(change_set_result.operations).to all(be_aborted)
    expect(change_set_result).not_to be_success
  end

  it 'does not treat an overall 200 batch as successful operations' do
    batch = Faraday::OData::Batch.new([query('Missing')])
    body = multipart('batch_resp', [http_part(status: 404, body: 'not found')])

    result = decode(batch, body)

    expect(result.operations.first.status).to eq(404)
    expect(result).not_to be_success
  end

  it 'raises a ParseError when the boundary is missing' do
    batch = Faraday::OData::Batch.new([query('Customers')])

    expect { described_class.new(batch).decode(content_type: 'text/plain', body: '') }
      .to raise_error(Faraday::OData::ParseError, /no boundary/)
  end
end
