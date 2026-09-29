#!/usr/bin/env bash
#
# Install ingress-nginx into the kind cluster and wait until it is ready to
# admit Ingress objects.
#
# This is what makes the service reachable from the host: the controller runs on
# the control-plane node (labelled ingress-ready in kind-config.yaml) and binds
# the host ports 80/443 that kind maps in. Curling http://localhost then reaches
# the controller, which routes to the Service by Ingress rule.
#
# Pinned to a specific ingress-nginx release for reproducibility. Uses the
# project's official "kind" provider manifest, which is pre-tuned for kind
# (hostPort, nodeSelector ingress-ready=true, tolerations).
#
# Usage:
#   ./cluster/install-ingress.sh
#
# Environment overrides:
#   INGRESS_NGINX_VERSION   controller release tag (default: controller-v1.14.5)
#   CLUSTER_NAME            kind cluster name       (default: w3w-greeter)

set -euo pipefail

INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.14.5}"
CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
CONTEXT="kind-${CLUSTER_NAME}"
MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "'kubectl' is not installed or not on PATH."

kubectl --context "$CONTEXT" cluster-info >/dev/null 2>&1 \
  || die "cannot reach cluster context '$CONTEXT'. Run ./cluster/setup.sh first."

log "Installing ingress-nginx ${INGRESS_NGINX_VERSION}."
kubectl --context "$CONTEXT" apply -f "$MANIFEST_URL"

# Pin the controller to the control-plane node. That node is the one labelled
# ingress-ready=true and the one whose host ports 80/443 kind maps to the host
# (see kind-config.yaml). The controller binds those ports via hostPort, so it
# must run there; otherwise traffic to http://localhost never reaches it. Some
# manifest revisions ship without this nodeSelector, so we set it explicitly for
# a deterministic result.
log "Pinning the controller to the ingress-ready (control-plane) node."
kubectl --context "$CONTEXT" -n ingress-nginx patch deployment ingress-nginx-controller \
  --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux","ingress-ready":"true"}}}}}'

log "Waiting for the ingress-nginx controller rollout to finish (timeout 180s)."
# rollout status waits for the new pods and ignores ones being torn down, which
# avoids a race with any pod the nodeSelector patch just replaced.
kubectl --context "$CONTEXT" -n ingress-nginx rollout status \
  deployment/ingress-nginx-controller --timeout=180s

log "ingress-nginx is ready. Ingress objects with class 'nginx' will now be served on http://localhost."
