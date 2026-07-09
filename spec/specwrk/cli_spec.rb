# frozen_string_literal: true

require "tmpdir"

require "specwrk/cli"
require "specwrk/cli_reporter"

RSpec.describe Specwrk::CLI::Seed do
  describe "#call" do
    let(:instance) { described_class.new }

    let(:client_env) do
      {uri: "http://localhost:5138", key: "", run: "seed-test", timeout: "5", network_retries: "1"}
    end

    around do |ex|
      saved = %w[SPECWRK_SRV_URI SPECWRK_SRV_KEY SPECWRK_RUN SPECWRK_TIMEOUT SPECWRK_NETWORK_RETRIES SPECWRK_SEED].to_h { |k| [k, ENV[k]] }
      ex.run
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    before do
      require "specwrk/list_examples"
      require "specwrk/client"

      allow(Specwrk::ListExamples).to receive(:new)
        .and_return(instance_double(Specwrk::ListExamples, examples: []))
    end

    # An empty enumeration almost always means the spec files failed to LOAD
    # during discovery (e.g. rails_helper needed a database that isn't there).
    # Seeding zero examples used to exit 0 — CI went on to run a suite of
    # nothing and looked green at the seed step.
    it "exits non-zero without contacting the server when no examples were enumerated" do
      expect(Specwrk::Client).not_to receive(:wait_for_server!)

      expect {
        expect { instance.call(max_retries: 0, dir: [], **client_env) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      }.to output(/no examples/i).to_stderr
    end
  end
end

RSpec.describe Specwrk::CLI::Work do
  describe "#status" do
    subject { instance.status }

    let(:instance) { described_class.new }

    before { instance.instance_variable_set(:@exited_pids, exited_pids) }

    context "when every worker exited cleanly" do
      let(:exited_pids) { {123 => 0, 456 => 0} }

      it { is_expected.to eq(0) }
    end

    context "when a worker exited with status 1" do
      let(:exited_pids) { {123 => 0, 456 => 1} }

      it { is_expected.to eq(1) }
    end

    context "when a worker exited with its failure count as the status" do
      let(:exited_pids) { {123 => 0, 456 => 7} }

      it { is_expected.to eq(1) }
    end
  end

  describe "#call" do
    subject { instance.call(**args) }

    let(:instance) { described_class.new }

    let(:args) do
      {
        uri: "http://localhost:5138", key: "", run: "work-test", timeout: "5", network_retries: "1",
        count: 1, output: File.join(Dir.tmpdir, "specwrk-work-cli-spec"), seed_waits: 10
      }
    end

    around do |ex|
      saved = %w[SPECWRK_ID SPECWRK_COUNT SPECWRK_SEED_WAITS SPECWRK_OUT SPECWRK_SRV_URI SPECWRK_SRV_KEY
        SPECWRK_RUN SPECWRK_TIMEOUT SPECWRK_NETWORK_RETRIES SPECWRK_RUN_SUMMARY].to_h { |k| [k, ENV[k]] }
      ex.run
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    before do
      allow(instance).to receive(:start_workers)
      allow(instance).to receive(:wait_for_workers_exit)
      allow(instance).to receive(:drain_outputs)
      allow(instance).to receive(:status).and_return(0)
    end

    context "SPECWRK_RUN_SUMMARY is unset (the default)" do
      before { ENV.delete("SPECWRK_RUN_SUMMARY") }

      # The /report fetch this drives is what's measured at median 13s / max
      # 27s per node at 80 workers — the dominant post-drain exit tail. It's
      # purely informational (exit status comes from the workers themselves),
      # so by default a worker node must skip it entirely rather than pay that
      # tax just to print a summary nobody reads on a CI node.
      it "does not instantiate CLIReporter or delay exit, and exits with the worker-derived status" do
        expect(Specwrk::CLIReporter).not_to receive(:new)

        expect { subject }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
    end

    context "SPECWRK_RUN_SUMMARY=1" do
      before { ENV["SPECWRK_RUN_SUMMARY"] = "1" }

      it "runs the best-effort run summary report" do
        reporter = instance_double(Specwrk::CLIReporter, report: 0)
        expect(Specwrk::CLIReporter).to receive(:new).and_return(reporter)

        expect { subject }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end

      it "keeps the best-effort rescue: a failing report is swallowed and the worker-derived status still wins" do
        allow(Specwrk::CLIReporter).to receive(:new).and_raise(Specwrk::UnhandledResponseError, "boom")

        expect {
          expect { subject }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        }.to output(/Skipping run summary report/).to_stderr
      end
    end
  end
end
