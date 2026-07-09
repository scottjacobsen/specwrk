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

    def run_time_bucket_maximum=(val)
      @run_time_bucket_maximum = self[RUN_TIME_BUCKET_MAXIMUM_KEY] = val
    end

    def run_time_bucket_maximum
      @run_time_bucket_maximum ||= self[RUN_TIME_BUCKET_MAXIMUM_KEY]
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

    def merge!(hash, prepend: false)
      return self if hash.nil? || hash.empty?

      buckets = grouped_examples(hash.values)
      new_bucket_ids = buckets.map { |examples| write_bucket(examples) }

      self.bucket_ids = prepend ? new_bucket_ids + bucket_ids : bucket_ids + new_bucket_ids
      self
    end

    def clear
      bucket_ids.each { |bucket_id| delete_bucket(bucket_id) }
      @bucket_ids = nil

      super
    end

    def reload
      @max_retries = nil
      @bucket_ids = nil
      super
    end

    def shift_bucket
      return nil if bucket_ids.empty?

      bucket_id = bucket_ids.first
      self.bucket_ids = bucket_ids.drop(1)
      bucket_id
    end

    def bucket_store_for(bucket_id)
      BucketStore.new(uri.to_s, File.join(scope, "buckets", bucket_id))
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

    # Pack whole spec files into buckets, slowest file first, up to a target total
    # run time per bucket (SPECWRK_SRV_BUCKET_RUN_TIME seconds). A file's examples
    # are never split across buckets — so a worker still loads each file at most
    # once (required by suites that redefine constants at file load, e.g. under
    # DeprecationToolkit) — while batching multiple files per bucket cuts the
    # per-file round trips to the server and dispatches the slowest files first to
    # avoid stragglers. Files without timing data sort first (treated as longest)
    # and get their own bucket.
    def group_by_batched_file(examples)
      # A run time of 0 is synthesized (e.g. an example reported as unexecuted),
      # not measured, so treat it like a missing timing. Otherwise zero-timed
      # files sort last and all pack into one giant final bucket (0 + 0 + ...
      # never exceeds the target) that no worker can finish.
      # Each file also carries a fixed cost (require/load, per-file setup) that
      # per-example run times don't capture, so charge file_overhead once per
      # file: without it, hundreds of tiny-example files sum to "one bucket's
      # worth" of run time whose true cost is dominated by the file loads.
      file_run_time = lambda do |file_examples|
        file_overhead + file_examples.sum do |example|
          run_time = example[:expected_run_time]
          run_time&.positive? ? run_time : Float::INFINITY
        end
      end

      # Group by the example id's file component: metadata file_path is where
      # the example is DEFINED, so every spec built from a shared example
      # carries the shared-examples file as file_path — grouping by that fuses
      # thousands of examples into one unsplittable pseudo-file mega-bucket.
      file_groups = examples.group_by { |example| Specwrk.example_file_key(example) }
        .values
        .sort_by { |file_examples| -file_run_time.call(file_examples) }

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

    # Target total run time (seconds) per bucket when batching whole files under
    # the :file strategy. 0 (default) keeps the legacy one-file-per-bucket behavior.
    def bucket_run_time_target
      @bucket_run_time_target ||= ENV.fetch("SPECWRK_SRV_BUCKET_RUN_TIME", "0").to_f
    end

    # Seconds charged per FILE when packing batched buckets, on top of its
    # examples' summed run times. Default 0 keeps the historical behavior.
    def file_overhead
      @file_overhead ||= ENV.fetch("SPECWRK_SRV_FILE_OVERHEAD", "0").to_f
    end
  end
end
