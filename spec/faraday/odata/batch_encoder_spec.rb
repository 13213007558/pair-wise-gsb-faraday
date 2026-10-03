# frozen_string_literal: true

RSpec.describe Faraday::OData::BatchEncoder do
  let(:json_headers) { { 'Content-Type' => 'application/json' } }

  def encode(batch, boundary: 'batch_test')
    described_class.new(batch, boundary: boundary).encode
  end

  it 'encodes a top-level query as an application/http part' do
    batch = Faraday::OData::Batch.new([
                                        Faraday::OData::Operation.new(method: :get, url: 'Customers')
                                      ])

    encoded = encode(batch)

    expect(encoded.content_type).to eq('multipart/mixed; boundary="batch_test"')
    expect(encoded.body).to include("--batch_test\r\n")
    expect(encoded.body).to include("Content-Type: application/http\r\n")
    expect(encoded.body).to include("Content-Transfer-Encoding: binary\r\n")
    expect(encoded.body).to include("GET Customers HTTP/1.1\r\n")
    expect(encoded.body).to end_with("--batch_test--\r\n")
  end

  it 'nests change sets with their own boundary and Content-IDs' do
    batch = Faraday::OData::Batch.new([
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

    encoded = encode(batch)

    expect(encoded.body).to match(%r{Content-Type: multipart/mixed; boundary="changeset_[^"]+"})
    change_set_boundary = encoded.body[/boundary="(changeset_[^"]+)"/, 1]
    expect(encoded.body).to include("--#{change_set_boundary}\r\n")
    expect(encoded.body).to include("--#{change_set_boundary}--\r\n")
    expect(encoded.body).to include("Content-ID: 1\r\n")
    expect(encoded.body).to include("Content-ID: 2\r\n")
    expect(encoded.body).to include("POST Customers HTTP/1.1\r\n")
    expect(encoded.body).to include("POST $1/Orders HTTP/1.1\r\n")
    expect(encoded.body).to include("Content-Length: 15\r\n")
    expect(encoded.body).to include('{"Name":"ACME"}')
  end

  it 'preserves binary bodies byte for byte' do
    binary = "\x00\xFF\xFE{}\xC3\xA9".b
    batch = Faraday::OData::Batch.new([
                                        Faraday::OData::ChangeSet.new([
                                                                        Faraday::OData::Operation.new(
                                                                          method: :put, url: "Media(1)/$value",
                                                                          body: binary, content_id: '1'
                                                                        )
                                                                      ])
                                      ])

    encoded = encode(batch)

    expect(encoded.body.encoding).to eq(Encoding::BINARY)
    expect(encoded.body).to include(binary)
  end

  it 'validates the batch before encoding' do
    batch = Faraday::OData::Batch.new([
                                        Faraday::OData::ChangeSet.new([
                                                                        Faraday::OData::Operation.new(
                                                                          method: :post, url: 'Customers',
                                                                          content_id: '1'
                                                                        ),
                                                                        Faraday::OData::Operation.new(
                                                                          method: :post, url: 'Orders',
                                                                          content_id: '1'
                                                                        )
                                                                      ])
                                      ])

    expect { encode(batch) }.to raise_error(Faraday::OData::ValidationError, /duplicate Content-ID/)
  end
end
