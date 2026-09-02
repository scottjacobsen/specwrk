# frozen_string_literal: true

require "securerandom"

require "specwrk"
require "specwrk/store/base"
require "specwrk/store/bucket_store"

module Specwrk
  class PendingStore < Store
    RUN_TIME_BUCKET_MAXIMUM_KEY = :____run_time_bucket_maximum
    MAX_RETRIES_KEY = :____max_retries
    BUCKET_IDS_KEY = :____bucket_ids
    BUCKET_RUN_TIME_TARGET_KEY = :____bucket_run_time_target
    FILE_OVERHEAD_KEY = :____file_overhead

    def run_time_bucket_maximum=(val)
      @run_time_bucket_maximum = self[RUN_TIME_BUCKET_MAXIMUM_KEY] = val
    end

    def run_time_bucket_maximum
      @run_time_bucket_maximum ||= self[RUN_TIME_BUCKET_MAXIMUM_KEY]
    end

    # The seed's per-run overrides persist here (not request-local) so the
    # requeue and retry paths regroup with the same values.

    # Target run time (seconds) per bucket under the :file strategy;
    # 0 = one file per bucket. A stored 0 beats a non-zero env value.
    def bucket_run_time_target=(val)
      @bucket_run_time_target = self[BUCKET_RUN_TIME_TARGET_KEY] = val
    end

    def bucket_run_time_target
      @bucket_run_time_target ||= self[BUCKET_RUN_TIME_TARGET_KEY] || ENV.fetch("SPECWRK_SRV_BUCKET_RUN_TIME", "0").to_f
    end

    # Seconds charged per FILE when packing batched buckets, on top of its
    # examples' summed run times. 0 disables the charge, stored or env.
    def file_overhead=(val)
      @file_overhead = self[FILE_OVERHEAD_KEY] = val
    end

    def file_overhead
      @file_overhead ||= self[FILE_OVERHEAD_KEY] || ENV.fetch("SPECWRK_SRV_FILE_OVERHEAD", "0").to_f
    end

    def max_retries=(val)
      @max_retries = self[MAX_RETRIES_KEY] = val
    end

    def max_retries
      @max_retries ||= self[MAX_RETRIES_KEY] || 0
    end

    def bucket_ids=(val)
      @bucket_ids = nil

      self[BUCKET_IDS_KEY] = if val.nil? || val.length.zero?
        nil
      else
        val
      end
    end

    def bucket_ids
      @bucket_ids ||= self[BUCKET_IDS_KEY] || []
    end

    # Total examples still queued, summed from every bucket's stored count in
    # ONE batched read — this is on the metrics scrape path, and a round trip
    # per bucket against a networked store cost tens of seconds. A bucket
    # missing the count field was popped and deleted since bucket_ids was
    # read — genuinely no longer queued — and contributes nothing.
    def example_count
      return 0 if bucket_ids.empty?

      count_key = BucketStore::EXAMPLE_COUNT_KEY.to_s
      counts = multi_scope_read(bucket_ids.to_h { |bucket_id| [bucket_scope(bucket_id), [count_key]] })

      counts.sum { |_bucket_scope, fields| fields[count_key].to_i }
    end

    # Every bucket goes out in one batch — thousands of sequential round
    # trips blocked the whole fleet on a networked store. Bucket ids are
    # written once, after the payloads land, so a reader never sees an id
    # whose bucket is missing.
    def merge!(hash, prepend: false)
      return self if hash.nil? || hash.empty?

      new_bucket_ids = []
      payloads = grouped_examples(hash.values).to_h do |examples|
        bucket_id = SecureRandom.uuid
        new_bucket_ids << bucket_id

        [bucket_scope(bucket_id), BucketStore.payload_for(examples)]
      end

      multi_scope_write(payloads)

      self.bucket_ids = prepend ? new_bucket_ids + bucket_ids : bucket_ids + new_bucket_ids
      self
    end

    def clear
      multi_scope_clear(bucket_ids.map { |bucket_id| bucket_scope(bucket_id) })
      @bucket_ids = nil

      super
    end

    def reload
      @max_retries = nil
      @bucket_ids = nil
      @bucket_run_time_target = nil
      @file_overhead = nil
      super
    end

    def shift_bucket
      return nil if bucket_ids.empty?

      bucket_id = bucket_ids.first
      self.bucket_ids = bucket_ids.drop(1)
      bucket_id
    end

    def bucket_store_for(bucket_id)
      BucketStore.new(uri.to_s, bucket_scope(bucket_id), ttl: ttl)
    end

    def bucket_scope(bucket_id)
      File.join(scope, "buckets", bucket_id)
    end

    def delete_bucket(bucket_id)
      bucket_store_for(bucket_id).clear
    end

    def keys
      bucket_ids
    end

    def length
      bucket_ids.length
    end

    private

    def write_bucket(examples)
      bucket_id = SecureRandom.uuid
      bucket_store_for(bucket_id).examples = examples
      bucket_id
    end

    def grouped_examples(examples)
      return [] if examples.empty?

      examples_to_group = examples.dup

      case grouping_strategy
      when :file
        bucket_run_time_target.positive? ? group_by_batched_file(examples_to_group) : group_by_file(examples_to_group)
      else
        group_by_timings(examples_to_group)
      end
    end

    # Take consecutive examples from the same spec file (per the example id —
    # NOT metadata file_path, which for shared examples is the shared file)
    def group_by_file(examples)
      buckets = []

      examples.each do |example|
        current_bucket = buckets.last

        if current_bucket.nil? || Specwrk.example_file_key(current_bucket.first) != Specwrk.example_file_key(example)
          buckets << [example]
        else
          current_bucket << example
        end
      end

      buckets
    end

    # Pack whole spec files into buckets, slowest file first, up to a target
    # run time per bucket (SPECWRK_SRV_BUCKET_RUN_TIME seconds). A file's
    # examples are never split across buckets — suites that redefine
    # constants at file load need each file loaded at most once per worker.
    # Files without timing data sort first (treated as longest) and get their
    # own bucket. With SPECWRK_SRV_SPLIT_FILES=1, a file exceeding the bucket
    # target is first carved into example-level chunks that each fit it.
    def group_by_batched_file(examples)
      # A run time of 0 is synthesized, not measured — treat it as missing,
      # or zero-timed files all pack into one unfinishable final bucket.
      # file_overhead charges the fixed require/setup cost per-example times
      # don't capture, so many tiny files can't masquerade as one cheap bucket.
      file_run_time = lambda do |file_examples|
        file_overhead + file_examples.sum do |example|
          run_time = example[:expected_run_time]
          run_time&.positive? ? run_time : Float::INFINITY
        end
      end

      # Group by the example id's file component, not metadata file_path:
      # file_path is where an example is DEFINED, which for shared examples
      # fuses everything into one unsplittable pseudo-file.
      file_groups = examples.group_by { |example| Specwrk.example_file_key(example) }
        .values

      file_groups = file_groups.flat_map { |file_examples| split_oversized_file(file_examples, file_run_time) } if split_files?

      file_groups = file_groups.sort_by { |file_examples| -file_run_time.call(file_examples) }

      buckets = []
      current_bucket = []
      current_total = 0.0

      file_groups.each do |file_examples|
        this_run_time = file_run_time.call(file_examples)

        if current_bucket.any? && (current_total + this_run_time) > bucket_run_time_target
          buckets << current_bucket
          current_bucket = []
          current_total = 0.0
        end

        current_bucket.concat(file_examples)
        current_total += this_run_time
      end

      buckets << current_bucket if current_bucket.any?
      buckets
    end

    # Carve one oversized file's examples into chunks that each fit the
    # bucket target; each chunk is its own file load, so each is charged
    # file_overhead. Only measured (finite) totals split — unknown-timing
    # files keep the whole-file handling (own bucket, dispatched first).
    def split_oversized_file(file_examples, file_run_time)
      return [file_examples] unless file_run_time.call(file_examples).finite?
      return [file_examples] unless file_run_time.call(file_examples) > bucket_run_time_target

      chunks = []
      current_chunk = []
      current_total = file_overhead

      file_examples.each do |example|
        run_time = example[:expected_run_time]

        if current_chunk.any? && (current_total + run_time) > bucket_run_time_target
          chunks << current_chunk
          current_chunk = []
          current_total = file_overhead
        end

        current_chunk << example
        current_total += run_time
      end

      chunks << current_chunk if current_chunk.any?
      chunks
    end

    def split_files?
      ENV["SPECWRK_SRV_SPLIT_FILES"] == "1"
    end

    # Take elements until the average runtime bucket has filled
    def group_by_timings(examples)
      buckets = []
      return group_by_file(examples) unless run_time_bucket_maximum&.positive?

      estimated_run_time_total = 0
      current_bucket = []

      examples.each do |example|
        estimated_run_time_total += example[:expected_run_time] || run_time_bucket_maximum

        if estimated_run_time_total > run_time_bucket_maximum && current_bucket.length.positive?
          buckets << current_bucket
          current_bucket = [example]
          estimated_run_time_total = example[:expected_run_time] || run_time_bucket_maximum
          next
        end

        current_bucket << example
      end

      buckets << current_bucket if current_bucket.any?
      buckets
    end

    def grouping_strategy
      return :file unless run_time_bucket_maximum&.positive?

      (ENV["SPECWRK_SRV_GROUP_BY"] == "file") ? :file : :timings
    end
  end
end
