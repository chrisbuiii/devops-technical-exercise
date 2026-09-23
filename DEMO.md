# DEMO — running the greeter on Kubernetes from a clean Mac

This is a step-by-step script for a live demo. It assumes a **fresh macOS
machine** with nothing but the source code, and walks through every task and
extension in the order that tells the clearest story.

Every command is copy-pasteable. Timings are rough (first run, cold caches).
Nothing here touches the internet except pulling public images and pinned
manifests.

- Total run time end to end: ~15-20 minutes.
- Everything runs locally in a `kind` cluster. No cloud account needed.

---

## What gets demonstrated, and where

| Step | Task | What it proves |
| --- | --- | --- |
| 1 | Task 1 - Dockerfile | Small, secure, multi-stage image |
| 2 | Task 2 - kind cluster | Reproducible multi-node cluster |
| 3 | Task 3 + 4 - Helm + Terraform | Two environments (dev, prod) deployed from IaC |
| 4 | Verify | The service behaves as the brief describes |
| 5 | Extension B - Observability | Metrics in Prometheus + an alert that fires |
| 6 | Extension D - Survival | Zero-downtime rollout and node drain, with evidence |
| 7 | Extension A - CI | A GitHub Actions pipeline for the service |
| 8 | Extension C - GitOps | A git commit reconciles the cluster via Argo CD |

Read `DECISIONS.md` alongside this for the *why* behind each choice.

---

## Step 0 - Prerequisites (one-time on a clean Mac)

Install the tools. With Homebrew:

```bash
# Container runtime (colima is a lightweight Docker daemon for macOS;
# Docker Desktop works too).
brew install colima docker

# Cluster + Kubernetes tooling.
brew install kind kubectl helm terraform

# git and curl ship with macOS; go is only needed to run the unit tests.
brew install go   # optional
```

Start the Docker daemon:

```bash
colima start            # or launch Docker Desktop
docker info             # should print server info, not an error
```

Then move into the project:

```bash
cd devops-technical-exercise
```

Note on hostnames: the demo uses `dev.localhost`, `prod.localhost`,
`gitops.localhost`. On macOS these all resolve to `127.0.0.1` automatically, so
there is nothing to add to `/etc/hosts`.

---

## Step 1 - Task 1: the container image

Build the image and show what it looks like.

```bash
docker build -t greeter:dev .
docker images greeter:dev
```

Talking points:
- Multi-stage build: a `golang` stage compiles a static binary
  (`CGO_ENABLED=0`), the final stage is `gcr.io/distroless/static-debian12:nonroot`.
- The runtime image is roughly **13 MB** and contains the binary and nothing
  else - no shell, no package manager.
- It runs as a non-root user by default.

Time: ~1-2 min (first build).

---

## Step 2 - Task 2: the kind cluster

Create a reproducible 1 control-plane + 2 worker cluster, then install the
ingress controller that makes the service reachable on `http://localhost`.

```bash
./cluster/setup.sh
./cluster/install-ingress.sh
```

Talking points:
- `setup.sh` checks its prerequisites (docker running, kind, kubectl), is
  idempotent, and works with the bash 3.2 that ships on macOS.
- The node image is pinned by digest in `cluster/kind-config.yaml`, so everyone
  gets byte-for-byte the same Kubernetes version.
- The ingress controller is pinned to a specific release and pinned to the
  control-plane node, which is the one whose ports 80/443 kind maps to the host.

Verify the nodes:

```bash
kubectl get nodes -o wide
```

Time: ~2-4 min.

---

## Step 3 - Task 3 + 4: deploy dev and prod with Terraform

The Helm chart lives in `deploy/greeter`. Terraform (helm provider) deploys it
into two environments that differ in replica count, greeting, version, and host.

First, load the image into the cluster (kind nodes do not share the host's
Docker images, so it is side-loaded):

```bash
./deploy/build-and-load.sh
```

Deploy **dev** (1 replica, greeting "Dev", host `dev.localhost`):

```bash
cd terraform/environments/dev
terraform init
terraform apply -auto-approve
cd ../../..
```

Deploy **prod** (3 replicas, greeting "Prod", host `prod.localhost`):

```bash
cd terraform/environments/prod
terraform init
terraform apply -auto-approve
cd ../../..
```

Talking points:
- One reusable module (`terraform/modules/greeter`), two thin environment
  wrappers - the difference between environments is just input values.
- The chart is hand-written: readiness/liveness/startup probes, a
  PodDisruptionBudget, topology spread across nodes, a locked-down
  securityContext, and a ConfigMap checksum that triggers a rollout when config
  changes.

Note (only if your kubeconfig is not the default): the provider defaults to
`~/.kube/config` and context `kind-w3w-greeter`, which is what a clean Mac gets.
If `KUBECONFIG` points elsewhere, add `-var kubeconfig=$KUBECONFIG` to the apply.

Time: ~2-3 min.

---

## Step 4 - Verify the service behaves as specified

```bash
# The greeting (comes from config, differs per environment):
curl http://dev.localhost/
curl http://prod.localhost/

# Liveness is 200 even during warm-up; readiness is 503 until warm:
curl -i http://prod.localhost/healthz
curl -i http://prod.localhost/readyz

# Build info and Prometheus metrics:
curl http://prod.localhost/version
curl http://prod.localhost/metrics | head

# Pods: dev has 1, prod has 3 spread across the two workers:
kubectl -n greeter-dev  get pods -o wide
kubectl -n greeter-prod get pods -o wide
```

