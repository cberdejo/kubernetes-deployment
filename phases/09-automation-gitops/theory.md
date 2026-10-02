# Phase 09: Automation and GitOps

Every phase so far ended with a `bootstrap.sh` that ran `helm upgrade --install` in a carefully chosen order. That script *is* the platform: it knows which component comes first, which versions to use, and which secrets to pass. It works, but only when you run it, only from your laptop, and only if nobody changed the cluster by hand in the meantime.

This phase replaces the script with **GitOps**. The desired state of the whole cluster lives in Git, and a controller running *inside* the cluster continuously makes reality match it. Deploying becomes a commit. Rolling back becomes a revert. And a cluster that dies can be rebuilt from the repository alone.

**Core concepts to master in this phase:**
- **The GitOps principles**, and why "pull" beats "push" for delivery
- **Reconciliation loops**, drift detection and pruning
- **Flux CD**, its controllers and custom resources
- **The Flux Operator**, a declarative way to install and upgrade Flux itself
- **Layered dependencies**, ordering a platform with `dependsOn` instead of a script
- **Secrets in GitOps**, and the one key you must never lose
- **Image automation**, closing the loop from `docker push` to a running Pod

---

## Why GitOps

Look at what the Phase 08 bootstrap cannot tell you:

- **What is running right now?** Only the cluster knows. If someone ran `kubectl edit` or `helm upgrade --set` last week, the script and the cluster disagree, and nothing reports it.
- **Who changed what, and when?** Shell history on one laptop is not an audit log.
- **How do I undo last Tuesday's change?** `helm rollback` per release, if you remember which ones changed.
- **How do I rebuild after a disk failure?** Run the script and hope the versions it installs today still match what you had.

GitOps answers all four with the same mechanism: the Git history *is* the deployment history, and the cluster continuously converges on the latest commit.

---

## The Four OpenGitOps Principles

