# frozen_string_literal: true

require "specwrk/version"

module Specwrk
  Error = Class.new(StandardError)

  # HTTP Client Errors
  ClientError = Class.new(Error)
  UnhandledResponseError = Class.new(ClientError)
  WaitingForSeedError = Class.new(ClientError)
  NoMoreExamplesError = Class.new(ClientError)
  CompletedAllExamplesError = Class.new(ClientError)

  @force_quit = false
  @starting_pid = Process.pid

  class << self
    attr_accessor :force_quit, :net_http
    attr_reader :starting_pid

    # Run in the parent once the app is preloaded, before any per-bucket fork, so
    # children inherit no live database connections and no locked connection-pool
    # mutexes. clear_all_connections! is graceful (safe here — no fork has
    # happened yet) and leaves the pools reusable, so each child lazily opens its
    # own fresh connections on first query.
    def prepare_for_fork!
      return unless defined?(::ActiveRecord::Base)

      ::ActiveRecord::Base.connection_handler.clear_all_connections!
    rescue => e
      warn "specwrk: clearing ActiveRecord connections before fork failed: #{e.class}: #{e.message}"
    end

    # Callbacks run inside each per-bucket child immediately after fork, before
    # the bucket's examples run. ActiveRecord reconnects lazily from the cleared
    # pools; register here to reset anything else that doesn't survive a fork
    # (ClickHouse, Kafka, Redis, ...).
    def after_fork(&block)
      after_fork_hooks << block
    end

    def after_fork!
      after_fork_hooks.each(&:call)
    end

    def after_fork_hooks
      @after_fork_hooks ||= []
    end

    # Callbacks run inside each per-bucket child right before it hard-exits.
    # Process.exit! deliberately skips at_exit hooks (a booted app's at_exit
    # can hang the shutdown), so anything that normally flushes state at exit
    # — e.g. SimpleCov writing its coverage resultset — must be flushed here.
    # Hooks run after the bucket's results are written; a hook failure is
    # warned and swallowed so it can never fail the bucket.
    def before_fork_exit(&block)
      before_fork_exit_hooks << block
    end

    def before_fork_exit!
      before_fork_exit_hooks.each do |hook|
        hook.call
      rescue => e
        warn "specwrk: before_fork_exit hook failed: #{e.class}: #{e.message}"
      end
    end

    def before_fork_exit_hooks
      @before_fork_exit_hooks ||= []
    end

    def wait_for_pids_exit(pids)
      exited_pids = {}

      loop do
        pids.each do |pid|
          next if exited_pids.key? pid

          _, status = Process.waitpid2(pid, Process::WNOHANG)
          exited_pids[pid] = status.exitstatus if status&.exitstatus
        rescue Errno::ECHILD
          exited_pids[pid] = 1
        end

        break if exited_pids.keys.length == pids.length
        sleep 0.1
      end

      exited_pids
    end

    # The spec file an example belongs to, derived from its rerun id
    # ("./spec/a_spec.rb[1:2]" or "spec/a_spec.rb:12" -> "./spec/a_spec.rb").
    # RSpec's metadata file_path points at the file where the example is
    # DEFINED — for a shared example that's the shared-examples file, shared by
    # every spec built from it — so file_path must never be used to group
    # examples into file buckets: it lumps all of them into one giant
    # unsplittable pseudo-file. Falls back to file_path when there's no id.
    def example_file_key(example)
      file = example[:id].to_s[/\A[^\[]+/]&.sub(/(:\d+)+\z/, "")

      return example[:file_path] if file.nil? || file.empty?

      file
    end

    def human_readable_duration(total_seconds, precision: 2)
      secs = total_seconds.to_f
      hours = (secs / 3600).to_i
      mins = ((secs % 3600) / 60).to_i
      seconds = secs % 60

      parts = []
      parts << "#{hours}h" if hours.positive?
      parts << "#{mins}m" if mins.positive?
      if seconds.positive?
        sec_str = format("%0.#{precision}f", seconds).sub(/\.?0+$/, "")
        parts << "#{sec_str}s"
      end
      parts.join(" ")
    end
  end
end
