# Glossary - Phase 09: Automation and GitOps

### GitOps

An operating model where the desired state of a system is stored declaratively in Git, and an agent running inside the cluster continuously makes reality match it.
Deploying becomes a commit, rolling back becomes a `git revert`, and a lost cluster can be rebuilt from the repository alone.

---

### OpenGitOps Principles

The vendor-neutral definition of GitOps maintained by a CNCF working group: the desired state must be **declarative**, **versioned and immutable**, **pulled automatically**, and **continuously reconciled**.
A setup that deploys from Git but skips any of the four (e.g., a pipeline that pushes once and forgets) is not GitOps in the strict sense.

---

### Push vs Pull Delivery

In the push model, a CI pipeline holds cluster credentials and runs `kubectl apply` or `helm upgrade` against the API server.
In the pull model, an agent inside the cluster fetches the repository with read-only access and applies it, so no cluster credentials ever leave the cluster and GitHub never needs to reach the homelab network.

---

### Reconciliation Loop

The control loop every Flux controller runs: fetch the desired state from a source, compare it with the live objects, apply the difference, prune removed objects, and run health checks.
It runs on a fixed `.spec.interval` or immediately when a new revision is detected, so the cluster keeps converging on Git instead of being updated once.

---

### Drift

Any difference between the state declared in Git and the state running in the cluster, usually caused by a manual `kubectl edit`, `kubectl scale`, or `helm upgrade --set`.
Flux corrects drift on plain manifests at every reconciliation; for Helm releases it must be enabled with `spec.driftDetection.mode: enabled`.

---

### Pruning

The deletion of cluster objects whose manifests were removed from Git, enabled with `prune: true` on a Flux `Kustomization`.
Without pruning, deleted files leave orphaned objects behind and Git stops being the full source of truth.

---

### Server-Side Apply

A Kubernetes apply mode where the API server, not the client, merges the submitted manifest with the live object and tracks which manager owns each field.
Flux applies every manifest this way, which lets it detect drift precisely and coexist with fields set by other controllers.

---

### CustomResourceDefinition (CRD)

A Kubernetes resource that registers a new object kind (e.g., `IPAddressPool`, `ClusterIssuer`, `HelmRelease`) with the API server.
A custom resource can only be applied after its CRD exists; applying it earlier fails with `no matches for kind`, which is why controllers and their configs live in separate layers.

---

### Flux CD

A CNCF-graduated GitOps tool that keeps a Kubernetes cluster in sync with sources such as Git repositories, OCI artifacts, and Helm repositories.
It is not one binary but a set of independent controllers (the GitOps Toolkit), each owning a few custom resources.

---

### GitOps Toolkit

The set of Flux controllers: **source-controller**, **kustomize-controller**, **helm-controller**, **notification-controller**, **image-reflector-controller**, and **image-automation-controller**.
Knowing which controller owns which resource is the first step when debugging: a failing `HelmRelease` points to helm-controller, an unfetchable chart points to source-controller.

---

### source-controller

The Flux controller that fetches artifacts from external sources (`GitRepository`, `OCIRepository`, `HelmRepository`, `HelmChart`, `Bucket`) and serves them to the other controllers.
Its status shows the fetched revision (e.g., `main@sha1:…`) and is where authentication, DNS, and TLS errors with a source appear.

---

### kustomize-controller

The Flux controller that reconciles `Kustomization` resources: it builds a directory with Kustomize, substitutes variables, applies the result, prunes, and runs health checks.

---

### helm-controller

The Flux controller that reconciles `HelmRelease` resources: it installs, upgrades, tests, and rolls back Helm charts, and reverts drift on the rendered objects when drift detection is enabled.

---

### notification-controller

The Flux controller that sends reconciliation events to external systems (Slack, Discord, GitHub commit statuses) through `Provider` and `Alert` resources.
It also exposes `Receiver` webhooks, so a Git push can trigger an immediate reconciliation instead of waiting for the next interval.

---

### Flux Operator

A Kubernetes operator that installs, configures, and upgrades Flux declaratively from a `FluxInstance` resource.
It is installed once with Helm; afterwards both the `FluxInstance` and the operator's own `HelmRelease` live in Git, so Flux upgrades itself through commits.

