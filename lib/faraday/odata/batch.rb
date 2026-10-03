# frozen_string_literal: true

module Faraday
  module OData
    # An ordered OData 4.01 batch described with plain Ruby objects.
    # Items are either {Operation} queries or {ChangeSet} groups.
    #
    # Call {#validate!} (done automatically by {BatchEncoder}) to check
    # the batch before anything is sent.
    class Batch
      # @return [Array<Operation, ChangeSet>]
      attr_reader :items

      def initialize(items = [])
        @items = items
      end

      # @return [Array<Operation>] top-level (non change set) operations.
      def operations
        items.grep(Operation)
      end

      # @return [Array<ChangeSet>]
      def change_sets
        items.grep(ChangeSet)
      end

      # @return [Array<Operation>] every operation, including change set members.
      def all_operations
        items.flat_map { |item| item.is_a?(ChangeSet) ? item.operations : [item] }
      end

      # Validates the batch description against the OData 4.01 rules this
      # library enforces:
      #
      # * Content-IDs are unique across the whole batch.
      # * Every change set operation carries a Content-ID.
      # * "$n" references only appear inside change sets and only point
      #   to Content-IDs of preceding operations of the same change set.
      #
      # @raise [ValidationError] when any rule is violated.
      # @return [self]
      def validate!
        validate_content_id_uniqueness!
        validate_change_set_content_ids!
        validate_references!
        self
      end

      private

      def validate_content_id_uniqueness!
        seen = {}
        all_operations.each do |operation|
          id = operation.content_id
          next unless id

          raise ValidationError, "duplicate Content-ID #{id.inspect} in batch" if seen[id]

          seen[id] = true
        end
      end

      def validate_change_set_content_ids!
        change_sets.each do |change_set|
          change_set.operations.each do |operation|
            next if operation.content_id

            raise ValidationError,
                  "change set operation #{operation.method} #{operation.url} is missing a Content-ID"
          end
        end
      end

      def validate_references!
        operations.each do |operation|
          next if operation.references.empty?

          raise ValidationError,
                "#{operation.method} #{operation.url} uses $n references outside a change set"
        end

        change_sets.each do |change_set|
          preceding = []
          change_set.operations.each do |operation|
            unknown = operation.references - preceding
            unless unknown.empty?
              raise ValidationError,
                    "#{operation.method} #{operation.url} references " \
                    "#{unknown.join(', ')} which is not a preceding operation " \
                    'of the same change set'
            end
            preceding << operation.content_id
          end
        end
      end
    end
  end
end
