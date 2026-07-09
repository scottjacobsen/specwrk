# frozen_string_literal: true

require "specwrk/web/endpoints/base"

module Specwrk
  class Web
    module Endpoints
      class Popable < Base
        LAST_EXPIRY_CHECK_AT_KEY = :last_expiry_check_at

        private

        # /pop and /complete_and_pop each both mutate state AND hand out a
        # bucket, so they cannot be safely retried — yet the client retries
        # them when a response is lost mid-flight (e.g. connection reset after
        # the server finished processing). Without this, the retry of a request
        # the server already handled would run the endpoint AGAIN: the same
        # results double-tallied and, worse, a second bucket shifted to the
        # worker while the first sits orphaned in processing under its name —
        # heartbeat-alive, so never reclaimed. Record each response against the
        # client-sent request id and replay it verbatim for a duplicate.
        def idempotent
          return yield if request_id.empty?

          replay = worker.replayable_response(request_id)
          return replay if replay

          yield.tap { |response| worker.record_response!(request_id, response) }
        end

        def request_id
          @request_id ||= request.get_header("HTTP_X_SPECWRK_REQUEST_ID").to_s
        end

        def with_pop_response
          if examples.any?
            [200, {"content-type" => "application/json"}, [JSON.generate(examples)]]
          elsif pending.empty? && processing.empty? && completed.empty?
            [204, {"content-type" => "text/plain"}, ["Waiting for sample to be seeded."]]
          elsif reclaim_expired_examples.any?
            # A worker missed its heartbeats; reclaim its in-flight examples back
            # onto the queue so a live worker can run them. Checked BEFORE the
            # all-done response so dead-worker work is recovered, not abandoned.
            @examples = nil

            if examples.any?
              [200, {"content-type" => "application/json"}, [JSON.generate(examples)]]
            else
              # Every reclaimed bucket was already stolen by another poller
              # before we got back around to handing one out. 404 so this
              # worker polls again, rather than 200 it an empty array.
              not_found
            end
          elsif completed.any? && pending.length.zero? && !stale_in_flight_work?
            # The bucket queue is drained and there's nothing to reclaim, so there
            # is no more work to hand out: tell the worker to go home. This used to
            # require processing.empty?, but a straggler left in processing (whose
            # owning worker is alive but idle) would then NEVER clear, so this 410
            # never fired and workers spin-polled /pop forever — starving the
            # single-process server until CI killed everyone on the no-output
            # timeout. Keying off the drained queue instead terminates cleanly;
            # any worker still running a bucket finishes and gets this on its next
            # request (its results are recorded before this response).
            #
            # stale_in_flight_work? carves out the dead-worker case: 410 is
            # terminal, so if in-flight work belongs to a worker that has stopped
            # heartbeating and everyone else goes home before the expiry scan
            # requeues it, nobody is left to run it and the run "drains" with
            # examples that never ran. 404 instead keeps the pollers around until
            # a scan reclaims the bucket and hands it back out.
            [410, {"content-type" => "text/plain"}, ["That's a good lad. Run along now and go home."]]
          else
            not_found
          end
        end

        def examples
          @examples ||= begin
            return [] if pending.length.zero?
            bucket_id = with_lock { pending.reload.shift_bucket }
            return [] if bucket_id.nil?

            bucket = pending.bucket_store_for(bucket_id)
            examples = bucket.examples

            processing_data = examples.map do |example|
              [
                example[:id], example.merge(worker_id: worker_id, processing_started_at: Time.now.to_i)
              ]
            end

            processing.merge!(processing_data.to_h)
            bucket.clear

            examples
          end
        end

        # Reclaim examples whose owning worker has missed its heartbeats, requeuing
        # them onto pending. Gated by expiry_check_due? so an empty-pop stampede
        # (e.g. dozens of idle workers post-drain) doesn't each run a full scan of
        # processing every request — at most one scan per
        # SPECWRK_SRV_EXPIRY_CHECK_INTERVAL actually walks the set, and that scan
        # (plus the requeue) happens under the store lock so concurrent checkers
        # collapse into it rather than duplicating the work or the requeue.
        def reclaim_expired_examples
          @reclaim_expired_examples ||= if processing.empty? || !expiry_check_due?
            {}
          else
            with_lock do
              next {} unless expiry_check_due? # someone scanned while we waited on the lock

              metadata[LAST_EXPIRY_CHECK_AT_KEY] = Time.now.to_i

              candidates = processing.reload.to_h.select { |_id, example| expired?(example) }
              next {} if candidates.empty?

              candidate_keys = candidates.keys.map(&:to_s)
              already_completed = completed.multi_read(*candidate_keys).keys
              requeueable = candidates.reject { |id, _| already_completed.include?(id.to_s) }
                .transform_values { |example| example.except(:worker_id, :processing_started_at) }

              pending.reload.merge!(requeueable, prepend: true) if requeueable.any?
              processing.delete(*candidate_keys) # completed stragglers cleared too

              requeueable
            end
          end
        end

        def expiry_check_due?
          Time.now.to_i - (metadata[LAST_EXPIRY_CHECK_AT_KEY] || 0) >= expiry_check_interval
        end

        # In-flight work owned by a worker that has missed its heartbeats. Such
        # work is (or is about to be) reclaimable, so the drained-queue 410 must
        # not send the remaining pollers home past it. Live owners don't count:
        # their buckets finish on their own and must not hold up the drain.
        # Deliberately NOT gated by expiry_check_due? — this read-only check is
        # what bridges the gap between two interval-gated reclaim scans.
        def stale_in_flight_work?
          return false if processing.empty?

          processing.reload.to_h.any? { |_id, example| expired?(example) }
        end

        # How often (seconds) the processing set is scanned for expired examples
        # on an empty pop. Override with SPECWRK_SRV_EXPIRY_CHECK_INTERVAL.
        def expiry_check_interval
          @expiry_check_interval ||= ENV.fetch("SPECWRK_SRV_EXPIRY_CHECK_INTERVAL", "5").to_i
        end

        # Has the worker missed two heartbeat check-ins?
        def expired?(example)
          return false unless example[:worker_id]
          return false unless example[:processing_started_at]
          return false unless example[:processing_started_at] < (Time.now - expire_after_seconds).to_i

          workers_last_heartbeats[example[:worker_id]] < Time.now - expire_after_seconds
        end

        # Seconds of missed heartbeats before a processing example is considered
        # abandoned. Override with SPECWRK_SRV_EXPIRE_AFTER.
        def expire_after_seconds
          @expire_after_seconds ||= ENV.fetch("SPECWRK_SRV_EXPIRE_AFTER", "20").to_i
        end

        def workers_last_heartbeats
          @workers_last_heartbeats ||= Hash.new do |h, k|
            h[k] = worker_store_for(k).last_seen_at || Time.at(0)
          end
        end
      end
    end
  end
end
