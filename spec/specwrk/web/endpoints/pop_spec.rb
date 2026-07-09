# frozen_string_literal: true

require "specwrk/web/endpoints/pop"
require "support/specwrk/web/endpoints"

RSpec.describe Specwrk::Web::Endpoints::Pop do
  include_context "worker endpoint"

  context "successfully pops an item off the queue" do
    let(:existing_pending_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}}
    end

    it { is_expected.to eq([200, {"content-type" => "application/json", "x-specwrk-status" => "1"}, [JSON.generate([{id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}])]]) }
    it { expect { subject }.to change { pending.reload.length }.from(1).to(0) }
    it { expect { subject }.to change { processing.reload["a.rb:2"] }.from(nil).to({expected_run_time: 0.1, file_path: "a.rb", id: "a.rb:2", worker_id: "foobar-0", processing_started_at: instance_of(Integer)}) }
  end

  context "no items in any queue" do
    it { is_expected.to eq([204, {"content-type" => "text/plain", "x-specwrk-status" => "1"}, ["Waiting for sample to be seeded."]]) }
  end

  context "no items in the processing queue, no known failed for worker, but completed queue has items" do
    let(:existing_completed_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}}
    end

    it { is_expected.to eq([410, {"content-type" => "text/plain", "x-specwrk-status" => "0"}, ["That's a good lad. Run along now and go home."]]) }
  end

  context "no items in the pending queue, but something in the processing queue but none are expired" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}}
    end

    it { is_expected.to eq([404, {"content-type" => "text/plain", "x-specwrk-status" => "1"}, ["This is not the path you're looking for, 'ol chap..."]]) }
  end

  context "processing entry has a stale processing_started_at but its owner's heartbeat is fresh" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    before { other_worker.last_seen_at = Time.now - 5 }

    it { is_expected.to eq([404, {"content-type" => "text/plain", "x-specwrk-status" => "1"}, ["This is not the path you're looking for, 'ol chap..."]]) }
    it { expect { subject }.not_to change { pending.reload.length } }
    it { expect { subject }.not_to change { processing.reload.to_h } }
  end

  context "the expiry scan interval has not elapsed since the last scan" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    before do
      other_worker.last_seen_at = Time.now - 21
      metadata[:last_expiry_check_at] = Time.now.to_i
    end

    # The example is genuinely expired, but a scan just ran — skip re-scanning
    # every empty pop so an 80-worker post-drain stampede doesn't serialize on
    # a full processing-set scan per request.
    it { is_expected.to eq([404, {"content-type" => "text/plain", "x-specwrk-status" => "1"}, ["This is not the path you're looking for, 'ol chap..."]]) }
    it { expect { subject }.not_to change { pending.reload.length } }
  end

  context "the expiry scan interval has elapsed with no prior scan timestamp" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    before { other_worker.last_seen_at = Time.now - 21 }

    # The requeued bucket is immediately handed back out in this same
    # response (reclaim, then re-check `examples`) rather than left sitting in
    # pending, so pending nets back to empty — assert on the response and the
    # processing record's new owner instead of a `pending.length` change.
    it "reclaims the expired example, hands it back out, and stamps the scan timestamp" do
      expect { subject }.to change { processing.reload["a.rb:2"][:worker_id] }.from(other_worker_id).to(worker_id)

      expect(response[0]).to eq(200)
      body_examples = JSON.parse(response[2].first, symbolize_names: true)
      expect(body_examples.map { |example| example[:id] }).to eq(["a.rb:2"])
      expect(metadata.reload[:last_expiry_check_at]).to be_within(5).of(Time.now.to_i)
    end
  end

  context "the expiry scan interval has elapsed with a stale prior scan timestamp" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    before do
      other_worker.last_seen_at = Time.now - 21
      metadata[:last_expiry_check_at] = (Time.now - 60).to_i
    end

    it "reclaims the expired example, hands it back out, and stamps the scan timestamp" do
      expect { subject }.to change { processing.reload["a.rb:2"][:worker_id] }.from(other_worker_id).to(worker_id)

      expect(response[0]).to eq(200)
      body_examples = JSON.parse(response[2].first, symbolize_names: true)
      expect(body_examples.map { |example| example[:id] }).to eq(["a.rb:2"])
      expect(metadata.reload[:last_expiry_check_at]).to be_within(5).of(Time.now.to_i)
    end
  end

  context "requeues expired examples repacked into properly-sized pending buckets, not one giant tail bucket" do
    let(:env_vars) { super().merge("SPECWRK_SRV_GROUP_BY" => "file", "SPECWRK_SRV_BUCKET_RUN_TIME" => "10") }

    let(:existing_processing_data) do
      (1..6).to_h do |n|
        [:"file#{n}.rb:1", {id: "file#{n}.rb:1", file_path: "file#{n}.rb", expected_run_time: 5.0, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}]
      end
    end

    before { other_worker.last_seen_at = Time.now - 21 }

    it "hands back only one bucket's worth of examples and repacks the rest into multiple pending buckets with no orphans" do
      subject

      expect(response[0]).to eq(200)
      body_examples = JSON.parse(response[2].first, symbolize_names: true)
      expect(body_examples.length).to be < 6

      expect(pending.reload.length).to be >= 2

      pending.bucket_ids.each do |bucket_id|
        bucket_examples = pending.bucket_store_for(bucket_id).examples
        expect(bucket_examples).not_to be_empty

        total_run_time = bucket_examples.sum { |example| example[:expected_run_time] }
        expect(total_run_time).to be <= 10.0
      end
    end
  end

  context "an expired processing entry is already in the completed queue" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_completed_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", status: "passed", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601}}
    end

    before { other_worker.last_seen_at = Time.now - 21 }

    it "does not re-add the duplicate to pending, clears it from processing, and reports the queue drained" do
      expect { subject }.not_to change { pending.reload.length }

      expect(response[0]).to eq(410)
      expect(processing.reload["a.rb:2"]).to be_nil
    end
  end

  context "a second PendingStore instance writes a bucket while this endpoint's own pending is memoized stale" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:interloper_example) { {"b.rb:1": {id: "b.rb:1", file_path: "b.rb"}} }

    before do
      other_worker.last_seen_at = Time.now - 21

      # `examples.any?` (the first line of with_pop_response) finds pending
      # empty and memoizes this endpoint's own PendingStore#bucket_ids as [].
      # Interleave a second instance's write right after that — but before
      # the reclaim's with_lock section runs — by hooking the due-check that
      # gates entry into the reclaim. Without `pending.reload` inside that
      # lock (popable.rb), the reclaim's requeue would merge against this
      # endpoint's now-stale [] and silently clobber the concurrent write.
      injected = false
      allow(instance).to receive(:expiry_check_due?).and_wrap_original do |original|
        unless injected
          injected = true
          pending.merge!(interloper_example)
        end
        original.call
      end
    end

    it "does not clobber the concurrently-written bucket when it requeues the reclaimed example" do
      subject

      response_ids = JSON.parse(response[2].first, symbolize_names: true).map { |example| example[:id] }
      pending_ids = pending.reload.bucket_ids.flat_map { |bucket_id| pending.bucket_store_for(bucket_id).examples.map { |example| example[:id] } }

      expect(response_ids + pending_ids).to include("b.rb:1")
    end
  end
end
