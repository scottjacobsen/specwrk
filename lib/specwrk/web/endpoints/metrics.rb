# frozen_string_literal: true

require "time"

require "specwrk/web/endpoints/base"

module Specwrk
  class Web
    module Endpoints
      # Prometheus text-format (version 0.0.4) snapshot of queue state, read
      # from the store at scrape time. The formatting is hand-rolled on
      # purpose: ten unlabeled gauges don't justify a prometheus-client
      # dependency in a gem that CI installs thousands of times a day.
      #
      # Every gauge is aggregated across active runs with NO run_id label:
      # run ids are CI-generated UUIDs, so a per-run label would create
      # unbounded series cardinality in Prometheus.
      #
      # Reads are sized for a scrape-per-15s budget: counts come from
      # Store#size (adapter-cheap, e.g. HLEN) or small dedicated fields —
      # never from #keys or full example payloads.
      class Metrics < Base
        # How long a seeded run stays in the index before a scrape prunes it.
        # Comfortably longer than any real run; pruning exists only to keep
        # the index from growing without bound on a long-lived server.
        RUN_TTL_SECONDS = 24 * 60 * 60

        # Far more simultaneously-active runs than a healthy deployment sees.
        # Past this, per-run reads could turn the scrape into the very load
        # spike it is meant to observe, so emit only the index-level numbers
        # plus a truncation flag and let an alert catch it.
        MAX_RUNS = 200

        # A scrape is a read-only observer: skip Base#response's worker
        # heartbeat and run metadata bookkeeping so a scraper that happens to
        # send run/worker headers can't mint the very state being measured.
        def response
          with_response
        end

        def with_response
          scrape_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          emit_run_metrics
          gauge "specwrk_run_times_size",
            "Entries in the cross-run run_times store.",
            run_times.size
          gauge "specwrk_metrics_truncated",
            "1 when the active-run count exceeded the per-run collection cap.",
            truncated? ? 1 : 0
          gauge "specwrk_server_scrape_duration_seconds",
            "Time spent computing this scrape.",
            (Process.clock_gettime(Process::CLOCK_MONOTONIC) - scrape_started_at).round(6)

          return [200, {}, []] if request.head?

          [200, {"content-type" => "text/plain; version=0.0.4"}, [lines.join("\n") << "\n"]]
        end

        private

        def emit_run_metrics
          # Truncated: the index length alone approximates active runs (the
          # per-run metadata liveness check is skipped along with everything
          # else per-run).
          totals = collect_run_totals unless truncated?

          gauge "specwrk_runs_active",
            "Runs seeded within the last 24 hours that still have run metadata.",
            truncated? ? fresh_runs.length : totals[:runs_active]

          return if truncated?

          gauge "specwrk_pending_examples",
            "Examples queued and not yet handed to a worker, across active runs.",
            totals[:pending_examples]
          gauge "specwrk_pending_buckets",
            "Work buckets queued and not yet handed to a worker, across active runs.",
            totals[:pending_buckets]
          gauge "specwrk_processing_examples",
            "Examples currently checked out by workers, across active runs.",
            totals[:processing_examples]
          gauge "specwrk_completed_examples",
            "Examples with recorded results, across active runs.",
            totals[:completed_examples]
          gauge "specwrk_failed_examples",
            "Examples that have failed at least once, across active runs.",
            totals[:failed_examples]
          gauge "specwrk_workers_connected",
            "Workers seen within the heartbeat-expiry window, across active runs.",
            totals[:workers_connected]
          gauge "specwrk_workers_stale",
            "Workers that stopped checking in without finishing, across active runs.",
            totals[:workers_stale]
          gauge "specwrk_oldest_active_run_age_seconds",
            "Age of the oldest active run's first request.",
            totals[:oldest_started_at] ? (now - totals[:oldest_started_at]).round : 0
        end

        def collect_run_totals
          totals = Hash.new(0)
          totals[:oldest_started_at] = nil

          fresh_runs.each do |run_id|
            # started_at is minted by the first run-scoped request (see
            # Base#response), so its presence doubles as the "run metadata
            # still exists" activity check.
            started_at = store_for(run_id, "metadata")["started_at"]
            next unless started_at

            started_at = Time.parse(started_at)
            totals[:runs_active] += 1
            totals[:oldest_started_at] = started_at if totals[:oldest_started_at].nil? || started_at < totals[:oldest_started_at]

            pending = PendingStore.new(store_uri, scope_for(run_id, "pending"))
            totals[:pending_examples] += pending.example_count
            totals[:pending_buckets] += pending.bucket_ids.length
            totals[:processing_examples] += store_for(run_id, "processing").size
            totals[:completed_examples] += store_for(run_id, "completed").size
            totals[:failed_examples] += store_for(run_id, "failure_counts").size

            connected, stale = worker_counts(run_id)
            totals[:workers_connected] += connected
            totals[:workers_stale] += stale
          end

          totals
        end

        # Active-run enumeration via the index /seed maintains, pruning aged
        # entries as a side effect — the scrape is the only reader that
        # cares, and CI runs have no reliable teardown request to hook.
        def fresh_runs
          @fresh_runs ||= begin
            cutoff = now.to_i - RUN_TTL_SECONDS
            fresh, expired = runs_index.to_h.partition { |_run_id, seeded_at| seeded_at.to_i >= cutoff }

            runs_index.delete(*expired.map { |run_id, _seeded_at| run_id.to_s }) if expired.any?

            fresh.map { |run_id, _seeded_at| run_id.to_s }
          end
        end

        # Same missed-heartbeats window the reclaim scan uses (see Popable),
        # so "stale" here means "its in-flight work is being reclaimed".
        def worker_counts(run_id)
          index = store_for(run_id, "workers_index").to_h
          threshold = now.to_i - ENV.fetch("SPECWRK_SRV_EXPIRE_AFTER", "20").to_i

          connected = index.count { |_worker_id, last_seen_at| last_seen_at.to_i >= threshold }
          [connected, index.length - connected]
        end

        def truncated?
          fresh_runs.length > MAX_RUNS
        end

        def store_for(run_id, name)
          Store.new(store_uri, scope_for(run_id, name))
        end

        # Mirrors Base#run_scope's hash-tag braces so a run's stores resolve
        # to the same keys the run-scoped endpoints wrote.
        def scope_for(run_id, name)
          File.join("{#{run_id}}", name)
        end

        def store_uri
          ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///")
        end

        def now
          @now ||= Time.now
        end

        def lines
          @lines ||= []
        end

        def gauge(name, help, value)
          lines << "# HELP #{name} #{help}"
          lines << "# TYPE #{name} gauge"
          lines << "#{name} #{value}"
        end
      end
    end
  end
end
