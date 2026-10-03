# frozen_string_literal: true

RSpec.describe 'Faraday::OData.execute_batch' do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) do
    Faraday.new(url: 'https://odata.example.com') do |faraday|
      faraday.adapter :test, stubs
    end
  end

  let(:json_headers) { { 'Content-Type' => 'application/json' } }

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

  def create_then_reference_batch
    Faraday::OData::Batch.new([
                                Faraday::OData::ChangeSet.new([
                                                                Faraday::OData::Operation.new(
                                                                  method: :post, url: 'Customers',
                                                                  headers: json_headers,
                                                                  body: '{"Name":"ACME"}',
                                                                  content_id: '1'
                                                                ),
                                                                Faraday::OData::Operation.new(
                                                                  method: :post, url: '$1/Orders',
                                                                  headers: json_headers,
                                                                  body: '{"Amount":42}',
                                                                  content_id: '2'
                                                                )
                                                              ])
                              ])
  end

  it 'creates a master record and references it within one change set' do
    response_body = multipart('batch_resp', [
                              change_set_part('changeset_resp', [
                                                http_part(status: 201, content_id: '1',
                                                          headers: { 'Location' => "Customers('abc')" },
                                                          body: '{"ID":"abc"}'),
                                                http_part(status: 201, content_id: '2', body: '{"ID":7}')
                                              ])
                            ])
    stubs.post('/$batch') do |env|
      expect(env.request_headers['Content-Type']).to match(%r{multipart/mixed; boundary="batch_})
      expect(env.request_headers['OData-Version']).to eq('4.01')
      expect(env.body).to include('POST Customers HTTP/1.1')
      expect(env.body).to include('POST $1/Orders HTTP/1.1')
      expect(env.body).to include('Content-ID: 1')
      [200, { 'Content-Type' => 'multipart/mixed; boundary=batch_resp' }, response_body]
    end

    result = Faraday::OData.execute_batch(connection, create_then_reference_batch)

    expect(result.items.size).to eq(1)
    change_set = result.change_sets.first
    expect(change_set.operations.map(&:status)).to eq([201, 201])
    expect(change_set.operations.first.headers['location']).to eq("Customers('abc')")
    expect(result).to be_success
    stubs.verify_stubbed_calls
  end

  it 'surfaces a failed change set even though the batch request returns 200' do
    response_body = multipart('batch_resp', [
                              change_set_part('changeset_resp', [
                                                http_part(status: 409, content_id: '2',
                                                          body: '{"error":{"code":"conflict"}}')
                                              ])
                            ])
    stubs.post('/$batch') do
      [200, { 'Content-Type' => 'multipart/mixed; boundary=batch_resp' }, response_body]
    end

    result = Faraday::OData.execute_batch(connection, create_then_reference_batch)

    change_set = result.change_sets.first
    expect(change_set).not_to be_success
    expect(change_set.operations[1].status).to eq(409)
    expect(change_set.operations[0]).to be_aborted
    expect(result).not_to be_success
    stubs.verify_stubbed_calls
  end

  it 'matches a deliberately reordered response by Content-ID' do
    batch = Faraday::OData::Batch.new([
                                        Faraday::OData::Operation.new(method: :get, url: 'Customers',
                                                                      content_id: '10'),
                                        Faraday::OData::Operation.new(method: :get, url: 'Orders',
                                                                      content_id: '11'),
                                        Faraday::OData::ChangeSet.new([
                                                                        Faraday::OData::Operation.new(
                                                                          method: :post, url: 'Customers',
                                                                          headers: json_headers, body: '{}',
                                                                          content_id: '1'
                                                                        )
                                                                      ])
                                      ])
    response_body = multipart('batch_resp', [
                              http_part(status: 200, content_id: '11', body: 'orders'),
                              change_set_part('changeset_resp', [
                                                http_part(status: 204, content_id: '1')
                                              ]),
                              http_part(status: 200, content_id: '10', body: 'customers')
                            ])
    stubs.post('/$batch') do
      [200, { 'Content-Type' => 'multipart/mixed; boundary=batch_resp' }, response_body]
    end

    result = Faraday::OData.execute_batch(connection, batch)

    expect(result.items.map(&:class)).to eq(
      [Faraday::OData::OperationResult, Faraday::OData::OperationResult,
       Faraday::OData::ChangeSetResult]
    )
    expect(result.operations.map(&:body)).to eq(%w[customers orders])
    expect(result.change_sets.first.operations.first.status).to eq(204)
    expect(result).to be_success
    stubs.verify_stubbed_calls
  end

  it 'raises before sending anything when the batch is invalid' do
    invalid = Faraday::OData::Batch.new([
                                         Faraday::OData::ChangeSet.new([
                                                                         Faraday::OData::Operation.new(
                                                                           method: :post, url: '$9/Orders',
                                                                           content_id: '1'
                                                                         )
                                                                       ])
                                      ])
    sent = false
    stubs.post('/$batch') do
      sent = true
      [200, {}, '']
    end

    expect { Faraday::OData.execute_batch(connection, invalid) }
      .to raise_error(Faraday::OData::ValidationError)
    expect(sent).to be(false)
  end
end
