# frozen_string_literal: true

require "json"
require "tempfile"

require "rspec/core"

require "specwrk"
require "specwrk/preloadable"

module Specwrk
  # Raised when a forked enumeration job dies without writing its slice of the
  # example list. A partial list would silently drop whole spec files from the
  # run — every worker would agree the queue was complete — so this always
  # aborts the seed.
  SeedEnumerationError = Class.new(Error)

  class ListExamples
    include Preloadable

    # jobs greater than one enumerates in forked children. Enumeration time is
    # dominated by LOADING spec files, which parallelizes cleanly once the
    # application itself is booted, so the app is preloaded here and each child
    # loads one contiguous slice of the file list. Defaults to SPECWRK_SEED_JOBS,
    # and one job runs the single-process path unchanged.
    def initialize(dir, jobs: nil)
      @dir = dir
      @jobs = [1, (jobs || ENV["SPECWRK_SEED_JOBS"]).to_i].max
    end

    def examples
      return forked_examples if @jobs > 1

      serial_examples
    end

    # Called as the formatter
    def stop(group_notification)
      group_notification.notifications.map do |notification|
        @examples << {
          id: notification.example.id,
          file_path: notification.example.metadata[:file_path]
        }
      end
    end

    private

    def serial_examples
      reset!
      return @examples if defined?(@examples)

      @examples = []

      RSpec.configuration.files_or_directories_to_run = @dir
      RSpec::Core::Formatters.register self.class, :stop
      RSpec.configuration.add_formatter(self)

      unless RSpec::Core::Runner.new(options).run($stderr, out).zero?
        out.tap(&:rewind).each_line { |line| $stdout.print line }
      end

      @examples
    end

    def forked_examples
      return @examples if defined?(@examples)

      unless fork_available?
        warn "specwrk seed: #{@jobs} enumeration jobs requested but this platform cannot fork; enumerating in one process"
        return serial_examples
      end

      unless preload_app!
        warn "specwrk seed: enumerating with #{@jobs} jobs but SPECWRK_PRELOAD is unset; every job boots the application on its own"
      end

      Specwrk.prepare_for_fork!

      slices = file_slices
      return serial_examples if slices.length < 2

      @examples = run_jobs(slices).flatten(1)
    end

    # Fork one child per slice, hand each its own tempfile, and merge their
    # output in slice order. Tempfiles rather than pipes: a large suite's slice
    # is megabytes of JSON and no child can be read until all of them are
    # forked, so a child would block forever on a full 64KB pipe buffer.
    def run_jobs(slices)
      outputs = slices.map { Tempfile.new("specwrk-seed-examples").tap(&:close) }

      # A child inherits whatever the parent has buffered and would flush a
      # duplicate copy of it on exit.
      $stdout.flush
      $stderr.flush

      pids = slices.each_with_index.map { |files, index| fork_job(files, outputs[index]) }
      statuses = Specwrk.wait_for_pids_exit(pids)

      pids.each_with_index do |pid, index|
        status = statuses[pid]
        next if status&.zero?

        raise SeedEnumerationError,
          "specwrk seed: enumeration job #{job_label(slices, index)} exited #{status.inspect}; refusing to seed a partial example list"
      end

      slices.each_index.map { |index| read_job(slices, index, outputs[index]) }
    ensure
      outputs&.each(&:unlink)
    end

    def fork_job(files, output)
      fork do
        # Loading spec files can touch whatever the preload connected to, and a
        # socket inherited from the parent would be shared by every job at once.
        Specwrk.after_fork!

        File.write(output.path, JSON.generate(self.class.new(files, jobs: 1).examples))

        $stdout.flush
        $stderr.flush
        # Hard exit like the worker's per-bucket children: at_exit in a booted
        # application can hang, or write state the parent owns such as a
        # coverage resultset, and this child's examples are already on disk.
        Process.exit!(0)
      rescue => e
        warn "specwrk seed: enumeration job over #{files.length} files failed: #{e.class}: #{e.message}"
        warn e.backtrace.join("\n") if e.backtrace
        $stderr.flush
        Process.exit!(1)
      end
    end

    def read_job(slices, index, output)
      data = File.read(output.path)
      if data.empty?
        raise SeedEnumerationError,
          "specwrk seed: enumeration job #{job_label(slices, index)} exited cleanly without writing any output"
      end

      JSON.parse(data, symbolize_names: true).tap do |examples|
        puts "specwrk seed: enumeration job #{job_label(slices, index)} found #{examples.length} examples"
      end
    rescue JSON::ParserError => e
      raise SeedEnumerationError,
        "specwrk seed: enumeration job #{job_label(slices, index)} wrote unreadable output: #{e.message}"
    end

    def job_label(slices, index)
      files = slices[index]

      "#{index + 1}/#{slices.length} (#{files.length} files, " \
        "#{RSpec::Core::Metadata.relative_path(files.first)}..#{RSpec::Core::Metadata.relative_path(files.last)})"
    end

    def file_slices
      RSpec.configuration.files_or_directories_to_run = @dir

      slice_evenly(RSpec.configuration.files_to_run.uniq.sort, @jobs)
    end

    # Contiguous slices, never round-robin: an example's id is its position
    # within its file, and a file's groups can depend on another file loaded
    # before it (shared examples, a custom DSL). A contiguous run of the sorted
    # file list preserves every file's relative load order, which is what makes
    # the merged list identical to a single-process enumeration.
    def slice_evenly(files, count)
      return [] if files.empty?

      count = [count, files.length].min
      base, extra = files.length.divmod(count)
      offset = 0

      Array.new(count) do |index|
        length = base + ((index < extra) ? 1 : 0)
        files[offset, length].tap { offset += length }
      end
    end

    def fork_available?
      Process.respond_to?(:fork)
    end

    def reset!
      return unless ENV["SPECWRK_SEED"]
      RSpec.clear_examples

      # see https://github.com/rspec/rspec-core/pull/2723
      if Gem::Version.new(RSpec::Core::Version::STRING) <= Gem::Version.new("3.9.1")
        RSpec.world.instance_variable_set(
          :@example_group_counts_by_spec_file, Hash.new(0)
        )
      end

      # RSpec.clear_examples does not reset those, which causes issues when
      # a non-example error occurs (subsequent jobs are not executed)
      RSpec.world.non_example_failure = false

      # we don't want an error that occured outside of the examples (which
      # would set this to `true`) to stop the worker
      RSpec.world.wants_to_quit = Specwrk.force_quit

      RSpec.configuration.silence_filter_announcements = true
      RSpec.configuration.filter_manager.inclusions.clear
      RSpec.configuration.filter_manager.exclusions.clear

      true
    end

    def out
      @out ||= Tempfile.new.tap do |f|
        f.define_singleton_method(:tty?) { true }
      end
    end

    def options
      RSpec::Core::ConfigurationOptions.new(
        ["--dry-run", *RSpec.configuration.files_to_run]
      )
    end
  end
end
