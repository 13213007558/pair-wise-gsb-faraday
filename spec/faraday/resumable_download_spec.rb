# frozen_string_literal: true

require 'stringio'

RSpec.describe Faraday::ResumableDownload do
  let(:content) { 'The quick brown fox jumps over a lazy dog!' }
  let(:etag) { '"v1"' }

  def chunked(string, size = 5)
    string.bytes.each_slice(size).map { |bytes| bytes.pack('C*').b }
  end

  def target_for(existing_ranges)
    target = StringIO.new(0.chr.b * content.bytesize)
    existing_ranges.each do |start, finish|
      target.seek(start)
      target.write(content.byteslice(start, finish - start + 1))
    end
    target.rewind
    target
  end

  def session(existing_ranges: [])
    target = target_for(existing_ranges)
    [described_class.new(target,
                         etag: etag,
                         total_length: content.bytesize,
                         existing_ranges: existing_ranges), target]
  end

  def response(status, headers, body)
    Faraday::Response.new(Faraday::Env.from(
      status: status,
      response_headers: headers,
      body: body,
      request: {},
      response: nil
    ))
  end

  def multipart(boundary, parts)
    encoded = parts.map do |start, finish, body|
      "\r\nContent-Range: bytes #{start}-#{finish}/#{content.bytesize}\r\n\r\n#{body}"
    end
    "--#{boundary}#{encoded.join("\r\n--#{boundary}")}\r\n--#{boundary}--"
  end

  it 'uses Adapter::Test chunks in shuffled order and rejects a midstream ETag change' do
    download, target = session(existing_ranges: [[0, 2]])
    requests = download.requests(chunk_size: 16)
    stubs = Faraday::Adapter::Test::Stubs.new
    connection = Faraday.new { |builder| builder.adapter(:test, stubs) }

    stubs.get('/file') do |env|
      range = env.request_headers['Range']
      start, finish = range.match(/bytes=(\d+)-(\d+)/).captures.map(&:to_i)
      expect(env.request_headers['If-Match']).to eq(etag)
      [206,
       {
         'Content-Range' => "bytes #{start}-#{finish}/#{content.bytesize}",
         'ETag' => etag
       },
       chunked(content.byteslice(start, finish - start + 1), 7)]
    end

    shuffled_requests = requests.shuffle
    changed_request = shuffled_requests.last
    successful_requests = shuffled_requests[0...-1]
    successful_requests.each do |request|
      resp = connection.get('/file') { |req| request.headers.each { |key, value| req.headers[key] = value } }
      download.ingest(resp)
    end

    changed_response = response(206,
                                {
                                  'Content-Range' => "bytes #{changed_request.ranges[0][0]}-#{changed_request.ranges[0][1]}/#{content.bytesize}",
                                  'ETag' => '"v2"'
                                },
                                content.byteslice(changed_request.ranges[0][0],
                                                  changed_request.ranges[0][1] - changed_request.ranges[0][0] + 1))
    expect { download.ingest(changed_response) }.to raise_error(described_class::ValidatorMismatch)

    result = download.finish
    expect(result).not_to be_complete
    expect(result.missing_ranges).to eq(changed_request.ranges)
    target.rewind
    actual = target.read
    expected = target_for([[0, 2]])
    successful_requests.each do |request|
      start, finish = request.ranges.first
      expected.seek(start)
      expected.write(content.byteslice(start, finish - start + 1))
    end
    expected.rewind
    expect(actual).to eq(expected.read)
    stubs.verify_stubbed_calls
  end

  it 'accepts streaming overlapping single 206 responses and verifies bytes' do
    download, target = session(existing_ranges: [[3, 7]])
    result = download.ingest(response(206,
                                      {
                                        'Content-Range' => "bytes 0-14/#{content.bytesize}",
                                        'ETag' => etag,
                                        'Content-Length' => '15'
                                      },
                                      chunked(content.byteslice(0, 15), 4)))

    expect(result.missing_ranges).to eq([[15, content.bytesize - 1]])
    target.rewind
    expect(target.read(15)).to eq(content.byteslice(0, 15))
  end

  it 'rejects conflicting overlap content without counting the response' do
    download, _target = session(existing_ranges: [[3, 7]])
    changed = content.dup.tap { |string| string[3] = 'X' }

    expect do
      download.ingest(response(206,
                               {
                                 'Content-Range' => "bytes 0-14/#{content.bytesize}",
                                 'ETag' => etag
                               },
                               changed.byteslice(0, 15)))
    end.to raise_error(described_class::ContentMismatch)
    expect(download.finish.missing_ranges).to eq([[0, 2], [8, content.bytesize - 1]])
  end

  it 'checks total length, content length, and strong ETag on 206 responses' do
    download, _target = session
    headers = { 'Content-Range' => "bytes 0-14/#{content.bytesize}" }
    body = content.byteslice(0, 15)

    expect { download.ingest(response(206, headers, body)) }
      .to raise_error(described_class::InvalidResponse, /ETag/)
    expect { download.ingest(response(206, headers.merge('ETag' => 'W/"v1"'), body)) }
      .to raise_error(described_class::ValidatorMismatch)
    expect { download.ingest(response(206, headers.merge('ETag' => '"v2"'), body)) }
      .to raise_error(described_class::ValidatorMismatch)
    expect do
      download.ingest(response(206,
                               {
                                 'Content-Range' => 'bytes 0-14/49',
                                 'ETag' => etag
                               },
                               body))
    end.to raise_error(described_class::InvalidResponse, /total length/)
    expect do
      download.ingest(response(206,
                               headers.merge('Content-Length' => '14', 'ETag' => etag),
                               body))
    end.to raise_error(described_class::InvalidResponse, /Content-Length/)
  end

  it 'rejects a declared part when the body is shorter or longer' do
    short, _short_target = session
    expect do
      short.ingest(response(206,
                             {
                               'Content-Range' => "bytes 0-14/#{content.bytesize}",
                               'ETag' => etag
                             },
                             content.byteslice(0, 14)))
    end.to raise_error(described_class::InvalidResponse, /shorter/)

    long, _long_target = session
    expect do
      long.ingest(response(206,
                           {
                             'Content-Range' => "bytes 0-14/#{content.bytesize}",
                             'ETag' => etag
                           },
                           content.byteslice(0, 16)))
    end.to raise_error(described_class::InvalidResponse, /longer/)
  end

  it 'requires a strong ETag when the session starts' do
    expect { described_class.new(StringIO.new, etag: 'W/"v1"', total_length: 0) }
      .to raise_error(ArgumentError, /strong ETag/)
    expect { described_class.new(StringIO.new, etag: 'v1', total_length: 0) }
      .to raise_error(ArgumentError, /strong ETag/)
  end

  it 'rejects a single 206 response without Content-Range' do
    download, _target = session

    expect do
      download.ingest(response(206, { 'ETag' => etag }, content))
    end.to raise_error(described_class::InvalidResponse, /Content-Range/)
  end

  it 'streams multipart parts split around a near-boundary byte sequence' do
    download, target = session
    boundary = 'boundary'
    prefix = "--#{boundary}X body bytes"
    body = multipart(boundary, [[0, prefix.bytesize - 1, prefix]])

    download.ingest(response(206,
                             {
                               'Content-Type' => "multipart/byteranges; boundary=#{boundary}",
                               'ETag' => etag
                             },
                             chunked(body, 3)))
    target.rewind
    expect(target.read(prefix.bytesize)).to eq(prefix)
  end

  it 'does not retain body bytes while waiting for a split closing CRLF' do
    download, target = session
    boundary = 'b'
    prefix = 'boundary-near-data'
    body = multipart(boundary, [[0, prefix.bytesize - 1, prefix]])
    split_at = body.bytesize - 4
    parser_body = [body.byteslice(0, split_at), body.byteslice(split_at, body.bytesize)]

    expect(download.ingest(response(206,
                                    {
                                      'Content-Type' => 'multipart/byteranges; boundary=b',
                                      'ETag' => etag
                                    },
                                    parser_body))).not_to be_complete
    target.rewind
    expect(target.read(prefix.bytesize)).to eq(prefix)
  end

  it 'accepts out-of-order multipart parts and rejects overlaps that differ' do
    good, target = session
    boundary = 'longboundary'
    good_body = multipart(boundary, [
      [20, content.bytesize - 1, content.byteslice(20, content.bytesize - 20)],
      [0, 24, content.byteslice(0, 25)]
    ])
    expect(good.ingest(response(206,
                                {
                                  'Content-Type' => "multipart/byteranges; boundary=#{boundary}",
                                  'ETag' => etag
                                },
                                chunked(good_body, 11)))).to be_complete
    target.rewind
    expect(target.read).to eq(content)

    bad, _target = session
    changed = content.dup.tap { |string| string[22] = 'X' }
    bad_body = multipart('b', [
      [20, content.bytesize - 1, changed.byteslice(20, content.bytesize - 20)],
      [0, 24, content.byteslice(0, 25)]
    ])
    expect do
      bad.ingest(response(206,
                          {
                            'Content-Type' => 'multipart/byteranges; boundary=b',
                            'ETag' => etag
                          },
                          bad_body))
    end.to raise_error(described_class::ContentMismatch)
    expect(bad.finish.missing_ranges).to eq([[0, content.bytesize - 1]])
  end

  it 'requires multipart boundary and per-part Content-Range' do
    download, _target = session

    expect do
      download.ingest(response(206,
                               { 'Content-Type' => 'multipart/byteranges', 'ETag' => etag },
                               ''))
    end.to raise_error(described_class::InvalidResponse, /boundary/)

    expect do
      download.ingest(response(206,
                               {
                                 'Content-Type' => 'multipart/byteranges; boundary=b',
                                 'ETag' => etag
                               },
                               "--b\r\nX-Invalid\r\n\r\n#{content}\r\n--b--"))
    end.to raise_error(described_class::InvalidResponse, /Content-Range/)
  end

  it 'handles 200 as full rewrite and 416 as unchanged, incomplete state' do
    full, target = session(existing_ranges: [[10, 14]])
    expect(full.ingest(response(200, { 'ETag' => etag }, chunked(content, 9)))).to be_complete
    target.rewind
    expect(target.read).to eq(content)

    blocked, _target = session(existing_ranges: [[0, 4]])
    blocked_result = blocked.ingest(response(416,
                                            {
                                              'ETag' => etag,
                                              'Content-Range' => "bytes */#{content.bytesize}"
                                            },
                                            ''))
    expect(blocked_result).to be_range_not_satisfiable
    expect(blocked_result.missing_ranges).to eq([[5, content.bytesize - 1]])

    expect do
      blocked.ingest(response(416,
                              {
                                'ETag' => '"v2"',
                                'Content-Range' => "bytes */#{content.bytesize}"
                              },
                              ''))
    end.to raise_error(described_class::ValidatorMismatch)
    expect do
      blocked.ingest(response(416,
                              {
                                'ETag' => etag,
                                'Content-Range' => "bytes */#{content.bytesize + 1}"
                              },
                              ''))
    end.to raise_error(described_class::InvalidResponse, /total length/)
  end

  it 'never treats a hole as success' do
    download, _target = session
    expect { download.finish! }.to raise_error(described_class::IncompleteDownload)
    expect(download.finish).not_to be_complete
  end
end
