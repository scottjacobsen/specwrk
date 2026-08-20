# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require "specwrk/list_examples"

RSpec.describe Specwrk::ListExamples do
  around do |ex|
    saved = %w[SPECWRK_SEED_JOBS SPECWRK_PRELOAD].to_h { |key| [key, ENV[key]] }
    saved.each_key { |key| ENV.delete(key) }
    ex.run
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  describe "#examples" do
    subject { instance.examples }

    let(:instance) { described_class.new("foo") }
    let(:runner_dbl) { instance_double(RSpec::Core::Runner) }
    let(:tmpfile_dbl) do
      instance_double(Tempfile).tap do |dbl|
        allow(Tempfile).to receive(:new)
          .and_return(dbl)
      end
    end

    before do
      expect(RSpec.configuration).to receive(:files_or_directories_to_run=)
        .with("foo")

      expect(RSpec::Core::Formatters).to receive(:register)
        .with(described_class, :stop)

      expect(RSpec.configuration).to receive(:add_formatter)
        .with(instance)

      expect(RSpec.configuration).to receive(:files_to_run)
        .and_return(["1_spec.rb", "2_spec.rb"])

      configuration_options_dbl = instance_double(RSpec::Core::ConfigurationOptions).tap do |dbl|
        expect(RSpec::Core::ConfigurationOptions).to receive(:new)
          .with(["--dry-run", "1_spec.rb", "2_spec.rb"])
          .and_return(dbl)
      end

      expect(RSpec::Core::Runner).to receive(:new)
        .with(configuration_options_dbl)
        .and_return(runner_dbl)
    end

    context "successfully ran" do
      it "doesn't print the the out to stdout" do
        expect(runner_dbl).to receive(:run)
          .with($stderr, tmpfile_dbl)
          .and_return(0)

        expect(subject).to eq([])
      end
    end

    context "failed to run" do
      it "prints the out to stdout" do
        expect(runner_dbl).to receive(:run)
          .with($stderr, tmpfile_dbl)
          .and_return(1)

        expect(tmpfile_dbl).to receive(:rewind)
        expect(tmpfile_dbl).to receive(:each_line)
          .and_yield("1")

        expect($stdout).to receive(:print)
          .with("1")

        expect(subject).to eq([])
      end
    end

    # One job is the single-process path this class has always taken; nothing
    # about it may become fork-dependent.
    context "with a single job" do
      it "enumerates in this process" do
        expect(instance).not_to receive(:fork)
        expect(runner_dbl).to receive(:run).and_return(0)

        expect(subject).to eq([])
      end
    end
  end

  describe "#initialize" do
    it "defaults the job count to SPECWRK_SEED_JOBS" do
      ENV["SPECWRK_SEED_JOBS"] = "4"

      expect(described_class.new("spec").instance_variable_get(:@jobs)).to eq(4)
    end

    it "prefers an explicit job count over SPECWRK_SEED_JOBS" do
      ENV["SPECWRK_SEED_JOBS"] = "4"

      expect(described_class.new("spec", jobs: 2).instance_variable_get(:@jobs)).to eq(2)
    end

    it "floors the job count at one" do
      expect(described_class.new("spec", jobs: 0).instance_variable_get(:@jobs)).to eq(1)
      expect(described_class.new("spec", jobs: -3).instance_variable_get(:@jobs)).to eq(1)
      expect(described_class.new("spec").instance_variable_get(:@jobs)).to eq(1)
    end
  end

  describe "#slice_evenly" do
    subject { described_class.new("spec").send(:slice_evenly, files, count) }

    let(:files) { %w[a b c d e f g] }

    context "when the files divide evenly" do
      let(:files) { %w[a b c d e f] }
      let(:count) { 2 }

      it { is_expected.to eq([%w[a b c], %w[d e f]]) }
    end

    context "when the files do not divide evenly" do
      let(:count) { 3 }

      it "hands the remainder to the earliest slices" do
        is_expected.to eq([%w[a b c], %w[d e], %w[f g]])
      end
    end

    context "when there are fewer files than jobs" do
      let(:files) { %w[a b] }
      let(:count) { 5 }

      it "never produces an empty slice" do
        is_expected.to eq([%w[a], %w[b]])
      end
    end

    context "when there are no files" do
      let(:files) { [] }
      let(:count) { 4 }

      it { is_expected.to eq([]) }
    end

    # Round-robin or size-balanced interleaving would reorder the files
    # relative to a single-process load, which changes the ids of examples
    # whose groups depend on an earlier file (shared examples, custom DSLs).
    context "for any job count" do
      it "covers every file exactly once, in order" do
        (1..9).each do |jobs|
          slices = described_class.new("spec").send(:slice_evenly, files, jobs)

          expect(slices.flatten).to eq(files)
          expect(slices.length).to eq([jobs, files.length].min)
        end
      end
    end
  end

  describe "forked enumeration" do
    let(:instance) { described_class.new(["spec"], jobs: 2) }
    let(:slices) { [["/tmp/a_spec.rb", "/tmp/b_spec.rb"], ["/tmp/c_spec.rb"]] }

    describe "#run_jobs" do
      subject { instance.send(:run_jobs, slices) }

      # Every job writes its slice to its own tempfile; nothing here forks so
      # the merge and its guards can be exercised deterministically.
      def stub_jobs(pids:, statuses:, contents:)
        allow(instance).to receive(:fork_job) do |files, output|
          index = slices.index(files)
          File.write(output.path, contents[index]) if contents[index]
          pids[index]
        end

        allow(Specwrk).to receive(:wait_for_pids_exit)
          .with(pids)
          .and_return(pids.zip(statuses).to_h)
      end

      context "when every job succeeds" do
        before do
          stub_jobs(
            pids: [111, 222],
            statuses: [0, 0],
            contents: [
              JSON.generate([{id: "./a_spec.rb[1:1]", file_path: "./a_spec.rb"}, {id: "./b_spec.rb[1:1]", file_path: "./b_spec.rb"}]),
              JSON.generate([{id: "./c_spec.rb[1:1]", file_path: "./c_spec.rb"}])
            ]
          )
        end

        it "merges the jobs in slice order" do
          expect(subject.flatten(1).map { |example| example[:id] })
            .to eq(["./a_spec.rb[1:1]", "./b_spec.rb[1:1]", "./c_spec.rb[1:1]"])
        end

        # Silent under-enumeration is the failure mode that matters most: a job
        # that loads its files and finds nothing still exits zero.
        it "reports each job's file and example counts" do
          expect { subject }.to output(/job 1\/2 \(2 files.*found 2 examples.*job 2\/2 \(1 files.*found 1 examples/m).to_stdout
        end

        it "removes its tempfiles" do
          paths = []
          allow(Tempfile).to receive(:new).and_wrap_original do |original, *args|
            original.call(*args).tap { |file| paths << file.path }
          end

          subject

          expect(paths.length).to eq(2)
          expect(paths.select { |path| File.exist?(path) }).to be_empty
        end
      end

      context "when a job exits non-zero" do
        before do
          stub_jobs(pids: [111, 222], statuses: [0, 1], contents: [JSON.generate([]), nil])
        end

        it "raises rather than seeding a partial list" do
          expect { subject }.to raise_error(
            Specwrk::SeedEnumerationError,
            %r{job 2/2 \(1 files, /tmp/c_spec\.rb\.\./tmp/c_spec\.rb\) exited 1}
          )
        end
      end

      context "when a job exits cleanly without writing anything" do
        before do
          stub_jobs(pids: [111, 222], statuses: [0, 0], contents: [JSON.generate([]), nil])
        end

        it "raises rather than seeding a partial list" do
          expect { subject }.to raise_error(Specwrk::SeedEnumerationError, %r{job 2/2 .* without writing any output})
        end
      end

      context "when a job writes truncated output" do
        before do
          stub_jobs(pids: [111, 222], statuses: [0, 0], contents: [JSON.generate([]), '[{"id":"./a'])
        end

        it "raises rather than seeding a partial list" do
          expect { subject }.to raise_error(Specwrk::SeedEnumerationError, %r{job 2/2 .* unreadable output})
        end
      end
    end

    describe "#forked_examples" do
      before { allow(instance).to receive(:serial_examples).and_return([{id: "serial"}]) }

      it "falls back to a single process when the platform cannot fork" do
        allow(instance).to receive(:fork_available?).and_return(false)

        expect(instance).not_to receive(:run_jobs)
        expect { expect(instance.examples).to eq([{id: "serial"}]) }
          .to output(/cannot fork/).to_stderr
      end

      # Without a preload the app boots once per job instead of once in total,
      # which makes parallel enumeration slower than serial rather than faster.
      it "warns when there is no preload file to boot the application" do
        allow(instance).to receive(:file_slices).and_return([])

        expect { instance.examples }.to output(/SPECWRK_PRELOAD is unset/).to_stderr
      end

      it "requires the preload file before forking" do
        ENV["SPECWRK_PRELOAD"] = "tempfile"
        allow(instance).to receive(:file_slices).and_return([])

        expect(instance).to receive(:require).with("tempfile")
        expect(Specwrk).to receive(:prepare_for_fork!)

        instance.examples
      end

      it "does not fork for a single slice" do
        allow(instance).to receive(:warn)
        allow(instance).to receive(:file_slices).and_return([["/tmp/a_spec.rb"]])

        expect(instance).not_to receive(:run_jobs)
        expect(instance.examples).to eq([{id: "serial"}])
      end
    end
  end

  # Enumeration is only worth parallelizing if the merged list is
  # indistinguishable from the single-process one, so run both for real. Out of
  # process: an in-process RSpec::Core::Runner would fight this suite's own
  # reporter and world for global state.
  describe "a real forked enumeration" do
    let(:project) { Dir.mktmpdir("specwrk-seed-jobs") }
    let(:gem_lib) { File.expand_path("../../lib", __dir__) }

    let(:script) do
      <<~RUBY
        require "json"
        require "specwrk/list_examples"

        ENV["SPECWRK_SEED"] = "1"
        examples = Specwrk::ListExamples.new(["spec"], jobs: Integer(ENV.fetch("JOBS"))).examples
        File.write(ENV.fetch("OUT"), JSON.generate(examples))
      RUBY
    end

    before do
      FileUtils.mkdir_p File.join(project, "spec", "nested")

      6.times do |index|
        path = (index.even? ? ["spec"] : ["spec", "nested"]) + ["job_#{index}_spec.rb"]

        File.write File.join(project, *path), <<~RUBY
          RSpec.describe "group #{index}" do
            it("passes") {}
            it("also passes") {}

            context "within a context" do
              it("passes too") {}
            end
          end
        RUBY
      end
    end

    after { FileUtils.remove_entry(project) }

    def enumerate(jobs)
      out = File.join(project, "examples-#{jobs}.json")
      log = File.join(project, "log-#{jobs}.txt")

      status = system(
        {"JOBS" => jobs.to_s, "OUT" => out},
        RbConfig.ruby, "-I", gem_lib, "-e", script,
        chdir: project, out: log, err: log
      )

      raise "enumeration with #{jobs} jobs failed:\n#{File.read(log)}" unless status

      [JSON.parse(File.read(out), symbolize_names: true), File.read(log)]
    end

    it "produces exactly the single-process example list" do
      serial, _ = enumerate(1)
      forked, log = enumerate(3)

      expect(serial.length).to eq(18)
      expect(forked).to eq(serial)
      expect(log).to include("job 1/3 (2 files", "job 2/3 (2 files", "job 3/3 (2 files")
    end
  end
end
