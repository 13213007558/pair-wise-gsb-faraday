# frozen_string_literal: true

require 'stringio'
require 'faraday'

RSpec.describe Faraday::DownloadSession do
  let(:source) { 'abcdefghij'.b }
  let(:etag) { '"v1"' }

  def io(content = nil)
    StringIO.new(content || "\0".b * source.bytesize, 'w+b')
  end

  def range_response(download, request, range, body, status: 206, headers: {})
    full_headers = { 'ETag' => etag }.merge(headers)
    if status == 206 && !full_headers.key?('Content-Range')
      full_headers['Content-Range'] = "bytes #{range}/#{source.bytesize}"
    end
    writer = download.begin_response(request, status, full_headers)
    writer.data(body)
    writer.finish
  end

  it 'builds the next gap request and completes a single 206' do
    target = io
    download = described_class.new(target, [], etag, size: source.bytesize)
    request = download.build_request

    expect(request.headers).to eq('Range' => 'bytes=0-9', 'If-Match' => etag)
    result = range_response(download, request, '0-9', source)

    expect(result).to be_complete
    expect(result.missing_ranges).to eq([])
    expect(target.string).to eq(source)
  end

  it 'uses existing ranges and keeps requests reserved until committed' do
    target = io
    download = described_class.new(target, [[0, 2], [8, 9]], etag, size: source.bytesize)
    request = download.build_request

    expect(request.ranges).to eq([[3, 7]])
    expect(download.build_request).to be_nil
    expect(range_response(download, request, '3-7', source.byteslice(3, 5))).to be_complete
  end

  it 'accepts 200 as a full restart and truncates stale trailing bytes' do
    target = StringIO.new(+'stale trailing content that must disappear', 'r+b')
    download = described_class.new(target, [[0, 1]], etag, size: source.bytesize)
    request = download.build_request

    result = range_response(
      download, request, nil, source, status: 200,
      headers: { 'Content-Length' => source.bytesize.to_s }
    )

    expect(result).to be_complete
    expect(target.string).to eq(source)
  end

  it 'surfaces 416 without marking a hole as completed and releases the request' do
    target = io
    download = described_class.new(target, [], etag, size: source.bytesize)
    request = download.build_request
    writer = download.begin_response(request, 416, 'Content-Range' => "bytes */#{source.bytesize}")

    expect { writer.finish }.to raise_error(Faraday::UnsatisfiableRangeError)
    expect(download.result.missing_ranges).to eq([[0, 9]])
  end

  it 'rejects changed and weak validators without recording partial success' do
    target = io
    download = described_class.new(target, [], etag, size: source.bytesize)
    request = download.build_request

    expect do
      range_response(download, request, '0-9', source, headers: { 'ETag' => '"v2"' })
    end.to raise_error(Faraday::ValidatorMismatchError)
    expect(download.result.missing_ranges).to eq([[0, 9]])

    expect do
      download.begin_response(request, 206, 'ETag' => 'W/"v1"', 'Content-Range' => 'bytes 0-9/10')
    end.to raise_error(Faraday::ValidatorMismatchError)
  end

  it 'checks total length, declared part length, and overlapping content' do
    target = io
    download = described_class.new(target, [], etag, size: source.bytesize)
    request = download.build_request

    expect { range_response(download, request, '0-9', source, headers: { 'Content-Range' => 'bytes 0-9/11' }) }
      .to raise_error(Faraday::RangeError)

    short = described_class.new(io, [], etag, size: source.bytesize)
    short_request = short.build_request
    expect { range_response(short, short_request, '0-9', source[0..-2], headers: { 'Content-Length' => '9' }) }
      .to raise_error(Faraday::RangeError)

    target_with_content = StringIO.new(source.dup.force_encoding(Encoding::BINARY), 'r+b')
    conflicting = described_class.new(target_with_content, [[3, 3]], etag, size: source.bytesize)
    conflict_request = conflicting.build_request([[3, 3]])
    changed = source.dup
    changed.setbyte(3, 'X'.ord)
    expect { range_response(conflicting, conflict_request, '3-3', changed.byteslice(3, 1)) }
      .to raise_error(Faraday::RangeContentMismatchError)
  end

  it 'parses streamed multipart/byteranges, accepts out-of-order parts, and keeps body lookalikes' do
    boundary = 'faraday-boundary'
    body = [
      "--#{boundary}\r\nContent-Range: bytes 7-9/10\r\n\r\n#{source.byteslice(7, 3)}",
      "--#{boundary}\r\nContent-Range: bytes 0-6/10\r\n\r\n#{source.byteslice(0, 7)}",
      "--#{boundary}--\r\n"
    ].join("\r\n")

    target = io
    download = described_class.new(target, [], etag, size: source.bytesize)
    request = download.build_request(nil, max_ranges: nil)
    writer = download.begin_response(request, 206, 'ETag' => etag, 'Content-Type' => "multipart/byteranges; boundary=#{boundary}")
    body.each_char.each_slice(3) { |chars| writer.data(chars.join) }
    result = writer.finish

    expect(result).to be_complete
    expect(target.string).to eq(source)
  end

  it 'does not consume a boundary lookalike while parsing one byte at a time' do
    boundary = 'b'
    parts = []
    parser = Faraday::DownloadSession::MultipartParser.new(boundary) do |part|
      part.on_headers { |headers, callback_part| callback_part.state = { headers: headers, body: +'' } }
      part.on_data { |chunk, callback_part| callback_part.state[:body] << chunk }
      part.on_end { |callback_part| parts << callback_part.state }
    end

    body = "\r\n--b\r\na: 1\r\n\r\n--bX\r\n--b\r\na: 2\r\n\r\nok\r\n--b--\r\n".b
    body.each_char { |char| parser.feed(char) }
    parser.finish

    expect(parts).to eq([
      { headers: { 'a' => '1' }, body: '--bX' },
      { headers: { 'a' => '2' }, body: 'ok' }
    ])
  end

  it 'supports unordered concurrent chunks and retries a changed ETag response' do
    LocalChunkAdapter::REQUESTS.clear
    target = io
    download = described_class.new(target, [], etag, size: source.bytesize, chunk_size: 3)
    connection = Faraday.new { |builder| builder.adapter LocalChunkAdapter }

    requests = Array.new(4) { download.build_request }
    threads = requests.map do |request|
      Thread.new do
        writer = nil
        begin
          connection.get('/') do |req|
            request.headers.each { |name, value| req.headers[name] = value }
            req.options.on_data = proc do |chunk, _size, env|
              writer ||= download.begin_response(request, env.status, env.response_headers)
              writer.data(chunk)
            end
          end
          writer.finish
        rescue Faraday::ValidatorMismatchError
          :changed
        end
      end
    end

    pending = Array.new(4) { LocalChunkAdapter.next_request }
    deliver = lambda do |index, changed: false|
      LocalChunkAdapter.respond(
        pending[index], source: source, etag: etag, changed: changed
      )
    end

    deliver.call(3)
    deliver.call(1)
    deliver.call(0, changed: true)
    deliver.call(2)

    expect(threads.map(&:value)).to eq([:changed, nil, nil, nil])
    expect(download.result.complete).to be(false)
    retry_request = download.build_request
    retry_pending = LocalChunkAdapter.next_request
    retry_writer = download.begin_response(retry_request, 206, retry_pending[:env].response_headers)
    LocalChunkAdapter.respond(retry_pending, source: source, etag: etag)

    result = retry_writer.finish
    expect(result).to be_complete
    expect(target.string).to eq(source)
  end
end
