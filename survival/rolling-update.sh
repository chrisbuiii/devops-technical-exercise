#!/usr/bin/env bash
#
# Evidence for a clean rolling update.
#
# Puts the prod service under continuous load, triggers a rolling restart, and
# records whether any request failed while pods were being replaced. With
# maxSurge=0/maxUnavailable=1, readiness gating and graceful shutdown, this
# should complete with no failed requests.
#
# Output is both printed and saved to survival/evidence/rolling-update.log.
#
# Usage:
#   ./survival/rolling-update.sh
#
# Environment overrides:
#   TARGET_URL     base URL under test  (default: http://prod.localhost)
#   NAMESPACE      app namespace        (default: greeter-prod)
#   DEPLOYMENT     deployment name      (default: greeter-prod)
#   CLUSTER_NAME   kind cluster name    (default: w3w-greeter)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_URL="${TARGET_URL:-http://prod.localhost}"
NAMESPACE="${NAMESPACE:-greeter-prod}"
DEPLOYMENT="${DEPLOYMENT:-greeter-prod}"
CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONTEXT="kind-${CLUSTER_NAME}"

EVIDENCE_DIR="${SCRIPT_DIR}/evidence"
EVIDENCE_FILE="${EVIDENCE_DIR}/rolling-update.log"
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
  rm -f "$RESULTS_FILE" 2>/dev/null || true
}
trap cleanup EXIT

main() {
  echo "=== Rolling update survival test: $(date) ==="
  echo "target=${TARGET_URL}  deployment=${NAMESPACE}/${DEPLOYMENT}"
  echo

  log "Pods before rollout:"
  kctl -n "$NAMESPACE" get pods -o wide --no-headers | awk '{print "  "$1, $3, $7}'
  echo

  log "Starting continuous load."
  "${SCRIPT_DIR}/loadgen.sh" "${TARGET_URL}/" "$RESULTS_FILE" 0.1 >/dev/null 2>&1 &
  LOAD_PID=$!
  sleep 5

  log "Triggering rolling restart of ${DEPLOYMENT}."
  kctl -n "$NAMESPACE" rollout restart "deploy/${DEPLOYMENT}"
  kctl -n "$NAMESPACE" rollout status "deploy/${DEPLOYMENT}" --timeout=180s
  echo

  log "Letting load run a few more seconds to settle."
  sleep 5

  log "Stopping load."
  kill -INT "$LOAD_PID" >/dev/null 2>&1 || true
  LOAD_PID=""
  sleep 1

  log "Pods after rollout:"
  kctl -n "$NAMESPACE" get pods -o wide --no-headers | awk '{print "  "$1, $3, $7}'
  echo

  log "Result across the rollout (expect 0 failed):"
  summarize "$RESULTS_FILE"
  echo
  echo "=== done ==="
}

main 2>&1 | tee "$EVIDENCE_FILE"
