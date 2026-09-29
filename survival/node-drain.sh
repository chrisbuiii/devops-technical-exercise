#!/usr/bin/env bash
#
# Evidence for "survives the loss of a single node".
#
# Puts the prod service under continuous load, fires a few long-running
# (in-flight) requests, drains one worker node, and records what happened to the
# traffic. Then uncordons the node again.
#
# Output is both printed and saved to survival/evidence/node-drain.log.
#
# Usage:
#   ./survival/node-drain.sh
#
# Environment overrides:
#   TARGET_URL     base URL under test  (default: http://prod.localhost)
#   DRAIN_NODE     node to drain        (default: w3w-greeter-worker)
#   NAMESPACE      app namespace        (default: greeter-prod)
#   CLUSTER_NAME   kind cluster name    (default: w3w-greeter)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_URL="${TARGET_URL:-http://prod.localhost}"
DRAIN_NODE="${DRAIN_NODE:-w3w-greeter-worker}"
NAMESPACE="${NAMESPACE:-greeter-prod}"
CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONTEXT="kind-${CLUSTER_NAME}"

EVIDENCE_DIR="${SCRIPT_DIR}/evidence"
EVIDENCE_FILE="${EVIDENCE_DIR}/node-drain.log"
RESULTS_FILE="$(mktemp)"
mkdir -p "$EVIDENCE_DIR"

log() { printf '==> %s\n' "$*"; }

summarize() {
  awk '{total++; if($2==200) ok++; else bad++}
       END{printf "  requests=%d  ok(200)=%d  failed=%d  success_rate=%.2f%%\n",
                  total, ok, bad, (total? ok/total*100:0)}' "$1"
}

kctl() { kubectl --context "$CONTEXT" "$@"; }

LOAD_PID=""
cleanup() {
  [ -n "$LOAD_PID" ] && kill -INT "$LOAD_PID" >/dev/null 2>&1 || true
  # Never leave the node cordoned.
  kctl uncordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  rm -f "$RESULTS_FILE" "${RESULTS_FILE}.work" 2>/dev/null || true
}
trap cleanup EXIT

main() {
  echo "=== Node drain survival test: $(date) ==="
  echo "target=${TARGET_URL}  node=${DRAIN_NODE}  namespace=${NAMESPACE}"
  echo

  log "Pods before drain:"
  kctl -n "$NAMESPACE" get pods -o wide --no-headers | awk '{print "  "$1, $3, $7}'
  echo

  log "Starting continuous load."
  # loadgen writes results to a file; its stdout goes to /dev/null so it does not
  # hold the tee pipe open.
  "${SCRIPT_DIR}/loadgen.sh" "${TARGET_URL}/" "$RESULTS_FILE" 0.1 >/dev/null 2>&1 &
  LOAD_PID=$!
  sleep 8
  log "Baseline (8s of load before disruption):"
  summarize "$RESULTS_FILE"
  echo

  # Long in-flight requests that straddle the drain, to prove graceful drain lets
  # them finish rather than dropping them. Track their PIDs so we wait on exactly
  # these, not the continuous load generator (which never exits on its own).
  log "Firing 5 in-flight /work?ms=8000 requests that will straddle the drain."
  : > "${RESULTS_FILE}.work"
  WORK_PIDS=""
  for _ in $(seq 1 5); do
    ( code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 "${TARGET_URL}/work?ms=8000" 2>/dev/null || echo 000)"
      echo "$code" >> "${RESULTS_FILE}.work" ) &
    WORK_PIDS="$WORK_PIDS $!"
  done

  log "Draining ${DRAIN_NODE} (evicting its pods)."
  kctl drain "$DRAIN_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=90s || true
  echo

  log "Pods right after drain (the cordoned node is excluded from the spread, so the evicted pod reschedules onto the surviving node; the service keeps serving throughout):"
  kctl -n "$NAMESPACE" get pods -o wide --no-headers | awk '{print "  "$1, $3, $7}'
  echo

  log "Waiting for the in-flight /work requests to return."
  for p in $WORK_PIDS; do wait "$p" 2>/dev/null || true; done
  echo "  in-flight /work results (expect 200 = finished gracefully): $(tr '\n' ' ' < "${RESULTS_FILE}.work")"
  echo

  log "Uncordoning ${DRAIN_NODE}."
  kctl uncordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  kctl -n "$NAMESPACE" rollout status deploy/greeter-prod --timeout=120s || true
  echo

  log "Stopping load."
  kill -INT "$LOAD_PID" >/dev/null 2>&1 || true
  LOAD_PID=""
  sleep 1

  log "Overall result across the whole test:"
  summarize "$RESULTS_FILE"
  echo
  echo "=== done ==="
}

# Run everything through tee in a single pipeline so all output is flushed to the
# evidence file, even when the script is run in the background.
main 2>&1 | tee "$EVIDENCE_FILE"
