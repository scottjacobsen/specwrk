# frozen_string_literal: true

require "specwrk/web/endpoints/complete_and_pop"
require "support/specwrk/web/endpoints"

RSpec.describe Specwrk::Web::Endpoints::CompleteAndPop do
  include_context "worker endpoint"

  let(:request_method) { "POST" }

  let(:body) {
    JSON.generate([
      {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "passed"},
      {id: "a.rb:3", file_path: "a.rb", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "passed"},
      {id: "a.rb:4", file_path: "a.rb", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "pending"},
      {id: "a.rb:5", file_path: "a.rb", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "failed"}
    ])
  }

  context "completes examples" do
    let(:existing_processing_data) do
      {
        "a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:4": {id: "a.rb:4", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:5": {id: "a.rb:5", file_path: "a.rb", expected_run_time: 0.1}
      }
    end

    let(:existing_in_flight_data) do
      {worker_id => {ids: ["a.rb:1", "a.rb:3", "a.rb:4", "a.rb:5"], processing_started_at: (Time.now - 10).to_i}}
    end

    it { is_expected.to eq([410, {"content-type" => "text/plain", "x-specwrk-status" => "1"}, ["That's a good lad. Run along now and go home."]]) } # 410: the pending queue is drained, so there's no more work to hand out — go home even though an orphaned straggler (a.rb:2, no live worker) remains in processing. Previously this returned 404 and the worker spin-polled forever, starving the server.
    # Only the PASSED examples' run times are recorded (a.rb:1 and a.rb:3):
    # failures and pendings are not scheduling signal — a cascade of
    # fast-failing examples (e.g. a poisoned worker where everything dies in
    # microseconds) would otherwise write absurdly tiny "measured" times that
    # the batched grouping then packs into unfinishable mega-buckets.
    it { expect { subject }.to change { run_times.reload.length }.from(0).to(2) }
    it "does not record run times for failed or pending examples" do
      subject

      expect(run_times.reload["a.rb:1"]).to eq(0.1)
      expect(run_times["a.rb:4"]).to be_nil # pending
      expect(run_times["a.rb:5"]).to be_nil # failed
    end
    it { expect { subject }.to change { processing.reload.length }.from(4).to(1) }
    # All four payload results complete — including a.rb:3, whose processing
    # entry is gone (a reclaimed-then-reported late result, merged rather
    # than discarded).
    it { expect { subject }.to change { completed.reload.length }.from(0).to(4) }
    it { expect { subject }.to change { worker["passed"] }.from(nil).to(2) }
    it { expect { subject }.to change { worker["failed"] }.from(nil).to(1) }
    it { expect { subject }.to change { worker["pending"] }.from(nil).to(1) }
    # No new bucket was handed out, so the worker has nothing in flight.
    it { expect { subject }.to change { in_flight.reload[worker_id] }.to(nil) }
  end

  context "a retried completion whose first response was lost (same x-specwrk-request-id)" do
    # The retry must replay the recorded response, not run the endpoint again —
    # a re-run hands out a SECOND bucket (the completion half is already deduped
    # by the processing_examples guard, but the pop half is not), leaving the
    # first bucket orphaned in processing under this worker's name,
    # heartbeat-alive and unreclaimable.
    let(:env_vars) { super().merge("SPECWRK_SRV_GROUP_BY" => "file") }

    let(:existing_processing_data) do
      {
        "a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:3": {id: "a.rb:3", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:4": {id: "a.rb:4", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:5": {id: "a.rb:5", file_path: "a.rb", expected_run_time: 0.1}
      }
    end

    let(:existing_pending_data) do
      {
        "b.rb:1": {id: "b.rb:1", file_path: "b.rb", expected_run_time: 0.1},
        "c.rb:1": {id: "c.rb:1", file_path: "c.rb", expected_run_time: 0.1}
      }
    end

    def response_for(request_id)
      request_env = env.merge(
        "HTTP_X_SPECWRK_REQUEST_ID" => request_id,
        "rack.input" => StringIO.new(body)
      )
      described_class.new(Rack::Request.new(request_env)).response
    end

    it "replays the recorded response instead of completing again and handing out a second bucket" do
      first = response_for("req-1")
      expect(first[0]).to eq(200)
      expect(worker.reload["passed"]).to eq(2)
      expect(completed.reload.length).to eq(4)
      expect(pending.reload.length).to eq(1) # one bucket handed out, one left

      replay = response_for("req-1")
      expect(replay[0]).to eq(200)
      expect(replay[2]).to eq(first[2]) # the same bucket, not the remaining one
      expect(worker.reload["passed"]).to eq(2) # not double-tallied
      expect(pending.reload.length).to eq(1) # the remaining bucket was NOT also handed out
    end
  end

  context "completes examples that never actually ran" do
    let(:body) {
      JSON.generate([
        {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "passed"},
        {id: "a.rb:4", file_path: "a.rb", run_time: 0.0, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "failed"},
        {id: "a.rb:5", file_path: "a.rb", status: "failed"}
      ])
    }

    let(:existing_processing_data) do
      {
        "a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:4": {id: "a.rb:4", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:5": {id: "a.rb:5", file_path: "a.rb", expected_run_time: 0.1}
      }
    end

    # A result with no positive run_time is synthesized (e.g. an unexecuted
    # example reported as failed after a child died), not measured. Recording
    # its 0.0 would poison the run_times store: on the next run every poisoned
    # file sorts as instantaneous and the batched grouping packs them all into
    # one giant bucket.
    it "records run times only for examples that actually ran" do
      subject

      expect(run_times.reload.length).to eq(1)
      expect(run_times["a.rb:1"]).to eq(0.1)
      expect(run_times["a.rb:4"]).to be_nil
      expect(run_times["a.rb:5"]).to be_nil
    end
  end

  context "successfully pops an item off the queue" do
    # An empty completion: these contexts pin the POP half of the endpoint.
    # (The default 4-result body used to be silently discarded here — its ids
    # were not in processing — but late results now merge, which would drag
    # completion side effects into these pop-shape assertions.)
    let(:body) { JSON.generate([]) }

    let(:existing_pending_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}}
    end

    it { is_expected.to eq([200, {"content-type" => "application/json", "x-specwrk-status" => "0"}, [JSON.generate([{id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}])]]) }
    it { expect { subject }.to change { pending.reload.length }.from(1).to(0) }
    it { expect { subject }.to change { processing.reload["a.rb:2"] }.from(nil).to({expected_run_time: 0.1, file_path: "a.rb", id: "a.rb:2", worker_id: "foobar-0", processing_started_at: instance_of(Integer)}) }

    it "replaces the worker's in-flight index entry with the new bucket" do
      subject

      expect(in_flight.reload[worker_id][:ids]).to eq(["a.rb:2"])
    end
  end

  context "no items in the processing queue, but completed queue has items" do
    let(:body) { JSON.generate([]) } # see "successfully pops an item off the queue"

    let(:existing_completed_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1}}
    end

    it { is_expected.to eq([410, {"content-type" => "text/plain", "x-specwrk-status" => "0"}, ["That's a good lad. Run along now and go home."]]) }
  end

  context "no items in the pending queue, but something in the processing queue but none are expired" do
    let(:body) { JSON.generate([]) } # see "successfully pops an item off the queue"

    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
    end

    before { other_worker.last_seen_at = Time.now - 19 }

    it { is_expected.to eq([404, {"content-type" => "text/plain", "x-specwrk-status" => "0"}, ["This is not the path you're looking for, 'ol chap..."]]) }
  end

  context "no items in the pending queue, but something in the processing queue that is expired" do
    let(:existing_processing_data) do
      {"a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, processing_started_at: (Time.now - 100).to_i, worker_id: other_worker_id}}
    end

    let(:existing_in_flight_data) do
      {other_worker_id => {ids: ["a.rb:2"], processing_started_at: (Time.now - 100).to_i}}
    end

    before { other_worker.last_seen_at = Time.now - 21 }

    it "requeues the expired example into a new pending bucket" do
      expect { subject }.to change { processing["a.rb:2"][:worker_id] }

      expect(response[0]).to eq(200)
      body_examples = JSON.parse(response[2].first, symbolize_names: true)
      expect(body_examples.map { |ex| ex[:id] }).to eq(["a.rb:2"])
      expect(in_flight.reload[other_worker_id]).to be_nil
      expect(in_flight[worker_id][:ids]).to eq(["a.rb:2"])
    end
  end

  context "retries examples" do
    let(:existing_failure_counts_data) { {"a.rb:1" => 1, "a.rb:2" => 5} }

    let(:body) do
      JSON.generate([
        {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1, status: "failed"},
        {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1, status: "failed"},
        {id: "a.rb:3", file_path: "a.rb", expected_run_time: 0.1, status: "failed"},
        {id: "a.rb:4", file_path: "a.rb", expected_run_time: 0.1, status: "passed"}
      ])
    end

    let(:existing_processing_data) do
      {
        "a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:2": {id: "a.rb:2", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:3": {id: "a.rb:3", file_path: "a.rb", expected_run_time: 0.1},
        "a.rb:4": {id: "a.rb:4", file_path: "a.rb", expected_run_time: 0.1}
      }
    end

    let(:response_body) do
      JSON.generate([
        {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1, status: "failed"},
        {id: "a.rb:3", file_path: "a.rb", expected_run_time: 0.1, status: "failed"}
      ])
    end

    before { pending.max_retries = 5 }

    it { is_expected.to eq([200, {"content-type" => "application/json", "x-specwrk-status" => "1"}, [response_body]]) }
    it { expect { subject }.to change { processing.reload.length }.from(4).to(2) }
    it { expect { subject }.to change { failure_counts.reload.to_h.values }.from(match_array([1, 5])).to(match_array([2, 5, 1])) }
  end

  # These three isolate the individual retry ↔ exit-code guarantees (the
  # mixed-payload "retries examples" context above already covers the shape
  # of a request with several statuses at once). We're about to enable
  # --max-retries 1 in CI, so a retried failure must never taint the worker's
  # x-specwrk-status: the server-side tallies (worker[:failed], completed)
  # must exclude examples that are still eligible for another attempt.
  context "a retried failure does not mark the worker failed" do
    let(:existing_failure_counts_data) { {} }
    let(:existing_processing_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end
    let(:body) do
      JSON.generate([{id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1, status: "failed"}])
    end

    before { pending.max_retries = 1 }

    it "requeues the example, leaves completed untouched, and reports a clean exit status" do
      subject

      expect(response[0]).to eq(200)
      body_examples = JSON.parse(response[2].first, symbolize_names: true)
      expect(body_examples.map { |example| example[:id] }).to eq(["a.rb:1"])
      expect(response[1]["x-specwrk-status"]).to eq("0")

      expect(worker.reload["failed"]).to eq(0)
      expect(completed.reload).to be_empty
    end
  end

  context "a flake round-trips to green across two sequential requests from the same worker" do
    let(:existing_failure_counts_data) { {} }
    let(:existing_processing_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    before { pending.max_retries = 1 }

    # A fresh Rack::Request/endpoint instance per request — same worker_id and
    # run_id (env only swaps the body) — mirroring two real, sequential
    # complete_and_pop calls from the one worker process that picked the
    # bucket back up after its first (failed) attempt was requeued.
    def complete_and_pop(body_json)
      described_class.new(Rack::Request.new(env.merge("rack.input" => StringIO.new(body_json)))).response
    end

    it "ends green: completed has exactly one passed entry and the worker is never marked failed" do
      first_body = JSON.generate([{id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1, status: "failed"}])
      first_response = complete_and_pop(first_body)

      # The requeued example comes right back in the same response — nothing
      # else is pending — so the same worker's next bucket is its own retry.
      expect(first_response[0]).to eq(200)
      requeued_ids = JSON.parse(first_response[2].first, symbolize_names: true).map { |example| example[:id] }
      expect(requeued_ids).to eq(["a.rb:1"])

      second_body = JSON.generate([{id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1, status: "passed"}])
      second_response = complete_and_pop(second_body)

      expect(completed.reload.length).to eq(1)
      expect(completed["a.rb:1"][:status]).to eq("passed")
      expect(worker.reload["failed"]).to eq(0)
      expect(second_response[1]["x-specwrk-status"]).to eq("0")
    end
  end

  context "a retry-exhausted failure is red exactly once" do
    let(:existing_failure_counts_data) { {"a.rb:1" => 5} }
    let(:existing_processing_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end
    let(:body) do
      JSON.generate([{id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1, status: "failed"}])
    end

    before { pending.max_retries = 5 }

    it "is not requeued, is completed exactly once, and marks the worker failed" do
      subject

      expect(response[0]).to eq(410)
      expect(response[1]["x-specwrk-status"]).to eq("1")

      expect(pending.reload.length).to eq(0)
      expect(completed.reload.length).to eq(1)
      expect(completed["a.rb:1"][:status]).to eq("failed")
      expect(worker.reload["failed"]).to eq(1)
    end
  end

  # Duplicate executions of the same example — a falsely-expired bucket
  # reclaimed and re-run while its original owner was still alive, or a
  # payload carrying two attempts — must converge on the passing outcome.
  # These pin that convergence WITHOUT masking genuine failures: an example
  # that never passed anywhere still reds (see "a retry-exhausted failure is
  # red exactly once" above).
  context "a duplicate execution's failure arrives after the example already completed as passed" do
    let(:existing_completed_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "passed", worker_id: other_worker_id}}
    end

    let(:existing_processing_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    let(:body) do
      JSON.generate([{id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "failed"}])
    end

    it "keeps the pass, releases the processing entry, and does not mark this worker failed" do
      subject

      expect(completed.reload["a.rb:1"][:status]).to eq("passed")
      expect(processing.reload).to be_empty
      expect(worker.reload["failed"]).to eq(0)
      expect(response[1]["x-specwrk-status"]).to eq("0")
    end
  end

  context "a duplicate execution's pass supersedes an earlier completed failure" do
    let(:existing_completed_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "failed", worker_id: other_worker_id}}
    end

    let(:existing_worker_data) { {} }

    let(:existing_processing_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    let(:body) do
      JSON.generate([{id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "passed"}])
    end

    before { other_worker.merge!(passed: 3, failed: 1, pending: 0) }

    it "overwrites the failure and releases it from the failing worker's tally" do
      subject

      expect(completed.reload["a.rb:1"][:status]).to eq("passed")
      expect(worker.reload["passed"]).to eq(1)
      expect(other_worker.reload["failed"]).to eq(0)
      expect(response[1]["x-specwrk-status"]).to eq("0")
    end
  end

  context "one payload carries a failed and a passed attempt of the same example" do
    let(:existing_processing_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    # Worst-case order: the failed record comes LAST, so plain last-write-wins
    # dedup would complete the example as failed even though it passed.
    let(:body) do
      JSON.generate([
        {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "passed"},
        {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "failed"}
      ])
    end

    it "completes the example as passed and does not mark the worker failed" do
      subject

      expect(completed.reload["a.rb:1"][:status]).to eq("passed")
      expect(worker.reload["failed"]).to eq(0)
      expect(response[1]["x-specwrk-status"]).to eq("0")
    end
  end

  # A falsely-expired bucket's original owner reporting after the reclaim:
  # its processing entries are gone (requeued into pending, or completed by
  # the worker that stole the bucket). The work really ran — merge the
  # results under the same pass-beats-fail rule instead of discarding them.
  # The request-id replay layer above still guards duplicate requests.
  context "late results whose processing entries were already reclaimed" do
    let(:existing_processing_data) { {} }

    let(:body) do
      JSON.generate([
        {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "passed"},
        {id: "a.rb:2", file_path: "a.rb", run_time: 0.1, started_at: Time.now.iso8601, finished_at: Time.now.iso8601, status: "failed"}
      ])
    end

    it "merges the results and tallies them for this worker" do
      subject

      expect(completed.reload["a.rb:1"][:status]).to eq("passed")
      expect(completed["a.rb:2"][:status]).to eq("failed")
      expect(worker.reload["passed"]).to eq(1)
      expect(worker["failed"]).to eq(1)
      expect(response[1]["x-specwrk-status"]).to eq("1")
    end
  end

  context "a late pass arrives after the stolen re-run already completed the example as failed" do
    let(:existing_processing_data) { {} }

    let(:existing_completed_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "failed", worker_id: other_worker_id}}
    end

    let(:body) do
      JSON.generate([{id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "passed"}])
    end

    before { other_worker.merge!(passed: 0, failed: 1, pending: 0) }

    it "supersedes the failure and releases it from the other worker's tally" do
      subject

      expect(completed.reload["a.rb:1"][:status]).to eq("passed")
      expect(other_worker.reload["failed"]).to eq(0)
      expect(response[1]["x-specwrk-status"]).to eq("0")
    end
  end

  # A late FAILED result must not be requeued through the retry path: the
  # reclaim that erased its processing entry already requeued the example
  # (or someone completed it), so a retry here would duplicate the pending
  # entry. It goes straight to completed under pass-beats-fail instead.
  context "a late failure with retries remaining" do
    let(:existing_processing_data) { {} }
    let(:existing_failure_counts_data) { {} }

    let(:body) do
      JSON.generate([{id: "a.rb:1", file_path: "a.rb", run_time: 0.1, status: "failed"}])
    end

    before { pending.max_retries = 5 }

    it "is completed, not requeued" do
      subject

      expect(pending.reload.length).to eq(0)
      expect(completed.reload["a.rb:1"][:status]).to eq("failed")
    end
  end

  context "a second PendingStore instance writes a bucket while this endpoint's own pending is memoized stale" do
    let(:existing_processing_data) do
      {"a.rb:1": {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1}}
    end

    let(:body) do
      JSON.generate([
        {id: "a.rb:1", file_path: "a.rb", expected_run_time: 0.1, status: "failed"}
      ])
    end

    let(:interloper_example) { {"b.rb:1": {id: "b.rb:1", file_path: "b.rb"}} }

    before do
      pending.max_retries = 5

      # `retry_examples` is pre-calculated before the lock (with_response's
      # first line). Force this endpoint's own PendingStore#bucket_ids to
      # memoize empty right there — mirroring the early read Popable#examples
      # does via `pending.length.zero?` — then have a second instance write a
      # bucket before the lock section runs. Without `pending.reload` at the
      # top of that lock (complete_and_pop.rb), requeuing the retry would
      # merge against this endpoint's now-stale [] and silently clobber the
      # concurrent write.
      injected = false
      allow(instance).to receive(:retry_examples).and_wrap_original do |original|
        unless injected
          injected = true
          instance.send(:pending).bucket_ids
          pending.merge!(interloper_example)
        end
        original.call
      end
    end

    it "does not clobber the concurrently-written bucket when it requeues the retry" do
      subject

      response_ids = JSON.parse(response[2].first, symbolize_names: true).map { |example| example[:id] }
      pending_ids = pending.reload.bucket_ids.flat_map { |bucket_id| pending.bucket_store_for(bucket_id).examples.map { |example| example[:id] } }

      expect(response_ids + pending_ids).to include("b.rb:1")
    end
  end
end
