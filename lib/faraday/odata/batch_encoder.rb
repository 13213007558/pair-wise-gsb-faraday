# frozen_string_literal: true

module Faraday
  module OData
    # Validates and serializes Ruby batch descriptions as OData 4.01
    # multipart/mixed request bodies.
    class BatchEncoder
      HEADER_VALUE = /[\r\n]/n.freeze
      CONTENT_ID = %r{\A[A-Za-z0-9!#$%&'*+.^_`|~=-]+\z}.freeze
      REFERENCE = %r{\A\$([A-Za-z0-9!#$%&'*+.^_`|~=-]+)(?:[/?#]|\z)}.freeze
      SYSTEM_PATHS = %w[$batch $metadata $crossjoin $all $entity $ref $count $value $root $filter $each].freeze

      attr_reader :boundary, :change_set_boundary, :odata_version

      # @param boundary [String, nil] outer multipart boundary
      # @param change_set_boundary [String, nil] prefix/template for nested
      #   boundaries
      # @param odata_version [String] OData-Version header value
      def initialize(boundary: nil, change_set_boundary: nil, odata_version: OData::VERSION)
        @boundary = boundary || "batch_#{SecureRandom.hex(16)}"
        @change_set_boundary = change_set_boundary || "changeset_#{SecureRandom.hex(12)}"
        @odata_version = odata_version
      end

      # @param operations [Array] batch description
      # @return [EncodedBatch] complete multipart request representation
      def encode(operations)
        parts = normalize(Array(operations))
        validate(parts)

        encoded_parts = parts.each_with_index.map { |part, index| encode_part(part, index) }
        body = encode_multipart(@boundary, encoded_parts)
        headers = {
          'Content-Type' => "#{OData::BATCH_CONTENT_TYPE}; boundary=#{@boundary}",
          'OData-Version' => odata_version,
          'MIME-Version' => '1.0'
        }
        EncodedBatch.new(body: body.b, headers: headers, boundary: @boundary, parts: parts)
      end

      private

      def normalize(parts)
        raise ValidationError, 'OData batch must contain at least one operation' if parts.empty?

        parts.map do |part|
          if change_set?(part)
            change_set = ChangeSet.from(part)
            change_set.dup
          else
            Request.from(part)
          end
        end
      end

      def change_set?(part)
        return true if part.is_a?(ChangeSet)

        part.is_a?(Hash) && (part.key?(:changeset) || part.key?('changeset') ||
          part.key?(:change_set) || part.key?('change_set'))
      end

      def validate(parts)
        errors = []
        assign_content_ids(parts, errors)
        validate_parts(parts, errors)
        return if errors.empty?

        raise ValidationError, "invalid OData batch: #{errors.join('; ')}"
      end

      def assign_content_ids(parts, errors)
        explicit_ids = {}
        each_request(parts) do |request, _change_set|
          next if request.content_id.nil?

          validate_content_id(request.content_id, errors)
          explicit_ids[request.content_id] = true
        end

        next_id = 1
        each_request(parts) do |request, change_set|
          if change_set && request.content_id.nil?
            next_id += 1 while explicit_ids.key?(next_id.to_s)
            request.instance_variable_set(:@content_id, next_id.to_s)
            explicit_ids[request.content_id] = true
            next_id += 1
          end
        end
      end

      def validate_parts(parts, errors)
        validate_boundary(@boundary, 'batch boundary', errors)
        seen = {}
        nested_boundaries = {}

        parts.each_with_index do |part, index|
          next unless part.is_a?(ChangeSet)

          boundary = nested_boundary(index)
          if nested_boundaries.key?(boundary) || boundary == @boundary
            errors << "change set #{index} boundary must be unique"
          else
            nested_boundaries[boundary] = true
            validate_boundary(boundary, "change set #{index} boundary", errors)
          end
        end

        parts.each_with_index do |part, part_index|
          if part.is_a?(ChangeSet)
            validate_change_set(part, part_index, seen, errors)
          else
            validate_request(part, "operation #{part_index}", seen, errors)
          end
        end

        validate_references(parts, errors)
      end

      def validate_change_set(change_set, index, seen, errors)
        location = "change set #{index}"
        if change_set.requests.empty?
          errors << "#{location} must contain at least one operation"
          return
        end

        change_set.requests.each_with_index do |request, request_index|
          unless request.change?
            errors << "#{location} operation #{request_index} must be POST, PUT, PATCH, or DELETE"
          end
          validate_request(request, "#{location} operation #{request_index}", seen, errors)
        end
      end

      def validate_request(request, location, seen, errors)
        unless Request::VALID_METHODS.include?(request.method)
          errors << "#{location} has unsupported HTTP method #{request.method.upcase}"
        end
        if request.url.strip.empty?
          errors << "#{location} is missing a URL"
        elsif request.url.match?(HEADER_VALUE)
          errors << "#{location} URL must not contain CR or LF"
        end

        request.headers.each do |name, value|
          if name.to_s.match?(HEADER_VALUE) || value.to_s.match?(HEADER_VALUE)
            errors << "#{location} headers must not contain CR or LF"
          end
        end

        header_content_id = request.headers.keys.find { |name| name.casecmp?('Content-ID') }
        if header_content_id && request.headers[header_content_id].to_s != request.content_id
          errors << "#{location} header Content-ID does not match its operation Content-ID"
        end

        return unless request.content_id

        validate_content_id(request.content_id, errors)
        if seen.key?(request.content_id)
          errors << "duplicate Content-ID #{request.content_id.inspect}"
        else
          seen[request.content_id] = true
        end
      end

      def validate_references(parts, errors)
        targets = reference_targets(parts)
        parts.each_with_index do |part, part_index|
          next unless part.is_a?(ChangeSet)

          part.requests.each_with_index do |request, request_index|
            reference_id = extract_reference(request.url)
            next unless reference_id

            target = targets[reference_id]
            if target.nil?
              message = "references unknown Content-ID #{reference_id.inspect}"
              errors << "#{location(part_index, request_index)} #{message}"
            elsif target[:change_set] != part_index
              errors << "#{location(part_index, request_index)} references an operation outside its change set"
            elsif target[:index].nil? || target[:index] >= request_index
              message = "references a later Content-ID #{reference_id.inspect}"
              errors << "#{location(part_index, request_index)} #{message}"
            elsif target[:request].method != :post
              message = "references a non-creating Content-ID #{reference_id.inspect}"
              errors << "#{location(part_index, request_index)} #{message}"
            end
          end
        end
      end

      def reference_targets(parts)
        targets = {}
        parts.each_with_index do |part, part_index|
          if part.is_a?(ChangeSet)
            part.requests.each_with_index do |request, request_index|
              next unless request.content_id

              targets[request.content_id] = {
                change_set: part_index,
                index: request_index,
                request: request
              }
            end
          else
            next unless part.content_id

            targets[part.content_id] = {
              change_set: nil,
              index: nil,
              request: part
            }
          end
        end
        targets
      end

      def extract_reference(url)
        return nil unless url.start_with?('$')
        system_path = SYSTEM_PATHS.any? do |path|
          url == path || url.start_with?("#{path}/") || url.start_with?("#{path}?")
        end
        return nil if system_path
        return nil unless (match = url.match(REFERENCE))

        match[1]
      end

      def validate_content_id(id, errors)
        return if id&.match?(CONTENT_ID) && !id.start_with?('$')

        errors << "Content-ID #{id.inspect} must be a non-empty token without whitespace or '$' prefix"
      end

      def validate_boundary(value, label, errors)
        if value.nil? || value.empty? || value.bytesize > 70 || value.match?(/[\s"\\]/) || value == '--'
          errors << "#{label} is invalid"
        end
      end

      def encode_part(part, index)
        case part
        when ChangeSet
          boundary = nested_boundary(index)
          body = encode_multipart(boundary, part.requests.map { |request| encode_operation(request) })
          headers = { 'Content-Type' => "#{OData::BATCH_CONTENT_TYPE}; boundary=#{boundary}" }
          [headers, body]
        else
          [operation_mime_headers, encode_operation(part).last]
        end
      end

      def nested_boundary(index)
        "#{change_set_boundary}_#{index + 1}"
      end

      def encode_operation(request)
        headers = Faraday::Utils::Headers.new
        body = encode_body(request.body)
        headers['Content-Type'] = 'application/json' if structured_body?(request.body) && body
        headers.update(request.headers)
        headers['Content-Length'] = body.bytesize if body
        headers['Content-ID'] = request.content_id if request.content_id

        text = +"#{request.method.upcase} #{request.url} HTTP/1.1#{OData::CRLF}"
        headers.each { |name, value| text << "#{name}: #{value}#{OData::CRLF}" }
        text << OData::CRLF
        text.force_encoding(Encoding::BINARY)
        text << body if body
        [operation_mime_headers, text]
      end

      def operation_mime_headers
        {
          'Content-Type' => OData::HTTP_CONTENT_TYPE,
          'Content-Transfer-Encoding' => OData::BINARY_ENCODING
        }
      end

      def encode_body(body)
        return nil if body.nil?

        bytes =
          case body
          when String then body.dup
          when Hash, Array then JSON.generate(body)
          when IO, StringIO then body.read
          else body.to_s
          end
        bytes.b
      end

      def structured_body?(body)
        body.is_a?(Hash) || body.is_a?(Array)
      end

      def encode_multipart(boundary, encoded_parts)
        text = encoded_parts.map do |headers, body|
          part = +"--#{boundary}#{OData::CRLF}"
          headers.each { |name, value| part << "#{name}: #{value}#{OData::CRLF}" }
          part << OData::CRLF
          part.force_encoding(Encoding::BINARY)
          part << body.to_s.b
          part
        end.join(OData::CRLF)
        "#{text}#{OData::CRLF}--#{boundary}--#{OData::CRLF}".b
      end

      def each_request(parts)
        parts.each_with_index do |part, part_index|
          if part.is_a?(ChangeSet)
            part.requests.each { |request| yield(request, part_index) }
          else
            yield(part, nil)
          end
        end
      end

      def location(change_set, request)
        "change set #{change_set} operation #{request}"
      end
    end
  end
end
