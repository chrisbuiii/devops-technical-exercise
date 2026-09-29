#!/usr/bin/env bash
#
# Demonstrate the GreeterHighErrorRate alert firing.
#
# It drives traffic at /boom (which always returns 500), port-forwards
# Prometheus, and polls the alerts API until the alert transitions to firing,
# then prints the evidence.
#
# Usage:
#   ./observability/demo-alert.sh
#
# Environment overrides:
#   TARGET_URL     base URL to hammer      (default: http://dev.localhost)
#   CLUSTER_NAME   kind cluster name       (default: w3w-greeter)
#   MAX_WAIT       seconds to wait to fire (default: 200)

set -euo pipefail

TARGET_URL="${TARGET_URL:-http://dev.localhost}"
CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONTEXT="kind-${CLUSTER_NAME}"
MAX_WAIT="${MAX_WAIT:-200}"
PROM_LOCAL_PORT="9090"

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "'kubectl' is not on PATH."
command -v curl >/dev/null 2>&1 || die "'curl' is not on PATH."

LOAD_PID=""
PF_PID=""
cleanup() {
  [ -n "$LOAD_PID" ] && kill "$LOAD_PID" >/dev/null 2>&1 || true
  [ -n "$PF_PID" ]   && kill "$PF_PID"   >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. Port-forward Prometheus.
log "Port-forwarding Prometheus to localhost:${PROM_LOCAL_PORT}."
kubectl --context "$CONTEXT" -n monitoring port-forward svc/prometheus \
  "${PROM_LOCAL_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!

for _ in $(seq 1 30); do
  if curl -sf "http://localhost:${PROM_LOCAL_PORT}/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf "http://localhost:${PROM_LOCAL_PORT}/-/ready" >/dev/null 2>&1 \
  || die "Prometheus port-forward did not become ready."

# 2. Generate continuous 5xx load in the background.
log "Generating load against ${TARGET_URL}/boom (Ctrl-C to stop early)."
(
  while true; do
    for _ in $(seq 1 20); do curl -s -o /dev/null "${TARGET_URL}/boom" & done
    wait
  done
) &
LOAD_PID=$!

# 3. Poll the alerts API until the alert is firing.
log "Waiting for GreeterHighErrorRate to fire (up to ${MAX_WAIT}s)."
deadline=$(( $(date +%s) + MAX_WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  alerts="$(curl -s "http://localhost:${PROM_LOCAL_PORT}/api/v1/alerts")"
  if printf '%s' "$alerts" | grep -q '"alertname":"GreeterHighErrorRate"' \
     && printf '%s' "$alerts" | grep -q '"state":"firing"'; then
    log "Alert is FIRING. Evidence from Prometheus /api/v1/alerts:"
    printf '%s\n' "$alerts" | tr ',' '\n' | grep -E 'alertname|state|severity|summary' || true
    echo
    log "Success."
    exit 0
  fi
  sleep 5
done

die "Alert did not fire within ${MAX_WAIT}s. Check Prometheus targets and that greeter pods are annotated for scraping."
