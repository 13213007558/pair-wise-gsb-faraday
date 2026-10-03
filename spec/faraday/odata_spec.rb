# frozen_string_literal: true

require 'faraday/odata'
require 'stringio'

RSpec.describe Faraday::OData do
  let(:batch_boundary) { 'batch_response' }
  let(:change_set_boundary) { 'changeset_response' }

  def http_response(status, content_id:, body: '', headers: {})
    reason = status == 400 ? 'Bad Request' : 'Created'
    lines = [
      "HTTP/1.1 #{status} #{reason}".strip,
      'Content-Type: application/json'
    ]
    lines << "Content-ID: #{content_id}" if content_id
    headers.each { |name, value| lines << "#{name}: #{value}" }
    [lines, '', body.b].join("\r\n")
  end

  def multipart(boundary, parts, content_type: 'multipart/mixed')
    chunk = parts.map { |part| "--#{boundary}\r\n#{part}" }.join("\r\n")
    "#{chunk}\r\n--#{boundary}--\r\n".b
  end

  def operation_part(status, content_id:, body: '', headers: {})
    [
      'Content-Type: application/http',
      'Content-Transfer-Encoding: binary',
      '',
      http_response(status, content_id: content_id, body: body, headers: headers)
    ].join("\r\n")
  end

  def change_set_part(statuses, content_ids:)
    operations = statuses.each_with_index.map do |status, index|
      operation_part(status, content_id: content_ids[index])
    end
    [
      "Content-Type: multipart/mixed; boundary=#{change_set_boundary}",
      '',
      multipart(change_set_boundary, operations)
    ].join("\r\n")
  end

  def response_body(parts)
    multipart(batch_boundary, parts)
  end

  def response_headers
    { 'Content-Type' => "multipart/mixed; boundary=#{batch_boundary}" }
  end

  describe 'encoding and decoding through the in-memory adapter' do
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }
    let(:connection) do
      Faraday.new do |builder|
        builder.adapter :test, stubs
      end
    end

    it 'creates a parent then references it with $1 and preserves shuffled responses' do
      operations = [
        { method: :get, url: 'Products', content_id: 'query' },
        { changeset: [
          { method: :post, url: 'Products', body: { name: 'Parent' } },
          {
            method: :post,
            url: '$1/Children',
            headers: { 'Content-Type' => 'application/octet-stream' },
            body: StringIO.new("\x00\xff")
          }
        ] }
      ]
      encoded = described_class.encode_batch(
        operations,
        boundary: 'batch_request',
        change_set_boundary: 'changeset_request'
      )

      stubs.post('/$batch') do |env|
        request_body = env.body
        expect(env.request_headers['Content-Type']).to include('boundary=batch_request')
        expect(request_body).to include('boundary=changeset_request_2')
        expect(request_body).to include('POST Products HTTP/1.1')
        expect(request_body).to include('Content-ID: 1')
        expect(request_body).to include('POST $1/Children HTTP/1.1')
        expect(request_body).to include('Content-ID: 2')
        expect(request_body).to include('Content-Type: application/octet-stream')
        expect(request_body).to include("\x00\xff".b)
        expect(request_body).to include('GET Products HTTP/1.1')
        expect(request_body).to include('Content-ID: query')
        [200, response_headers, response_body([
          change_set_part([201, 201], content_ids: %w[2 1]),
          operation_part(200, content_id: 'query', body: '{"value":[]}')
        ])]
      end

      response = connection.post('/$batch', encoded.body, encoded.headers)
      decoded = described_class.decode_batch(response, batch: encoded)

      expect(decoded.status).to eq(200)
      expect(decoded.success?).to be(true)
      expect(decoded.parts).to contain_exactly(
        an_instance_of(described_class::ChangeSetResponse),
        an_instance_of(described_class::OperationResponse)
      )
      expect(decoded.operations.map(&:content_id)).to eq(%w[2 1 query])
      expect(decoded.operation(1).status).to eq(201)
      expect(decoded.operation(2).status).to eq(201)
      expect(decoded.operation('query').status).to eq(200)
      stubs.verify_stubbed_calls
    end

    it 'keeps an atomic change set failed even when the outer response is 200' do
      encoded = described_class.encode_batch(
        [{ changeset: [
          { method: :post, url: 'Products', body: { name: 'Parent' } },
          { method: :post, url: '$1/Children', body: {} }
        ] }],
        boundary: 'failed_batch',
        change_set_boundary: 'failed_changeset'
      )

      stubs.post('/$batch') do
        [200, response_headers, response_body([
          change_set_part([400], content_ids: %w[1])
        ])]
      end

      response = connection.post('/$batch', encoded.body, encoded.headers)
      decoded = described_class.decode_batch(response, batch: encoded)
      change_set = decoded.parts.first

      expect(response.status).to eq(200)
      expect(decoded.outer_success?).to be(true)
      expect(decoded.success?).to be(false)
      expect(change_set).to be_a(described_class::ChangeSetResponse)
      expect(change_set.success?).to be(false)
      expect(change_set.status).to eq(400)
      expect(change_set.operations.map(&:status)).to eq([400])
      stubs.verify_stubbed_calls
    end

    it 'wraps the single failure response returned for an atomic change set' do
      encoded = described_class.encode_batch(
        [{ changeset: [
          { method: :post, url: 'Products', body: { name: 'Parent' } },
          { method: :post, url: '$1/Children', body: {} }
        ] }],
        boundary: 'single_failure_batch',
        change_set_boundary: 'single_failure_changeset'
      )

      stubs.post('/$batch') do
        [200, response_headers, response_body([
          operation_part(400, content_id: 1, body: '{"error":{"code":"rollback"}}')
        ])]
      end

      response = connection.post('/$batch', encoded.body, encoded.headers)
      decoded = described_class.decode_batch(response, batch: encoded)

      expect(decoded.parts).to contain_exactly(an_instance_of(described_class::ChangeSetResponse))
      expect(decoded.success?).to be(false)
      expect(decoded.operations.map { |operation| [operation.content_id, operation.status] }).to eq([['1', 400]])
      stubs.verify_stubbed_calls
    end

    it 'preserves arbitrary binary bodies and inner response headers' do
      binary = "\x00\xff\r\n--#{batch_boundary}X\r\n".b
      encoded = described_class.encode_batch(
        [{ method: :get, url: 'Files(1)', content_id: 'file' }],
        boundary: 'binary_batch'
      )

      stubs.post('/$batch') do
        [200, response_headers, response_body([
          operation_part(
            200,
            content_id: 'file',
            body: binary,
            headers: { 'Content-Type' => 'application/octet-stream' }
          )
        ])]
      end

      response = connection.post('/$batch', encoded.body, encoded.headers)
      decoded = described_class.decode_batch(response, batch: encoded)

      expect(decoded.operation('file').body).to eq(binary)
      expect(decoded.operation('file').headers['Content-Type']).to eq('application/octet-stream')
      stubs.verify_stubbed_calls
    end
  end

  describe 'validation before sending' do
    it 'rejects duplicate Content-ID values' do
      operations = [
        { method: :get, url: 'Products', content_id: 'same' },
        { changeset: [
          { method: :post, url: 'Products', content_id: 'same' },
          { method: :post, url: '$1/Children' }
        ] }
      ]

      expect { described_class.encode_batch(operations) }.to raise_error(
        described_class::ValidationError,
        /duplicate Content-ID/
      )
    end

    it 'rejects references to later, external, or non-creating operations' do
      expect do
        described_class.encode_batch([{ changeset: [
          { method: :post, url: '$2/Children' },
          { method: :post, url: 'Products', content_id: 2 }
        ] }])
      end.to raise_error(described_class::ValidationError, /later Content-ID/)

      expect do
        described_class.encode_batch([
          { method: :get, url: 'Products', content_id: 1 },
          { changeset: [{ method: :post, url: '$1/Children' }] }
        ])
      end.to raise_error(described_class::ValidationError, /outside its change set/)

      expect do
        described_class.encode_batch([{ changeset: [
          { method: :put, url: 'Products(1)', content_id: 1, body: {} },
          { method: :patch, url: '$1', body: {} }
        ] }])
      end.to raise_error(described_class::ValidationError, /non-creating Content-ID/)
    end

    it 'rejects read operations inside a change set' do
      expect do
        described_class.encode_batch([{ changeset: [{ method: :get, url: 'Products' }] }])
      end.to raise_error(described_class::ValidationError, /must be POST/)
    end

    it 'rejects a Content-ID header that conflicts with the operation metadata' do
      expect do
        described_class.encode_batch([{
          method: :post,
          url: 'Products',
          content_id: 'one',
          headers: { 'Content-ID' => 'two' },
          body: {}
        }])
      end.to raise_error(described_class::ValidationError, /header Content-ID does not match/)
    end

    it 'does not number a preceding query when assigning $1 inside a change set' do
      encoded = described_class.encode_batch([
        { method: :get, url: 'Products' },
        { changeset: [
          { method: :post, url: 'Products', body: {} },
          { method: :post, url: '$1/Children', body: {} }
        ] }
      ])

      expect(encoded.body).to include('POST Products HTTP/1.1', 'Content-ID: 1')
      expect(encoded.body).to include('POST $1/Children HTTP/1.1', 'Content-ID: 2')
      expect(encoded.body).not_to include("GET Products HTTP/1.1\r\nContent-ID")
    end
  end

  describe 'outer transport failures' do
    it 'does not treat a non-batch 400 response as successful operations' do
      decoded = described_class.decode_batch(
        { status: 400, headers: { 'Content-Type' => 'text/plain' }, body: 'bad request' },
        nil,
        batch: nil
      )

      expect(decoded.status).to eq(400)
      expect(decoded.success?).to be(false)
      expect(decoded.parts).to be_empty
      expect(decoded.body).to eq('bad request')
    end
  end

  describe 'protocol errors' do
    it 'rejects an invalid inner HTTP status line before returning operations' do
      body = multipart(batch_boundary, [
        [
          'Content-Type: application/http',
          '',
          'BROKEN/1.1 200 OK',
          '',
          'invalid'
        ].join("\r\n")
      ])

      expect do
        described_class.decode_batch(body, response_headers)
      end.to raise_error(described_class::ProtocolError, /invalid application\/http status line/)
    end

    it 'requires a boundary in the outer multipart content type' do
      expect do
        described_class.decode_batch('body', { 'Content-Type' => 'multipart/mixed' })
      end.to raise_error(described_class::ProtocolError, /missing a boundary/)
    end

    it 'does not treat a boundary-like binary sequence as a real boundary' do
      fake = "\x00\xff\r\n--#{batch_boundary}X\r\n".b
      body = multipart(batch_boundary, [
        operation_part(200, content_id: 'binary', body: fake)
      ])

      decoded = described_class.decode_batch(body, response_headers)

      expect(decoded.operation('binary').body).to eq(fake)
    end
  end
end
