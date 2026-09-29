#!/usr/bin/env bash
#
# Stand up the local GitOps loop:
#   1. deploy gitea (in-cluster git server),
#   2. create an admin user and a public repo,
#   3. push this repository into gitea,
#   4. install Argo CD,
#   5. apply the Argo CD Application that reconciles the greeter from gitea.
#
# After this, editing gitops/values-gitops.yaml and pushing it to gitea changes
# the cluster. See gitops/demo-gitops.sh for that demonstration.
#
# Usage:
#   ./gitops/install.sh
#
# Environment overrides:
#   CLUSTER_NAME       kind cluster name    (default: w3w-greeter)
#   ARGOCD_VERSION     Argo CD release tag  (default: v3.5.3)
#   GITEA_USER         gitea admin user     (default: greeter)
#   GITEA_PASSWORD     gitea admin password (default: greeter123)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONTEXT="kind-${CLUSTER_NAME}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.3}"
GITEA_USER="${GITEA_USER:-greeter}"
GITEA_PASSWORD="${GITEA_PASSWORD:-greeter123}"
GITEA_LOCAL_PORT="3000"

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

kctl() { kubectl --context "$CONTEXT" "$@"; }

command -v kubectl >/dev/null 2>&1 || die "'kubectl' is not on PATH."
command -v git >/dev/null 2>&1 || die "'git' is not on PATH."
kctl cluster-info >/dev/null 2>&1 || die "cannot reach '$CONTEXT'. Run ./cluster/setup.sh first."

PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --- 1. gitea ---------------------------------------------------------------
log "Deploying gitea."
kctl apply -f "${SCRIPT_DIR}/gitea.yaml"
kctl -n gitea rollout status deployment/gitea --timeout=180s

# --- 2. admin user ----------------------------------------------------------
log "Ensuring gitea admin user '${GITEA_USER}' exists."
# The gitea CLI refuses to run as root, but `kubectl exec` runs as root, so run
# it as the git user and point it at the generated config.
kctl -n gitea exec deploy/gitea -- su git -c \
  "gitea --config /data/gitea/conf/app.ini admin user create --username ${GITEA_USER} --password ${GITEA_PASSWORD} --email ${GITEA_USER}@example.com --admin --must-change-password=false" \
  >/dev/null 2>&1 || log "  (user already exists, continuing)"

# --- port-forward gitea for host-side git and API calls ---------------------
log "Port-forwarding gitea to localhost:${GITEA_LOCAL_PORT}."
kctl -n gitea port-forward svc/gitea "${GITEA_LOCAL_PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do
  curl -sf "http://localhost:${GITEA_LOCAL_PORT}/api/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "http://localhost:${GITEA_LOCAL_PORT}/api/healthz" >/dev/null 2>&1 \
  || die "gitea port-forward did not become ready."

# --- 3. repo + push ---------------------------------------------------------
log "Creating public repo '${GITEA_USER}/greeter' (if absent)."
curl -sf -u "${GITEA_USER}:${GITEA_PASSWORD}" \
  -X POST "http://localhost:${GITEA_LOCAL_PORT}/api/v1/user/repos" \
  -H 'Content-Type: application/json' \
  -d '{"name":"greeter","private":false,"auto_init":false}' >/dev/null 2>&1 \
  || log "  (repo already exists, continuing)"

log "Pushing current HEAD to gitea as branch 'main'."
git -C "$REPO_ROOT" push -f \
  "http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:${GITEA_LOCAL_PORT}/${GITEA_USER}/greeter.git" \
  HEAD:main

# --- 4. Argo CD -------------------------------------------------------------
log "Installing Argo CD ${ARGOCD_VERSION}."
kctl create namespace argocd --dry-run=client -o yaml | kctl apply -f -
# Server-side apply: the Argo CD CRDs are too large for the client-side
# last-applied-configuration annotation (256KB limit).
kctl apply --server-side --force-conflicts -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

log "Waiting for Argo CD to be ready (this can take a couple of minutes)."
kctl -n argocd rollout status deployment/argocd-repo-server --timeout=240s
kctl -n argocd rollout status deployment/argocd-server --timeout=240s
kctl -n argocd rollout status statefulset/argocd-application-controller --timeout=240s

# --- 5. Application ---------------------------------------------------------
log "Applying the Argo CD Application."
kctl apply -f "${SCRIPT_DIR}/application.yaml"

log "Waiting for the first sync."
for _ in $(seq 1 60); do
  sync="$(kctl -n argocd get application greeter -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kctl -n argocd get application greeter -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
  sleep 5
done

echo
log "GitOps loop is up. Application status:"
kctl -n argocd get application greeter
echo
cat <<EOF
The greeter is now reconciled from gitea into namespace greeter-gitops.

  curl http://gitops.localhost/

To demonstrate a commit changing the cluster:

  ./gitops/demo-gitops.sh
EOF
