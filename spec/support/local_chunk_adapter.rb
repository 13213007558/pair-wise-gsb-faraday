# frozen_string_literal: true

require 'thread'

  REQUESTS = ::Queue.new

  def self.next_request
    REQUESTS.pop
  end

  def self.respond(pending, source:, etag:, changed: false, chunk_size: 3)
    env = pending.fetch(:env)
    range = pending.fetch(:range)
    body = source.byteslice(range[0], range[1] - range[0] + 1)
    tag = changed ? '"v2"' : etag
    headers = {
      'ETag' => tag,
      'Content-Range' => "bytes #{range[0]}-#{range[1]}/#{source.bytesize}"
    }
    env.status = 206
    env.response_headers = Faraday::Utils::Headers.new(headers)
    env.stream_response do |receiver|
      body.each_char.each_slice(chunk_size) do |chars|
        chunk = chars.join
        receiver.call(chunk, chunk.bytesize, env)
      end
    end
    pending.fetch(:done) << true
  end

  def call(env)
    match = /bytes=(\d+)-(\d+)/.match(env.request_headers.fetch('Range'))
    range = [Integer(match[1]), Integer(match[2])]
    done = Queue.new
    self.class::REQUESTS << { env: env, range: range, done: done }
    done.pop
    @app.call(env) || env.response
  end
end
