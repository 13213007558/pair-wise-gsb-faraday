# frozen_string_literal: true

require 'timeout'
require 'securerandom'

module Faraday
  class Adapter
    # @example
    #   test = Faraday::Connection.new do
    #     use Faraday::Adapter::Test do |stub|
    #       # Define matcher to match the request
    #       stub.get '/resource.json' do
    #         # return static content
    #         [200, {'Content-Type' => 'application/json'}, 'hi world']
    #       end
    #
    #       # response with content generated based on request
    #       stub.get '/showget' do |env|
    #         [200, {'Content-Type' => 'text/plain'}, env[:method].to_s]
    #       end
    #
    #       # A regular expression can be used as matching filter
    #       stub.get /\A\/items\/(\d+)\z/ do |env, meta|
    #         # in case regular expression is used, an instance of MatchData
    #         # can be received
    #         [200,
    #          {'Content-Type' => 'text/plain'},
    #          "showing item: #{meta[:match_data][1]}"
    #         ]
    #       end
    #
    #      # Test the request body is the same as the stubbed body
    #      stub.post('/bar', 'name=YK&word=call') { [200, {}, ''] }
    #
    #      # You can pass a proc as a stubbed body and check the request body in your way.
    #      # In this case, the proc should return true or false.
    #      stub.post('/foo', ->(request_body) do
    #        JSON.parse(request_body).slice('name') == { 'name' => 'YK' } }) { [200, {}, '']
    #      end
    #
    #       # You can set strict_mode to exactly match the stubbed requests.
    #       stub.strict_mode = true
    #     end
    #   end
    #
    #   resp = test.get '/resource.json'
    #   resp.body # => 'hi world'
    #
    #   resp = test.get '/showget'
    #   resp.body # => 'get'
    #
    #   resp = test.get '/items/1'
    #   resp.body # => 'showing item: 1'
    #
    #   resp = test.get '/items/2'
    #   resp.body # => 'showing item: 2'
    #
    #   resp = test.post '/bar', 'name=YK&word=call'
    #   resp.status # => 200
    #
    #   resp = test.post '/foo', JSON.dump(name: 'YK', created_at: Time.now)
    #   resp.status # => 200
    class Test < Faraday::Adapter
      attr_accessor :stubs

      # A stack of Stubs
      class Stubs
        class NotFound < StandardError
        end

        class InvalidScenarioStep < NotFound
        end

        class ScenarioCreationFailed < NotFound
        end

        def initialize(strict_mode: false)
          # { get: [Stub, Stub] }
          @stack = {}
          @consumed = {}
          @scenarios = []
          @strict_mode = strict_mode
          @stubs_mutex = Monitor.new
          yield(self) if block_given?
        end

        def empty?
          @stack.empty? && @scenarios.empty?
        end

        # @param env [Faraday::Env]
        def match(env)
          request_method = env[:method]

          @stubs_mutex.synchronize do
            lifecycle_error = nil
            @scenarios.each do |scenario|
              begin
                request = scenario.match(env)
                return request if request
              rescue InvalidScenarioStep, ScenarioCreationFailed => error
                lifecycle_error ||= error
              end
            end
            raise lifecycle_error if lifecycle_error
          end

          return false unless @stack.key?(request_method)

          stack = @stack[request_method]
          consumed = (@consumed[request_method] ||= [])

          @stubs_mutex.synchronize do
            stub, meta = matches?(stack, env)
            if stub
              removed = stack.delete(stub)
              consumed << removed unless removed.nil?
              return stub, meta
            end
          end
          matches?(consumed, env)
        end

        def get(path, headers = {}, &block)
          new_stub(:get, path, headers, &block)
        end

        def head(path, headers = {}, &block)
          new_stub(:head, path, headers, &block)
        end

        def post(path, body = nil, headers = {}, &block)
          new_stub(:post, path, headers, body, &block)
        end

        def put(path, body = nil, headers = {}, &block)
          new_stub(:put, path, headers, body, &block)
        end

        def patch(path, body = nil, headers = {}, &block)
          new_stub(:patch, path, headers, body, &block)
        end

        def delete(path, headers = {}, &block)
          new_stub(:delete, path, headers, &block)
        end

        def options(path, headers = {}, &block)
          new_stub(:options, path, headers, &block)
        end

        def scenario(name, initial_state: :new, &block)
          scenario = Scenario.new(name, initial_state: initial_state,
                                  strict_mode: @strict_mode, &block)
          @scenarios << scenario
          scenario
        end

        # Removes all stubs, including the ones that have already been consumed.
        def clear
          @stubs_mutex.synchronize do
            @stack.clear
            @consumed.clear
            @scenarios.clear
          end
        end

        # Raises an error if any of the stubbed calls have not been made.
        def verify_stubbed_calls
          failed_stubs = []
          @stack.each do |method, stubs|
            next if stubs.empty?

            failed_stubs.concat(
              stubs.map do |stub|
                "Expected #{method} #{stub}."
              end
            )
          end
          raise failed_stubs.join(' ') unless failed_stubs.empty?
        end

        # Set strict_mode. If the value is true, this adapter tries to find matched requests strictly,
        # which means that all of a path, parameters, and headers must be the same as an actual request.
        def strict_mode=(value)
          @strict_mode = value
          @stack.each_value do |stubs|
            stubs.each do |stub|
              stub.strict_mode = value
            end
          end
          @scenarios.each { |scenario| scenario.strict_mode = value }
        end

        protected

        def new_stub(request_method, path, headers = {}, body = nil, &block)
          normalized_path, host =
            if path.is_a?(Regexp)
              path
            else
              [
                Faraday::Utils.normalize_path(path),
                Faraday::Utils.URI(path).host
              ]
            end
          path, query = normalized_path.respond_to?(:split) ? normalized_path.split('?') : normalized_path
          headers = Utils::Headers.new(headers)

          stub = Stub.new(host, path, query, headers, body, @strict_mode, block)
          (@stack[request_method] ||= []) << stub
        end

        # @param stack [Hash]
        # @param env [Faraday::Env]
        def matches?(stack, env)
          stack.each do |stub|
            match_result, meta = stub.matches?(env)
            return stub, meta if match_result
          end
          nil
        end
      end

      # Stateful sequence of requests for create/poll/delete style SDK flows.
      class Scenario
        Request = Struct.new(:name, :method, :path, :display_path, :query,
                             :headers, :body, :host, :state, :to,
                             :creates_session, :id_block, :strict_mode,
                             :block, keyword_init: true) do
          def matches?(env)
            matched, meta = Stub.new(host, path, query, Utils::Headers.new(headers), body,
                                    strict_mode, nil).matches?(env)
            [method == env[:method] && matched, meta]
          end
        end

        Session = Struct.new(:id, :state, :data, :attempts, :creation_failed,
                             keyword_init: true) do
          def initialize(*arguments)
            super
            self.data ||= {}
            self.attempts ||= Hash.new(0)
            self.creation_failed ||= false
          end

          def attempts_for(request)
            attempts[request]
          end
        end

        class StateBuilder
          def initialize(scenario, state)
            @scenario = scenario
            @state = state
          end

          def get(path, headers = {}, **options, &block)
            add(:get, path, nil, headers, **options, &block)
          end

          def head(path, headers = {}, **options, &block)
            add(:head, path, nil, headers, **options, &block)
          end

          def post(path, body = nil, headers = {}, **options, &block)
            add(:post, path, body, headers, **options, &block)
          end

          def put(path, body = nil, headers = {}, **options, &block)
            add(:put, path, body, headers, **options, &block)
          end

          def patch(path, body = nil, headers = {}, **options, &block)
            add(:patch, path, body, headers, **options, &block)
          end

          def delete(path, headers = {}, **options, &block)
            add(:delete, path, nil, headers, **options, &block)
          end

          def options(path, headers = {}, **options, &block)
            add(:options, path, nil, headers, **options, &block)
          end

          private

          def add(method, path, body, headers, **options, &block)
            @scenario.add_request(method, path, body, headers, @state,
                                  **options, &block)
          end
        end

        attr_reader :name, :requests, :sessions

        def initialize(name, initial_state:, strict_mode: false, &block)
          @name = name
          @initial_state = initial_state
          @strict_mode = strict_mode
          @states = [initial_state]
          @requests = []
          @sessions = {}
          @failed_sessions = []
          @scenario_mutex = Monitor.new
          instance_exec(&block)
        end

        def state(name, &block)
          @states << name unless @states.include?(name)
          StateBuilder.new(self, name).instance_exec(&block)
        end

        %i[get head options delete].each do |method|
          define_method(method) do |path, headers = {}, **options, &block|
            add_request(method, path, nil, headers, @initial_state, **options, &block)
          end
        end

        %i[post put patch].each do |method|
          define_method(method) do |path, body = nil, headers = {}, **options, &block|
            add_request(method, path, body, headers, @initial_state, **options, &block)
          end
        end

        def add_request(method, path, body, headers, state,
                        to: nil, creates_session: state == @initial_state,
                        id: nil, &block)
          host, request_path, display_path, query = compile_path(path)
          @requests << Request.new(
            name: "#{method.to_s.upcase} #{display_path}",
            method: method,
            host: host,
            path: request_path,
            display_path: display_path,
            query: query,
            headers: headers,
            body: body,
            state: state,
            to: to,
            creates_session: creates_session,
            id_block: id,
            strict_mode: @strict_mode,
            block: block
          )
        end

        def match(env)
          @scenario_mutex.synchronize do
            candidates = structural_matches(env)
            return nil if candidates.empty?

            current_candidate = current_state_candidate(candidates, env)
            if current_candidate
              request, session, meta = current_candidate
            else
              request, meta = candidates.first
            end
            session ||= session_for(request, env, meta)
            validate!(request, session, env)
            [ScenarioStub.new(self, request, session, meta), meta]
          end
        end

        def invoke(request, session, env, meta)
          @scenario_mutex.synchronize do
            session.attempts[request] += 1
            arguments = block_arguments(request, session, env, meta)
            response = request.block.call(*arguments)
            original_id = session.id
            target = target_state(request, session)
            handle_response(request, session, response, target)
            rekey_session(session, original_id) if session.id != original_id
            response
          rescue StandardError => error
            @failed_sessions << session if request.creates_session
            session.data[:creation_error] = error
            raise
          end
        end

        # Returns the current state of a session, or the only session when no ID is given.
        def session_state(id = nil)
          session = id ? @sessions[id] : @sessions.values.first
          session&.state
        end

        def strict_mode=(value)
          @strict_mode = value
          @requests.each { |request| request.strict_mode = value }
        end

        private

        def structural_matches(env)
          @requests.each_with_object([]) do |request, matches|
            matched, meta = request.matches?(env)
            matches << [request, meta] if matched
          end
        end

        def current_state_candidate(candidates, env)
          candidates.each do |request, meta|
            next unless request.creates_session || extract_id(request, env, meta)

            session = session_for(request, env, meta)
            return request, session, meta if session&.state == request.state
          end
          nil
        end

        def session_for(request, env, meta)
          if request.creates_session
            id = extract_id(request, env, meta)
            id ||= SecureRandom.hex(4)
            return @sessions[id] if @sessions[id]&.state == @initial_state

            Session.new(id: id, state: @initial_state)
          else
            id = extract_id(request, env, meta)
            return @sessions[id] if id && @sessions.key?(id)
            return @sessions.values.first if id.nil? && @sessions.one?

            nil
          end
        end

        def validate!(request, session, env)
          raise creation_failed_error(env) if !request.creates_session && session&.creation_failed

          if session.nil?
            if @failed_sessions.any?
              raise creation_failed_error(env)
            end

            raise missing_session_error(request, env)
          end

          return if session.state == request.state

          raise invalid_step_error(request, session, env)
        end

        def handle_response(request, session, response, target)
          status = response.is_a?(Array) ? response.first : nil
          if status.is_a?(Integer) && status.between?(200, 299)
            commit_success(request, session, response, target)
          elsif status.is_a?(Integer) && request.creates_session
            mark_creation_failed(session, response)
          end
        end

        def commit_success(request, session, response, target)
          session.creation_failed = false
          body = response.is_a?(Array) ? response.last : nil
          session.id = body[:session_id] || body[:id] || session.id if body.is_a?(Hash)
          @sessions[session.id] = session
          @failed_sessions.delete(session)
          unless target.nil? || target == :same || @states.include?(target)
            raise Stubs::InvalidScenarioStep, "unknown scenario state #{target.inspect}"
          end
          session.state = target unless target.nil? || target == :same
        end

        def rekey_session(session, original_id)
          @sessions.delete(original_id)
          @sessions[session.id] = session
        end

        def mark_creation_failed(session, response)
          session.creation_failed = true
          session.data[:creation_error] = response
          @sessions[session.id] = session
          @failed_sessions << session unless @failed_sessions.include?(session)
        end

        def target_state(request, session)
          target = request.to
          if target.respond_to?(:call)
            arity = target.lambda? ? target.arity : target.arity.abs
            arguments = [session, session.attempts_for(request)].take([arity, 1].max)
            target = target.call(*arguments)
          end
          target
        end

        def block_arguments(request, session, env, meta)
          arity = request.block.arity
          arity = 3 if arity.negative?
          [env, session, meta].take(arity)
        end

        def extract_id(request, env, meta)
          return request.id_block.call(env, meta) if request.id_block

          captures = meta[:match_data]&.named_captures
          captures&.values&.compact&.first
        end

        def compile_path(path)
          if path.is_a?(Regexp)
            [nil, path, path.inspect, nil]
          else
            normalized = Faraday::Utils.normalize_path(path)
            host = Faraday::Utils.URI(path).host
            path_part, query = normalized.split('?')
            [host, compile_pattern(path_part), path_part, query]
          end
        end

        def compile_pattern(path)
          source = path.split('/').map do |segment|
            if segment.start_with?(':')
              name = segment[1..]
              "(?<#{name}>[^/?#]+)"
            else
              Regexp.escape(segment)
            end
          end
          %r{\A#{source.join('/')}\z}
        end

        def missing_session_error(request, env)
          expected = @requests.select { |item| item.state == @initial_state }
          Stubs::InvalidScenarioStep.new(
            "scenario #{name.inspect}: #{env.method.upcase} #{env.url.path} was " \
            "received before a resource was created. Expected one of: " \
            "#{expected.map(&:name).join(', ')}."
          )
        end

        def creation_failed_error(env)
          session = @failed_sessions.last
          response = session.data[:creation_error]
          detail = error_detail(response)
          Stubs::ScenarioCreationFailed.new(
            "scenario #{name.inspect}: #{env.method.upcase} #{env.url.path} was " \
            "received after resource creation failed with #{detail}. Create the " \
            "resource successfully before polling it."
          )
        end

        def error_detail(error)
          case error
          when Array then "status #{error.first}"
          when Exception then "#{error.class}: #{error.message}"
          else 'an error'
          end
        end

        def invalid_step_error(request, session, env)
          allowed = @requests.select { |item| item.state == session.state }
          Stubs::InvalidScenarioStep.new(
            "scenario #{name.inspect}: #{env.method.upcase} #{env.url.path} is not " \
            "allowed while the session is in state #{session.state.inspect}. " \
            "Allowed requests in this state: #{allowed.map(&:name).join(', ')}."
          )
        end

        # Adapter-facing stub backed by a scenario request and session.
        ScenarioStub = Struct.new(:scenario, :request, :session, :meta) do
          def block
            proc do |env, _call_meta|
              scenario.invoke(request, session, env, meta)
            end
          end
        end
      end

      # Stub request
      Stub = Struct.new(:host, :path, :query, :headers, :body, :strict_mode, :block) do
        # @param env [Faraday::Env]
        def matches?(env)
          request_host = env[:url].host
          request_path = Faraday::Utils.normalize_path(env[:url].path)
          request_headers = env.request_headers
          request_body = env[:body]

          # meta is a hash used as carrier
          # that will be yielded to consumer block
          meta = {}
          [(host.nil? || host == request_host) &&
            path_match?(request_path, meta) &&
            params_match?(env) &&
            body_match?(request_body) &&
            headers_match?(request_headers), meta]
        end

        def path_match?(request_path, meta)
          if path.is_a?(Regexp)
            !!(meta[:match_data] = path.match(request_path))
          else
            path == request_path
          end
        end

        # @param env [Faraday::Env]
        def params_match?(env)
          request_params = env[:params]
          params = env.params_encoder.decode(query) || {}

          if strict_mode
            return Set.new(params) == Set.new(request_params)
          end

          params.keys.all? do |key|
            request_params[key] == params[key]
          end
        end

        def headers_match?(request_headers)
          if strict_mode
            headers_with_user_agent = headers.dup.tap do |hs|
              # NOTE: Set User-Agent in case it's not set when creating Stubs.
              #       Users would not want to set Faraday's User-Agent explicitly.
              hs[:user_agent] ||= Connection::USER_AGENT
            end
            return Set.new(headers_with_user_agent) == Set.new(request_headers)
          end

          headers.keys.all? do |key|
            request_headers[key] == headers[key]
          end
        end

        def body_match?(request_body)
          return true if body.to_s.empty?

          case body
          when Proc
            body.call(request_body)
          else
            request_body == body
          end
        end

        def to_s
          "#{path} #{body}"
        end
      end

      def initialize(app, stubs = nil, &block)
        super(app)
        @stubs = stubs || Stubs.new
        configure(&block) if block
      end

      def configure
        yield(stubs)
      end

      # @param env [Faraday::Env]
      def call(env)
        super

        env.request.params_encoder ||= Faraday::Utils.default_params_encoder
        env[:params] = env.params_encoder.decode(env[:url].query) || {}
        stub, meta = stubs.match(env)

        unless stub
          raise Stubs::NotFound, "no stubbed request for #{env[:method]} " \
                                 "#{env[:url]} #{env[:body]} #{env[:headers]}"
        end

        block_arity = stub.block.arity
        params = if block_arity >= 0
                   [env, meta].take(block_arity)
                 else
                   [env, meta]
                 end

        timeout = request_timeout(:open, env[:request])
        timeout ||= request_timeout(:read, env[:request])

        status, headers, body =
          if timeout
            ::Timeout.timeout(timeout, Faraday::TimeoutError) do
              stub.block.call(*params)
            end
          else
            stub.block.call(*params)
          end

        # We need to explicitly pass `reason_phrase = nil` here to avoid keyword args conflicts.
        #   See https://github.com/lostisland/faraday/issues/1444
        # TODO: remove `nil` explicit reason_phrase once Ruby 3.0 becomes minimum req. version
        save_response(env, status, body, headers, nil)

        @app.call(env)
      end
    end
  end
end

Faraday::Adapter.register_middleware(test: Faraday::Adapter::Test)
