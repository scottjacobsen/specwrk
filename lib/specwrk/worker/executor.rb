# frozen_string_literal: true

require "tempfile"
require "time"

require "rspec/core"

require "specwrk/worker/progress_formatter"
require "specwrk/worker/completion_formatter"
require "specwrk/worker/null_formatter"

module Specwrk
  class Worker
    class Executor
      def examples
        completion_formatter.examples
      end

      def final_output
        progress_formatter.final_output
      end

      def run(examples)
        reset!

        @assigned_examples = examples
        example_ids = examples.map { |example| example[:id] }

        options = RSpec::Core::ConfigurationOptions.new ["--format", "Specwrk::Worker::NullFormatter"] + example_ids
        RSpec::Core::Runner.new(options).run($stderr, $stdout)
      end

      # Examples this worker was asked to run but which produced no result — e.g.
      # the spec file raised while loading, so RSpec never executed them. We
      # report them as failures so the server releases them from its processing
      # queue; otherwise they sit there held by a worker that is still alive and
      # heartbeating, so they never expire and the run hangs forever.
      def unexecuted_examples
        return [] if Specwrk.force_quit
        return [] unless @assigned_examples

        executed_ids = examples.map { |example| example[:id] }

        @assigned_examples
          .reject { |example| executed_ids.include?(example[:id]) }
          .map { |example| unexecuted_failure(example) }
      end

      def unexecuted_failure(example)
        now = Time.now.iso8601(6)

        {
          id: example[:id],
          full_description: example[:full_description] || example[:id],
          status: "failed",
          file_path: example[:file_path],
          line_number: example[:line_number],
          started_at: now,
          finished_at: now,
          run_time: 0.0,
          exception: {
            class: "Specwrk::Worker::UnexecutedExample",
            message: "Example was not executed by the worker — its spec file likely failed to load. " \
              "Marked as failed by specwrk so the run can complete instead of stalling.",
            backtrace: []
          }
        }
      end

      # https://github.com/skroutz/rspecq/blob/341383ce3ca25f42fad5483cbb6a00ba1c405570/lib/rspecq/worker.rb#L208-L224
      def reset!
        flush_log
        completion_formatter.examples.clear

        RSpec.clear_examples
        RSpec.configuration.backtrace_formatter.filter_gem "specwrk"

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

        RSpec.configuration.add_formatter progress_formatter
        RSpec.configuration.add_formatter completion_formatter

        # This formatter may be specified by the runner options so
        # it will be initialized by RSpec
        RSpec.configuration.add_formatter NullFormatter

        true
      end

      # We want to persist this object between example runs
      def progress_formatter
        @progress_formatter ||= ProgressFormatter.new($stdout)
      end

      def completion_formatter
        @completion_formatter ||= CompletionFormatter.new
      end

      def flush_log
        completion_formatter.examples.each { |example| json_log_file.puts JSON.generate(example) }
      end

      def json_log_file
        @json_log_file ||= if json_log_file_path
          FileUtils.mkdir_p(File.dirname(json_log_file_path))
          File.truncate(json_log_file_path, 0) if File.exist?(json_log_file_path)
          File.open(json_log_file_path, "a", sync: true)
        else
          File.open(File::NULL, "a")
        end
      end

      def json_log_file_path
        return unless ENV["SPECWRK_OUT"]

        @json_log_file_path ||= File.join(ENV["SPECWRK_OUT"], ENV["SPECWRK_RUN"], "#{ENV["SPECWRK_FORKED"]}.ndjson")
      end
    end
  end
end