---

### FluxInstance

The Flux Operator custom resource that describes a Flux installation: the distribution version, the enabled components, cluster options (`multitenant`, `networkPolicy`), and the `sync` source and path.
Upgrading Flux is a one-line change to `spec.distribution.version`; pinning an exact version keeps rebuilds reproducible.

---

### `flux bootstrap`

The Flux CLI command that generates the Flux manifests (`gotk-components.yaml`), commits them to Git, and applies them to the cluster.
It is the alternative to the Flux Operator; upgrades require re-running the command or committing regenerated manifests.

---

### Flux CLI (`flux`)

An optional command-line tool for inspecting and driving Flux: `flux get`, `flux tree`, `flux reconcile`, `flux diff`, `flux logs`, `flux events`, `flux suspend`, and `flux resume`.
Everything it does can also be done with `kubectl`, but it presents Flux resources and their status far more readably.

---

### GitRepository

A Flux source that clones a Git repository at a branch, tag, or commit and stores the selected files as an artifact for the other controllers.
Authentication comes from a Secret (here a GitHub username and token), the only credential created by hand in this phase.

---

### OCIRepository

A Flux source that pulls an artifact from an OCI registry, such as a Helm chart pushed to Harbor (`oci://harbor.local/todo/todo-app`).
It can reference a fixed tag, a digest, or a semver range, and accepts a `certSecretRef` to trust a private CA.

---

### HelmRepository

A Flux source pointing to a classic Helm chart repository served over HTTP(S) with an `index.yaml`.
Charts published to OCI registries are fetched with an `OCIRepository` instead.

---

### `.sourceignore`

A file at the repository root, using `.gitignore` syntax, that tells source-controller which paths to exclude from the artifact it builds.
Here it narrows the artifact to `solution/`, so other phases and application code never become part of a cluster revision.

---

### Kustomize

A Kubernetes-native tool, built into `kubectl`, that assembles and patches plain manifests without templating, driven by a `kustomization.yaml` file in each directory.
It answers *which files* make up a directory and how to transform them.

---

### Kustomization (Flux)

A Flux custom resource (`kustomize.toolkit.fluxcd.io/v1`) that tells kustomize-controller *where* a directory is, *when* to apply it, *after what*, and *how* to verify it.
It is unrelated to Kustomize's `kustomization.yaml` despite the shared name; if the target path has no `kustomization.yaml`, Flux generates one with every manifest it finds.

---

### HelmRelease

A Flux custom resource that describes a Helm release whose lifecycle is owned by helm-controller instead of a terminal.
On top of plain Helm it adds automatic remediation, CRD upgrades, values from Secrets, and drift detection.

---

### Remediation (HelmRelease)

The `install.remediation` and `upgrade.remediation` settings of a `HelmRelease` that retry failed operations a given number of times and roll back after the last failure.
It replaces the manual `helm rollback` of earlier phases.

---

### `valuesFrom`

A `HelmRelease` field that injects keys from a `Secret` or `ConfigMap` into the chart values at a given `targetPath`.
Passwords therefore never appear in the `HelmRelease` itself, replacing the `--set-string` flags read from `.env` in Phase 08.

---

### CRD Lifecycle (`crds: CreateReplace`)

A `HelmRelease` policy that creates and upgrades the CRDs shipped in a chart's `crds/` directory.
Plain Helm installs those CRDs once and never upgrades them, which leaves charts like Envoy Gateway or Longhorn with outdated CRDs after an upgrade.

---

### Wrapper Chart

A local Helm chart that declares an upstream chart as a dependency and adds extra templates (routes, issuers, address pools), used in Phases 05 to 08.
With Flux, each wrapper splits into a source plus a `HelmRelease` for the upstream chart and plain manifests applied by a `Kustomization`.

---

### `dependsOn`

A field on Flux `Kustomization` and `HelmRelease` resources listing other resources that must be Ready before this one is reconciled.
It turns the command order of a bootstrap script into a dependency graph stored in Git (controllers → configs and secrets → platform → apps).

