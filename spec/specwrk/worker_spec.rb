# frozen_string_literal: true

require "specwrk/worker"

RSpec.describe Specwrk::Worker do
  let(:client) { instance_double(Specwrk::Client, close: true, stats: {}) }
  let(:heartbeat_client) { instance_double(Specwrk::Client, close: true, stats: {}) }
  let(:tempfile) { instance_double(Tempfile, rewind: true) }
  let(:thread) { instance_double(Thread, kill: true) }

  let(:instance) { described_class.new }

  let(:executor) do
    instance_double Specwrk::Worker::Executor,
      final_output: tempfile,
      examples: %w[a.rb:1 b.rb:2],
      unexecuted_examples: []
  end

  before do
    allow(Specwrk::Client).to receive(:new)
      .and_return(client, heartbeat_client)

    allow(client).to receive(:fetch_examples) { [{id: "./a_spec.rb[1:1]"}, {id: "./b_spec.rb[1:2]"}] }

    allow(executor).to receive(:flush_log)

    allow(Specwrk::Worker::Executor).to receive(:new)
      .and_return(executor)

    allow(Thread).to receive(:new)
      .and_return(thread)

    allow(tempfile).to receive(:each_line)
      .and_yield("foo")
      .and_yield("bar")

    allow($stdout).to receive(:write) # default for e.g. the blank line before a bucket footer
    allow($stdout).to receive(:write)
      .with("foo")
    allow($stdout).to receive(:write)
      .with("bar")

    allow_any_instance_of(described_class).to receive(:log_ts)
  end

  around do |ex|
    final_output_reference = $final_output # standard:disable Style/GlobalVars
    $final_output = nil # standard:disable Style/GlobalVars
    ex.run
    $final_output = final_output_reference # standard:disable Style/GlobalVars
  end

  describe ".run!" do
    subject { described_class.run! }

    it "delegates to #run" do
      expect(described_class).to receive(:new)
        .and_return(instance)
      expect(instance).to receive(:run)

      described_class.run!
    end
  end

  describe "#run" do
    subject { instance.run }

    context "server connection refused" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!).and_raise(Errno::ECONNREFUSED) }

      it "warns and exits status 1" do
        expect(instance).to receive(:warn)
          .with(a_string_including("refusing connections"))

        expect(subject).to eq(1)
      end
    end

    context "server connection reset" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!).and_raise(Errno::ECONNRESET) }

      it "warns and exits with status 1" do
        expect(instance).to receive(:warn)
          .with(a_string_including("stopped responding"))

        expect(subject).to eq(1)
      end
    end

    context "no examples processed" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!) }

      it "returns 0 when no examples were processed, but server signals all examples completed" do
        expect(client).to receive(:worker_status)
          .and_return(0)
        expect(instance).to receive(:execute)
          .and_raise(Specwrk::CompletedAllExamplesError)

        expect(subject).to eq(0)
      end

      it "returns client's worker_status when no examples were processed, but server did not signal all examples completed" do
        expect(instance).to receive(:sleep)
          .with(1)
          .exactly(10).times

        expect(instance).to receive(:warn)
          .exactly(11).times

        expect(instance).to receive(:execute)
          .and_raise(Specwrk::WaitingForSeedError)
          .exactly(11).times

        expect(client).to receive(:worker_status)
          .and_return(42)

        expect(subject).to eq(42)
      end
    end

    context "Specwrk.force_quit" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!) }

      it "breaks the loop" do
        count = 0
        expect(instance).to receive(:execute).exactly(4).times
        expect(Specwrk).to receive(:force_quit).exactly(6).times do
          count += 1
          count >= 5
        end

        expect(subject).to eq(1)
      end
    end

    context "calls run_examples until CompletedAllExamplesError" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!) }

      it "breaks the loop and returns 0" do
        expect(client).to receive(:worker_status)
          .and_return(0)

        count = 1
        expect(instance).to receive(:execute).exactly(5).times do
          if count == 5
            raise Specwrk::CompletedAllExamplesError
          end

          count += 1
        end

        expect(subject).to eq(0)
      end

      # The parent's state matters too: forked children get ZEROED Coverage
      # counters (MRI resets them on fork), so anything executed only in the
      # parent — e.g. a Rails eager load during preload — is visible solely in
      # the parent's own coverage. The parent must flush exit-time state like
      # its children do, before the init script hard-exits the process.
      it "runs before_fork_exit hooks in the parent after the run completes" do
        expect(client).to receive(:worker_status).and_return(0)
        expect(instance).to receive(:execute).and_raise(Specwrk::CompletedAllExamplesError)

        expect(Specwrk).to receive(:before_fork_exit!)

        expect(subject).to eq(0)
      end
    end

    context "calls run_examples when WaitingForSeedError" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!) }

      it "waits up to 10s before exiting" do
        expect(instance).to receive(:sleep)
          .with(1)
          .exactly(10).times

        expect(instance).to receive(:execute)
          .and_raise(Specwrk::WaitingForSeedError)
          .exactly(11).times

        expect(instance).to receive(:warn)
          .with("No examples seeded yet, waiting...")
          .exactly(10).times

        expect(instance).to receive(:warn)
          .with("No examples seeded, giving up!")

        expect(client).to receive(:worker_status)
          .and_return(42)

        expect(subject).to eq(42)
      end
    end

    context "calls run_examples until NoMoreExamplesError" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!) }

      it "sleeps but doesn't break loop" do
        expect(client).to receive(:worker_status)
          .and_return(0)

        completed = false
        expect(instance).to receive(:sleep)
          .with(0.5)
          .exactly(4).times

        count = 0
        expect(instance).to receive(:execute).exactly(5).times do
          count += 1

          if count < 5
            raise Specwrk::NoMoreExamplesError
          else
            # breaks the loop
            completed = true
            raise Specwrk::CompletedAllExamplesError
          end
        end

        expect(subject).to eq(0)
        expect(completed).to eq(true) # ensures the loop was broken in the way we expected
      end
    end

    context "queue stays drained past the no-work limit" do
      before { allow(Specwrk::Client).to receive(:wait_for_server!) }

      it "exits cleanly instead of waiting forever (the CI no-output hang fix)" do
        allow(instance).to receive(:no_work_max).and_return(3)
        allow(client).to receive(:worker_status).and_return(0)

        expect(instance).to receive(:sleep)
          .with(0.5)
          .exactly(3).times

        expect(instance).to receive(:execute)
          .and_raise(Specwrk::NoMoreExamplesError)
          .exactly(4).times

        expect(subject).to eq(0)
      end
    end
  end

  describe "#execute" do
    it "fetches a bucket, runs it in a fork, and completes it with the results" do
      results = [{id: "a.rb:1", status: "passed"}]

      expect(instance).to receive(:run_in_fork)
        .with([{id: "./a_spec.rb[1:1]"}, {id: "./b_spec.rb[1:2]"}])
        .and_return(results)

      expect(instance).to receive(:complete_examples)
        .with(results)

      instance.execute
    end

    it "logs a bucket header with the rerun command and a footer with timing and status counts" do
      results = [
        {id: "./a_spec.rb[1:1]", status: "passed", run_time: 0.1},
        {id: "./b_spec.rb[1:2]", status: "failed", run_time: 0.2}
      ]

      allow(instance).to receive(:run_in_fork).and_return(results)
      allow(instance).to receive(:complete_examples)
      allow(instance).to receive(:rspec_seed_options).and_return(" --seed 1234")

      expect(instance).to receive(:log_ts).with("bucket 1: 2 examples from 2 files")
      expect(instance).to receive(:log_ts).with("bucket 1 rerun: bundle exec rspec --seed 1234 './a_spec.rb[1:1]' './b_spec.rb[1:2]'")
      expect(instance).to receive(:log_ts).with(a_string_matching(/\Abucket 1 done in \d+\.\ds: 1 passed, 1 failed, 0 pending\z/))

      instance.execute
    end

    it "warns when an unhandled error is raised fetching examples" do
      expect(client).to receive(:fetch_examples)
        .and_raise(Specwrk::UnhandledResponseError, "oops")

      expect(instance).not_to receive(:run_in_fork)
      expect(instance).not_to receive(:complete_examples)

      expect(instance).to receive(:warn)
        .with("oops")

      instance.execute
    end

    it "accumulates example count and total spec run time in @metrics" do
      results = [
        {id: "a.rb:1", status: "passed", run_time: 1.5},
        {id: "a.rb:2", status: "failed", run_time: nil} # synthesized (never actually ran); nil.to_f == 0
      ]

      allow(instance).to receive(:run_in_fork).and_return(results)
      allow(instance).to receive(:complete_examples)

      expect { instance.execute }
        .to change { instance.metrics[:examples] }.from(0).to(2)

      expect(instance.metrics[:example_time]).to eq(1.5)
    end
  end

  describe "#rspec_command" do
    before { allow(instance).to receive(:rspec_seed_options).and_return("") }

    it "collapses same-file example ids into rspec's multi-scope bracket syntax" do
      examples = [
        {id: "./spec/a_spec.rb[1:1]"},
        {id: "./spec/a_spec.rb[1:4:2]"},
        {id: "./spec/b_spec.rb[1:2]"}
      ]

      expect(instance.send(:rspec_command, examples))
        .to eq("bundle exec rspec './spec/a_spec.rb[1:1,1:4:2]' './spec/b_spec.rb[1:2]'")
    end

    it "keeps whole-file ids as bare paths, subsuming any scoped ids for that file" do
      examples = [
        {id: "./spec/a_spec.rb[1:1]"},
        {id: "./spec/a_spec.rb"},
        {id: "./spec/b_spec.rb"}
      ]

      expect(instance.send(:rspec_command, examples))
        .to eq("bundle exec rspec './spec/a_spec.rb' './spec/b_spec.rb'")
    end
  end

  describe "#rspec_seed_options" do
    subject { instance.send(:rspec_seed_options) }

    it "pins the configured seed when ordering is random, so reruns match CI's order" do
      allow(RSpec.configuration).to receive(:seed).and_return(1234)

      expect(subject).to eq(" --seed 1234")
    end

    it "is empty when ordering is not random (--seed would force random order)" do
      registry = instance_double(RSpec::Core::Ordering::Registry)
      allow(registry).to receive(:fetch).with(:global).and_return(RSpec::Core::Ordering::Identity.new)
      allow(RSpec.configuration).to receive(:ordering_registry).and_return(registry)

      expect(subject).to be_empty
    end
  end

  describe "#complete_examples" do
    let(:results) { [{id: "a.rb:1", status: "passed"}] }

    it "completes the given results and fetches the next bucket" do
      expect(client).to receive(:complete_and_fetch_examples)
        .with(results)
        .and_return("foobar")

      instance.complete_examples(results)

      expect(instance.instance_variable_get(:@next_examples)).to eq("foobar")
    end

    it "tries completing examples again when an unhandled error is raised" do
      expect(client).to receive(:complete_and_fetch_examples).with(results)
        .and_raise(Specwrk::UnhandledResponseError, "oops")
        .ordered

      expect(client).to receive(:complete_and_fetch_examples).with(results)
        .ordered

      expect(instance).to receive(:warn)
        .with("oops")
      expect(instance).to receive(:sleep)
        .with(1)

      instance.complete_examples(results)
    end
  end

  describe "#run_in_fork" do
    after { Specwrk.before_fork_exit_hooks.clear }

    # The child hard-exits (Process.exit! skips at_exit hooks), so state that
    # is normally flushed at exit — e.g. SimpleCov's resultset — must go
    # through before_fork_exit hooks. Real fork: the child inherits this
    # spec's stubs and the hook writes through to a file the parent can read.
    it "runs before_fork_exit hooks in the child before it exits" do
      flag = Tempfile.new("specwrk-hook-flag")
      flag.close
      Specwrk.before_fork_exit { File.write(flag.path, "ran in #{Process.pid}") }

      allow(executor).to receive(:run)
      results = instance.run_in_fork([{id: "a.rb:1", file_path: "a.rb"}])

      expect(File.read(flag.path)).to start_with("ran in ")
      expect(File.read(flag.path)).not_to eq("ran in #{Process.pid}") # ran in the child, not here
      expect(results).to eq(%w[a.rb:1 b.rb:2]) # executor double's examples, via the results file
    ensure
      flag&.unlink
    end

    it "counts the bucket and accumulates wall time in @metrics" do
      allow(executor).to receive(:run)

      expect { instance.run_in_fork([{id: "a.rb:1", file_path: "a.rb"}]) }
        .to change { instance.metrics[:buckets] }.from(0).to(1)

      expect(instance.metrics[:bucket_wall]).to be > 0
    end

    # ensure covers the kill-on-timeout return too, not just the normal path —
    # a hung bucket still counts against @metrics rather than vanishing from it.
    it "still counts the bucket when the child is killed for exceeding the timeout" do
      allow(instance).to receive(:wait_for_child).and_return(nil)
      allow(executor).to receive(:run)
      allow(executor).to receive(:unexecuted_failure).and_return({id: "a.rb:1", status: "failed"})

      expect { instance.run_in_fork([{id: "a.rb:1", file_path: "a.rb"}]) }
        .to change { instance.metrics[:buckets] }.from(0).to(1)
    end
  end

  describe "#decode_bucket_results" do
    let(:examples) { [{id: "a.rb:1", file_path: "a.rb", line_number: 1}] }

    it "parses the child's JSON payload on success" do
      data = JSON.generate([{id: "a.rb:1", status: "passed"}])

      expect(instance.decode_bucket_results(examples, true, data))
        .to eq([{id: "a.rb:1", status: "passed"}])
    end

    it "reports the bucket's examples as failures when the child failed" do
      allow(executor).to receive(:unexecuted_failure)
        .with(examples.first)
        .and_return({id: "a.rb:1", status: "failed"})
      allow(instance).to receive(:warn)

      expect(instance.decode_bucket_results(examples, false, ""))
        .to eq([{id: "a.rb:1", status: "failed"}])
    end

    it "reports failures when the child exited cleanly but wrote nothing" do
      allow(executor).to receive(:unexecuted_failure)
        .with(examples.first)
        .and_return({id: "a.rb:1", status: "failed"})
      allow(instance).to receive(:warn)

      expect(instance.decode_bucket_results(examples, true, ""))
        .to eq([{id: "a.rb:1", status: "failed"}])
    end
  end

  describe "#preload!" do
    around do |ex|
      original = ENV["SPECWRK_PRELOAD"]
      ex.run
      ENV["SPECWRK_PRELOAD"] = original
    end

    it "requires the SPECWRK_PRELOAD file when set" do
      ENV["SPECWRK_PRELOAD"] = "tempfile"

      expect(instance).to receive(:require).with("tempfile")
      expect(client).to receive(:reconnect)

      instance.preload!
    end

    # The socket died server-side while the preload ran; a stale connection
    # here means the first /pop logs a pointless EOFError retry.
    it "reconnects the data client after the preload's long idle gap" do
      ENV["SPECWRK_PRELOAD"] = "tempfile"

      allow(instance).to receive(:require)
      expect(client).to receive(:reconnect)

      instance.preload!
    end

    it "does nothing when SPECWRK_PRELOAD is unset" do
      ENV.delete("SPECWRK_PRELOAD")

      expect(instance).not_to receive(:require)
      expect(client).not_to receive(:reconnect)

      instance.preload!
    end
  end

  describe "#thump" do
    context "while running and not force_quit" do
      before do
        allow(instance).to receive(:running)
          .and_return(true)

        allow(Specwrk).to receive(:force_quit)
          .and_return(false)

        sleep_count = 0

        allow(instance).to receive(:sleep).with(10) do
          raise "Boom" if sleep_count == 1
          sleep_count += 1
        end
      end

      it "last request nil" do
        allow(client).to receive(:last_request_at)
          .and_return(nil)

        expect(heartbeat_client).to receive(:heartbeat)
          .and_return(true)
        expect(client).not_to receive(:heartbeat)

        expect { instance.thump }.to raise_error("Boom")
      end

      it "last request < 10 sec ago" do
        allow(client).to receive(:last_request_at)
          .and_return(Time.now - 1)

        expect(heartbeat_client).not_to receive(:heartbeat)

        expect { instance.thump }.to raise_error("Boom")
      end

      it "last request > 9 sec ago" do
        allow(client).to receive(:last_request_at)
          .and_return(Time.now - 9)

        expect(heartbeat_client).to receive(:heartbeat)
          .and_return(true)
        expect(client).not_to receive(:heartbeat)

        expect { instance.thump }.to raise_error("Boom")
      end

      it "heartbeat raises an error" do
        allow(client).to receive(:last_request_at)
          .and_return(nil)

        expect(heartbeat_client).to receive(:heartbeat)
          .and_raise("Bang!")

        expect(instance).to receive(:warn)
          .with("Heartbeat failed!")

        expect { instance.thump }.to raise_error("Boom")
      end
    end

    context "while not running and not force_quit" do
      before do
        allow(instance).to receive(:running)
          .and_return(false)

        allow(Specwrk).to receive(:force_quit)
          .and_return(false)
      end

      it "does not heartbeat" do
        expect(client).not_to receive(:last_request_at)
        expect(heartbeat_client).not_to receive(:heartbeat)

        instance.thump
      end
    end

    context "while running and force_quit" do
      before do
        allow(instance).to receive(:running)
          .and_return(true)

        allow(Specwrk).to receive(:force_quit)
          .and_return(true)
      end

      it "does not heartbeat" do
        expect(client).not_to receive(:last_request_at)
        expect(heartbeat_client).not_to receive(:heartbeat)

        instance.thump
      end
    end
  end

  describe "heartbeat connection isolation" do
    it "opens a dedicated Client instance for heartbeats, separate from the data client" do
      instance

      expect(Specwrk::Client).to have_received(:new).twice
    end

    context "#run" do
      subject { instance.run }

      before do
        allow(Specwrk::Client).to receive(:wait_for_server!)
        allow(instance).to receive(:execute).and_raise(Specwrk::CompletedAllExamplesError)
        allow(client).to receive(:worker_status).and_return(0)
      end

      it "closes both the data client and the heartbeat client" do
        expect(client).to receive(:close)
        expect(heartbeat_client).to receive(:close)

        subject
      end
    end
  end

  describe "end-of-run summary" do
    subject { instance.run }

    before do
      allow(Specwrk::Client).to receive(:wait_for_server!)
      allow(instance).to receive(:execute).and_raise(Specwrk::CompletedAllExamplesError)
      allow(client).to receive(:worker_status).and_return(0)

      allow(client).to receive(:stats).and_return({
        "/pop" => {calls: 2, duration: 1.0},
        "/complete_and_pop" => {calls: 3, duration: 2.5}
      })
      allow(heartbeat_client).to receive(:stats).and_return({"/heartbeat" => {calls: 4, duration: 0.2}})
    end

    # Always on — independent of SPECWRK_RUN_SUMMARY (that gate lives on the
    # CLI's Work command, not here), printed locally with no /report fetch.
    it "prints a greppable end-of-run metrics summary before the coverage flush" do
      expect(instance).to receive(:log_ts).with(a_string_matching(/\Asummary: buckets=0 examples=0/))
      expect(instance).to receive(:log_ts).with(a_string_including("server calls=5", "complete_and_pop=3/2.5s", "heartbeat=4/0.2s"))
      expect(instance).to receive(:log_ts).with(a_string_matching(/summary: run_wall=\d+\.\ds/))

      subject
    end

    it "prints the summary before before_fork_exit! flushes coverage" do
      expect(instance).to receive(:log_ts).with(a_string_matching(/\Asummary: buckets=/))
      expect(instance).to receive(:log_ts).with(a_string_including("server calls="))
      expect(instance).to receive(:log_ts).with(a_string_matching(/run_wall=/)).ordered
      expect(Specwrk).to receive(:before_fork_exit!).ordered

      subject
    end

    # This is purely diagnostic bookkeeping sitting ahead of the coverage
    # flush in #run — a raise here must never take that flush down with it.
    it "swallows a raise while building the summary and still runs before_fork_exit!" do
      allow(client).to receive(:stats).and_raise("stats boom")
      allow(instance).to receive(:warn)

      expect(instance).to receive(:warn).with(a_string_including("Skipping end-of-run metrics summary", "stats boom"))
      expect(Specwrk).to receive(:before_fork_exit!)

      subject
    end
  end
end
