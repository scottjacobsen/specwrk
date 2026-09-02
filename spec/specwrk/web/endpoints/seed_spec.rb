# frozen_string_literal: true

require "specwrk/web/endpoints/seed"
require "support/specwrk/web/endpoints"

RSpec.describe Specwrk::Web::Endpoints::Seed do
  include_context "worker endpoint"

  let(:request_method) { "POST" }
  let(:body) { JSON.generate(max_retries: 42, examples: [{id: "a.rb:1", file_path: "a.rb", run_time: 0.1}]) }

  context "pending store reset with examples and meta data" do
    let(:existing_pending_data) { {"b.rb:2" => {id: "b.rb:2", file_path: "b.rb", expected_run_time: 0.1}} }

    it { is_expected.to eq(ok) }
    it "replaces pending buckets with the seeded examples" do
      original_bucket_ids = pending.bucket_ids.dup

      subject

      expect(pending.reload.length).to eq(1)

      bucket_id = pending.shift_bucket
      expect(bucket_id).to be_a(String)
      expect(original_bucket_ids).not_to include(bucket_id)
      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", bucket_id)).examples.map { |ex| ex[:id] }).to eq(["a.rb:1"])
    end
    it { expect { subject }.to change { pending.reload.max_retries }.from(0).to(42) }

    it "registers the run in the runs index for /metrics enumeration" do
      runs_index = Specwrk::Store.new(datastore_uri, "runs_index")

      expect { subject }.to change { runs_index.reload[run_id] }.from(nil).to(be_within(5).of(Time.now.to_i))
    end
  end

  context "with per-run bucketing overrides in the payload" do
    let(:env_vars) { super().merge("SPECWRK_SRV_GROUP_BY" => "file") }
    let(:existing_run_times_data) { {"a.rb:1": 1.0, "b.rb:1": 1.0} }
    let(:body) do
      JSON.generate(
        bucket_run_time: 2.5,
        file_overhead: 0.1,
        examples: [
          {id: "a.rb:1", file_path: "a.rb"},
          {id: "b.rb:1", file_path: "b.rb"}
        ]
      )
    end

    it "persists the overrides on the pending store for later regrouping (requeue/retry paths)" do
      expect { subject }.to change { pending.reload.bucket_run_time_target }.from(0.0).to(2.5)
        .and change { pending.reload.file_overhead }.from(0.0).to(0.1)
    end

    it "groups this seed with the overrides: both files batch into one bucket" do
      subject

      bucket_id = pending.shift_bucket
      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", bucket_id)).examples.map { |ex| ex[:id] }).to match_array(%w[a.rb:1 b.rb:1])
      expect(pending.shift_bucket).to be_nil
    end
  end

  context "without bucketing overrides in the payload" do
    it "stores nothing, leaving the server env in charge" do
      subject

      expect(pending.reload[Specwrk::PendingStore::BUCKET_RUN_TIME_TARGET_KEY]).to be_nil
      expect(pending.reload[Specwrk::PendingStore::FILE_OVERHEAD_KEY]).to be_nil
    end
  end

  # The seed body is by far the largest request specwrk sends — tens of
  # megabytes of JSON for a large suite, which gzip shrinks ~25x. The
  # compressed body has to seed exactly what the plain one does.
  context "a gzipped request body" do
    let(:body) { Zlib.gzip(JSON.generate(max_retries: 42, examples: [{id: "a.rb:1", file_path: "a.rb", run_time: 0.1}])) }
    let(:env) { super().merge("HTTP_CONTENT_ENCODING" => "gzip") }

    it { is_expected.to eq(ok) }

    it "seeds the same examples and metadata a plain body would" do
      subject

      bucket_id = pending.reload.shift_bucket
      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", bucket_id)).examples.map { |ex| ex[:id] }).to eq(["a.rb:1"])
      expect(pending.reload.max_retries).to eq(42)
    end
  end

  context "merged with  sorted by file" do
    let(:body) do
      JSON.generate(examples: [
        {id: "a.rb:1", file_path: "a.rb"},
        {id: "b.rb:1", file_path: "b.rb"},
        {id: "a.rb:2", file_path: "a.rb"}
      ])
    end

    it "creates buckets grouped by file path" do
      subject

      first_bucket_id = pending.shift_bucket
      second_bucket_id = pending.shift_bucket

      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", first_bucket_id)).examples.map { |ex| ex[:id] }).to eq(%w[a.rb:1 a.rb:2])
      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", second_bucket_id)).examples.map { |ex| ex[:id] }).to eq(%w[b.rb:1])
      expect(pending.shift_bucket).to be_nil
    end
  end

  context "shared-example specs seeded under one shared file_path" do
    let(:body) do
      JSON.generate(examples: [
        {id: "a_spec.rb:1", file_path: "shared_examples.rb"},
        {id: "b_spec.rb:1", file_path: "shared_examples.rb"},
        {id: "a_spec.rb:2", file_path: "shared_examples.rb"}
      ])
    end

    # RSpec reports a shared example's file_path as the file where it is
    # DEFINED, so specs from different files share one file_path. Sorting and
    # grouping by it lumps them all into a single giant pseudo-file bucket;
    # the example id's file component is the real spec file.
    it "creates buckets by the examples' real spec files" do
      subject

      first_bucket_id = pending.shift_bucket
      second_bucket_id = pending.shift_bucket

      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", first_bucket_id)).examples.map { |ex| ex[:id] }).to eq(%w[a_spec.rb:1 a_spec.rb:2])
      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", second_bucket_id)).examples.map { |ex| ex[:id] }).to eq(%w[b_spec.rb:1])
      expect(pending.shift_bucket).to be_nil
    end
  end

  context "merged with run_time_bucket_maximum sorted by timings" do
    let(:existing_run_times_data) do
      {
        "a.rb:1": 0.2,
        "a.rb:2": 0.3,
        "b.rb:4": 0.8
      }
    end

    let(:body) do
      JSON.generate(examples: [
        {id: "a.rb:1", file_path: "a.rb"},
        {id: "a.rb:2", file_path: "a.rb"},
        {id: "b.rb:3", file_path: "b.rb"},
        {id: "b.rb:4", file_path: "b.rb"}
      ])
    end

    it { expect { subject }.to change { pending.reload.run_time_bucket_maximum }.from(nil).to(0.7) }

    it "creates buckets grouped by expected run time" do
      subject

      first_bucket_id = pending.shift_bucket
      second_bucket_id = pending.shift_bucket
      third_bucket_id = pending.shift_bucket

      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", first_bucket_id)).examples.map { |ex| ex[:id] }).to eq(%w[b.rb:3])
      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", second_bucket_id)).examples.map { |ex| ex[:id] }).to eq(%w[b.rb:4])
      expect(Specwrk::BucketStore.new(datastore_uri, run_scope("pending", "buckets", third_bucket_id)).examples.map { |ex| ex[:id] }).to eq(%w[a.rb:2 a.rb:1])
      expect(pending.shift_bucket).to be_nil
    end
  end
end
