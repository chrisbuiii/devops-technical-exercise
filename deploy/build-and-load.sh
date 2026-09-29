#!/usr/bin/env bash
#
# Build the greeter image and load it into the kind cluster.
#
# kind nodes do not share the host's Docker image store, so an image has to be
# side-loaded with `kind load` before a pod can use it (the chart sets
# imagePullPolicy: IfNotPresent and there is no registry). Run this once before
# `terraform apply`, and again whenever the app or Dockerfile changes.
#
# Usage:
#   ./deploy/build-and-load.sh              # build greeter:dev and load it
#   IMAGE_TAG=1.0.0 ./deploy/build-and-load.sh
#
# Environment overrides:
#   IMAGE_REPO     image repository name   (default: greeter)
#   IMAGE_TAG      image tag               (default: dev)
#   CLUSTER_NAME   kind cluster name       (default: w3w-greeter)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_REPO="${IMAGE_REPO:-greeter}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
CLUSTER_NAME="${CLUSTER_NAME:-w3w-greeter}"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "'docker' is not installed or not on PATH."
command -v kind   >/dev/null 2>&1 || die "'kind' is not installed or not on PATH."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Start Docker/colima and retry."
kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
  || die "kind cluster '$CLUSTER_NAME' not found. Run ./cluster/setup.sh first."

log "Building image ${IMAGE}."
docker build -t "$IMAGE" "$REPO_ROOT"

log "Loading ${IMAGE} into kind cluster '${CLUSTER_NAME}'."
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

log "Done. ${IMAGE} is available to pods on every node."
