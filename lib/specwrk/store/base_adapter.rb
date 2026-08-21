# frozen_string_literal: true

require "uri"

require "specwrk/store"
require "specwrk/store/serializer"

module Specwrk
  class Store
    class BaseAdapter
      class << self
        def with_lock(_uri, _key)
          yield
        end

        def serializer
          @serializer ||= Serializer.resolve
        end

        def reset_serializer!
          @serializer = nil
        end
      end

      def initialize(uri, scope)
        @uri = uri
        @scope = scope
      end

      def [](key)
        raise "Not implemented"
      end

      def []=(key, value)
        raise "Not implemented"
      end

      def keys
        raise "Not implemented"
      end

      def clear
        raise "Not implemented"
      end

      def delete(*keys)
        raise "Not implemented"
      end

      def merge!(h2)
        raise "Not implemented"
      end

      def multi_read(*read_keys)
        raise "Not implemented"
      end

      def multi_write(hash)
        raise "Not implemented"
      end

      # Write several scopes at once, given { scope => { key => value } }.
      # Unlike the rest of this class these have a working default rather
      # than raising: an adapter with no way to batch is still correct doing
      # the writes one at a time, which is exactly what it did before the
      # batch call existed. Adapters that can do better override — the Redis
      # one collapses the whole set into a single pipelined round trip, which
      # is the point of the call for the thousands of buckets a seed writes.
      def multi_scope_write(scoped_hashes)
        scoped_hashes.each { |other_scope, hash| adapter_for(other_scope).multi_write(hash) }

        nil
      end

      # Read fields from several scopes at once, given { scope => [key, ...] }
      # and answering { scope => { key => value } }. Same default-and-override
      # story as multi_scope_write: correct one scope at a time, one pipelined
      # round trip on the Redis adapter — which is the point of the call for
      # the per-bucket counts a metrics scrape sums.
      def multi_scope_read(scoped_keys)
        scoped_keys.to_h do |other_scope, read_keys|
          [other_scope, adapter_for(other_scope).multi_read(*read_keys)]
        end
      end

      # Bulk #clear across scopes; same default-and-override story.
      def multi_scope_clear(scopes)
        scopes.each { |other_scope| adapter_for(other_scope).clear }

        nil
      end

      def empty?
        raise "Not implemented"
      end

      private

      attr_reader :uri, :scope

      # A sibling adapter on the same backing store, carrying this one's ttl
      # so batched writes expire like their single-scope equivalents. The ttl
      # accessor is guarded because BaseAdapter itself declares none.
      def adapter_for(other_scope)
        return self if other_scope == @scope

        self.class.new(uri, other_scope).tap do |instance|
          instance.ttl = ttl if respond_to?(:ttl) && instance.respond_to?(:ttl=)
        end
      end
    end
  end
end
