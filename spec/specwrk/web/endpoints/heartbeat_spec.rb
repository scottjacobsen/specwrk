# frozen_string_literal: true

require "specwrk/web/endpoints/heartbeat"
require "support/specwrk/web/endpoints"

RSpec.describe Specwrk::Web::Endpoints::Heartbeat do
  include_context "worker endpoint"

  let(:workers_index) { Specwrk::Store.new(datastore_uri, run_scope("workers_index")) }

  it { expect(response).to eq(ok) }

  it "records the worker's contact in the run's workers index" do
    expect { response }.to change { workers_index.reload[worker_id] }.from(nil).to(be_within(5).of(Time.now.to_i))
  end

  context "without a worker id" do
    let(:worker_id) { "" }

    it "records nothing" do
      expect { response }.not_to change { workers_index.reload.to_h }
    end
  end
end
