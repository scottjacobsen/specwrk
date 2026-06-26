# frozen_string_literal: true

require "securerandom"
require "tmpdir"

require "specwrk/store/pending_store"
require "specwrk/store/bucket_store"

RSpec.describe Specwrk::PendingStore do
  let(:uri_string) { "file://#{Dir.tmpdir}" }
  let(:scope) { SecureRandom.uuid }

  let(:instance) { described_class.new(uri_string, scope) }

  before { instance.clear }

  def bucket_for(id)
    Specwrk::BucketStore.new(uri_string, File.join(scope, "buckets", id))
  end

  describe "#run_time_bucket_maximum=" do
    subject { instance.run_time_bucket_maximum = 3 }

    it { expect { subject }.to change(instance, :run_time_bucket_maximum).from(nil).to(3) }
  end

  describe "#run_time_bucket_maximum" do
    subject { instance.run_time_bucket_maximum }

    before { instance[described_class::RUN_TIME_BUCKET_MAXIMUM_KEY] = 4 }

    it { is_expected.to eq(4) }
  end

  describe "#max_retries=" do
    subject { instance.max_retries = 3 }

    it { expect { subject }.to change(instance, :max_retries).from(0).to(3) }
  end

  describe "#max_retries" do
    subject { instance.max_retries }

    before { instance[described_class::MAX_RETRIES_KEY] = 4 }

    it { is_expected.to eq(4) }
  end

  describe "#merge!" do
    context "grouping by timings" do
      before do
        stub_const("ENV", ENV.to_h.merge("SPECWRK_SRV_GROUP_BY" => "timings"))
        instance.run_time_bucket_maximum = 2.5
      end

      it "creates buckets that respect the timing threshold" do
        instance.merge!({
          "a.rb:2": {id: "a.rb:2", expected_run_time: 1.2},
          "a.rb:3": {id: "a.rb:3", expected_run_time: 1.3},
          "a.rb:4": {id: "a.rb:4", expected_run_time: 1.4}
        })

        first_bucket_id = instance.shift_bucket
        second_bucket_id = instance.shift_bucket

        expect(first_bucket_id).not_to eq(second_bucket_id)
        expect(bucket_for(first_bucket_id).examples).to eq([
          {id: "a.rb:2", expected_run_time: 1.2},
          {id: "a.rb:3", expected_run_time: 1.3}
        ])
        expect(bucket_for(second_bucket_id).examples).to eq([
          {id: "a.rb:4", expected_run_time: 1.4}
        ])
        expect(instance.shift_bucket).to be_nil
      end
    end

    context "grouping by file" do
      before do
        stub_const("ENV", ENV.to_h.merge("SPECWRK_SRV_GROUP_BY" => "file"))
      end

      it "creates buckets grouped by file path" do
        instance.merge!({
          "a.rb:4": {id: "a.rb:4", expected_run_time: 1.2, file_path: "a.rb"},
          "a.rb:5": {id: "a.rb:5", expected_run_time: 1.3, file_path: "a.rb"},
          "b.rb:1": {id: "b.rb:1", expected_run_time: 1.4, file_path: "b.rb"}
        })

        first_bucket_id = instance.shift_bucket
        second_bucket_id = instance.shift_bucket

        expect(bucket_for(first_bucket_id).examples).to eq([
          {id: "a.rb:4", expected_run_time: 1.2, file_path: "a.rb"},
          {id: "a.rb:5", expected_run_time: 1.3, file_path: "a.rb"}
        ])
        expect(bucket_for(second_bucket_id).examples).to eq([
          {id: "b.rb:1", expected_run_time: 1.4, file_path: "b.rb"}
        ])
        expect(instance.shift_bucket).to be_nil
      end

      it "separates shared-example specs from different spec files despite the common file_path" do
        # RSpec reports a shared example's file_path as the file where it is
        # DEFINED, so every spec built from it carries the shared-examples file
        # as file_path. The example id's file component is the real spec file.
        instance.merge!({
          "a_spec.rb:1": {id: "a_spec.rb:1", file_path: "shared_examples.rb"},
          "b_spec.rb:1": {id: "b_spec.rb:1", file_path: "shared_examples.rb"}
        })

        first_bucket_id = instance.shift_bucket
        second_bucket_id = instance.shift_bucket

        expect(bucket_for(first_bucket_id).examples.map { |example| example[:id] }).to eq(["a_spec.rb:1"])
        expect(bucket_for(second_bucket_id).examples.map { |example| example[:id] }).to eq(["b_spec.rb:1"])
        expect(instance.shift_bucket).to be_nil
      end
    end

    context "grouping by batched file" do
      before do
        stub_const("ENV", ENV.to_h.merge("SPECWRK_SRV_GROUP_BY" => "file", "SPECWRK_SRV_BUCKET_RUN_TIME" => "2.5"))
      end

      it "packs whole files into buckets up to the target, slowest file first, without splitting a file" do
        instance.merge!({
          "a.rb:1": {id: "a.rb:1", expected_run_time: 1.0, file_path: "a.rb"},
          "a.rb:2": {id: "a.rb:2", expected_run_time: 1.0, file_path: "a.rb"},
          "b.rb:1": {id: "b.rb:1", expected_run_time: 0.5, file_path: "b.rb"},
          "c.rb:1": {id: "c.rb:1", expected_run_time: 3.0, file_path: "c.rb"}
        })

        first_bucket_id = instance.shift_bucket
        second_bucket_id = instance.shift_bucket

        # Slowest file (c.rb, 3.0s) is dispatched first and, exceeding the target on
        # its own, gets a bucket to itself.
        expect(bucket_for(first_bucket_id).examples).to eq([
          {id: "c.rb:1", expected_run_time: 3.0, file_path: "c.rb"}
        ])
        # a.rb (2.0s) + b.rb (0.5s) = 2.5s batched into one bucket; a.rb's examples
        # stay together (never split across buckets).
        expect(bucket_for(second_bucket_id).examples).to eq([
          {id: "a.rb:1", expected_run_time: 1.0, file_path: "a.rb"},
          {id: "a.rb:2", expected_run_time: 1.0, file_path: "a.rb"},
          {id: "b.rb:1", expected_run_time: 0.5, file_path: "b.rb"}
        ])
        expect(instance.shift_bucket).to be_nil
      end

      it "charges the per-file overhead so hundreds of tiny files cannot pack into one bucket" do
        # SPECWRK_SRV_FILE_OVERHEAD models the fixed cost a bucket pays per
        # FILE (require/load, per-file setup) that per-example run times don't
        # capture. Without it, 5 files x 0.1s pack into a single "0.5s" bucket
        # whose true cost is dominated by 5 file loads. On a ~100k-example
        # suite that built a ~1,300-example, ~200-file bucket that blew the
        # bucket timeout under two-workers-per-node contention.
        stub_const("ENV", ENV.to_h.merge(
          "SPECWRK_SRV_GROUP_BY" => "file",
          "SPECWRK_SRV_BUCKET_RUN_TIME" => "2.5",
          "SPECWRK_SRV_FILE_OVERHEAD" => "1.0"
        ))

        instance.merge!((1..5).to_h { |n|
          [:"f#{n}.rb:1", {id: "f#{n}.rb:1", expected_run_time: 0.1, file_path: "f#{n}.rb"}]
        })

        # Each file costs 0.1 + 1.0 overhead = 1.1; the 2.5s target fits two
        # files per bucket, so five files land in three buckets instead of one.
        bucket_sizes = []
        while (bucket_id = instance.shift_bucket)
          bucket_sizes << bucket_for(bucket_id).examples.length
        end

        expect(bucket_sizes).to eq([2, 2, 1])
      end

      it "buckets shared-example specs by their own spec file, not the metadata file_path" do
        instance.merge!({
          "./spec/a_spec.rb[1:1]": {id: "./spec/a_spec.rb[1:1]", expected_run_time: 2.0, file_path: "./spec/support/shared_examples.rb"},
          "./spec/b_spec.rb[1:1]": {id: "./spec/b_spec.rb[1:1]", expected_run_time: 1.9, file_path: "./spec/support/shared_examples.rb"}
        })

        # Each real spec file sums 2.0/1.9s; together they exceed the 2.5s
        # target, so they must land in two buckets. Grouping by the metadata
        # file_path treats them as ONE 3.9s pseudo-file which — files never
        # being split — becomes a single giant bucket. On a ~100k-example
        # suite that meant ~2,480 shared-example request specs in one
        # unfinishable mega-bucket (killed at the bucket timeout, all
        # reported failed).
        first_bucket_id = instance.shift_bucket
        second_bucket_id = instance.shift_bucket

        expect(bucket_for(first_bucket_id).examples.map { |example| example[:id] }).to eq(["./spec/a_spec.rb[1:1]"])
        expect(bucket_for(second_bucket_id).examples.map { |example| example[:id] }).to eq(["./spec/b_spec.rb[1:1]"])
        expect(instance.shift_bucket).to be_nil
      end

      it "gives unknown-timing files (nil or 0) their own bucket, dispatched first" do
        instance.merge!({
          "a.rb:1": {id: "a.rb:1", expected_run_time: 1.0, file_path: "a.rb"},
          "zero1.rb:1": {id: "zero1.rb:1", expected_run_time: 0.0, file_path: "zero1.rb"},
          "zero2.rb:1": {id: "zero2.rb:1", expected_run_time: 0.0, file_path: "zero2.rb"},
          "nil.rb:1": {id: "nil.rb:1", expected_run_time: nil, file_path: "nil.rb"}
        })

        buckets = []
        while (bucket_id = instance.shift_bucket)
          buckets << bucket_for(bucket_id).examples
        end

        # Files without usable timing data (nil or 0 — e.g. examples that were
        # synthesized as unexecuted, which record a 0.0 run time) are treated as
        # unknown: dispatched first and never packed together. Otherwise a pile
        # of zero-timed files sorts last and packs into one giant final bucket
        # (0 + 0 + ... never exceeds the target) that no worker can finish.
        expect(buckets.length).to eq(4)
        expect(buckets.first(3).map { |examples| examples.first[:file_path] })
          .to contain_exactly("zero1.rb", "zero2.rb", "nil.rb")
        expect(buckets.last.map { |example| example[:id] }).to eq(["a.rb:1"])
      end

      it "packs all files into one bucket when they fit under the target, slowest first" do
        instance.merge!({
          "a.rb:1": {id: "a.rb:1", expected_run_time: 0.3, file_path: "a.rb"},
          "b.rb:1": {id: "b.rb:1", expected_run_time: 0.6, file_path: "b.rb"},
          "c.rb:1": {id: "c.rb:1", expected_run_time: 0.9, file_path: "c.rb"}
        })

        bucket_id = instance.shift_bucket

        expect(bucket_for(bucket_id).examples).to eq([
          {id: "c.rb:1", expected_run_time: 0.9, file_path: "c.rb"},
          {id: "b.rb:1", expected_run_time: 0.6, file_path: "b.rb"},
          {id: "a.rb:1", expected_run_time: 0.3, file_path: "a.rb"}
        ])
        expect(instance.shift_bucket).to be_nil
      end
    end
  end

  describe "#shift_bucket" do
    it "returns nil when no buckets remain" do
      expect(instance.shift_bucket).to be_nil
    end
  end

  describe "#push_examples" do
    it "adds a new bucket and returns its data later" do
      instance.push_examples([{id: "a.rb:1", file_path: "a.rb"}])

      bucket_id = instance.shift_bucket
      expect(bucket_id).to be_a(String)
      expect(bucket_for(bucket_id).examples).to eq([{id: "a.rb:1", file_path: "a.rb"}])
    end
  end

  describe "#clear" do
    it "removes stored buckets" do
      instance.push_examples([{id: "a.rb:1", file_path: "a.rb"}])
      bucket_id = instance.shift_bucket
      bucket = bucket_for(bucket_id)

      expect(bucket.examples).to eq([{id: "a.rb:1", file_path: "a.rb"}])

      instance.bucket_ids = [bucket_id]
      instance.clear

      expect(bucket.reload.examples).to eq([])
    end
  end

  describe "#bucket_store_for / #delete_bucket" do
    it "returns a bucket store scoped to the pending store and can delete it" do
      instance.push_examples([{id: "a.rb:1", file_path: "a.rb"}])
      bucket_id = instance.shift_bucket

      bucket = instance.bucket_store_for(bucket_id)
      expect(bucket.examples).to eq([{id: "a.rb:1", file_path: "a.rb"}])

      instance.delete_bucket(bucket_id)
      expect(bucket.reload.examples).to eq([])
    end
  end
end
