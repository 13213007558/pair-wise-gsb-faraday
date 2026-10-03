# frozen_string_literal: true

module Faraday
  module OData
    # An OData atomicity group, encoded as a nested multipart change set.
    class ChangeSet
      attr_reader :requests

      # @param requests [Array<Hash, Request>] data modification requests
      def initialize(requests = [])
        @requests = requests.map { |request| Request.from(request) }
      end

      # @param value [Hash, ChangeSet] change set description
      # @return [ChangeSet]
      def self.from(value)
        return value.dup if value.is_a?(self)

        unless value.is_a?(Hash)
          raise ValidationError, "unsupported OData change set: #{value.inspect}"
        end

        hash = value.transform_keys(&:to_s)
        key = hash.key?('changeset') ? 'changeset' : 'change_set'
        requests = hash.fetch(key) { raise ValidationError, 'missing OData changeset requests' }
        new(Array(requests))
      end
    end
  end
end
