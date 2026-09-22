#!/usr/bin/env bash
#
# Create the local kind cluster for the greeter exercise and wait until it is
# ready to use.
#
# The script is written to be safe to run on a clean macOS machine:
#   - it checks for the tools it needs and gives an actionable message if one
#     is missing, rather than failing halfway through;
#   - it checks that the Docker daemon is actually reachable (easy to forget on
#     macOS with colima or Docker Desktop);
#   - it is idempotent: re-running it leaves the cluster in place unless you
#     pass --recreate;
#   - it avoids GNU-only and bash 4+ features, so it works with the bash 3.2
#     that ships with macOS.
#
# Usage:
#   ./cluster/setup.sh              # create the cluster if it does not exist
#   ./cluster/setup.sh --recreate   # delete and recreate it from scratch
#
# Environment overrides:
#   CLUSTER_NAME   kind cluster name        (default: w3w-greeter)
#   NODE_IMAGE     kindest/node image       (default: the digest pinned in
#                                            kind-config.yaml)

set -euo pipefail

# Resolve the directory this script lives in without relying on `readlink -f`,
# which is not available by default on macOS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONFIG_FILE="${SCRIPT_DIR}/kind-config.yaml"
NODE_READY_TIMEOUT="180s"

RECREATE="false"
if [ "${1:-}" = "--recreate" ]; then
  RECREATE="true"
fi

log()  { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed or not on PATH. $2"
}

# --- Preconditions -----------------------------------------------------------

require_cmd docker  "Install Docker (or start colima) first."
require_cmd kind    "Install it with 'brew install kind' or from https://kind.sigs.k8s.io/."
require_cmd kubectl "Install it with 'brew install kubectl'."

if ! docker info >/dev/null 2>&1; then
  die "cannot talk to the Docker daemon. Start Docker Desktop or run 'colima start', then retry."
fi

[ -f "$CONFIG_FILE" ] || die "cluster config not found at $CONFIG_FILE"

# --- Create (or recreate) the cluster ---------------------------------------

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

if cluster_exists; then
  if [ "$RECREATE" = "true" ]; then
    log "Cluster '$CLUSTER_NAME' exists; deleting it (--recreate)."
    kind delete cluster --name "$CLUSTER_NAME"
  else
    log "Cluster '$CLUSTER_NAME' already exists; leaving it as is (pass --recreate to rebuild)."
  fi
fi

if ! cluster_exists; then
  log "Creating kind cluster '$CLUSTER_NAME' (1 control-plane + 2 workers)."
  if [ -n "${NODE_IMAGE:-}" ]; then
    log "Overriding node image with NODE_IMAGE=$NODE_IMAGE"
    kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_FILE" --image "$NODE_IMAGE"
  else
    kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_FILE"
  fi
fi

# --- Wait until the cluster is actually usable -------------------------------

CONTEXT="kind-${CLUSTER_NAME}"

log "Waiting for all nodes to become Ready (timeout ${NODE_READY_TIMEOUT})."
kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout="$NODE_READY_TIMEOUT"

log "Cluster is ready. Nodes:"
kubectl --context "$CONTEXT" get nodes -o wide

cat <<EOF

Next steps:
  - kubectl config use-context ${CONTEXT}
  - build and load the image, then deploy (see deploy/ and terraform/).

To tear the cluster down again:
  ./cluster/teardown.sh
EOF