---

### Layer (GitOps)

A group of resources reconciled by one Flux `Kustomization` and ordered against the others with `dependsOn`.
This phase uses `infra-controllers`, `infra-configs`, `platform-secrets`, `platform`, `apps`, and `image-automation`.

---

### `wait` / `timeout` / `retryInterval`

`Kustomization` health settings: `wait: true` marks a layer Ready only when every applied object is healthy, `timeout` limits how long to wait, and `retryInterval` sets how soon to retry after a failure.
Together they let transient errors, such as a webhook not yet listening, heal on the next retry instead of breaking the bootstrap.

---

### Suspend / Resume

Flux operations (`flux suspend`, `flux resume`) that pause and restart reconciliation of a resource by setting `spec.suspend`.
They are the escape hatch for emergency manual changes: suspend, fix by hand, commit the fix to Git, then resume.

---

### Variable Substitution (`postBuild.substituteFrom`)

A Flux `Kustomization` feature that replaces `${VAR}` placeholders in the rendered manifests with values from a `ConfigMap` or `Secret` before applying them.
Cluster-specific values (MetalLB range, Gateway IP) live in a `cluster-settings` ConfigMap, so a second cluster only needs its own copy.

---

### Base and Overlay

A Kustomize layout where `base/` holds environment-independent manifests and each overlay (`prod/`, `staging/`) patches them with per-environment values.
With a single cluster it looks redundant, but it makes adding a second environment a matter of a new overlay and cluster entrypoint.

---

### Sealed Secrets Key Backup

A copy of the Sealed Secrets controller's private key, stored outside Git and restored before the controller starts on a new cluster.
Without it, a rebuilt cluster generates a new key pair and every SealedSecret in Git becomes undecryptable. The controller rotates keys every 30 days, so the backup must be refreshed.

---

### SOPS (Secrets OPerationS)

A tool that encrypts only the values of YAML or JSON files with age, PGP, or a cloud KMS, leaving keys readable in diffs.
Flux's kustomize-controller can decrypt SOPS files natively at apply time, making it the main alternative to Sealed Secrets for GitOps.

---

### Image Automation

The Flux feature that detects new image tags in a registry and commits the updated tags to Git, closing the loop from `docker push` to a running Pod.
It never patches the cluster directly: the commit is deployed by the normal reconciliation, so deployment history stays in `git log`.

---

### ImageRepository

A Flux resource, handled by image-reflector-controller, that periodically scans a registry repository and records its available tags.
It works for container images and for Helm charts stored as OCI artifacts.

---

### ImagePolicy

A Flux resource that selects the latest tag from an `ImageRepository` according to a rule, such as a semver range (`>=1.0.0`), alphabetical, or numerical ordering.

---

### ImageUpdateAutomation

A Flux resource, handled by image-automation-controller, that rewrites the `$imagepolicy` markers in the repository with the tags selected by each `ImagePolicy`, then commits and pushes the change.
It needs a Git token with write access to the target branch.

---

### `$imagepolicy` Marker

A YAML comment placed on a line that image automation should update, naming the `ImagePolicy` to use (e.g., `tag: "1.0.0" # {"$imagepolicy": "flux-system:todo-frontend:tag"}`).
A misspelled marker is just a comment and fails silently, which is why `validate.sh` checks every marker against existing policies.

---

### `coredns-custom` (k3s)

A ConfigMap in `kube-system` that k3s's CoreDNS loads to extend its configuration without replacing the default Corefile.
Here it maps `.local` hostnames like `harbor.local` to the Gateway IP, so in-cluster clients such as source-controller can resolve them.

---

### `certSecretRef`

A field on Flux sources that references a Secret whose `ca.crt` key contains a CA certificate to trust when connecting to the source.
It lets source-controller pull charts from Harbor, whose certificate is signed by the homelab CA.

---

### kubeconform

A fast Kubernetes manifest validator that checks objects against JSON schemas, including schemas for custom resources.
`validate.sh` runs it in CI over every Kustomize build, so a broken manifest is caught before it is merged and reaches the cluster.
