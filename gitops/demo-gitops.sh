#!/usr/bin/env bash
#
# Demonstrate that a commit changes the cluster.
#
# Clones the gitea repo into a temp dir, changes the greeting in
# gitops/values-gitops.yaml, commits and pushes, then forces an Argo CD refresh
# and waits for the running service to serve the new greeting - all without
# touching the cluster directly.
#
# Output is printed and saved to gitops/evidence/gitops-sync.log.
#
# Usage:
#   ./gitops/demo-gitops.sh
#
# Environment overrides:
#   CLUSTER_NAME     kind cluster name    (default: w3w-greeter)
#   TARGET_URL       gitops service URL   (default: http://gitops.localhost)
#   GITEA_USER       gitea user           (default: greeter)
#   GITEA_PASSWORD   gitea password       (default: greeter123)
#   NEW_GREETING     greeting to set      (default: GitOps-reconciled)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONTEXT="kind-${CLUSTER_NAME}"
TARGET_URL="${TARGET_URL:-http://gitops.localhost}"
GITEA_USER="${GITEA_USER:-greeter}"
GITEA_PASSWORD="${GITEA_PASSWORD:-greeter123}"
NEW_GREETING="${NEW_GREETING:-GitOps-reconciled}"
GITEA_LOCAL_PORT="3000"

EVIDENCE_DIR="${SCRIPT_DIR}/evidence"
EVIDENCE_FILE="${EVIDENCE_DIR}/gitops-sync.log"
WORKDIR="$(mktemp -d)"
mkdir -p "$EVIDENCE_DIR"

log() { printf '==> %s\n' "$*"; }

kctl() { kubectl --context "$CONTEXT" "$@"; }

PF_PID=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

main() {
  echo "=== GitOps sync demo: $(date) ==="
  echo "target=${TARGET_URL}  new_greeting=${NEW_GREETING}"
  echo

  log "Greeting before the commit:"
  echo -n "  "; curl -s "${TARGET_URL}/" || true
  echo

  log "Port-forwarding gitea."
  kctl -n gitea port-forward svc/gitea "${GITEA_LOCAL_PORT}:3000" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3

  local repo="http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:${GITEA_LOCAL_PORT}/${GITEA_USER}/greeter.git"

  log "Cloning the gitea repo into a temp dir (keeps the real repo history clean)."
  git clone -q --branch main "$repo" "${WORKDIR}/repo"
  cd "${WORKDIR}/repo"
  git config user.email "demo@example.com"
  git config user.name "GitOps Demo"

  log "Editing gitops/values-gitops.yaml: greetingName -> ${NEW_GREETING}"
  sed "s/^  greetingName:.*/  greetingName: \"${NEW_GREETING}\"/" \
    gitops/values-gitops.yaml > gitops/values-gitops.yaml.tmp
  mv gitops/values-gitops.yaml.tmp gitops/values-gitops.yaml
  git commit -qam "GitOps demo: set greeting to ${NEW_GREETING}"
  git push -q origin main
  log "Pushed commit $(git rev-parse --short HEAD) to gitea."
  echo

  log "Forcing an Argo CD refresh."
  kctl -n argocd annotate application greeter argocd.argoproj.io/refresh=hard --overwrite >/dev/null

  # Wait for Argo CD to sync the new commit into the cluster. The full reconcile
  # is: git commit -> Argo CD sync -> ConfigMap update -> checksum-triggered
  # rolling update. With maxSurge=0 and a warmup delay the two pods are replaced
  # sequentially, so we poll generously (up to 5 minutes).
  log "Waiting for Argo CD to reconcile the new commit (up to 300s)."
  changed=false
  for _ in $(seq 1 60); do
    if curl -s "${TARGET_URL}/" | grep -q "$NEW_GREETING"; then
      changed=true
      break
    fi
    sleep 5
  done

  # Let the rolling update finish so the final snapshot is stable rather than
  # catching a pod mid-rollout.
  log "Waiting for the rollout to settle."
  kctl -n greeter-gitops rollout status deploy/greeter --timeout=120s || true

  echo
  log "Argo CD Application status:"
  kctl -n argocd get application greeter
  echo
  log "Greeting after the commit:"
  after="$(curl -s "${TARGET_URL}/" || true)"
  echo "  ${after}"
  echo

  # Decide success on the settled state, not just the poll window, so a slow
  # (but correct) reconcile is not reported as a failure.
  if printf '%s' "$after" | grep -q "$NEW_GREETING"; then
    log "SUCCESS: a git commit reconciled through Argo CD and changed the cluster."
  elif [ "$changed" = true ]; then
    log "SUCCESS: the new greeting was observed during reconcile (see above)."
  else
    log "Greeting did not change within the timeout; check Argo CD Application status above."
  fi
  echo "=== done ==="
}

main 2>&1 | tee "$EVIDENCE_FILE"
