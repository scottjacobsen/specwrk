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
end
