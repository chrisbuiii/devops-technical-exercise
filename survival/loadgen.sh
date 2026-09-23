#!/usr/bin/env bash
#
# Minimal continuous load generator. Sends GET requests to a URL at a steady
# rate and appends "epoch_seconds http_status" to a results file, one line per
# request. It runs until it receives SIGINT/SIGTERM, so an orchestrator can
# start it, perform a disruption, then stop it and summarise the file.
#
# Usage:
#   ./survival/loadgen.sh <target_url> <results_file> [sleep_seconds]

set -uo pipefail

TARGET_URL="${1:-http://prod.localhost/}"
RESULTS_FILE="${2:-/tmp/loadgen-results.txt}"
SLEEP_BETWEEN="${3:-0.1}"

: > "$RESULTS_FILE"

running=true
trap 'running=false' INT TERM

while [ "$running" = true ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$TARGET_URL" 2>/dev/null || echo 000)"
  printf '%s %s\n' "$(date +%s)" "$code" >> "$RESULTS_FILE"
  sleep "$SLEEP_BETWEEN"
done
