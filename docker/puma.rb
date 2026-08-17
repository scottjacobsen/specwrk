# frozen_string_literal: true

# Prometheus metrics for the queue server. Everything else about the server
# (workers, threads, bind) stays on the CLI in the entrypoint; CLI flags take
# precedence over this file, so it only carries the metrics wiring.
#
# The metrics listener is a separate plain-HTTP port, never the app port: the
# app port is TLS + bearer-auth'd, while Prometheus and the Datadog agent's
# openmetrics check need unauthenticated plain HTTP. The metrics port is
# simply not exposed outside the pod/host network.
#
# The puma-metrics plugin runs in the cluster master, whose Puma.stats
# includes per-worker worker_status, so one scrape reflects the whole cluster
# (per-worker gauges carry an index label; totals are a PromQL sum() away)
# rather than whichever worker happened to answer.
metrics_port = ENV.fetch("METRICS_PORT", "9394")

if metrics_port.to_i.positive?
  plugin :metrics
  metrics_url "tcp://0.0.0.0:#{metrics_port.to_i}"

  require "prometheus/client"
  require "specwrk/version"

  # Build metadata for dashboards/alerts; the value is a constant 1 and the
  # interesting part is the label set.
  Prometheus::Client.registry.gauge(
    :specwrk_server_info,
    docstring: "specwrk queue-server build information",
    labels: [:version],
    preset_labels: {version: Specwrk::VERSION}
  ).set(1)
end
