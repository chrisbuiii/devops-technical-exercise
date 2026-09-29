#!/usr/bin/env bash
#
# Install a minimal Prometheus into the cluster and point it at the greeter
# pods. Prometheus discovers pods that carry the prometheus.io/scrape annotation
# (set by the greeter chart), scrapes /metrics, and evaluates the alert rule in
# prometheus-config.yaml.
#
# Usage:
#   ./observability/install.sh
#
# Environment overrides:
#   CLUSTER_NAME   kind cluster name (default: w3w-greeter)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONTEXT="kind-${CLUSTER_NAME}"

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "'kubectl' is not installed or not on PATH."
kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 \
  || die "cannot reach cluster context '$CONTEXT'. Run ./cluster/setup.sh first."

log "Applying Prometheus manifests."
kubectl --context "$CONTEXT" apply -f "${SCRIPT_DIR}/namespace.yaml"
kubectl --context "$CONTEXT" apply -f "${SCRIPT_DIR}/prometheus-rbac.yaml"
kubectl --context "$CONTEXT" apply -f "${SCRIPT_DIR}/prometheus-config.yaml"
kubectl --context "$CONTEXT" apply -f "${SCRIPT_DIR}/prometheus-deploy.yaml"

# Pick up config/rule changes on re-runs (ConfigMap edits do not restart the pod
# on their own).
log "Restarting Prometheus to pick up any config changes."
kubectl --context "$CONTEXT" -n monitoring rollout restart deployment/prometheus

log "Waiting for Prometheus to be ready (timeout 120s)."
kubectl --context "$CONTEXT" -n monitoring rollout status deployment/prometheus --timeout=120s

cat <<EOF

Prometheus is up. To open the UI:

  kubectl --context ${CONTEXT} -n monitoring port-forward svc/prometheus 9090:9090
  # then browse http://localhost:9090  (Status > Targets, and Alerts)

To demonstrate the alert firing:

  ./observability/demo-alert.sh
EOF
