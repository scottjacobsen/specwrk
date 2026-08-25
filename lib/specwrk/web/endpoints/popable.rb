# frozen_string_literal: true

require "specwrk/web/endpoints/base"

module Specwrk
  class Web
    module Endpoints
      class Popable < Base
        LAST_EXPIRY_CHECK_AT_KEY = :last_expiry_check_at
        STALE_IN_FLIGHT_POSSIBLE_AT_KEY = :stale_in_flight_possible_at

        private

        # /pop and /complete_and_pop both mutate state AND hand out a bucket,
        # yet the client retries them when a response is lost mid-flight.
        # Re-running a request the server already handled double-tallies
        # results and orphans the first bucket in processing — so record each
        # response against the client-sent request id and replay duplicates.
        def idempotent
          if request_id.empty?
            record_worker_contact!
            return yield
          end

          replay = worker.replayable_response(request_id)
          return replay if replay

          # Record contact only past the replay check: a replayed gone-home
          # 410 must not resurrect the index entry its original delivery
          # removed (see with_pop_response).
          record_worker_contact!
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
            # Checked BEFORE the all-done response so a dead worker's
            # in-flight examples are recovered, not abandoned.
            @examples = nil

            if examples.any?
              [200, {"content-type" => "application/json"}, [JSON.generate(examples)]]
            else
              # Another poller stole every reclaimed bucket first; 404 so
              # this worker polls again rather than 200 with an empty array.
              not_found
            end
          elsif completed.any? && pending.length.zero? && !stale_in_flight_work?
            # Bucket queue drained and nothing reclaimable: go home. Keyed off
            # the drained queue, NOT processing.empty? — a live-but-idle
            # straggler in processing would keep this 410 from ever firing and
            # workers would spin-poll forever. stale_in_flight_work? carves out
            # the dead-worker case: 410 is terminal, so pollers must stay
            # around until an expiry scan requeues a dead worker's bucket —
            # otherwise the run "drains" with examples that never ran.
            #
            # The 410 is this worker's clean exit — drop it from the workers
            # index so /metrics counts only workers that vanished mid-run as
            # stale.
            workers_index.delete(worker_id) unless worker_id.empty?

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
            now = Time.now.to_i

            processing_data = examples.map do |example|
              [
                example[:id], example.merge(worker_id: worker_id, processing_started_at: now)
              ]
            end

            processing.merge!(processing_data.to_h)
            # Index the handout by worker so the expiry scan can find reclaim
            # candidates from worker-count-sized records instead of walking
            # every processing payload.
            in_flight[worker_id] = {ids: examples.map { |example| example[:id] }, processing_started_at: now}
            bucket.clear

            examples
          end
        end

        # Requeue examples whose owning worker has missed its heartbeats.
        # At most one scan per SPECWRK_SRV_EXPIRY_CHECK_INTERVAL runs, under
        # the store lock, so an empty-pop stampede collapses into it. The
        # scan reads the in-flight index (one small record per worker), never
        # the multi-MB processing payloads — those are read only for the
        # stale workers' examples actually being requeued, normally none.
        def reclaim_expired_examples
          @reclaim_expired_examples ||= if processing.empty? || !expiry_check_due?
            {}
          else
            with_lock do
              next {} unless expiry_check_due? # someone scanned while we waited on the lock

              metadata[LAST_EXPIRY_CHECK_AT_KEY] = Time.now.to_i

              stale, live = in_flight.to_h.partition { |id, record| record_expired?(id.to_s, record) }.map(&:to_h)

              # Cache the staleness verdict for the empty pops between scans,
              # under the same lock as the requeue so the two can never
              # disagree. Everything stale is requeued below, so only the live
              # records bound when staleness next becomes possible.
              metadata[STALE_IN_FLIGHT_POSSIBLE_AT_KEY] = stale_in_flight_possible_at(live)

              next {} if stale.empty?

              candidate_keys = stale.values.flat_map { |record| record[:ids] }.map(&:to_s)
              candidates = candidate_keys.any? ? processing.multi_read(*candidate_keys) : {}
              already_completed = candidates.any? ? completed.multi_read(*candidates.keys).keys : []
              requeueable = candidates.except(*already_completed)
                .transform_values { |example| example.except(:worker_id, :processing_started_at) }

              pending.reload.merge!(requeueable, prepend: true) if requeueable.any?
              processing.delete(*candidate_keys) if candidate_keys.any? # completed stragglers cleared too
              # Index entries go last: if we die mid-reclaim the next scan
              # re-candidates these workers, finds their examples gone from
              # processing, and just finishes the cleanup — no double-requeue.
              in_flight.delete(*stale.keys.map(&:to_s))

              requeueable
            end
          end
        end

        def expiry_check_due?
          Time.now.to_i - (metadata[LAST_EXPIRY_CHECK_AT_KEY] || 0) >= expiry_check_interval
        end

        # In-flight work owned by a worker that has missed its heartbeats —
        # reclaimable, so the drained-queue 410 must not send the remaining
        # pollers home past it. Live owners don't count: their buckets finish
        # on their own. Answered from the verdict the reclaim scan caches,
        # never by scanning here: this runs on EVERY empty pop, and no bucket
        # can turn stale sooner than the cached horizon. A missing verdict
        # means unknown — assume stale and let the next scan write one.
        def stale_in_flight_work?
          return false if processing.empty?

          Time.now.to_i >= (metadata[STALE_IN_FLIGHT_POSSIBLE_AT_KEY] || 0).to_i
        end

        # Earliest future moment in-flight work could first turn stale: each
        # live record can't expire before max(handout, last heartbeat) +
        # expire_after, and nothing handed out after this scan can expire
        # before now + expire_after — which also caps the verdict, so it can
        # never overshoot work this scan didn't see.
        def stale_in_flight_possible_at(live_records)
          horizon = Time.now.to_i + expire_after_seconds
          earliest = live_records.map do |worker_id, record|
            [record[:processing_started_at].to_i, workers_last_heartbeats[worker_id.to_s].to_i].max + expire_after_seconds
          end.min

          [earliest, horizon].compact.min
        end

        # Per-run worker_id -> {ids:, processing_started_at:} record of the
        # bucket each worker holds, so staleness questions are answered from
        # worker-count-sized records instead of processing payloads.
        def in_flight
          @in_flight ||= Store.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "in_flight"), ttl: run_ttl)
        end

        # How often (seconds) the processing set is scanned for expired examples
        # on an empty pop. Override with SPECWRK_SRV_EXPIRY_CHECK_INTERVAL.
        def expiry_check_interval
          @expiry_check_interval ||= ENV.fetch("SPECWRK_SRV_EXPIRY_CHECK_INTERVAL", "5").to_i
        end

        # Has the record's worker missed two heartbeat check-ins?
        def record_expired?(worker_id, record)
          return false unless record[:processing_started_at]
          return false unless record[:processing_started_at] < (Time.now - expire_after_seconds).to_i

          workers_last_heartbeats[worker_id] < Time.now - expire_after_seconds
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
