# Decisions

This is the reasoning behind the submission, not a description of it. The commits
show what was done, task by task. Here I cover why, what I rejected, what I
assumed, and what I would change.

Everything runs locally on a single machine: a multi-node kind cluster, the
image built and side-loaded, the service packaged with Helm, and two
environments deployed with Terraform.

## Tool choices, and what I rejected

**kind, over k3d and minikube.** I needed a multi-node cluster that another
person can reproduce exactly. kind gives that from a single config file, pins the
node image by digest, and `kind load` moves a locally built image onto every
node without a registry. k3d would have been fine too. I avoided minikube here
because multi-node is less of a first-class path and the VM/driver differences
across machines are exactly the kind of "works on mine" risk I wanted to remove.

**Helm, over Kustomize.** Either was acceptable. I picked Helm because Task 4
asks for two environments that differ by a few values, and Helm plus the
Terraform helm provider expresses "same chart, different values" very directly.
Kustomize would have meant a base plus overlays, which is also clean, but the
Helm route let the Terraform module stay a single resource with a handful of
`set` blocks. The chart is written by hand, not `helm create`: only the resources
I can justify are present.

**ingress-nginx, over NodePort or port-forward.** The brief wants the service
reachable from outside the cluster and leaves the method to me. An ingress is the
closest thing to how this would really be exposed, and kind has a documented
pattern for it (host ports 80/443 mapped to a control-plane node labelled
`ingress-ready`). NodePort would have worked with less machinery but is less
representative; port-forward is a debugging tool, not an exposure method.

**Terraform helm provider, over the kubernetes provider.** This follows from
choosing Helm. The kubernetes provider would have meant re-expressing every
manifest as HCL, duplicating what the chart already describes.

## Key technical decisions

**Container image.** Multi-stage build, distroless `static:nonroot` runtime,
CGO disabled. CGO off gives a static binary that runs on a base with no libc,
and as a bonus avoids the macOS `LC_UUID` issue the README warns about. I chose
distroless over scratch because it ships CA certificates, tzdata and a nonroot
user for almost no size cost; the final image is about 13 MB. Over Alpine,
distroless has no shell or package manager, so a smaller attack surface. The
image never contains the build toolchain.

**Probes map directly to the app's documented behaviour.** This is the heart of
the exercise, so the logic is deliberate:

- Liveness and startup probe `/healthz`, which is always 200 while the process
  is alive. A pod that is still warming up is alive and must not be restarted.
  Pointing liveness at `/readyz` would fail throughout the 30s warm-up and
  CrashLoop the pod. That is the main trap in this brief and the config avoids it.
- Readiness probes `/readyz`, which is 503 during warm-up and again the moment
  shutdown begins. This keeps traffic off a pod until it is warm, and pulls it
  out of the Service the instant it starts draining. The readiness period is
  short (3s) so traffic stops quickly on shutdown.

**Graceful shutdown.** The app, on SIGTERM, reports not-ready, keeps serving for
`SHUTDOWN_DELAY_SECONDS` (10), then drains in-flight requests for up to
`DRAIN_TIMEOUT_SECONDS` (20) before exiting. That is up to 30s. I set
`terminationGracePeriodSeconds` to 45 so the kubelet never SIGKILLs the pod
mid-drain, with headroom to spare. The rule I held to:
`terminationGracePeriodSeconds > SHUTDOWN_DELAY + DRAIN_TIMEOUT`.

**Surviving the loss of a single node.** Two things together: at least two
replicas, and a hard topology spread (`DoNotSchedule`, one pod per hostname) so
replicas cannot pile onto the same node. A PodDisruptionBudget with
`minAvailable: 1` protects the service during voluntary disruptions such as a
node drain.

**Two decisions I only got right after seeing them fail** (kept here because the
reasoning matters):

- With a hard spread and only two worker nodes, a rolling update that surges a
  third pod deadlocks: there is nowhere for the extra pod to go. The fix is
  `maxSurge: 0` with `maxUnavailable: 1`, so the rollout frees a node by removing
  an old pod before scheduling the new one.
