#!/usr/bin/env bash
#
# Delete the local kind cluster created by setup.sh.
#
# Usage:
#   ./cluster/teardown.sh
#
# Environment overrides:
#   CLUSTER_NAME   kind cluster name (default: w3w-greeter)

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }

command -v kind >/dev/null 2>&1 || die "'kind' is not installed or not on PATH."

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Deleting kind cluster '$CLUSTER_NAME'."
  kind delete cluster --name "$CLUSTER_NAME"
  log "Done."
else
  log "Cluster '$CLUSTER_NAME' does not exist; nothing to do."
fi
