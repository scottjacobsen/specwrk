# frozen_string_literal: true

require "specwrk/web/endpoints/base"
require "specwrk/store/memory_adapter"
require "support/specwrk/web/endpoints"

RSpec.describe Specwrk::Web::Endpoints::Base do
  include_context "worker endpoint"

  context "sets worker metadata at first look" do
    let!(:time) { Time.now.round(0) - 100 }

    before { allow(Time).to receive(:now).and_return(time) }

    it do
      expect { response }
        .to change { worker.reload.first_seen_at }
        .from(nil)
        .to(time)
    end

    it do
      expect { response }
        .to change { worker.reload.last_seen_at }
        .from(nil)
        .to(time)
    end
  end

  context "updates worker metadata on subsequent look" do
    let(:existing_worker_data) do
      {Specwrk::WorkerStore::FIRST_SEEN_AT_KEY => (Time.now - 100).to_i, Specwrk::WorkerStore::LAST_SEEN_AT_KEY => (Time.now - 100).to_i}
    end

    it { expect { response }.not_to change { worker.reload.first_seen_at } }
    it { expect { response }.to change { worker.reload.last_seen_at } }
  end

  # A large suite's seed body is tens of megabytes of JSON, so clients may
  # send it gzipped. Inflation lives in the shared body reader, which is what
  # makes the parsed payload identical either way for every endpoint.
  context "gzipped request bodies" do
    subject(:payload) { instance.send(:payload) }

    let(:request_method) { "POST" }
    let(:json) { JSON.generate(max_retries: 42, examples: [{id: "a.rb:1", file_path: "a.rb"}]) }
    let(:parsed) { {max_retries: 42, examples: [{id: "a.rb:1", file_path: "a.rb"}]} }

    context "with Content-Encoding: gzip" do
      let(:body) { Zlib.gzip(json) }
      let(:env) { super().merge("HTTP_CONTENT_ENCODING" => "gzip") }

      it { is_expected.to eq(parsed) }
    end

    context "with the header cased and padded as a proxy might rewrite it" do
      let(:body) { Zlib.gzip(json) }
      let(:env) { super().merge("HTTP_CONTENT_ENCODING" => " GZIP ") }

      it { is_expected.to eq(parsed) }
    end

    # The compatibility half: a client that predates compression sends no
    # Content-Encoding, and its body must still be read verbatim.
    context "without Content-Encoding" do
      let(:body) { json }

      it { is_expected.to eq(parsed) }
    end

    context "with an empty body" do
      let(:body) { "" }
      let(:env) { super().merge("HTTP_CONTENT_ENCODING" => "gzip") }

      it "has no payload rather than failing to inflate nothing" do
        expect(payload).to be_nil
      end
    end
  end

  # Run-scoped keys wrap the run id in a Redis Cluster hash tag so a run's
  # stores and lock all land in the same cluster slot.
  context "datastore key format" do
    let(:memory_uri) { "memory:///" }
    let(:env_vars) { {"SPECWRK_SRV_STORE_URI" => memory_uri} }

    before { Specwrk::Store::MemoryAdapter.clear }

    it "hash-tags every run-scoped store key with the run id" do
      instance.send(:pending).merge!({
        "./spec/a_spec.rb[1:1]" => {id: "./spec/a_spec.rb[1:1]"},
        "./spec/a_spec.rb[1:2]" => {id: "./spec/a_spec.rb[1:2]"}
      })
      instance.send(:processing)[:x] = 1
      instance.send(:completed)[:x] = 2
      instance.send(:failure_counts)[:x] = 3
      instance.send(:metadata)[:x] = 4
      instance.send(:worker)[:x] = 5

      bucket_id = Specwrk::PendingStore.new(memory_uri, "{main}/pending").bucket_ids.first
      expect(bucket_id).not_to be_nil
      expect(Specwrk::BucketStore.new(memory_uri, "{main}/pending/buckets/#{bucket_id}").examples).to eq([{id: "./spec/a_spec.rb[1:1]"}, {id: "./spec/a_spec.rb[1:2]"}])

      expect(Specwrk::Store.new(memory_uri, "{main}/processing")[:x]).to eq(1)
      expect(Specwrk::Store.new(memory_uri, "{main}/completed")[:x]).to eq(2)
      expect(Specwrk::Store.new(memory_uri, "{main}/failure_counts")[:x]).to eq(3)
      expect(Specwrk::Store.new(memory_uri, "{main}/metadata")[:x]).to eq(4)
      expect(Specwrk::Store.new(memory_uri, "{main}/workers/foobar-0")[:x]).to eq(5)
    end

    it "keeps the cross-run run_times store un-tagged" do
      instance.send(:run_times)[:x] = 1.23

      expect(Specwrk::Store.new(memory_uri, "run_times")[:x]).to eq(1.23)
    end

    it "locks on the hash-tagged run id" do
      allow(Specwrk::Store).to receive(:with_lock).and_yield

      instance.send(:with_lock) { nil }

      expect(Specwrk::Store).to have_received(:with_lock).with(anything, "{main}")
    end
  end

  # Run-scoped stores expire (SPECWRK_SRV_RUN_TTL, default one day) so a
  # long-lived server doesn't accumulate every run's data forever; the
  # cross-run stores are the deliberate permanent set.
  context "run-scoped store ttl" do
    let(:memory_uri) { "memory:///" }
    let(:env_vars) { {"SPECWRK_SRV_STORE_URI" => memory_uri} }

    before { Specwrk::Store::MemoryAdapter.clear }

    def spy_store_constructors!
      allow(Specwrk::PendingStore).to receive(:new).and_call_original
      allow(Specwrk::ProcessingStore).to receive(:new).and_call_original
      allow(Specwrk::CompletedStore).to receive(:new).and_call_original
      allow(Specwrk::WorkerStore).to receive(:new).and_call_original
      allow(Specwrk::Store).to receive(:new).and_call_original
    end

    it "constructs every run-scoped store with the default 24h ttl" do
      spy_store_constructors!

      instance.send(:pending)
      instance.send(:processing)
      instance.send(:completed)
      instance.send(:failure_counts)
      instance.send(:metadata)
      instance.send(:workers_index)
      instance.send(:worker)

      expect(Specwrk::PendingStore).to have_received(:new).with(memory_uri, "{main}/pending", ttl: 86400)
      expect(Specwrk::ProcessingStore).to have_received(:new).with(memory_uri, "{main}/processing", ttl: 86400)
      expect(Specwrk::CompletedStore).to have_received(:new).with(memory_uri, "{main}/completed", ttl: 86400)
      expect(Specwrk::WorkerStore).to have_received(:new).with(memory_uri, "{main}/workers/foobar-0", ttl: 86400)
      expect(Specwrk::Store).to have_received(:new).with(memory_uri, "{main}/failure_counts", ttl: 86400)
      expect(Specwrk::Store).to have_received(:new).with(memory_uri, "{main}/metadata", ttl: 86400)
      expect(Specwrk::Store).to have_received(:new).with(memory_uri, "{main}/workers_index", ttl: 86400)
    end

    it "constructs the cross-run stores without a ttl" do
      spy_store_constructors!

      instance.send(:run_times)
      instance.send(:runs_index)

      expect(Specwrk::Store).to have_received(:new).with(memory_uri, "run_times")
      expect(Specwrk::Store).to have_received(:new).with(memory_uri, "runs_index")
    end

    context "with SPECWRK_SRV_RUN_TTL set" do
      let(:env_vars) { {"SPECWRK_SRV_STORE_URI" => memory_uri, "SPECWRK_SRV_RUN_TTL" => "120"} }

      it "uses the configured ttl" do
        spy_store_constructors!

        instance.send(:pending)

        expect(Specwrk::PendingStore).to have_received(:new).with(memory_uri, "{main}/pending", ttl: 120)
      end
    end

    context "with SPECWRK_SRV_RUN_TTL=0" do
      let(:env_vars) { {"SPECWRK_SRV_STORE_URI" => memory_uri, "SPECWRK_SRV_RUN_TTL" => "0"} }

      it "disables expiry" do
        spy_store_constructors!

        instance.send(:pending)
        instance.send(:metadata)

        expect(Specwrk::PendingStore).to have_received(:new).with(memory_uri, "{main}/pending", ttl: nil)
        expect(Specwrk::Store).to have_received(:new).with(memory_uri, "{main}/metadata", ttl: nil)
      end
    end
  end
end
