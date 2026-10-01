# frozen_string_literal: true

RSpec.describe Faraday::Adapter::Test do
  def connection_with_stubs(stubs, extra_middleware = nil)
    Faraday.new do |builder|
      builder.request :url_encoded
      extra_middleware&.call(builder)
      builder.adapter :test, stubs
    end
  end

  def hints_stubs(fail_after: false)
    described_class::Stubs.new do |stub|
      stub.get('/hints') do |_env, _meta, emitter|
        emitter.continue
        emitter.early_hints('Link' => '</style.css>; rel=preload; as=style')
        emitter.early_hints('Link' => '</app.js>; rel=modulepreload')
        emitter.fail! if fail_after
        [200, { 'Content-Type' => 'application/json' }, '{}']
      end
    end
  end

  describe 'informational responses' do
    it 'declares the informational responses capability' do
      expect(described_class.supports_informational_responses?).to be(true)
    end

    it 'delivers 100 and two 103 responses in order before the final 200' do
      events = []
      conn = connection_with_stubs(hints_stubs)

      response = conn.get('/hints') do |req|
        req.options.on_information = proc { |info| events << info }
      end

      expect(events.map(&:status)).to eq([100, 103, 103])
      expect(events.first.status).to eq(100)
      expect(events[1].early_hints?).to be(true)
      expect(events[1]['link']).to include('style.css')
      expect(events[2]['link']).to include('app.js')
      expect(response.status).to eq(200)
      expect(response.informations.map(&:status)).to eq([100, 103, 103])
    end

    it 'provides an independent, immutable snapshot per notification' do
      shared_headers = { 'Link' => '</style.css>; rel=preload' }
      events = []
      stubs = described_class::Stubs.new do |stub|
        stub.get('/hints') do |_env, _meta, emitter|
          emitter.early_hints(shared_headers)
          shared_headers['Link'] = '</mutated.css>'
          emitter.early_hints(shared_headers)
          [200, {}, '']
        end
      end
      conn = connection_with_stubs(stubs)

      conn.get('/hints') do |req|
        req.options.on_information = proc { |info| events << info }
      end

      expect(events[0]['link']).to include('style.css')
      expect(events[1]['link']).to include('mutated.css')
      expect(events[0]).to be_frozen
      expect(events[0].headers).to be_frozen
      expect { events[0].headers['X'] = 'y' }.to raise_error(FrozenError)
      expect(events[0].headers).not_to equal(events[1].headers)
    end

    it 'does not trigger JSON decoding or raise_error for 1xx responses' do
      events = []
      extra = proc do |builder|
        builder.response :raise_error
        builder.response :json
      end
      conn = connection_with_stubs(hints_stubs, extra)

      response = conn.get('/hints') do |req|
        req.options.on_information = proc { |info| events << info }
      end

      expect(events.size).to eq(3)
      expect(events.map(&:class).uniq).to eq([Faraday::Response::Information])
      expect(response.status).to eq(200)
      expect(response.body).to eq({})
    end

    it 'allows middleware to subscribe before the adapter runs' do
      collector = Class.new(Faraday::Middleware) do
        def on_request(env)
          env.response ||= Faraday::Response.new
          env.response.on_information do |info|
            links << [info.status, info.headers['Link']]
          end
        end

        def links
          @links ||= []
        end

        def on_complete(env)
          env[:collected_informations] = links
        end
      end

      conn = Faraday.new do |builder|
        builder.use collector
        builder.adapter :test, hints_stubs
      end

      response = conn.get('/hints')
      expect(response.env[:collected_informations].map(&:first)).to eq([100, 103, 103])
    end

    context 'on a delayed completion path' do
      it 'notifies while the request is still in flight, then finishes' do
        events_gate = Thread::Queue.new
        finish_gate = Thread::Queue.new
        events = []
        stubs = described_class::Stubs.new do |stub|
          stub.get('/hints') do |_env, _meta, emitter|
            emitter.continue
            emitter.early_hints('Link' => '</style.css>; rel=preload')
            emitter.early_hints('Link' => '</app.js>; rel=preload')
            events_gate << :hints_sent
            finish_gate.pop
            [200, {}, 'done']
          end
        end
        conn = connection_with_stubs(stubs)

        thread = Thread.new do
          conn.get('/hints') do |req|
            req.options.on_information = proc { |info| events << info.status }
          end
        end

        expect(events_gate.pop).to eq(:hints_sent)
        expect(events).to eq([100, 103, 103])

        finish_gate << :finish
        response = thread.value
        expect(response.status).to eq(200)
        expect(response.body).to eq('done')
      end
    end

    context 'when the request fails midway' do
      it 'keeps delivered events and raises the failure' do
        events = []
        conn = connection_with_stubs(hints_stubs(fail_after: true))

        expect do
          conn.get('/hints') do |req|
            req.options.on_information = proc { |info| events << info.status }
          end
        end.to raise_error(described_class::Emitter::MidwayFailure)

        expect(events).to eq([100, 103, 103])
      end

      it 'marks the response aborted and rejects late events' do
        response = Faraday::Response.new
        response.information!(100, {})
        error = described_class::Emitter::MidwayFailure.new
        response.abort(error)

        expect(response.aborted?).to be(true)
        expect(response.abort_error).to equal(error)
        expect(response.finished?).to be(false)
        expect(response.status).to be_nil
        expect(response.informations.map(&:status)).to eq([100])
        expect { response.information!(103, {}) }
          .to raise_error(Faraday::Response::LateInformationError)
        expect { response.finish(Faraday::Env.from(status: 200)) }
          .to raise_error(described_class::Emitter::MidwayFailure)
      end
    end

    context 'when an informational callback raises' do
      it 'aborts the request with the callback error' do
        conn = connection_with_stubs(hints_stubs)

        expect do
          conn.get('/hints') do |req|
            req.options.on_information = proc { raise 'callback failure' }
          end
        end.to raise_error(RuntimeError, 'callback failure')
      end
    end

    it 'rejects non-1xx statuses from the emitter' do
      stubs = described_class::Stubs.new do |stub|
        stub.get('/hints') do |_env, _meta, emitter|
          emitter.information(200, {})
        end
      end
      conn = connection_with_stubs(stubs)

      expect { conn.get('/hints') }.to raise_error(ArgumentError, /100-199/)
    end
  end
end
