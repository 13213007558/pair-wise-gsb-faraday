# frozen_string_literal: true

module Faraday
  class Adapter
    # Test adapter with named scenario support; see Stubs#scenario.
    class Test < Faraday::Adapter
      # Reopened to attach its nested class; see Scenario.
      class Scenario
        # A single request/response pair accepted by a state.
        class Step
          CAPTURE_PATTERN = /\{(\w+)\}/

          attr_reader :method, :transition, :name, :block

          def initialize(method, path, to:, name:, &block)
            @method = method.to_sym
            @transition = to&.to_sym
            @name = name || "#{method.to_s.upcase} #{path}"
            @block = block
            @matcher = build_matcher(path)
          end

          # @return [Hash, nil] the match meta when the request is
          #   acceptable for the given session (or any session when nil)
          def matches?(env, session)
            return nil unless env[:method] == @method

            matched, meta = @matcher.matches?(env)
            return nil unless matched

            captures = meta[:match_data] ? meta[:match_data].named_captures : {}
            if session
              captures.each do |key, value|
                known = session.captures[key.to_sym]
                return nil if session.captures.key?(key.to_sym) && known != value
              end
            end
            meta
          end

          private

          def build_matcher(path)
            host = nil
            query = nil
            if path.is_a?(Regexp)
              matcher_path = path
            elsif path.include?('{')
              template, query = path.split('?', 2)
              matcher_path = compile_template(template)
            else
              normalized = Faraday::Utils.normalize_path(path)
              host = Faraday::Utils.URI(path).host
              matcher_path, query = normalized.split('?')
            end
            Stub.new(host, matcher_path, query, Utils::Headers.new, nil, false, nil)
          end

          def compile_template(template)
            pattern = +'\\A'
            rest = template
            while (match = CAPTURE_PATTERN.match(rest))
              pattern << Regexp.escape(match.pre_match) << "(?<#{match[1]}>[^/?]+)"
              rest = match.post_match
            end
            Regexp.new("#{pattern}#{Regexp.escape(rest)}\\z")
          end
        end
      end
    end
  end
end

