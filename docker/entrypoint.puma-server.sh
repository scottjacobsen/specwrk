#!/bin/sh
# Boot the specwrk queue server under a Puma cluster. All tuning comes from the
# environment; binds TLS only when a cert is provided (bare-VM parity runs) and
# plain TCP otherwise (Kubernetes, where TLS terminates at the edge).
set -eu

: "${PORT:=5138}"
: "${PUMA_WORKERS:=2}"
: "${PUMA_THREADS:=16}"

if [ -n "${SPECWRK_TLS_CERT:-}" ]; then
  : "${SPECWRK_TLS_KEY:?SPECWRK_TLS_KEY is required when SPECWRK_TLS_CERT is set}"
  bind="ssl://0.0.0.0:${PORT}?key=${SPECWRK_TLS_KEY}&cert=${SPECWRK_TLS_CERT}&verify_mode=none"
else
  bind="tcp://0.0.0.0:${PORT}"
fi

# docker/puma.rb only wires the Prometheus metrics listener (METRICS_PORT,
# default 9394, 0/empty disables); CLI flags below take precedence over it.
exec bundle exec puma -C docker/puma.rb -w "$PUMA_WORKERS" -t "${PUMA_THREADS}:${PUMA_THREADS}" -b "$bind" config.ru