- A hard spread counts the tainted control-plane node as a zero-pod domain, so
  three replicas across two workers (2-1) is read as skew 2 and the third pod
  stays Pending. `nodeTaintsPolicy: Honor` excludes nodes the pod cannot land on
  from the calculation, and 2-1 becomes valid.

**Config as environment variables from a ConfigMap.** The greeting and the
timing knobs live in a ConfigMap, not the image, so an operator changes them per
environment without a rebuild. A checksum annotation on the pod template rolls
the pods when the ConfigMap changes; without it, a config-only edit would not
restart anything and the new values would never take effect.

**Security context.** Pod runs as nonroot with a numeric UID (65532),
`readOnlyRootFilesystem`, all capabilities dropped, and the RuntimeDefault
seccomp profile. The numeric UID matters: with only the image's named `nonroot`
user, the kubelet cannot verify non-root and refuses to start the pod when
`runAsNonRoot` is true. I hit exactly that and fixed it by setting the UID
explicitly.

**Terraform stays DRY.** One module holds the single `helm_release`. Each
environment passes only what differs (greeting, replicas, version, namespace,
host). Nothing about the deployment is duplicated between dev and prod.

## Decisions I am least sure about

- **Hard spread vs soft.** `DoNotSchedule` guarantees separation but makes
  scheduling brittle on a tiny cluster, as the two failures above show. On a
  larger cluster I would likely use `ScheduleAnyway` plus enough replicas that
  losing a node is statistically fine, trading a hard guarantee for flexibility.
  What would change my mind: cluster size and how strict the availability target
  is. On two nodes, the hard rule is defensible; at scale it is often not worth
  the scheduling pain.
- **No preStop hook.** The app already fails readiness and then sleeps before
  closing its listener, which is the window the cluster needs to stop routing.
  So a `preStop: sleep` would be redundant here. I would add one if the app did
  not self-delay, because endpoint removal and SIGTERM race each other. I left it
  out on purpose rather than by omission.
- **The startup probe is close to redundant.** Because `/healthz` is always 200,
  liveness alone would survive warm-up. I kept the startup probe as cheap
  insurance against a genuinely slow start (for example a slow bind), but I could
  be argued out of it.

## Ambiguities, and the assumptions I made

- **"Reachable from outside the cluster."** I read this as reachable from the
  host running kind, and implemented it as ingress on `http://localhost`. dev and
  prod are separated by host header (`dev.localhost`, `prod.localhost`), both of
  which resolve to loopback.
- **Kubernetes version.** I intended to pin v1.31, but the current kind release
  (v0.33.0) no longer ships a prebuilt v1.31 node image. Using an unofficial
  image would undermine reproducibility, so I pinned v1.34.11, the oldest image
  kind v0.33.0 supports, by digest. The version is a single variable to change.
- **kubeconfig location.** The provider defaults to `~/.kube/config` and context
  `kind-w3w-greeter`, which is what a clean machine gets. On a machine where
  `KUBECONFIG` points elsewhere, pass `-var kubeconfig=$KUBECONFIG`.
- **Replica counts.** dev runs 1 (it does not need to survive node loss); prod
  runs 3. Three on two workers spreads 2-1 and still tolerates losing one node.

## What I would do differently for real production

- **Remote, locked Terraform state** (S3 + DynamoDB or similar) instead of local
  state, so the environments are not tied to one laptop and applies are safe to
  run concurrently.
- **A real registry with digest-pinned images**, instead of `kind load` and a
  floating tag. Deployments should reference an immutable digest.
- **TLS at the ingress**, real hostnames, and cert-manager, rather than plain
  HTTP on localhost.
- **Autoscaling and real resource numbers.** The requests/limits here are guesses
  sized for a laptop; production values come from load testing, with an HPA on a
  meaningful signal.
- **Secrets** in a real store (the app has none today, but a real one would).
- **NetworkPolicies and a dedicated ServiceAccount** with least privilege.
- **Highly available ingress**, not a single controller pinned to the
  control-plane node, which is a local convenience and a single point of failure.

## What I deliberately left out, and why

