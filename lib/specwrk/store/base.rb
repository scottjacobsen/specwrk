# frozen_string_literal: true

require "uri"

module Specwrk
  class Store
    class << self
      def with_lock(uri, key)
        adapter_klass(uri).with_lock(uri, key) { yield }
      end

      def adapter_klass(uri)
        case uri.scheme
        when "memory"
          require "specwrk/store/memory_adapter" unless defined?(MemoryAdapter)

          MemoryAdapter
        when "file"
          require "specwrk/store/file_adapter" unless defined?(FileAdapter)

          FileAdapter
        when /redis/
          begin
            require "specwrk/store/redis_adapter" unless defined?(RedisAdapter)
          rescue LoadError
            warn "Unable use RedisAdapter with #{uri}, gem not found. Add `gem 'specwrk-store-redis_adapter'` to your Gemfile and bundle install."
            exit(1)
          end

          RedisAdapter
        end
      end
    end

    def initialize(uri_string, scope, ttl: nil)
      @uri = URI(uri_string)
      @scope = scope
      @ttl = ttl
    end

    def [](key)
      adapter[key.to_s]
    end

    def multi_read(*keys)
      adapter.multi_read(*keys)
    end

    def []=(key, value)
      adapter[key.to_s] = value
    end

    def keys
      all_keys = adapter.keys

      all_keys.reject { |k| k.start_with? "____" }
    end

    def length
      keys.length
    end

    # Raw field count, ____internal bookkeeping fields included (unlike
    # #length, which counts only the filtered #keys). Prefers the adapter's
    # cheap count when it has one: on a store with tens of thousands of
    # fields (e.g. run_times), #keys transfers every field name just to
    # count them — too expensive for a per-scrape read path like /metrics.
    # The fallback keeps older adapter gems that predate #size working.
    def size
      return adapter.size if adapter.respond_to?(:size)

      adapter.keys.length
    end

    def any?
      !empty?
    end

    def empty?
      adapter.empty?
    end

    def delete(*keys)
      adapter.delete(*keys)
    end

    def merge!(h2)
      h2.transform_keys!(&:to_s)
      adapter.merge!(h2)
    end

    # Merge into a whole family of sibling stores at once, keyed by scope —
    # one pipelined round trip on adapters that batch, the same sequence of
    # writes as before on those that don't. Scopes are absolute, as built by
    # PendingStore#bucket_scope.
    def multi_scope_write(scoped_hashes)
      adapter.multi_scope_write(
        scoped_hashes.transform_values { |hash| hash.transform_keys(&:to_s) }
      )
    end

    # Read from a whole family of sibling stores at once, given
    # { scope => [key, ...] } and answering { scope => { key => value } } —
    # one pipelined round trip on adapters that batch, the same sequence of
    # reads as before on those that don't. Keys are stringified like #[] does,
    # so a symbol reads the same field a symbol wrote.
    def multi_scope_read(scoped_keys)
      adapter.multi_scope_read(
        scoped_keys.transform_values { |read_keys| read_keys.map(&:to_s) }
      )
    end

    # #clear for a whole family of sibling stores.
    def multi_scope_clear(scopes)
      adapter.multi_scope_clear(scopes)
    end

    def clear
      adapter.clear
    end

    def to_h
      multi_read(*keys).transform_keys!(&:to_sym)
    end

    def inspect
      reload.to_h.dup
    end

    # Bypass any cached values. Helpful when you have two instances
    # of the same store where one mutates data and the other needs to check
    # on the status of that data (i.e. endpoint tests)
    def reload
      @adapter = nil
      self
    end

    private

    attr_reader :uri, :scope, :ttl

    # The ttl is assigned after construction rather than passed to the
    # constructor so every adapter keeps the shared (uri, scope) signature,
    # and guarded because released adapter gems may predate ttl support —
    # stores on such adapters simply never expire, as before.
    def adapter
      @adapter ||= self.class.adapter_klass(uri).new(uri, scope).tap do |instance|
        instance.ttl = ttl if ttl && instance.respond_to?(:ttl=)
      end
    end
  end
end
