# frozen_string_literal: true

require "specwrk/web/endpoints/metrics"
require "specwrk/store/memory_adapter"
require "support/specwrk/web/endpoints"

RSpec.describe Specwrk::Web::Endpoints::Metrics do
  include_context "worker endpoint"

  # The memory adapter's class-level storage outlives each example; wipe it
  # before the shared context's before hook re-seeds the stores.
  prepend_before { Specwrk::Store::MemoryAdapter.clear }

  let(:base_uri) { "memory:///" }

  let(:runs_index) { Specwrk::Store.new(datastore_uri, "runs_index") }
  let(:workers_index) { Specwrk::Store.new(datastore_uri, run_scope("workers_index")) }

  let(:body_text) { response[2].first }

  def gauge_value(name)
    body_text[/^#{name} (.+)$/, 1]&.to_f
  end

  let(:gauge_names) do
    %w[
      specwrk_runs_active
      specwrk_pending_examples
      specwrk_pending_buckets
      specwrk_processing_examples
      specwrk_completed_examples
      specwrk_failed_examples
      specwrk_workers_connected
      specwrk_workers_stale
      specwrk_oldest_active_run_age_seconds
      specwrk_run_times_size
      specwrk_metrics_truncated
      specwrk_server_scrape_duration_seconds
    ]
  end

  context "with no runs" do
    it "responds 200 with the Prometheus text content type" do
      expect(response[0]).to eq(200)
      expect(response[1]["content-type"]).to eq("text/plain; version=0.0.4")
    end

    it "emits HELP and TYPE for every gauge and zeroes for all counts" do
      gauge_names.each do |name|
        expect(body_text).to include("# HELP #{name} ")
        expect(body_text).to include("# TYPE #{name} gauge")
      end

      expect(gauge_value("specwrk_runs_active")).to eq(0)
      expect(gauge_value("specwrk_pending_examples")).to eq(0)
      expect(gauge_value("specwrk_workers_connected")).to eq(0)
      expect(gauge_value("specwrk_metrics_truncated")).to eq(0)
    end

    it "emits valid text format 0.0.4: name-value samples and a trailing newline" do
      expect(body_text).to end_with("\n")

      body_text.each_line do |line|
        next if line.start_with?("#")

        expect(line).to match(/\A[a-z_]+ \d+(\.\d+)?(e-?\d+)?\n\z/)
      end
    end
  end

  context "with an active run" do
    let(:existing_pending_data) do
      {
        "a.rb:1": {id: "a.rb:1", file_path: "a.rb"},
        "a.rb:2": {id: "a.rb:2", file_path: "a.rb"},
        "b.rb:1": {id: "b.rb:1", file_path: "b.rb"}
      }
    end

    let(:existing_processing_data) do
      {
        "c.rb:1": {id: "c.rb:1", file_path: "c.rb", worker_id: worker_id},
        "c.rb:2": {id: "c.rb:2", file_path: "c.rb", worker_id: worker_id}
      }
    end

    let(:existing_completed_data) do
      {"d.rb:1": {id: "d.rb:1", file_path: "d.rb", status: "passed"}}
    end

    let(:existing_failure_counts_data) { {"e.rb:1": 1} }
    let(:existing_run_times_data) { {"a.rb:1": 0.1, "d.rb:1": 0.2} }

    let(:started_at_iso8601) { (Time.now - 120).iso8601 }

    before do
      runs_index[run_id] = Time.now.to_i
      metadata[:started_at] = started_at_iso8601

      workers_index["fresh-worker"] = Time.now.to_i
      workers_index["stale-worker"] = Time.now.to_i - 3600
    end

    it "reports queue state aggregated from the run's stores" do
      expect(gauge_value("specwrk_runs_active")).to eq(1)
      expect(gauge_value("specwrk_pending_examples")).to eq(3)
      expect(gauge_value("specwrk_pending_buckets")).to eq(2)
      expect(gauge_value("specwrk_processing_examples")).to eq(2)
      expect(gauge_value("specwrk_completed_examples")).to eq(1)
      expect(gauge_value("specwrk_failed_examples")).to eq(1)
      expect(gauge_value("specwrk_run_times_size")).to eq(2)
      expect(gauge_value("specwrk_metrics_truncated")).to eq(0)
    end

    it "classifies workers by the heartbeat-expiry window" do
      expect(gauge_value("specwrk_workers_connected")).to eq(1)
      expect(gauge_value("specwrk_workers_stale")).to eq(1)
    end

    it "reports the oldest run's age from its metadata started_at" do
      expect(gauge_value("specwrk_oldest_active_run_age_seconds")).to be_within(5).of(120)
    end

    it "does not record scrape headers as worker or run state" do
      response

      expect(workers_index.reload.length).to eq(2)
      expect(metadata.reload[:started_at]).to eq(started_at_iso8601)
    end
  end

  context "with two active runs" do
    let(:other_run_metadata) { Specwrk::Store.new(datastore_uri, "{other}/metadata") }
    let(:other_run_processing) { Specwrk::Store.new(datastore_uri, "{other}/processing") }

    let(:existing_processing_data) do
      {"c.rb:1": {id: "c.rb:1", file_path: "c.rb"}}
    end

    before do
      runs_index[run_id] = Time.now.to_i
      runs_index["other"] = Time.now.to_i

      metadata[:started_at] = (Time.now - 60).iso8601
      other_run_metadata["started_at"] = (Time.now - 300).iso8601
      other_run_processing.merge!("x.rb:1" => {id: "x.rb:1"})
    end

    it "sums across runs without emitting run labels" do
      expect(gauge_value("specwrk_runs_active")).to eq(2)
      expect(gauge_value("specwrk_processing_examples")).to eq(2)
      expect(gauge_value("specwrk_oldest_active_run_age_seconds")).to be_within(5).of(300)

      # No per-run labels: run ids are CI-generated UUIDs, so labeling would
      # create unbounded series cardinality.
      expect(body_text).not_to include("{")
      expect(body_text).not_to include("other")
    end
  end

  context "with an index entry whose run has no metadata" do
    before { runs_index[run_id] = Time.now.to_i }

    it "does not count the run as active" do
      expect(gauge_value("specwrk_runs_active")).to eq(0)
    end
  end

  context "with an index entry older than 24 hours" do
    before do
      runs_index["ancient"] = Time.now.to_i - described_class::RUN_TTL_SECONDS - 60

      runs_index[run_id] = Time.now.to_i
      metadata[:started_at] = Time.now.iso8601
    end

    it "ignores it and prunes it from the index" do
      expect(gauge_value("specwrk_runs_active")).to eq(1)

      expect(runs_index.reload["ancient"]).to be_nil
      expect(runs_index.reload[run_id]).not_to be_nil
    end
  end

  context "with more active runs than the collection cap" do
    before do
      (described_class::MAX_RUNS + 1).times { |n| runs_index["run-#{n}"] = Time.now.to_i }
    end

    it "emits only the cheap aggregates plus the truncation flag" do
      expect(gauge_value("specwrk_metrics_truncated")).to eq(1)
      expect(gauge_value("specwrk_runs_active")).to eq(described_class::MAX_RUNS + 1)
      expect(gauge_value("specwrk_run_times_size")).to eq(0)
      expect(gauge_value("specwrk_server_scrape_duration_seconds")).not_to be_nil

      expect(body_text).not_to include("specwrk_pending_examples")
      expect(body_text).not_to include("specwrk_workers_connected")
    end
  end

  context "HEAD requests" do
    let(:request_method) { "HEAD" }

    it { is_expected.to eq([200, {}, []]) }
  end
end
