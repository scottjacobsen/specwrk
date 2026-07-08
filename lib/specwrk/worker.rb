# frozen_string_literal: true

require "stringio"
require "fileutils"
require "json"
require "tempfile"
require "time"

require "specwrk/client"
require "specwrk/worker/executor"

module Specwrk
  class Worker
    def self.run!
      new.run
    end

    def initialize
      Process.setproctitle ENV.fetch("SPECWRK_ID", "specwrk-worker")
      FileUtils.mkdir_p(ENV["SPECWRK_OUT"]) if ENV["SPECWRK_OUT"]

      @running = true
      @client = Client.new
      @executor = Executor.new
      @all_examples_completed = false
      @seed_waits = ENV.fetch("SPECWRK_SEED_WAITS", "10").to_i
      @heartbeat_thread ||= Thread.new do
        thump
      end
    end

    def run
      Client.wait_for_server!
      preload!

      loop do
        break if Specwrk.force_quit

        execute
      rescue CompletedAllExamplesError
        @all_examples_completed = true
        break
      rescue NoMoreExamplesError
        # The queue is drained for now. Wait briefly so a straggler's expired and
        # requeued bucket can still be stolen — but NEVER wait forever. An
        # orphaned/stuck bucket can mean the server never signals "all complete"
        # (410), and a silent infinite wait here gets the CI job killed by a
        # no-output timeout (~10m) long after the tests actually finished. Emit a
        # timestamped line each cycle so the test→idle boundary is visible and
        # output keeps flowing, then exit once the wait is exhausted.
        @no_work_waits = (@no_work_waits || 0) + 1
        if @no_work_waits > no_work_max
          log_ts "queue drained (no work after #{@no_work_waits} checks) — exiting"
          @all_examples_completed = true
          break
        end
        log_ts "no work yet, waiting for stragglers (#{@no_work_waits}/#{no_work_max})" if (@no_work_waits % 10) == 1
        sleep 0.5
      rescue WaitingForSeedError
        @seed_wait_count ||= 0
        @seed_wait_count += 1

        if @seed_wait_count <= @seed_waits
          warn "No examples seeded yet, waiting..."
          sleep 1
        else
          warn "No examples seeded, giving up!"
          break
        end
      end

      @heartbeat_thread.kill
      client.close

      # The parent hard-exits via the init script (Process.exit! — at_exit is
      # unsafe in a booted app), and forked children get ZEROED Coverage
      # counters, so state recorded only in this parent — e.g. coverage of a
      # Rails eager load during preload — must be flushed here like the
      # children flush theirs.
      Specwrk.before_fork_exit!

      status
    rescue Errno::ECONNREFUSED
      warn "\nServer at #{ENV.fetch("SPECWRK_SRV_URI", "http://localhost:5138")} is refusing connections, exiting..."
      1
    rescue Errno::ECONNRESET
      warn "\nServer at #{ENV.fetch("SPECWRK_SRV_URI", "http://localhost:5138")} stopped responding to connections, exiting..."
      1
    end

    # Boot the application (e.g. Rails) once in this long-lived parent process so
    # every per-bucket child fork inherits a fully-booted app whose load-time
    # registrations (model callbacks, subscribers, constants, RSpec config) have
    # run exactly once. SPECWRK_PRELOAD names a file to require, e.g. the app's
    # spec/rails_helper. Without it the app boots lazily inside the first child.
    def preload!
      preload = ENV["SPECWRK_PRELOAD"].to_s
      return if preload.empty?

      # Put the conventional RSpec load paths in place (mirrors `rspec -Ilib
      # -Ispec`) so the preloaded helper and its own requires (e.g. rails_helper's
      # `require "spec_helper"`) resolve the same way a normal rspec run would.
      ["lib", "spec", File.dirname(preload)].each do |dir|
        path = File.expand_path(dir)
        $LOAD_PATH.unshift(path) if File.directory?(path) && !$LOAD_PATH.include?(path)
      end

      require preload

      # Drop the connections opened while booting so per-bucket children fork
      # from a clean, lock-free baseline and each reconnects on its own.
      Specwrk.prepare_for_fork!
    end

    # Run one bucket of examples in a forked child, then report its results.
    #
    # Forking per bucket gives each bucket the clean, run-once global state a
    # fresh CI process has: RSpec before(:suite) hooks, model callbacks/
    # subscribers, and constant definitions execute once per child rather than
    # accumulating across buckets in one reused process (which manifests as e.g.
    # an audit event firing N times instead of once on the Nth bucket).
    def execute
      examples = next_examples
      @no_work_waits = 0 # got work — reset the idle-exit counter
      @next_examples = nil

      results = run_in_fork(examples)
      log_ts "ran #{results.length} examples"
      complete_examples results
    rescue UnhandledResponseError => e
      # If fetching examples via next_examples fails we can just try again so warn and return
      # Expects complete_examples to rescue this error if raised in that method
      warn e.message
    end

    def next_examples
      return @next_examples if @next_examples&.length&.positive?
      client.fetch_examples
    end

    def complete_examples(results)
      @next_examples = client.complete_and_fetch_examples(results)
    rescue UnhandledResponseError => e
      # I do not think we should so lightly abandon the completion of executed examples
      # try to complete until successful or terminated
      warn e.message

      sleep 1
      retry
    end

    # Fork, run the bucket in the child, and hand its example results back to the
    # parent through a tempfile. The HTTP client and heartbeat thread live solely
    # in the parent, so the child never touches the shared server connection. If
    # the child dies without writing results (e.g. a spec file crashes the
    # process), the bucket's examples are reported as failures so the server can
    # release them and the run still completes instead of hanging.
    def run_in_fork(examples)
      results_file = Tempfile.new("specwrk-bucket-results")
      results_file.close

      pid = fork do
        Specwrk.after_fork!
        executor.run(examples)
        executor.flush_log
        flush_final_output
        File.write(results_file.path, JSON.generate(executor.examples + executor.unexecuted_examples))
        # Results are safely written; give exit-flush hooks (e.g. coverage)
        # their chance before the hard exit skips every at_exit handler.
        Specwrk.before_fork_exit!
        Process.exit!(0)
      end

      wait_status = wait_for_child(pid)
      if wait_status.nil?
        # The child blew past the bucket timeout — almost certainly a hung example
        # (e.g. a wedged browser in a system spec). Kill it and report the bucket
        # as failures rather than letting one hung test stall the whole node in an
        # unbounded Process.wait2 until CI's no-output timeout kills the container.
        Process.kill("KILL", pid)
        Process.wait(pid)
        log_ts "bucket exceeded #{bucket_timeout}s — killed child #{pid}, reporting its examples as failures"
        return examples.map { |example| executor.unexecuted_failure(example) }
      end

      decode_bucket_results(examples, wait_status.success?, File.read(results_file.path))
    rescue => e
      warn "bucket execution failed: #{e.class}: #{e.message}; reporting its examples as failures"
      examples.map { |example| executor.unexecuted_failure(example) }
    ensure
      results_file&.unlink
    end

    # Reap the child, but give up after bucket_timeout so a hung example can't
    # stall the node. Returns the Process::Status on exit, or nil on timeout.
    def wait_for_child(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + bucket_timeout
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.5
      end
    end

    def decode_bucket_results(examples, success, data)
      if success && !data.empty?
        JSON.parse(data, symbolize_names: true)
      else
        warn "bucket child exited without results; reporting its examples as failures"
        examples.map { |example| executor.unexecuted_failure(example) }
      end
    end

    def thump
      while running && !Specwrk.force_quit
        sleep 10

        begin
          client.heartbeat if client.last_request_at.nil? || client.last_request_at < Time.now - 9
        rescue
          warn "Heartbeat failed!"
        end
      end
    end

    private

    attr_reader :running, :client, :executor

    # Flush the child's accumulated failure/pending summary back to the worker's
    # output stream. Children run sequentially (the parent waits on each), so
    # writes to the shared $final_output pipe don't interleave.
    def flush_final_output
      executor.final_output.tap(&:rewind).each_line { |line| final_output.write line }
    end

    def final_output
      $final_output || $stdout # standard:disable Style/GlobalVars
    end

    # How many empty /pop checks (0.5s apart) to tolerate before a worker gives up
    # waiting for stragglers and exits. Default ~60s — long enough to steal an
    # expired/requeued bucket (heartbeat expiry is ~20s), short enough to never
    # trip CI's no-output timeout. Override with SPECWRK_NO_WORK_WAITS.
    def no_work_max
      @no_work_max ||= ENV.fetch("SPECWRK_NO_WORK_WAITS", "120").to_i
    end

    # Max seconds to wait for a single bucket's child before killing it as hung.
    # Well above any legit bucket (buckets target ~10s of run time) and below CI's
    # ~10m no-output timeout, so a wedged example fails its bucket instead of
    # stalling the whole node. Override with SPECWRK_BUCKET_TIMEOUT.
    def bucket_timeout
      @bucket_timeout ||= ENV.fetch("SPECWRK_BUCKET_TIMEOUT", "300").to_i
    end

    # Timestamped line to stdout so the CI log shows when each bucket finished and
    # where the test→idle boundary is (specwrk's own output is otherwise untimed).
    def log_ts(msg)
      $stdout.puts "[#{Time.now.utc.iso8601}] #{ENV.fetch("SPECWRK_ID", "specwrk-worker")}: #{msg}"
      $stdout.flush
    end

    def status
      return 0 if @all_examples_completed && client.worker_status.zero?
      return 1 if Specwrk.force_quit

      client.worker_status
    end

    def warn(msg)
      super("#{ENV.fetch("SPECWRK_ID", "specwrk-worker")}: #{msg}")
    end
  end
end
