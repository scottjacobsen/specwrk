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

    it "records the worker's in-flight bucket in the index" do
      subject

      record = in_flight.reload[worker_id]
      expect(record[:ids]).to eq(["a.rb:2"])
      expect(record[:processing_started_at]).to be_within(5).of(Time.now.to_i)
    end
  end

  context "no items in any queue" do
    it { is_expected.to eq([204, {"content-type" => "text/plain", "x-specwrk-status" => "1"}, ["Waiting for sample to be seeded."]]) }
  end

  context "workers index bookkeeping" do
    let(:workers_index) { Specwrk::Store.new(datastore_uri, run_scope("workers_index")) }

    context "on a pop" do
      let(:existing_pending_data) do
        {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}}
      end

      it "records the worker's contact" do
        expect { subject }.to change { workers_index.reload[worker_id] }.from(nil).to(be_within(5).of(Time.now.to_i))
      end
    end

    context "on the gone-home 410" do
      let(:existing_completed_data) do
        {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}}
      end

      before { workers_index[worker_id] = Time.now.to_i }

      it "removes the worker so it can't linger as stale in /metrics" do
        expect(response[0]).to eq(410)
        expect(workers_index.reload[worker_id]).to be_nil
      end
    end
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

  context "queue drained but a dead worker's bucket is still in processing" do
    # The drained-queue 410 must not fire while in-flight work belongs to a
    # worker that has stopped heartbeating: 410 is terminal for every idle
    # worker, and if they all go home before the expiry scan reclaims this
    # bucket, nobody is left to re-run it — the run "completes" with examples
    # that never ran. 404 keeps the pollers around; a later poll (once the
    # scan interval elapses) reclaims and hands the bucket out.
    let(:existing_completed_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
    end

    before do
      other_worker.last_seen_at = Time.now - 21
      # Scan gate closed: the reclaim path is not due, so only the 410 guard
      # stands between this bucket and every worker going home. The last scan
      # cached a verdict that staleness became possible a moment ago.
      metadata[:last_expiry_check_at] = Time.now.to_i
      metadata[:stale_in_flight_possible_at] = (Time.now - 1).to_i
    end

    it { is_expected.to eq([404, {"content-type" => "text/plain", "x-specwrk-status" => "0"}, ["This is not the path you're looking for, 'ol chap..."]]) }

    it "answers from the cached verdict without reading the in-flight index or processing payloads" do
      expect(instance).not_to receive(:in_flight)
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:to_h)
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:keys)
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:multi_read)

      expect(response[0]).to eq(404)
    end

    context "with no cached verdict at all" do
      before { metadata.delete("stale_in_flight_possible_at") }

      # Unknown means "assume reclaimable work": 404 keeps the pollers around
      # for one scan interval, which writes the real verdict.
      it { is_expected.to eq([404, {"content-type" => "text/plain", "x-specwrk-status" => "0"}, ["This is not the path you're looking for, 'ol chap..."]]) }
    end
  end

  context "queue drained while a live worker still runs its final bucket" do
    # The fast drain tail: in-flight work owned by a live (heartbeating)
    # worker must NOT hold everyone else hostage — idle workers go home
    # immediately; the live owner reports its results on its own next request.
    let(:existing_completed_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
    end

    before do
      other_worker.last_seen_at = Time.now - 5
      # The last scan (gate closed) cached its verdict: the live owner's
      # bucket can't turn stale for another 15s.
      metadata[:last_expiry_check_at] = Time.now.to_i
      metadata[:stale_in_flight_possible_at] = (Time.now + 15).to_i
    end

    it { is_expected.to eq([410, {"content-type" => "text/plain", "x-specwrk-status" => "0"}, ["That's a good lad. Run along now and go home."]]) }

    # This is THE hot path of a drained run: thousands of idle workers
    # polling every 0.5s. Each empty pop must cost a couple of small reads —
    # the cached verdict — never a walk of the in-flight index (per-worker
    # heartbeat reads) or of the processing payloads (multi-MB).
    it "answers from the cached verdict without reading the in-flight index or processing payloads" do
      expect(instance).not_to receive(:in_flight)
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:to_h)
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:keys)
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:multi_read)

      expect(response[0]).to eq(410)
    end
  end

  context "a retried pop whose first response was lost (same x-specwrk-request-id)" do
    # /pop is non-idempotent: it hands out a bucket. When the client loses the
    # response (connection reset after the server processed the request), its
    # retry must get the SAME bucket replayed, not a second one — otherwise the
    # first bucket sits orphaned in processing under this worker's name,
    # heartbeat-alive and unreclaimable.
    let(:env_vars) { super().merge("SPECWRK_SRV_GROUP_BY" => "file") }

    let(:existing_pending_data) do
      {
        "a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1},
        "b.rb:1": {id: "b.rb:1", file_path: "b.rb", expected_run_time: 0.1}
      }
    end

    def response_for(request_id)
      request_env = env.merge(
        "HTTP_X_SPECWRK_REQUEST_ID" => request_id,
        "rack.input" => StringIO.new(body)
      )
      described_class.new(Rack::Request.new(request_env)).response
    end

    it "replays the recorded response instead of handing out a second bucket" do
      first = response_for("req-1")
      expect(first[0]).to eq(200)
      expect(processing.reload.length).to eq(1)

      replay = response_for("req-1")
      expect(replay[0]).to eq(200)
      expect(replay[2]).to eq(first[2])
      expect(processing.reload.length).to eq(1) # no second bucket moved in-flight

      fresh = response_for("req-2")
      expect(fresh[0]).to eq(200)
      expect(fresh[2]).not_to eq(first[2])
      expect(processing.reload.length).to eq(2)
    end
  end

  context "processing entry has a stale processing_started_at but its owner's heartbeat is fresh" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
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

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
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

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
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

    it "moves the in-flight index entry from the dead worker to the new owner" do
      subject

      expect(in_flight.reload[other_worker_id]).to be_nil
      expect(in_flight[worker_id][:ids]).to eq(["a.rb:2"])
    end

    it "caches a staleness verdict for the empty pops between scans" do
      subject

      # The only record was stale and got requeued, so nothing left in
      # flight can expire sooner than a fresh handout: now + expire_after.
      expect(metadata.reload[:stale_in_flight_possible_at]).to be_within(5).of(Time.now.to_i + 20)
    end
  end

  context "the expiry scan interval has elapsed with a stale prior scan timestamp" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
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

  context "the reclaim scan reads payloads only for the stale workers' examples" do
    # The scan used to materialize the ENTIRE processing store — full example
    # payloads, multi-MB at tens of thousands of in-flight entries — while
    # holding the per-run lock. It only ever needed (worker, started_at) per
    # bucket to pick candidates, which the in-flight index provides; payloads
    # are read just for the entries actually being requeued.
    let(:third_worker_id) { "foobar-2" }
    let(:third_worker) { Specwrk::WorkerStore.new datastore_uri, run_scope("workers", third_worker_id) }

    let(:existing_processing_data) do
      {
        "a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id},
        "b.rb:1": {id: "b.rb:1", file_path: "b.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: third_worker_id}
      }
    end

    let(:existing_in_flight_data) do
      {
        other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i},
        third_worker_id => {ids: ["b.rb:1"], processing_started_at: (Time.now - 100).to_i}
      }
    end

    before do
      other_worker.last_seen_at = Time.now - 21 # dead
      third_worker.last_seen_at = Time.now - 5 # alive, its bucket must stay put
    end

    it "never walks the full processing store and multi_reads only the dead worker's ids" do
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:to_h)
      expect_any_instance_of(Specwrk::ProcessingStore).not_to receive(:keys)
      expect_any_instance_of(Specwrk::ProcessingStore).to receive(:multi_read).with("a.rb:2").and_call_original

      expect(response[0]).to eq(200)
      body_examples = JSON.parse(response[2].first, symbolize_names: true)
      expect(body_examples.map { |example| example[:id] }).to eq(["a.rb:2"])
      expect(processing.reload["b.rb:1"][:worker_id]).to eq(third_worker_id)
    end
  end

  context "requeues expired examples repacked into properly-sized pending buckets, not one giant tail bucket" do
    let(:env_vars) { super().merge("SPECWRK_SRV_GROUP_BY" => "file", "SPECWRK_SRV_BUCKET_RUN_TIME" => "10") }

    let(:existing_processing_data) do
      (1..6).to_h do |n|
        [:"file#{n}.rb:1", {id: "file#{n}.rb:1", file_path: "file#{n}.rb", expected_run_time: 5.0, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}]
      end
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: (1..6).map { |n| "file#{n}.rb:1" }, processing_started_at: (Time.now - 100).to_i}}
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

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
    end

    before { other_worker.last_seen_at = Time.now - 21 }

    it "does not re-add the duplicate to pending, clears it from processing, and reports the queue drained" do
      expect { subject }.not_to change { pending.reload.length }

      expect(response[0]).to eq(410)
      expect(processing.reload["a.rb:2"]).to be_nil
      expect(in_flight.reload[other_worker_id]).to be_nil
    end
  end

  context "a cached maybe-stale verdict flips back to the drain once the scan reclaims the dead worker's bucket" do
    let(:existing_completed_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
    end

    before do
      other_worker.last_seen_at = Time.now - 21
      metadata[:last_expiry_check_at] = Time.now.to_i
      metadata[:stale_in_flight_possible_at] = (Time.now - 1).to_i
    end

    def pop
      described_class.new(Rack::Request.new(env.merge("rack.input" => StringIO.new(body)))).response
    end

    it "404s while the verdict holds, then hands the reclaimed bucket out and re-opens the drain" do
      expect(pop[0]).to eq(404) # verdict: maybe stale, scan not due — keep polling

      metadata[:last_expiry_check_at] = (Time.now - 60).to_i # the interval passes

      reclaim_response = pop
      expect(reclaim_response[0]).to eq(200)
      body_examples = JSON.parse(reclaim_response[2].first, symbolize_names: true)
      expect(body_examples.map { |example| example[:id] }).to eq(["a.rb:2"])

      # The scan refreshed the verdict, so the next drained pop 410s home.
      expect(metadata.reload[:stale_in_flight_possible_at]).to be > Time.now.to_i
    end
  end

  context "a second PendingStore instance writes a bucket while this endpoint's own pending is memoized stale" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
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
