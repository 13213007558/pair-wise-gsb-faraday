# frozen_string_literal: true

require 'webrick'

RSpec.describe 'FollowRedirects over localhost' do
  before(:all) do
    @server_b, @port_b = start_server do |server|
      server.mount_proc('/headers') do |req, res|
        res.status = 200
        res.body = "auth=#{req['Authorization'].inspect} host=#{req['Host'].inspect}"
      end
    end

    @server_a, @port_a = start_server do |server|
      server.mount_proc('/mixed/1') { |_req, res| redirect(res, 301, '/mixed/2') }
      server.mount_proc('/mixed/2') { |_req, res| redirect(res, 302, '/mixed/3') }
      server.mount_proc('/mixed/3') { |_req, res| redirect(res, 303, '/mixed/4') }
      server.mount_proc('/mixed/4') { |_req, res| redirect(res, 307, '/mixed/5') }
      server.mount_proc('/mixed/5') { |_req, res| redirect(res, 308, '/echo') }

      server.mount_proc('/keep/1') { |_req, res| redirect(res, 307, '/keep/2') }
      server.mount_proc('/keep/2') { |_req, res| redirect(res, 308, '/echo') }

      server.mount_proc('/cross') do |_req, res|
        redirect(res, 302, "http://127.0.0.1:#{@port_b}/headers")
      end

      server.mount_proc('/echo') do |req, res|
        res.status = 200
        res.body = "#{req.request_method} #{req.path} #{req.body}"
      end
    end
  end

  after(:all) do
    @server_a&.shutdown
    @server_b&.shutdown
  end

  def start_server
    server = WEBrick::HTTPServer.new(
      BindAddress: '127.0.0.1', Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    yield server
    Thread.new { server.start }
    deadline = Time.now + 5
    sleep 0.01 while server.listeners.empty? && Time.now < deadline
    [server, server.listeners.first.addr[1]]
  end

  def redirect(response, status, location)
    response.status = status
    response['Location'] = location
  end

  def connection(path_prefix_port, **options)
    Faraday.new("http://127.0.0.1:#{path_prefix_port}") do |builder|
      builder.response :follow_redirects, **options
      builder.adapter :net_http
    end
  end

  it 'follows a mixed 301/302/303/307/308 chain and records every hop' do
    response = connection(@port_a, limit: 10).post('/mixed/1', 'payload') do |req|
      req.headers['Content-Type'] = 'text/plain'
    end

    expect(response.status).to eq(200)
    # 301 rewrote the POST to a GET and dropped the body.
    expect(response.body).to eq('GET /echo ')
    expect(response.env[:redirects].map { |hop| hop[:status] })
      .to eq([301, 302, 303, 307, 308])
    expect(response.env[:redirects].map { |hop| hop[:location] })
      .to eq((2..5).map { |n| "http://127.0.0.1:#{@port_a}/mixed/#{n}" } +
             ["http://127.0.0.1:#{@port_a}/echo"])
  end

  it 'keeps method and body across 307/308 redirects' do
    response = connection(@port_a).post('/keep/1', 'live-payload')

    expect(response.status).to eq(200)
    expect(response.body).to eq('POST /echo live-payload')
  end

  it 'follows redirects to another port and strips credentials and manual Host' do
    response = connection(@port_a).get('/cross') do |req|
      req.headers['Authorization'] = 'Token secret'
      req.headers['Host'] = 'made-up.example'
    end

    expect(response.status).to eq(200)
    expect(response.body).to eq(%(auth=nil host="127.0.0.1:#{@port_b}"))
  end

  it 'resends a rewindable streaming body after a 307' do
    body = StringIO.new('live-stream')
    response = connection(@port_a).post('/keep/1', body) do |req|
      req.headers['Content-Length'] = '11'
    end

    expect(response.status).to eq(200)
    expect(response.body).to eq('POST /echo live-stream')
  end

  it 'refuses to send a body that can only be read once a second time' do
    one_shot = Class.new do
      def initialize(content)
        @io = StringIO.new(content)
      end

      def read(*args)
        @io.read(*args)
      end
    end.new('one shot')

    expect do
      connection(@port_a).post('/keep/1', one_shot) do |req|
        req.headers['Content-Length'] = '8'
      end
    end.to raise_error(Faraday::Response::FollowRedirects::NonReplayableBodyError, /cannot be replayed/)
  end
end
