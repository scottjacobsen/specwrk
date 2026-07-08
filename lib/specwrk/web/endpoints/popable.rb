# frozen_string_literal: true

require "specwrk/web/endpoints/base"

module Specwrk
  class Web
    module Endpoints
      class Popable < Base
        private

        def with_pop_response
          if examples.any?
            [200, {"content-type" => "application/json"}, [JSON.generate(examples)]]
          elsif pending.empty? && processing.empty? && completed.empty?
            [204, {"content-type" => "text/plain"}, ["Waiting for sample to be seeded."]]
          elsif expired_examples.length.positive?
            # A worker missed its heartbeats; reclaim its in-flight examples back
            # onto the queue so a live worker can run them. Checked BEFORE the
            # all-done response so dead-worker work is recovered, not abandoned.
            expired_examples.each { |_id, example| example[:worker_id] = worker_id }

            with_lock do
              pending.push_examples(expired_examples.values)
              processing.delete(*expired_examples.keys.map(&:to_s))
            end

            @examples = nil

            [200, {"content-type" => "application/json"}, [JSON.generate(examples)]]
          elsif completed.any? && pending.length.zero?
            # The bucket queue is drained and there's nothing to reclaim, so there
            # is no more work to hand out: tell the worker to go home. This used to
            # require processing.empty?, but a straggler left in processing (whose
            # owning worker is alive but idle) would then NEVER clear, so this 410
            # never fired and workers spin-polled /pop forever — starving the
            # single-process server until CI killed everyone on the no-output
            # timeout. Keying off the drained queue instead terminates cleanly;
            # any worker still running a bucket finishes and gets this on its next
            # request (its results are recorded before this response).
            [410, {"content-type" => "text/plain"}, ["That's a good lad. Run along now and go home."]]
          else
            not_found
          end
        end

        def examples
          @examples ||= begin
            return [] if pending.length.zero?
            bucket_id = with_lock { pending.shift_bucket }
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

        def expired_examples
          return {} unless processing.any?

          @expired_examples ||= processing.to_h.select { |_id, example| expired?(example) }
        end

        # Has the worker missed two heartbeat check-ins?
        def expired?(example)
          return false unless example[:worker_id]
          return false unless example[:processing_started_at]
          return false unless example[:processing_started_at] < (Time.now - 20).to_i

          workers_last_heartbeats[example[:worker_id]] < Time.now - 20
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
