# frozen_string_literal: true

require "specwrk/web/endpoints/popable"

module Specwrk
  class Web
    module Endpoints
      class CompleteAndPop < Popable
        EXAMPLE_STATUSES = %w[passed failed pending]

        def with_response
          idempotent do
            retry_examples # pre-calculate before lock
            # Snapshot what the completed store held BEFORE this payload's
            # merge: reconciliation and tallies below must compare against the
            # prior state, not read back their own writes.
            previously_completed

            with_lock do
              pending.reload
              processing.delete(*(completed_examples.keys + retry_examples.keys))
              # This worker's bucket is fully reported; drop its in-flight
              # index entry (with_pop_response writes a fresh one if another
              # bucket is handed out below).
              in_flight.delete(worker_id) unless worker_id.empty?
              pending.merge!(retry_examples)
            end

            completed.merge!(mergeable_completed_examples)
            release_superseded_failures
            failure_counts.merge!(retry_examples_new_failure_counts)

            update_run_times

            with_pop_response
          end
        end

        private

        # Deduplicated by id with pass-beats-fail semantics: when one payload
        # carries several attempts of the same example (duplicate executions),
        # a failed record never displaces a non-failed one — otherwise the
        # last record would win regardless of order and a flake's failing
        # attempt could complete an example that actually passed.
        #
        # Results whose processing entries are GONE are accepted too: they're
        # a falsely-expired bucket's original owner reporting after the
        # reclaim erased its entries. That work really ran — discarding it
        # threw away real outcomes. The request-id replay layer still guards
        # duplicate requests.
        def all_examples
          @all_examples ||= payload.each_with_object({}) do |example, examples|
            already_seen = examples[example[:id]]
            next if already_seen && example[:status] == "failed" && already_seen[:status] != "failed"

            examples[example[:id]] = example
          end
        end

        def processing_examples
          @processing_examples ||= processing.multi_read(*payload.map { |example| example[:id] })
        end

        def completed_examples
          @completed_examples ||= all_examples.map do |id, example|
            next if retry_example?(example)

            [id, example]
          end.compact.to_h
        end

        def retry_examples
          @retry_examples ||= all_examples.map do |id, example|
            next unless retry_example?(example)

            [id, example]
          end.compact.to_h
        end

        def retry_examples_new_failure_counts
          @retry_examples_new_failure_counts ||= retry_examples.map do |id, _example|
            [id, all_example_failure_counts.fetch(id, 0) + 1]
          end.to_h
        end

        def retry_example?(example)
          return false unless example[:status] == "failed"
          # A late result whose processing entry is gone: the reclaim that
          # erased it already requeued the example (or someone completed it),
          # so a retry here would duplicate the pending entry. It completes
          # under pass-beats-fail instead.
          return false unless processing_examples[example[:id]]
          # A duplicate execution of an example that already completed as
          # passed: there is nothing to retry, and requeuing it would run a
          # green example yet again. It falls through to completed_examples,
          # where mergeable_completed_examples drops it.
          return false if previously_completed.dig(example[:id], :status) == "passed"
          return false unless pending.max_retries.positive?

          example_failure_count = all_example_failure_counts.fetch(example[:id], 0)

          example_failure_count < pending.max_retries
        end

        # What the completed store already holds for this payload's ids — the
        # basis for reconciling duplicate executions of the same example.
        def previously_completed
          @previously_completed ||= all_examples.any? ? completed.multi_read(*all_examples.keys) : {}
        end

        # Pass-beats-fail against the completed store: a failed record must
        # never overwrite a pass another execution already recorded, while a
        # pass may overwrite an earlier failure (release_superseded_failures
        # then credits that back). Records are stamped with the reporting
        # worker so a later pass knows whose tally held the failure.
        def mergeable_completed_examples
          @mergeable_completed_examples ||= completed_examples.reject { |id, example|
            example[:status] == "failed" && previously_completed.dig(id, :status) == "passed"
          }.transform_values { |example| example.merge(worker_id: worker_id) }
        end

        # A pass landing over an earlier completed failure removes that
        # failure from the tally of the worker that reported it, so an
        # already-superseded flake can't red the node that saw it fail first.
        # Failures recorded before worker stamping existed have no worker_id
        # and are left alone.
        def release_superseded_failures
          superseded_by_worker = mergeable_completed_examples.filter_map { |id, example|
            next if example[:status] == "failed"

            previous = previously_completed[id]
            previous[:worker_id] if previous && previous[:status] == "failed"
          }.tally

          superseded_by_worker.each do |id, count|
            next if id.nil?

            store = (id.to_s == worker_id) ? worker : worker_store_for(id.to_s)
            store.merge!(failed: [store[:failed].to_i - count, 0].max)
          end
        end

        def all_example_failure_counts
          @all_example_failure_counts ||= failure_counts.multi_read(*all_examples.keys)
        end

        # Tally only records that actually landed and changed the recorded
        # outcome: a dropped failed-over-passed duplicate must not red this
        # worker, and a same-status duplicate must not inflate its counts.
        def completed_examples_status_counts
          @completed_examples_status_counts ||= mergeable_completed_examples
            .reject { |id, example| previously_completed.dig(id, :status) == example[:status] }
            .values.map { |example| example[:status] }.tally
        end

        def update_run_times
          # Rough run time tracking does not require holding the store lock
          run_times.merge! run_time_data

          # workers are single process, single-threaded, so safe to do this work without the lock
          existing_status_counts = worker.multi_read(*EXAMPLE_STATUSES)
          new_status_counts = EXAMPLE_STATUSES.map do |status|
            [status, existing_status_counts.fetch(status, 0) + completed_examples_status_counts.fetch(status, 0)]
          end.to_h

          worker.merge!(new_status_counts)
        end

        def run_time_data
          # Record run times ONLY for passed examples. Synthesized results
          # (unexecuted examples reported as failed after a child died) carry
          # run_time 0.0, but real failures and skips also poison the store:
          # a cascade that fails everything instantly (e.g. one bad connection
          # state) records microsecond "measured" times for hundreds of
          # browser specs, and the next run's batched grouping packs them all
          # into one unfinishable mega-bucket. Passed times are the only
          # trustworthy scheduling signal.
          @run_time_data ||= payload.filter_map { |example|
            next unless example[:status] == "passed"

            [example[:id], example[:run_time]] if example[:run_time]&.positive?
          }.to_h
        end
      end
    end
  end
end
