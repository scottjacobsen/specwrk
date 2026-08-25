# frozen_string_literal: true

require "stringio"
require "fileutils"
require "json"
require "tempfile"
require "time"

require "specwrk/client"
require "specwrk/preloadable"
require "specwrk/worker/executor"

module Specwrk
  class Worker
    include Preloadable

    def self.run!
      new.run
    end

    attr_reader :metrics

    def initialize
      Process.setproctitle ENV.fetch("SPECWRK_ID", "specwrk-worker")
      FileUtils.mkdir_p(ENV["SPECWRK_OUT"]) if ENV["SPECWRK_OUT"]

      @running = true
      # One call per bucket, so logging them is cheap and shows server time inline
      @client = Client.new(log_requests: true)
      @heartbeat_client = Client.new
      @executor = Executor.new
      @all_examples_completed = false
      @seed_waits = ENV.fetch("SPECWRK_SEED_WAITS", "10").to_i
      @metrics = {buckets: 0, examples: 0, bucket_wall: 0.0, example_time: 0.0}
      @heartbeat_thread ||= Thread.new do
        thump
      end
    end

    def run
      @run_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Client.wait_for_server!
      preload!

      loop do
        break if Specwrk.force_quit

        execute
      rescue CompletedAllExamplesError
        @all_examples_completed = true
        break
      rescue NoMoreExamplesError
        # Queue drained for now: wait so a straggler's requeued bucket can
        # still be stolen, but never forever — an orphaned bucket can mean
        # 410 never comes, and a silent infinite wait gets the CI job killed
        # by its no-output timeout long after the tests finished.
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
      rescue PoisonedWorkerError
        # Stop popping so a broken node can't vacuum the queue; the withheld
        # bucket is reclaimed for a healthy worker once our heartbeats stop.
        @poisoned = true
        break
      end

      @heartbeat_thread.kill
      client.close
      heartbeat_client.close

      print_summary

      # The parent hard-exits past at_exit like its children do, so state
      # recorded only here (e.g. coverage of the preload) needs the same
      # explicit flush the children get.
      Specwrk.before_fork_exit!

      status
    rescue Errno::ECONNREFUSED
      warn "\nServer at #{ENV.fetch("SPECWRK_SRV_URI", "http://localhost:5138")} is refusing connections, exiting..."
      1
    rescue Errno::ECONNRESET
      warn "\nServer at #{ENV.fetch("SPECWRK_SRV_URI", "http://localhost:5138")} stopped responding to connections, exiting..."
      1
    rescue OpenSSL::SSL::SSLError => e
      # A TLS connection that stays dead past the client's own retries lands
      # here; exit controlled instead of crashing away the summary.
      warn "\nTLS connection to #{ENV.fetch("SPECWRK_SRV_URI", "http://localhost:5138")} failed (#{e.message}), exiting..."
      1
    end

    # Boot the application once in this long-lived parent process so every
    # per-bucket child fork inherits it. Without SPECWRK_PRELOAD the app boots
    # lazily inside the first child instead.
    def preload!
      return unless preload_app!

      # Drop the connections opened while booting so per-bucket children fork
      # from a clean, lock-free baseline and each reconnects on its own.
      Specwrk.prepare_for_fork!

      # The data client's keep-alive socket, opened at boot, died server-side
      # during the minutes the preload took (the heartbeat client kept its own
      # alive). Reconnect now so the first /pop doesn't log an EOFError retry.
      client.reconnect
    end

    # Run one bucket in a forked child, then report its results. Forking per
    # bucket gives each bucket the run-once global state a fresh process has:
    # before(:suite) hooks, subscribers, and constants don't accumulate
    # across buckets in one reused process.
    def execute
      examples = next_examples
      @no_work_waits = 0 # got work — reset the idle-exit counter
      @next_examples = nil

      bucket = @metrics[:buckets] + 1
      log_bucket_start(bucket, examples)

      bucket_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = run_in_fork(examples)
      bucket_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - bucket_started_at

      @metrics[:examples] += results.length
      @metrics[:example_time] += results.sum { |result| result[:run_time].to_f } # nil.to_f == 0 handles synthesized results
      log_bucket_done(bucket, results, bucket_wall)
      register_poison! results
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

    # Results come back from the child through a tempfile; the HTTP client and
    # heartbeat thread live solely in the parent. A child that dies without
    # writing results gets its examples reported as failures so the server can
    # release them and the run completes instead of hanging.
    def run_in_fork(examples)
      bucket_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results_file = Tempfile.new("specwrk-bucket-results")
      results_file.close

      pid = fork do
        install_quit_backtrace_trap
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
        # Past the bucket timeout. SIGQUIT first — its trap dumps every
        # thread's backtrace before exiting, and a child too far gone to run
        # the trap (blocked in native code) tells its own story when SIGKILL
        # follows. The hang may be in an exit-time flush AFTER the results
        # were fully written, so a complete results file is salvaged rather
        # than failing examples that really ran.
        log_ts "bucket exceeded #{bucket_timeout}s — sending SIGQUIT to child #{pid} for a thread dump"
        signal_child("QUIT", pid)
        unless wait_for_child(pid, timeout: quit_grace)
          signal_child("KILL", pid)
          Process.wait(pid)
        end

        salvaged = salvage_bucket_results(examples, File.read(results_file.path))
        if salvaged
          log_ts "bucket exceeded #{bucket_timeout}s — killed child #{pid}, salvaged its written results"
          return salvaged
        end

        log_ts "bucket exceeded #{bucket_timeout}s — killed child #{pid}, reporting its examples as failures"
        return examples.map { |example| executor.unexecuted_failure(example) }
      end

      decode_bucket_results(examples, wait_status.success?, File.read(results_file.path))
    rescue => e
      warn "bucket execution failed: #{e.class}: #{e.message}; reporting its examples as failures"
      examples.map { |example| executor.unexecuted_failure(example) }
    ensure
      results_file&.unlink
      # Covers the normal, kill-on-timeout, and rescue paths alike — a hung or
      # crashed bucket still counts against @metrics rather than vanishing.
      @metrics[:buckets] += 1
      @metrics[:bucket_wall] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - bucket_started_at
    end

    # A wedged child leaves its blocked frames behind instead of vanishing.
    # Trap context forbids Mutex use, so plain IO writes only.
    def install_quit_backtrace_trap
      Signal.trap("QUIT") do
        $stderr.write "\nspecwrk child #{Process.pid}: SIGQUIT thread dump\n"
        Thread.list.each do |thread|
          $stderr.write "--- #{thread.inspect} status=#{thread.status.inspect}\n"
          $stderr.write((thread.backtrace || ["<no backtrace>"]).join("\n"))
          $stderr.write "\n"
        end
        Process.exit!(2)
      end
    end

    # Reap the child, but give up after the timeout so a hung example can't
    # stall the node. Returns the Process::Status on exit, or nil on timeout.
    def wait_for_child(pid, timeout: bucket_timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.5
      end
    end

    # Results from a killed child, if it got as far as writing them. nil
    # unless the file parses (a kill mid-write leaves truncated JSON). Any
    # assigned example missing from the file is synthesized as a failure so
    # the server gets a result for everything it handed out.
    def salvage_bucket_results(examples, data)
      return if data.empty?

      results = JSON.parse(data, symbolize_names: true)
      results_by_id = results.group_by { |result| result[:id] if result.is_a?(Hash) }

      examples.flat_map do |example|
        results_by_id[example[:id]] || executor.unexecuted_failure(example)
      end
    rescue JSON::ParserError
      nil
    end

    def decode_bucket_results(examples, success, data)
      if success && !data.empty?
        JSON.parse(data, symbolize_names: true)
      else
        warn "bucket child exited without results; reporting its examples as failures"
        examples.map { |example| executor.unexecuted_failure(example) }
      end
    end

    # Heartbeats run over their own connection (@heartbeat_client), never the
    # data client (@client): a stalled complete_and_pop request that blocks on
    # the shared connection must not also block the heartbeat that keeps this
    # worker's in-flight bucket from being falsely reclaimed as expired.
    def thump
      while running && !Specwrk.force_quit
        sleep 10

        begin
          heartbeat_client.heartbeat if client.last_request_at.nil? || client.last_request_at < Time.now - 9
        rescue
          warn "Heartbeat failed!"
        end
      end
    end

    private

    attr_reader :running, :client, :heartbeat_client, :executor

    # Flush the child's accumulated failure/pending summary back to the worker's
    # output stream. Children run sequentially (the parent waits on each), so
    # writes to the shared $final_output pipe don't interleave.
    def flush_final_output
      executor.final_output.tap(&:rewind).each_line { |line| final_output.write line }
    end

    def final_output
      $final_output || $stdout # standard:disable Style/GlobalVars
    end

    # The child may die between the timeout decision and the signal; that's a
    # win, not an error (Process.wait still reaps it).
    def signal_child(signal, pid)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end

    # Seconds the parent waits for a SIGQUITed child to dump its threads and
    # exit before escalating to SIGKILL.
    def quit_grace
      @quit_grace ||= ENV.fetch("SPECWRK_QUIT_GRACE", "5").to_f
    end

    # Empty /pop checks (0.5s apart) tolerated before a worker exits. Must
    # outlast the server's bucket-expiry reclaim or a dead node's work is
    # never stolen. Override with SPECWRK_NO_WORK_WAITS.
    def no_work_max
      @no_work_max ||= ENV.fetch("SPECWRK_NO_WORK_WAITS", "120").to_i
    end

    # A node with broken local infrastructure insta-fails every bucket and
    # vacuums the queue. Its signature — every example failed, near-zero run
    # time, N buckets in a row — is distinct from a legitimately failing
    # bucket. The raise withholds the tripping bucket's results so expiry
    # requeues them for a healthy worker; the worker then exits red.
    def register_poison!(results)
      return if poison_bucket_max.zero?

      unless poisoned_bucket?(results)
        @poisoned_buckets = 0
        return
      end

      @poisoned_buckets = (@poisoned_buckets || 0) + 1
      return if @poisoned_buckets < poison_bucket_max

      log_ts "poison circuit breaker: #{@poisoned_buckets} consecutive instant total-failure buckets — " \
        "withholding this bucket's results for reclaim and exiting"
      raise PoisonedWorkerError
    end

    def poisoned_bucket?(results)
      return false if results.empty?
      return false unless results.all? { |result| result[:status].to_s == "failed" }

      average_run_time = results.sum { |result| result[:run_time].to_f } / results.length
      average_run_time < poison_avg_seconds
    end

    # Consecutive instant total-failure buckets before the breaker trips.
    # 0 disables. Override with SPECWRK_POISON_BUCKETS.
    def poison_bucket_max
      @poison_bucket_max ||= ENV.fetch("SPECWRK_POISON_BUCKETS", "3").to_i
    end

    # A bucket only counts as poisoned when its average per-example run time
    # is under this many seconds. Override with SPECWRK_POISON_AVG_SECONDS.
    def poison_avg_seconds
      @poison_avg_seconds ||= ENV.fetch("SPECWRK_POISON_AVG_SECONDS", "0.1").to_f
    end

    # Max seconds for a bucket's child before it is killed as hung — a wedged
    # example fails its bucket instead of stalling the whole node. Override
    # with SPECWRK_BUCKET_TIMEOUT.
    def bucket_timeout
      @bucket_timeout ||= ENV.fetch("SPECWRK_BUCKET_TIMEOUT", "300").to_i
    end

    def log_bucket_start(bucket, examples)
      files = examples.map { |example| example[:id].to_s.split("[", 2).first }.uniq
      log_ts "bucket #{bucket}: #{examples.length} examples from #{files.length} file#{"s" unless files.length == 1}"
      log_ts "bucket #{bucket} rerun: #{rspec_command(examples)}"
    end

    # The leading newline separates this from the child's progress dots, which
    # end without one.
    def log_bucket_done(bucket, results, bucket_wall)
      statuses = results.group_by { |result| result[:status].to_s }
      counts = %w[passed failed pending].map { |status| "#{statuses.fetch(status, []).length} #{status}" }.join(", ")

      $stdout.puts
      log_ts format("bucket %d done in %.1fs: %s", bucket, bucket_wall, counts)
    end

    # One runnable command line that reproduces this bucket exactly. Example
    # ids are already valid rspec args (executor#run passes them verbatim);
    # ids from the same file collapse into rspec's multi-scope bracket syntax
    # (path[1:1,1:4]). A whole-file id (no bracket) subsumes any scoped ids
    # for that file. Args are single-quoted because `[` is a shell glob.
    def rspec_command(examples)
      scopes_by_file = {}
      examples.each do |example|
        file, scope = example[:id].to_s.split("[", 2)
        (scopes_by_file[file] ||= []) << scope&.delete_suffix("]")
      end

      args = scopes_by_file.map do |file, scopes|
        scopes.include?(nil) ? "'#{file}'" : "'#{file}[#{scopes.join(",")}]'"
      end

      "bundle exec rspec#{rspec_seed_options} #{args.join(" ")}"
    end

    # --seed pins random ordering (and anything the app derives from the
    # seed) so the rerun executes the bucket exactly as this run did.
    # Appended only when random ordering is configured: --seed implies
    # --order rand, which would CHANGE an identity-ordered suite's order.
    def rspec_seed_options
      @rspec_seed_options ||= if RSpec.configuration.ordering_registry.fetch(:global).is_a?(RSpec::Core::Ordering::Random)
        " --seed #{RSpec.configuration.seed}"
      else
        ""
      end
    end

    def log_ts(msg)
      $stdout.puts "[#{Time.now.utc.iso8601}] #{ENV.fetch("SPECWRK_ID", "specwrk-worker")}: #{msg}"
      $stdout.flush
    end

    # Local bookkeeping only, no network call (unlike SPECWRK_RUN_SUMMARY's
    # /report fetch). Runs before the coverage flush, so a raise here must
    # never take that flush down with it — best-effort only.
    def print_summary
      fork_overhead = metrics[:bucket_wall] - metrics[:example_time]
      log_ts format("summary: buckets=%d examples=%d bucket_wall=%.1fs example_time=%.1fs fork_overhead=%.1fs",
        metrics[:buckets], metrics[:examples], metrics[:bucket_wall], metrics[:example_time], fork_overhead)

      data_stats = client.stats
      data_calls = data_stats.values.sum { |s| s[:calls] }
      data_time = data_stats.values.sum { |s| s[:duration] }
      endpoints = data_stats.sort_by { |_path, s| -s[:duration] }
        .map { |path, s| format("%s=%d/%.1fs", path.delete_prefix("/"), s[:calls], s[:duration]) }
        .join(", ")

      heartbeat_stats = heartbeat_client.stats
      heartbeat_calls = heartbeat_stats.values.sum { |s| s[:calls] }
      heartbeat_time = heartbeat_stats.values.sum { |s| s[:duration] }

      log_ts format("summary: server calls=%d time=%.1fs [%s] heartbeat=%d/%.1fs (counts are attempts incl. retries; heartbeats ran concurrently)",
        data_calls, data_time, endpoints, heartbeat_calls, heartbeat_time)

      # Data-client calls are serial with buckets, so this decomposition holds;
      # heartbeats run concurrently and are deliberately excluded.
      run_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @run_started_at
      other = run_wall - metrics[:bucket_wall] - data_time

      log_ts format("summary: run_wall=%.1fs = buckets %.1fs + server %.1fs + other %.1fs (boot, idle polls, drain wait)",
        run_wall, metrics[:bucket_wall], data_time, other)
    rescue => e
      warn "Skipping end-of-run metrics summary: #{e.class}: #{e.message}"
    end

    def status
      # A poisoned node is sick by definition — never exit green, even if its
      # completed failures were all superseded by healthy re-runs by now.
      return client.worker_status.clamp(1, 255) if @poisoned
      return 0 if @all_examples_completed && client.worker_status.zero?
      return 1 if Specwrk.force_quit

      # POSIX keeps only the low 8 bits of an exit status — a failure count
      # of exactly 256 would truncate to 0 and read as green.
      client.worker_status.clamp(0, 255)
    end

    def warn(msg)
      super("#{ENV.fetch("SPECWRK_ID", "specwrk-worker")}: #{msg}")
    end
  end
end