The [OpenGitOps](https://opengitops.dev/) project (a CNCF working group) defines GitOps with four principles:

| Principle | Meaning | In this phase |
|---|---|---|
| **Declarative** | The system's desired state is expressed declaratively | Every component is a YAML manifest or a `HelmRelease`, with no imperative `helm` commands |
| **Versioned and immutable** | The desired state is stored in a way that enforces immutability and keeps a complete history | Git commits: every change has an author, a timestamp, a diff and a revert |
| **Pulled automatically** | Software agents pull the desired state from the source | Flux runs in the cluster and fetches the repository; nothing outside pushes into the cluster |
| **Continuously reconciled** | Agents continuously observe actual state and attempt to apply the desired state | Flux re-applies every few minutes and corrects any drift |

---

## Push vs Pull Delivery

Traditional CI/CD **pushes**: a pipeline holds cluster credentials and runs `kubectl apply` or `helm upgrade` against the API server.

In the **push model** (classic CI/CD), a `git push` triggers a CI pipeline that holds cluster-admin credentials and connects directly to the API server to apply changes. In the **pull model** (GitOps), a `git push` updates the Git repository, and Flux, running inside the cluster, fetches the repository with read-only access and applies the desired state to the API server. No external system needs credentials to reach the cluster.

The pull model has three structural advantages:

1. **No cluster credentials leave the cluster.** CI never needs a kubeconfig, so a compromised pipeline cannot deploy arbitrary workloads. In a homelab behind NAT this also means GitHub never needs to reach your network.
2. **Continuous, not one-shot.** A push pipeline applies once and forgets. Flux applies again every interval, so manual changes are reverted instead of silently persisting.
3. **The cluster is self-describing.** Point any cluster at the repository and it converges on the same state, which is exactly what a rebuild is.

---

## The Reconciliation Loop

Every Flux controller runs the same loop, borrowed from Kubernetes itself:

The loop runs on a fixed interval (`.spec.interval`) or immediately when a new Git revision is detected. Each cycle follows the same steps: fetch the desired state from the source (Git, OCI or Helm repository), compare it with the objects currently in the cluster, apply the difference using server-side apply, delete any objects removed from Git (pruning), and wait for health checks before reporting the resource as Ready or Failed. Once health checks finish, the cycle restarts.

Two terms matter:

- **Drift**: any difference between Git and the cluster. Flux corrects drift on plain manifests at every reconciliation. For Helm releases, drift detection is opt-in (`spec.driftDetection.mode: enabled`) and is enabled here for the todo-app.
- **Pruning**: with `prune: true`, deleting a file from Git deletes the object from the cluster. Without it, removed manifests leave orphans behind, and Git stops being the full truth.

---

## Flux Architecture

Flux is not one binary but a set of controllers (the **GitOps Toolkit**), each owning a few custom resources:

| Controller | Custom resources | Job |
|---|---|---|
| **source-controller** | `GitRepository`, `OCIRepository`, `HelmRepository`, `HelmChart`, `Bucket` | Fetches artifacts from external sources and serves them to the other controllers |
| **kustomize-controller** | `Kustomization` | Builds manifests with Kustomize, substitutes variables, applies them, prunes and health-checks |
| **helm-controller** | `HelmRelease` | Installs, upgrades, tests and rolls back Helm charts |
| **notification-controller** | `Provider`, `Alert`, `Receiver` | Sends events to Slack/Discord/GitHub and receives webhooks that trigger reconciliation |
| **image-reflector-controller** | `ImageRepository`, `ImagePolicy` | Scans registries for tags and picks the latest according to a policy |
| **image-automation-controller** | `ImageUpdateAutomation` | Writes the selected tags back to Git and pushes a commit |

The separation matters for debugging: if a `HelmRelease` fails, look at helm-controller; if its chart cannot be fetched, the problem is in the `OCIRepository` or `HelmRepository` status, owned by source-controller.

---

## Installing Flux: Bootstrap vs Flux Operator

There are two supported ways to install Flux:

| | `flux bootstrap` (CLI) | Flux Operator |
|---|---|---|
| **How** | CLI generates `gotk-components.yaml`, commits it to Git and applies it | An operator installed once with Helm; a `FluxInstance` resource describes Flux |
| **Upgrades** | Re-run `flux bootstrap` or commit regenerated manifests | Change `spec.distribution.version` in a commit (a range like `2.9.x` would follow patches automatically) |
| **Configuration** | Kustomize patches on generated YAML | Typed fields: `multitenant`, `networkPolicy`, `size`, `components`… |
| **Self-management** | Flux manages its own manifests | The operator reconciles the `FluxInstance`, which is itself stored in Git |

This phase uses the **Flux Operator**, the method now used by the official Flux examples. The bootstrap script installs the operator and applies `flux-instance.yaml` once; from then on the `FluxInstance` and even the operator's own `HelmRelease` are reconciled from Git. Adding the image automation controllers, for example, was a two-line change in `components`.

Both versions are pinned exactly (Flux `2.9.5` in the `FluxInstance`, operator `0.60.0` in its `HelmRelease`) and each lives in exactly one file. A floating `2.9.x` is convenient, but then two rebuilds a month apart run different software, which is the drift GitOps exists to prevent.

---

## Two Things Called "Kustomization"

A classic source of confusion: there are two unrelated resources with the same name:

| | `kustomize.config.k8s.io/v1beta1` | `kustomize.toolkit.fluxcd.io/v1` |
|---|---|---|
| **What it is** | Kustomize's build file (`kustomization.yaml`) | A Flux custom resource stored in the cluster |
| **Answers** | *Which files* make up this directory, and how to patch them | *Where* to find a directory, *when* to apply it, *after what*, and *how* to verify it |
| **Lives in** | Every directory Kustomize builds | `clusters/prod/*.yaml` |

The Flux `Kustomization` points at a path; Kustomize builds that path using its `kustomization.yaml`. If the path has no `kustomization.yaml`, Flux generates one with every manifest it finds, which is used here for `platform-secrets/`.

---

## HelmRelease: Helm, Operated by a Controller

A `HelmRelease` is a Helm release whose lifecycle is owned by helm-controller instead of your terminal. It adds what the CLI does not do on its own:

- **Remediation**: `install.remediation.retries` and `upgrade.remediation.retries` retry failed operations and roll back automatically after the last failure.
- **CRD lifecycle**: plain Helm installs CRDs from `crds/` once and never upgrades them. `crds: CreateReplace` keeps them current, which matters for Envoy Gateway (Gateway API CRDs) and Longhorn.
- **Values from Secrets**: `valuesFrom` injects keys from a `Secret` or `ConfigMap` at a `targetPath`, so passwords never appear in the `HelmRelease`. This replaces the `--set-string "harbor.harborAdminPassword=${...}"` flags of Phase 08.
- **Drift detection**: compares the live objects with the rendered chart and reverts manual edits.
- **Sources**: the chart comes from a `HelmRepository` (classic `index.yaml`) or an `OCIRepository` (`oci://` registries such as quay.io, Docker Hub or your own Harbor).

### From wrapper charts to HelmReleases

Phases 05–08 used **wrapper charts**: a local chart with the upstream chart as a dependency, plus extra templates (routes, issuers, address pools). With Flux, each wrapper splits into two simpler pieces:

| Phase 08 wrapper | Phase 09 equivalent |
|---|---|
| `Chart.yaml` dependency on the upstream chart | `HelmRepository`/`OCIRepository` + `HelmRelease` with the same pinned version |
| `values/prod-values.yaml` (under the subchart key) | `spec.values` (no subchart prefix) |
| Extra templates (`route.yaml`, `gateway.yaml`, issuers) | Plain manifests applied by a Flux `Kustomization` |
| Helm hooks to order resources (`post-install` on `IPAddressPool`) | Separate layer with `dependsOn` |
| `--set-string` secrets from `.env` | SealedSecret + `valuesFrom` |

The wrapper existed to bundle "chart + extras + order" into one `helm install`. Flux already provides the bundling (Kustomization) and the ordering (`dependsOn`), so the wrapper is no longer needed.

---

## Ordering with `dependsOn`: The Layer Model

Phase 08's bootstrap encoded a dependency graph as the order of shell commands. Here the same graph is data:

The dependency chain has five layers. **infra-controllers** (Sealed Secrets, MetalLB, cert-manager, Envoy Gateway, Longhorn) installs the operators and their CRDs. Two layers depend on it: **infra-configs** (IPAddressPool, ClusterIssuers, Gateway, TLS certificate, CoreDNS, CA bundle: custom resources that need the CRDs above) and **platform-secrets** (SealedSecrets for authentik and Harbor). Once both are ready, **platform** (authentik, Harbor, Longhorn UI behind SSO) can start. Platform in turn gates **apps** (the todo-app, with chart and images pulled from Harbor) and **image-automation** (watches Harbor for new tags and commits them back to Git).

Three settings make the graph reliable:

- **`dependsOn`**: a Kustomization waits until the ones it depends on are Ready.
- **`wait: true`**: a Kustomization is only Ready when every object it applied is healthy (Deployments rolled out, HelmReleases installed, Certificates issued). Without it, "Ready" would only mean "applied".
- **`timeout` and `retryInterval`**: how long to wait for health, and how soon to retry after a failure. Transient failures (a CRD not yet registered, a webhook not yet listening) heal on the next retry instead of failing the whole bootstrap.

Why split controllers and configs? Applying an `IPAddressPool` before MetalLB's CRD exists fails with *no matches for kind*. Kustomize cannot order across CRD registration; `dependsOn` can.

### Variable substitution

Some values are cluster-specific (the MetalLB range, the Gateway IP). Instead of hardcoding them, `infra-configs` uses `postBuild.substituteFrom` with the `cluster-settings` ConfigMap: Flux replaces `${GATEWAY_IP}` in the rendered manifests before applying them. A second cluster would only need its own `cluster-settings`.

---

## Secrets in GitOps

"Everything in Git" collides with "never put secrets in Git". The standard solutions encrypt the secret so the ciphertext can be committed:

| Tool | Where decryption happens | Key management | Trade-off |
|---|---|---|---|
| **Sealed Secrets** | A controller in the cluster | Controller key pair; public key encrypts, private key stays in-cluster | Simple; ciphertext is bound to one cluster's key |
| **SOPS** (+ age or KMS) | kustomize-controller at apply time | age key or cloud KMS | Files stay readable (only values encrypted); native Flux support |
| **External Secrets** | An operator syncing from Vault/OpenBao/1Password | The external secret store | No ciphertext in Git at all; requires running a secret store |

This phase keeps **Sealed Secrets** from Phase 04: the concepts carry over and it needs no extra infrastructure. The difference is the workflow: Phase 04 sealed *and applied*; here the script only seals, and **the commit is the deployment**.

### The key you must never lose

Sealed Secrets generates its key pair on first start. A rebuilt cluster generates a *new* key pair, and every SealedSecret in Git becomes undecryptable. That breaks the central GitOps promise of rebuilding from the repository.

The fix is to treat the private key as the one secret that lives outside Git: back it up (`scripts/backup-sealed-secrets-key.sh`) and restore it *before* the controller starts on a new cluster (`bootstrap.sh` does this automatically). The controller also rotates keys every 30 days while keeping the old ones, so the backup must be refreshed.

---

## Image Automation

So far a new release meant: build, push, edit a tag, run `helm upgrade`. With image automation:

A developer pushes a new image (`docker push harbor.local/todo/frontend:1.1.0`). The **ImageRepository** scans Harbor every five minutes and lists available tags. The **ImagePolicy** applies a semver filter (`>=1.0.0`) and selects `1.1.0` as the latest. The **ImageUpdateAutomation** rewrites the `$imagepolicy` markers in the repository YAML, commits and pushes the change to `main`. From there, Flux's normal reconciliation picks up the new commit and helm-controller upgrades the running release.

The crucial design decision: the automation **does not patch the cluster directly**: it commits to Git, and the normal reconciliation deploys the commit. The deployment history stays in Git, a bad release is undone with `git revert`, and there is still exactly one path into the cluster.

The markers are ordinary YAML comments on the lines to update:

```yaml
tag: "1.0.0" # {"$imagepolicy": "flux-system:todo-frontend:tag"}
```

The chart goes through the same loop. A Helm chart in an OCI registry is just another artifact with tags, so an `ImageRepository` can scan `harbor.local/todo/todo-app` and a marker can sit on the `OCIRepository` tag:

```yaml
ref:
  tag: "0.1.0" # {"$imagepolicy": "flux-system:todo-app-chart:tag"}
```

The shortcut would be a semver range on the `OCIRepository` itself (`semver: ">=0.1.0 <1.0.0"`): new charts deploy just as fast, but Git never learns about it. The repository would still say one version while the cluster runs another, and `git revert` could not undo the upgrade. Automatic is fine; automatic *without a commit* breaks the second OpenGitOps principle.

---

## Trust and DNS: The Homelab Specifics

Two problems appear only because Flux runs *inside* the cluster:

**DNS.** `harbor.local` resolves on your laptop through `/etc/hosts`, but Pods use CoreDNS, which has never heard of it. When source-controller tries to pull `oci://harbor.local/todo/todo-app`, the lookup fails. k3s lets you extend CoreDNS with a `coredns-custom` ConfigMap; the one in `infrastructure/configs/coredns/` maps the `.local` hostnames to the Gateway IP. The zones are the exact hostnames: a generic `local` zone would also capture `*.cluster.local` and break every in-cluster lookup.

**TLS.** Harbor's certificate is signed by the homelab CA, which source-controller does not trust. Flux sources accept a `certSecretRef` with a `ca.crt` key. Rather than copying the CA secret (which contains the CA *private key*) into `flux-system`, a small `Certificate` is issued there by the `homelab-ca` issuer: cert-manager places the issuing CA's public certificate in `ca.crt`, which is exactly what Flux needs. The Secret also holds that leaf certificate's own `tls.crt`/`tls.key`, which Flux would offer as a client certificate, but a TLS client only sends one when the server requests it, and the Gateway never does. Tools like trust-manager can distribute *only* the CA certificate; they are the right answer when many namespaces need a bundle.

The Gateway IP is pinned through an `EnvoyProxy` resource with the `metallb.io/loadBalancerIPs` annotation, so the CoreDNS entries and your `/etc/hosts` stay valid across rebuilds.

---

## What Stays Imperative

GitOps does not remove every manual step, but it reduces them to the few that cannot be declarative by definition:

| Step | Why it cannot live in Git |
|---|---|
| Git credential for Flux | Flux needs it to *read* Git in the first place |
| Sealed Secrets key backup/restore | It is the key that decrypts the secrets in Git |
| Trusting the CA on the node (`registries.yaml`) | Node configuration, outside the Kubernetes API (on Talos it would be part of the machine config) |
| Seeding Harbor with the first images and chart | Harbor is installed by Flux, so it cannot exist before Flux runs |
| authentik providers | Application configuration stored in authentik's database (could be automated with authentik blueprints) |

Knowing this list is part of the design: each item is documented in `bootstrap.sh` and is run once per cluster, not once per change.

---

## Repository Structure

This phase follows the layout of the official [flux2-kustomize-helm-example](https://github.com/fluxcd/flux2-kustomize-helm-example), adapted to a single cluster with more platform layers:

A `.sourceignore` at the repository root narrows what source-controller downloads to `solution/`, so the other phases and the application code never become part of a cluster revision.

The `solution/` directory has six top-level folders. **clusters/prod/** is what Flux syncs: it contains the FluxInstance, cluster settings, and one file per layer. **infrastructure/** splits into **controllers/** (operators and CRDs as HelmReleases) and **configs/** (their custom resources). **platform-secrets/** holds SealedSecrets without a kustomization.yaml. **platform/** contains authentik, Harbor and Longhorn UI. **apps/** splits into **base/** (the environment-independent HelmRelease) and **prod/** (per-cluster values where image tags live). Finally, **image-automation/** holds the ImageRepository, ImagePolicy and ImageUpdateAutomation resources.

The `base/` + `prod/` split looks unnecessary with one cluster, but it is what makes a second environment cheap: a `staging/` overlay with a pre-release image policy and a `clusters/staging/` entrypoint, without touching the base. The empty `staging/` directories are already in place for this.

Larger organisations take this further: separate repositories per team (Flux multi-tenancy) or manifests packaged as signed OCI artifacts that clusters pull without Git access at all (the [Flux D2 reference architecture](https://github.com/controlplaneio-fluxcd/d2-fleet)). A monorepo is the right size for a single-owner platform.

---

## Further Reading

- [OpenGitOps principles](https://opengitops.dev/): the vendor-neutral definition of GitOps
- [Flux documentation](https://fluxcd.io/flux/): concepts, components and guides
- [Flux Operator documentation](https://fluxcd.control-plane.io/operator/): `FluxInstance` reference
- [Ways of structuring your repositories](https://fluxcd.io/flux/guides/repository-structure/): monorepo, repo-per-team, repo-per-app
- [flux2-kustomize-helm-example](https://github.com/fluxcd/flux2-kustomize-helm-example): the reference this phase is based on
- [HelmRelease API](https://fluxcd.io/flux/components/helm/helmreleases/): remediation, drift detection, `valuesFrom`
- [Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/): `dependsOn`, `wait`, `postBuild`
- [Automate image updates to Git](https://fluxcd.io/flux/guides/image-update/): image automation guide
- [Flux security best practices](https://fluxcd.io/flux/security/best-practices/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets): key management and rotation