- **A registry, TLS, secrets, network policies, an HPA, a dedicated
  ServiceAccount.** All are production concerns that would add moving parts
  without demonstrating anything the brief asks for on a local cluster. They are
  listed above as what I would add for production.
- **A generated Helm scaffold.** The brief scores generated boilerplate at zero,
  and rightly. Everything in the chart is there because I put it there.
- **Alertmanager and Grafana (Extension B).** The alert transitioning to firing
  in Prometheus is enough to prove the rule works on a local cluster. Routing a
  page (Alertmanager) and dashboards (Grafana) are what I would add next in a
  real setup; here they would be moving parts without more evidence.

## Extension B (Observability), as built

I deployed a minimal, hand-written Prometheus (`observability/`) rather than a
full stack, since the brief explicitly does not grade the size of the stack.
Prometheus discovers greeter pods by the `prometheus.io/scrape` annotation the
chart sets, scrapes `/metrics`, and evaluates one rule.

The rule is `GreeterHighErrorRate`: the share of requests failing with 5xx over
a 2m window exceeds 5%, held for 1m. I chose this because it tracks a real,
user-visible symptom rather than a proxy like CPU, which is the kind of thing
actually worth a page. The `for: 1m` is short so it demonstrates quickly;
in production I would lengthen the window and tune the threshold to the service's
normal error budget. `observability/demo-alert.sh` drives `/boom`, waits for the
alert to reach `firing`, and prints the evidence.

## Extension D (Prove it survives), as built

The scripts in `survival/` put prod (3 replicas) under continuous load and
capture what happens during a disruption. The evidence is committed under
`survival/evidence/`.

**Rolling update** (`rolling-update.sh`): a rolling restart under load completed
with 739/739 requests succeeding, zero failures. `maxSurge=0/maxUnavailable=1`
means one pod is replaced at a time; readiness gating keeps traffic off a new pod
until it is warm, and graceful shutdown drains the old one. The result is a
zero-downtime rollout.

**Node drain** (`node-drain.sh`): draining a worker under load evicted its two
pods; both were rescheduled onto the surviving worker and all five long-running
in-flight `/work` requests returned 200. Across the whole test, 291/291 requests
succeeded, zero failures.

One thing worth calling out because it refines an earlier decision: I expected
the hard topology spread to leave the evicted pods Pending until the node came
back. It did not. Cordoning a node adds an `unschedulable` taint, and because the
spread uses `nodeTaintsPolicy: Honor`, the cordoned node drops out of the skew
calculation, so the evicted pods legally reschedule onto the remaining worker.
That is a better outcome than I predicted: the service self-heals to full replica
count on one node during the drain, then rebalances 2-1 once the node returns and
the pods are next replaced. The trade-off noted earlier still stands for normal
scheduling, but during a drain the combination behaves well.

## Extensions: the order I would do them, and why

The order is B, then D, then A, then C.

- **B (Observability) first.** It gives visibility into the service's actual
  behaviour, which everything else builds on. It is also self-contained and has a
  clear, gradable outcome: metrics in Prometheus and one alert I would genuinely
  want to be paged on (a sustained rate of 5xx, demonstrated with `/boom`).
- **D (Prove it survives) second, because B makes it measurable.** The core tasks
  claim the service survives node loss and rolls out cleanly. D is where those
  claims are tested rather than asserted: drain a worker and do a rolling update
  under continuous load, and capture what happens to in-flight requests. This is
  the most direct evidence that the important design decisions actually hold, so
  it ranks above tooling.
- **A (CI) third.** A pipeline protects quality over time (go test, build, lint
  the chart, validate Terraform), but on a one-shot local exercise it guards
  future work more than it proves the current design. High value in a real team,
  lower marginal value for demonstrating this system today.
- **C (GitOps) last.** Valuable, but the brief itself warns that repository
  authentication can become a time sink, and the payoff is delivery mechanics
  rather than anything about how the service behaves. Most likely to consume time
  on plumbing for the least evidence about the system, so it comes last.

The principle behind the order: first make behaviour visible (B), then prove the
claims that matter most (D), then protect quality over time (A), then improve how
changes are delivered (C).
