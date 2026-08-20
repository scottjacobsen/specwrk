# frozen_string_literal: true

require "specwrk/store/base"

module Specwrk
  class BucketStore < Store
    EXAMPLES_KEY = :____examples
    EXAMPLE_COUNT_KEY = :____example_count

    def examples=(val)
      @examples = nil

      if val.nil? || val.length.zero?
        self[EXAMPLES_KEY] = nil
        self[EXAMPLE_COUNT_KEY] = nil
      else
        merge!(self.class.payload_for(val))
      end
    end

    # The fields #examples= writes, for callers filling many buckets in one
    # batch (PendingStore#merge!) that never build a BucketStore per bucket.
    # Keeps a bucket's on-the-wire shape defined in one place.
    def self.payload_for(examples)
      {EXAMPLES_KEY => examples, EXAMPLE_COUNT_KEY => examples.length}
    end

    def examples
      @examples ||= self[EXAMPLES_KEY] || []
    end

    # Written alongside the payload so an observer (e.g. /metrics) can count
    # a bucket's examples with one small field read instead of pulling the
    # whole serialized examples array. The fallback covers buckets written
    # before this field existed.
    def example_count
      self[EXAMPLE_COUNT_KEY] || examples.length
    end

    def clear
      @examples = nil
      super
    end

    def reload
      @examples = nil
      super
    end
  end
end
