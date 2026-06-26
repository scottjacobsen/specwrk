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