Talking points:
- `/healthz` (liveness) stays 200 through startup so Kubernetes does not kill a
  slow-starting pod; `/readyz` (readiness) gates traffic until warm and flips to
  503 during shutdown so the pod drains cleanly.
- prod's 3 pods sit 2-1 across the two workers, so losing a node keeps serving.

---

## Step 5 - Extension B: observability (metrics + a real alert)

Install a minimal Prometheus, then drive the alert to firing.

```bash
./observability/install.sh
./observability/demo-alert.sh
```

`demo-alert.sh` hammers `/boom` (which always returns 500) and polls Prometheus
until `GreeterHighErrorRate` transitions to **firing**, then prints the evidence.

To look around the UI yourself:

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# browse http://localhost:9090  ->  Status > Targets, and Alerts
```

Talking points:
- Prometheus discovers greeter pods by a `prometheus.io/scrape` annotation the
  chart sets, and scrapes `/metrics`.
- The alert is on a **user-visible symptom** (sustained rate of 5xx), which is
  the kind of thing actually worth being paged for - not CPU.

Time: ~2-3 min (mostly waiting for the alert to fire).

---

## Step 6 - Extension D: prove it survives

Both scripts put **prod** under continuous load and capture what happens. They
print a summary and also write to `survival/evidence/`. (Committed evidence from
a previous run is already in that folder.)

Rolling update under load (expect zero failed requests):

```bash
./survival/rolling-update.sh
```

Drain a worker node under load (expect in-flight requests to finish, pods to
reschedule onto the surviving node):

```bash
./survival/node-drain.sh
```

Talking points:
- `maxSurge=0/maxUnavailable=1` plus readiness gating and graceful shutdown gives
  a zero-downtime rollout.
- On drain, the cordoned node drops out of the topology-spread calculation, so
  the evicted pods legally reschedule onto the surviving worker - the service
  self-heals to full replica count during the drain.

Time: ~2-3 min each.

---

## Step 7 - Extension A: CI pipeline

There is no live GitHub run in this demo (the repo has no remote yet), so show
the workflow and explain what each job guards:

```bash
cat .github/workflows/ci.yml
```

Talking points - it runs on push and PRs to `main` with five jobs:
- `app-test`: `go test ./...` with CGO disabled, matching the image build.
- `chart-lint`: `helm lint` + a `helm template` render check.
- `terraform-validate`: `fmt -check`, `init -backend=false`, and `validate` for
  both dev and prod.
- `shellcheck`: lints every script (they are part of the deliverable).
- `image-build`: multi-arch (amd64 + arm64) Buildx build; pushes to GHCR only on
  `main` and tags.

Every step was verified locally. To show the tests actually pass (optional):

```bash
cd app && go test ./... && cd ..
helm lint deploy/greeter
```

---

## Step 8 - Extension C: GitOps (a commit changes the cluster)

Everything stays inside the cluster - an in-cluster gitea (git server) plus Argo
CD - so there are no external tokens to manage and it runs the same anywhere.

Stand up the loop (deploys gitea, pushes this repo into it, installs Argo CD,
applies the Application):

```bash
./gitops/install.sh
```

When it finishes, the greeter is reconciled from gitea into `greeter-gitops`:

```bash
curl http://gitops.localhost/          # -> Hello GitOps, ...
kubectl -n argocd get application greeter   # -> Synced / Healthy
```

Now prove a commit changes the cluster. This script clones the gitea repo,
changes the greeting, commits and pushes, then waits for Argo CD to reconcile it:

```bash
./gitops/demo-gitops.sh
curl http://gitops.localhost/          # -> Hello GitOps-reconciled, ...
```

Evidence from a previous run is in `gitops/evidence/gitops-sync.log`.

Talking points:
- The Application is **multi-source**: it reuses the exact same
  `deploy/greeter` chart as Terraform, with GitOps-specific values via a
  `$values` ref - no forked chart.
- Sync is automated with self-heal and prune: change git, the cluster follows.

Time: ~3-5 min (Argo CD install is the slow part).

---

## Teardown

```bash
./cluster/teardown.sh     # deletes the kind cluster
colima stop               # if you started colima
```

Terraform state is local; deleting the cluster is enough to reset the demo.

---

## If something goes wrong

- **`cannot talk to the Docker daemon`**: run `colima start` (or open Docker
  Desktop), then `docker info` to confirm.
- **`http://localhost` returns nothing**: the ingress controller may still be
  rolling out - `kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller`.
- **Terraform `context does not exist`**: your `KUBECONFIG` is not the default;
  re-run the apply with `-var kubeconfig=$KUBECONFIG`.
- **A pod is `Pending`**: usually the image was not loaded - re-run
  `./deploy/build-and-load.sh`.
- **Start clean**: `./cluster/setup.sh --recreate` rebuilds the cluster from
  scratch.

---

## The 60-second version (if you are short on time)

```bash
colima start
docker build -t greeter:dev .
./cluster/setup.sh && ./cluster/install-ingress.sh
./deploy/build-and-load.sh
( cd terraform/environments/dev  && terraform init && terraform apply -auto-approve )
( cd terraform/environments/prod && terraform init && terraform apply -auto-approve )
curl http://dev.localhost/ ; curl http://prod.localhost/
```

That gets the service built, the cluster up, and both environments serving.
Extensions B/D/A/C are then each a single script or file to show.
