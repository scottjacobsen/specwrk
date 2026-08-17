# frozen_string_literal: true

require "json"

require "specwrk/store"

module Specwrk
  class Web
    module Endpoints
      class Base
        MUTEX = Mutex.new

        attr_reader :started_at

        def initialize(request)
          @request = request
        end

        def response
          return with_response unless run_id # No run_id, no datastore usage in the endpoint

          payload # parse the payload before any locking

          worker.first_seen_at ||= Time.now
          worker.last_seen_at = Time.now

          started_at = metadata[:started_at] ||= Time.now.iso8601
          @started_at = Time.parse(started_at)

          with_response.tap do |response|
            response[1]["x-specwrk-status"] = worker_status.to_s
          end
        end

        def with_response
          not_found
        end

        private

        attr_reader :request

        def not_found
          if request.head?
            [404, {}, []]
          else
            [404, {"content-type" => "text/plain"}, ["This is not the path you're looking for, 'ol chap..."]]
          end
        end

        def ok
          if request.head?
            [200, {}, []]
          else
            [200, {"content-type" => "text/plain"}, ["OK, 'ol chap"]]
          end
        end

        def payload
          return unless request.content_type&.start_with?("application/json")
          return unless request.post? || request.put? || request.delete?
          return if body.empty?

          @payload ||= JSON.parse(body, symbolize_names: true)
        end

        def body
          @body ||= request.body.read
        end

        def pending
          @pending ||= PendingStore.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "pending"))
        end

        def processing
          @processing ||= ProcessingStore.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "processing"))
        end

        def completed
          @completed ||= CompletedStore.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "completed"))
        end

        def failure_counts
          @failure_counts ||= Store.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "failure_counts"))
        end

        def metadata
          @metadata ||= Store.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "metadata"))
        end

        def run_times
          @run_times ||= Store.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "file://#{File.join(Dir.tmpdir, "specwrk")}"), "run_times")
        end

        # Global run_id -> seeded-at-epoch index, written by /seed and read
        # (and pruned) by /metrics. The Store abstraction deliberately has no
        # keyspace scan, so an index is the only way to enumerate runs — and
        # it stays portable across the memory/file/redis adapters. Untagged
        # (no hash-tag braces) like run_times: it spans runs.
        def runs_index
          @runs_index ||= Store.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), "runs_index")
        end

        # Per-run worker_id -> last-contact-epoch index so /metrics can
        # enumerate a run's workers without a keyspace scan. Worker stores
        # themselves are keyed {run}/workers/<id> and thus unenumerable.
        def workers_index
          @workers_index ||= Store.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "workers_index"))
        end

        # Called from the worker-driven endpoints only — /heartbeat for idle
        # workers, /pop and /complete_and_pop for busy ones (a busy worker's
        # heartbeat thread stays quiet while its data client is active). The
        # orchestrator's requests (/seed, /report, /shutdown) never land here,
        # so the index holds exactly the worker fleet.
        def record_worker_contact!
          return if worker_id.empty?

          workers_index[worker_id] = Time.now.to_i
        end

        def worker
          @worker ||= worker_store_for(worker_id)
        end

        def worker_id
          request.get_header("HTTP_X_SPECWRK_ID").to_s
        end

        def worker_status
          return 0 if worker[:failed].nil? && completed.any? # worker starts after run has completed

          worker[:failed] || 1
        end

        def worker_store_for(id)
          WorkerStore.new(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///"), File.join(run_scope, "workers", id))
        end

        def run_id
          request.get_header("HTTP_X_SPECWRK_RUN")
        end

        # The braces are a Redis Cluster hash tag: every key for a run — its
        # stores and its lock — hashes to the same cluster slot, which
        # multi-key and pipelined operations on the run require. The global
        # run_times store stays untagged; it's shared across runs. Other
        # adapters treat the braces as ordinary characters.
        def run_scope
          @run_scope ||= "{#{run_id}}"
        end

        def with_lock
          return yield unless run_id

          with_mutex do
            Store.with_lock(URI(ENV.fetch("SPECWRK_SRV_STORE_URI", "memory:///")), run_scope) { yield }
          end
        end

        def with_mutex
          if Thread.current == Thread.main
            yield
          else
            MUTEX.synchronize { yield }
          end
        end
      end

      # Base default response is 404
      NotFound = Class.new(Base)
    end
  end
end
