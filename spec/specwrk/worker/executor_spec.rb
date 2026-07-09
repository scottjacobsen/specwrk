require "fileutils"
require "tmpdir"
require "rspec_junit_formatter"

require "specwrk/worker/executor"

RSpec.describe Specwrk::Worker::Executor do
  let(:instance) { described_class.new }

  # Neutralizes the real RSpec-global mutations #reset! makes (add_formatter,
  # clear_examples, etc.) so calling it for real in a test doesn't attach
  # formatters to — or otherwise disturb — the RSpec process currently running
  # this very spec suite. Use plain `allow` (not `expect`) here: these tests
  # care about file-system side effects, not which formatters got added —
  # the #reset! examples below assert that precisely instead.
  def stub_rspec_globals!
    allow(RSpec).to receive(:clear_examples)
    allow(RSpec.world).to receive(:non_example_failure=)
    allow(RSpec.world).to receive(:wants_to_quit=)
    allow(RSpec.configuration).to receive(:add_formatter)
    allow(RSpec.configuration).to receive(:silence_filter_announcements=)
  end

  describe "#examples" do
    subject { instance.examples }

    it { is_expected.to be(instance.completion_formatter.examples) }
  end

  describe "#final_output" do
    subject { instance.final_output }

    it { is_expected.to be(instance.progress_formatter.final_output) }
  end

  describe "#flush_log" do
    let(:json_log_file_path) { File.join(Dir.tmpdir, "1.ndjson") }
    let(:examples) do
      [
        {foo: "bar"},
        {biz: "buzz"}
      ]
    end

    before do
      allow(instance).to receive(:json_log_file_path)
        .and_return(json_log_file_path)

      allow(instance).to receive(:completion_formatter)
        .and_return(instance_double(Specwrk::Worker::CompletionFormatter, examples: examples))
    end

    it "writes the ndjson file" do
      instance.flush_log
      instance.json_log_file.flush
      ndjson_contents = File.read(json_log_file_path)

      expect(ndjson_contents).to eq(
        %({"foo":"bar"}\n{"biz":"buzz"}\n)
      )
    end
  end

  describe "#run" do
    let(:examples) { [{id: "foo.rb:1"}, {id: "bar.rb:1"}] }
    let(:options_dbl) { instance_double(RSpec::Core::ConfigurationOptions) }
    let(:runner_dbl) { instance_double(RSpec::Core::Runner) }

    it "calls the rspec runner" do
      expect(instance).to receive(:reset!)
        .and_return(true)

      expect(RSpec::Core::ConfigurationOptions).to receive(:new)
        .with(["--format", "Specwrk::Worker::NullFormatter", "foo.rb:1", "bar.rb:1"])
        .and_return(options_dbl)

      expect(RSpec::Core::Runner).to receive(:new)
        .with(options_dbl)
        .and_return(runner_dbl)

      expect(runner_dbl).to receive(:run)
        .with($stderr, $stdout)
        .and_return("🇺🇸!Big Success!🇺🇸")
        .ordered

      # publish_junit! must only run after a normal return from the runner —
      # a raise instead abandons the .inprogress file, which is exactly the
      # truncation protection a SPECWRK_BUCKET_TIMEOUT-killed child needs.
      expect(instance).to receive(:publish_junit!).ordered

      expect(instance.run(examples)).to eq("🇺🇸!Big Success!🇺🇸")
    end
  end

  describe "#unexecuted_examples" do
    let(:assigned) do
      [
        {id: "foo.rb[1:1]", file_path: "foo.rb", line_number: 1},
        {id: "bar.rb[1:1]", file_path: "bar.rb", line_number: 1}
      ]
    end

    before do
      instance.instance_variable_set(:@assigned_examples, assigned)
      allow(instance).to receive(:examples).and_return([{id: "foo.rb[1:1]", status: "passed"}])
    end

    it "returns a failure for each assigned example that produced no result" do
      expect(instance.unexecuted_examples).to contain_exactly(
        a_hash_including(
          id: "bar.rb[1:1]",
          status: "failed",
          file_path: "bar.rb",
          line_number: 1,
          run_time: 0.0,
          exception: a_hash_including(class: "Specwrk::Worker::UnexecutedExample")
        )
      )
    end

    it "returns nothing when every assigned example was executed" do
      allow(instance).to receive(:examples)
        .and_return([{id: "foo.rb[1:1]", status: "passed"}, {id: "bar.rb[1:1]", status: "failed"}])

      expect(instance.unexecuted_examples).to eq([])
    end

    it "returns nothing when force quitting (let the server expire them instead)" do
      previous_force_quit = Specwrk.force_quit
      Specwrk.force_quit = true
      expect(instance.unexecuted_examples).to eq([])
    ensure
      Specwrk.force_quit = previous_force_quit
    end

    it "returns nothing before any examples have been assigned" do
      instance.instance_variable_set(:@assigned_examples, nil)
      expect(instance.unexecuted_examples).to eq([])
    end
  end

  describe "#reset!" do
    around do |ex|
      previous_force_quit = Specwrk.force_quit
      Specwrk.force_quit = true
      ex.run
      Specwrk.force_quit = previous_force_quit
    end

    # Determinism: this pins the no-JUnit-knob shape (exactly three
    # add_formatter calls), regardless of whatever SPECWRK_JUNIT_DIR happens
    # to be set to in the ambient environment.
    before { stub_const("ENV", ENV.to_h.except("SPECWRK_JUNIT_DIR")) }

    it "resets everything to a clean slate" do
      expect(instance.completion_formatter.examples).to receive(:clear)
      expect(RSpec).to receive(:clear_examples)
        .and_return(true)

      expect(RSpec.world).to receive(:non_example_failure=)
        .with(false)
        .and_return(false)

      expect(RSpec.world).to receive(:wants_to_quit=)
        .with(Specwrk.force_quit)
        .and_return(false)

      expect(RSpec.configuration).to receive(:add_formatter)
        .with(instance.progress_formatter)

      expect(RSpec.configuration).to receive(:add_formatter)
        .with(instance.completion_formatter)

      expect(RSpec.configuration).to receive(:add_formatter)
        .with(Specwrk::Worker::NullFormatter)

      expect(RSpec.configuration).to receive(:silence_filter_announcements=)
        .with(true)
        .and_return(true)

      expect(instance.reset!).to eq(true)
    end

    context "when SPECWRK_JUNIT_DIR is set" do
      let(:junit_dir) { Dir.mktmpdir }

      before { stub_const("ENV", ENV.to_h.merge("SPECWRK_JUNIT_DIR" => junit_dir)) }
      after { FileUtils.rm_rf(junit_dir) }

      it "adds a JUnit formatter instance and opens an .inprogress file" do
        expect(instance.completion_formatter.examples).to receive(:clear)
        expect(RSpec).to receive(:clear_examples)
          .and_return(true)

        expect(RSpec.world).to receive(:non_example_failure=)
          .with(false)
          .and_return(false)

        expect(RSpec.world).to receive(:wants_to_quit=)
          .with(Specwrk.force_quit)
          .and_return(false)

        expect(RSpec.configuration).to receive(:add_formatter)
          .with(instance.progress_formatter)

        expect(RSpec.configuration).to receive(:add_formatter)
          .with(instance.completion_formatter)

        expect(RSpec.configuration).to receive(:add_formatter)
          .with(Specwrk::Worker::NullFormatter)

        expect(RSpec.configuration).to receive(:add_formatter)
          .with(an_instance_of(RSpecJUnitFormatter))

        expect(RSpec.configuration).to receive(:silence_filter_announcements=)
          .with(true)
          .and_return(true)

        expect(instance.reset!).to eq(true)

        matching = Dir.glob(File.join(junit_dir, "*")).select do |path|
          path.match?(/rspec-.+-#{Process.pid}-1\.xml\.inprogress\z/)
        end
        expect(matching.length).to eq(1)
      end
    end

    context "when SPECWRK_JUNIT_DIR is set but the rspec_junit_formatter gem is not available" do
      let(:junit_dir) { Dir.mktmpdir }

      before do
        stub_const("ENV", ENV.to_h.merge("SPECWRK_JUNIT_DIR" => junit_dir))
        allow_any_instance_of(described_class).to receive(:require)
          .with("rspec_junit_formatter")
          .and_raise(LoadError)
      end

      after { FileUtils.rm_rf(junit_dir) }

      # Resolution happens eagerly in #initialize, so the instance must be
      # built here (after the require stub is in place), not via the shared
      # `let(:instance)`, which could be constructed too early.
      it "warns once and continues without JUnit output" do
        expect_any_instance_of(described_class).to receive(:warn)
          .with(a_string_including("rspec_junit_formatter"))
          .once

        instance = described_class.new

        expect(instance.completion_formatter.examples).to receive(:clear)
        expect(RSpec).to receive(:clear_examples)
          .and_return(true)

        expect(RSpec.world).to receive(:non_example_failure=)
          .with(false)
          .and_return(false)

        expect(RSpec.world).to receive(:wants_to_quit=)
          .with(Specwrk.force_quit)
          .and_return(false)

        expect(RSpec.configuration).to receive(:add_formatter)
          .with(instance.progress_formatter)

        expect(RSpec.configuration).to receive(:add_formatter)
          .with(instance.completion_formatter)

        expect(RSpec.configuration).to receive(:add_formatter)
          .with(Specwrk::Worker::NullFormatter)

        expect(RSpec.configuration).to receive(:silence_filter_announcements=)
          .with(true)
          .and_return(true)

        expect(instance.reset!).to eq(true)
        expect(Dir.glob(File.join(junit_dir, "*"))).to eq([])
      end
    end
  end

  describe "#publish_junit!" do
    let(:junit_dir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(junit_dir) }

    context "when SPECWRK_JUNIT_DIR is set" do
      before { stub_const("ENV", ENV.to_h.merge("SPECWRK_JUNIT_DIR" => junit_dir)) }

      it "renames the .inprogress file to .xml and closes the IO on success" do
        stub_rspec_globals!
        instance.reset! # add_junit_formatter! opens the .inprogress file

        junit_output = instance.instance_variable_get(:@junit_output)
        inprogress_path = junit_output.path
        final_path = inprogress_path.delete_suffix(".inprogress")

        instance.publish_junit!

        expect(junit_output.closed?).to be(true)
        expect(File.exist?(inprogress_path)).to be(false)
        expect(File.exist?(final_path)).to be(true)
      end

      it "leaves the .inprogress file in place when the runner raises (never publishes a truncated file)" do
        stub_rspec_globals!
        allow(instance).to receive(:reset!).and_call_original
        allow(RSpec::Core::Runner).to receive(:new).and_raise("boom")

        expect { instance.run([{id: "a.rb:1"}]) }.to raise_error("boom")

        junit_output = instance.instance_variable_get(:@junit_output)
        inprogress_path = junit_output.path
        final_path = inprogress_path.delete_suffix(".inprogress")

        expect(File.exist?(inprogress_path)).to be(true)
        expect(File.exist?(final_path)).to be(false)
      end
    end

    context "when SPECWRK_JUNIT_DIR is unset" do
      before { stub_const("ENV", ENV.to_h.except("SPECWRK_JUNIT_DIR")) }

      it "no-ops (nothing was ever opened to publish)" do
        expect { instance.publish_junit! }.not_to raise_error
      end
    end
  end

  describe "#progress_formatter" do
    subject { instance.progress_formatter }

    it { is_expected.to be_kind_of(Specwrk::Worker::ProgressFormatter) }
  end

  describe "#completion_formatter" do
    subject { instance.completion_formatter }

    it { is_expected.to be_kind_of(Specwrk::Worker::CompletionFormatter) }
  end
end
