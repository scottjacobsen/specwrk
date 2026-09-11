require "fileutils"
require "tmpdir"
require "rspec_junit_formatter"
require "parallel_tests/rspec/runtime_logger"

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

    # The real RSpec runner in a forked child, as Worker#run_in_fork does: the
    # child runs its bucket and hard-exits, so whatever the log holds once the
    # parent reaps it is what CI gets. The child chdirs into a tmpdir of
    # generated spec files, keeping this suite's .rspec and .rspec_status out
    # of its run.
    context "when SPECWRK_RUNTIME_LOG is set" do
      let(:dir) { Dir.mktmpdir }
      let(:log_path) { File.join(dir, "runtime.log") }
      let(:line_pattern) { /\A\S+_spec\.rb:\d+(\.\d+)?(e-\d+)?\z/ }

      before { stub_const("ENV", ENV.to_h.except("SPECWRK_JUNIT_DIR").merge("SPECWRK_RUNTIME_LOG" => log_path, "TEST_ENV_NUMBER" => "")) }
      after { FileUtils.rm_rf(dir) }

      # One-example spec files named <prefix>_<i>_spec.rb; returns their bucket.
      def write_spec_files(prefix, count, body: "expect(1).to eq(1)")
        Array.new(count) do |i|
          name = format("%s_%03d_spec.rb", prefix, i)
          File.write(File.join(dir, name), "RSpec.describe(#{name.inspect}) { it { #{body} } }\n")
          {id: "./#{name}[1:1]"}
        end
      end

      def run_bucket_in_fork(executor, bucket)
        fork do
          Dir.chdir(dir)
          $stdout.reopen(File::NULL)
          RSpec.configuration.order = :defined # run the bucket's files in order
          executor.run(bucket)
          Process.exit!(0)
        rescue Exception => e # standard:disable Lint/RescueException -- report the child's failure, then hard-exit like the worker
          warn e.full_message
          Process.exit!(1)
        end
      end

      def wait_all(pids)
        pids.each do |pid|
          _, status = Process.wait2(pid)
          expect(status).to be_success
        end
      end

      def logged_files
        File.readlines(log_path, chomp: true)
          .each { |line| expect(line).to match(line_pattern) }
          .map { |line| line.split(":").first }
      end

      it "appends each sequential bucket's per-file runtimes, keeping every earlier line" do
        File.write(log_path, "earlier_spec.rb:1.5\n")
        first = write_spec_files("first", 2)
        second = write_spec_files("second", 1)

        wait_all([run_bucket_in_fork(instance, first)])
        wait_all([run_bucket_in_fork(instance, second)])

        expect(File.readlines(log_path, chomp: true).first).to eq("earlier_spec.rb:1.5")
        expect(logged_files).to contain_exactly("earlier_spec.rb", "first_000_spec.rb", "first_001_spec.rb", "second_000_spec.rb")
      end

      # Every bucket ends with an example that sleeps until a shared deadline, so
      # all children reach the logger's end-of-run dump together, each with more
      # than an IO buffer (8KB) of lines — the shape that tears a line when a
      # buffered flush straddles the flock.
      it "keeps every line whole when concurrent children dump at the same moment" do
        buckets = Array.new(4) { |c| write_spec_files("child#{c}_#{"x" * 60}", 150) }
        deadline = Process.clock_gettime(Process::CLOCK_REALTIME) + 2
        buckets.each_with_index do |bucket, c|
          bucket.concat write_spec_files("child#{c}_barrier", 1, body: "sleep([#{deadline} - Process.clock_gettime(Process::CLOCK_REALTIME), 0].max)")
        end

        wait_all(buckets.map { |bucket| run_bucket_in_fork(instance, bucket) })

        expect(logged_files).to match_array(Dir.children(dir).grep(/_spec\.rb\z/))
      end
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

    # Determinism: this pins the no-knob shape (exactly three add_formatter
    # calls), regardless of whatever SPECWRK_JUNIT_DIR / SPECWRK_RUNTIME_LOG
    # happen to be set to in the ambient environment. Nested contexts merge
    # their knob into this already-stubbed ENV.
    before { stub_const("ENV", ENV.to_h.except("SPECWRK_JUNIT_DIR", "SPECWRK_RUNTIME_LOG")) }

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

    context "when SPECWRK_RUNTIME_LOG is set" do
      let(:log_dir) { Dir.mktmpdir }
      let(:log_path) { File.join(log_dir, "runtime_logs", "node-0.log") }

      before { stub_const("ENV", ENV.to_h.merge("SPECWRK_RUNTIME_LOG" => log_path, "TEST_ENV_NUMBER" => "")) }
      after { FileUtils.rm_rf(log_dir) }

      # sync pins the concurrency guarantee: the logger flocks around its puts
      # but flushes only after unlocking, so buffered output could tear.
      it "adds a RuntimeLogger writing unbuffered to a log it creates, directory included" do
        stub_rspec_globals!
        added = []
        allow(RSpec.configuration).to receive(:add_formatter) { |formatter| added << formatter }

        expect(instance.reset!).to eq(true)

        logger = added.find { |formatter| formatter.is_a?(ParallelTests::RSpec::RuntimeLogger) }
        expect(logger.output.path).to eq(log_path)
        expect(logger.output.sync).to be(true)
        expect(File.exist?(log_path)).to be(true)
      end

      it "leaves an existing log's lines in place (appends, never truncates)" do
        FileUtils.mkdir_p(File.dirname(log_path))
        File.write(log_path, "spec/earlier_spec.rb:1.5\n")
        stub_rspec_globals!

        instance.reset!

        expect(File.read(log_path)).to eq("spec/earlier_spec.rb:1.5\n")
      end
    end

    context "when SPECWRK_RUNTIME_LOG is unset" do
      it "adds no RuntimeLogger" do
        stub_rspec_globals!
        expect(RSpec.configuration).not_to receive(:add_formatter).with(an_instance_of(ParallelTests::RSpec::RuntimeLogger))

        expect(instance.reset!).to eq(true)
      end
    end

    context "when SPECWRK_RUNTIME_LOG is set but the parallel_tests gem is not available" do
      let(:log_dir) { Dir.mktmpdir }
      let(:log_path) { File.join(log_dir, "runtime.log") }

      before do
        stub_const("ENV", ENV.to_h.merge("SPECWRK_RUNTIME_LOG" => log_path, "TEST_ENV_NUMBER" => ""))
        allow_any_instance_of(described_class).to receive(:require)
          .with("parallel_tests/rspec/runtime_logger")
          .and_raise(LoadError)
      end

      after { FileUtils.rm_rf(log_dir) }

      # Built after the require stub, for the same reason as the JUnit case above.
      it "warns once and continues without a runtime log" do
        expect_any_instance_of(described_class).to receive(:warn)
          .with(a_string_including("parallel_tests"))
          .once

        instance = described_class.new
        stub_rspec_globals!
        expect(RSpec.configuration).not_to receive(:add_formatter).with(an_instance_of(ParallelTests::RSpec::RuntimeLogger))

        expect(instance.reset!).to eq(true)
        expect(File.exist?(log_path)).to be(false)
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
