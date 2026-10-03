# Phase 09: Automation and GitOps with Flux CD

This phase removes every manual `helm install` from the platform. You will describe the entire cluster (controllers, configuration, platform services and the todo-app) as manifests in Git, install Flux CD with the Flux Operator, and let it build and maintain the cluster from the repository. At the end, a `docker push` of a new image version is enough to get it deployed, through a commit that Flux writes itself.

**Starting point:** the Phase 08 platform, but on a **clean cluster**. Proving that everything rebuilds from Git is the whole point, and Flux-managed releases should not be mixed with the Helm releases created by hand in Phase 08. On k3s: `/usr/local/bin/k3s-uninstall.sh`, then reinstall.

**What you build in this phase:**

| Artifact | Purpose |
|---|---|
| `clusters/prod/` | The entrypoint Flux syncs: `FluxInstance`, cluster settings and one Flux `Kustomization` per layer |
| `infrastructure/controllers/` | Sealed Secrets, MetalLB, cert-manager, Envoy Gateway and Longhorn as `HelmRelease`s |
| `infrastructure/configs/` | Address pool, CA issuers, Gateway, TLS certificate, CoreDNS entries, CA bundle for Flux |
| `platform-secrets/` | authentik and Harbor credentials as SealedSecrets |
| `platform/` | authentik, Harbor and the Longhorn UI behind forward-auth |
| `apps/` | todo-app `HelmRelease` with the chart pulled from Harbor OCI |
| `image-automation/` | Scans Harbor and commits new image tags and chart versions to Git |
| `scripts/` | Sealing, key backup/restore, validation (plus the Phase 08 Harbor helpers) |
| `.github/workflows/gitops-validate.yaml` | Validates every manifest on pull requests (shared with later GitOps phases) |
| `.sourceignore` | Keeps everything outside `solution/` out of what Flux downloads |

Compare your work with `solution/` when you are done.

---

## How it works

Two inputs feed the system: you push code to the GitHub repository, and developers push container images (e.g. version 1.1.0) to Harbor. Inside the cluster, Flux fetches the repository every minute and reconciles layers in dependency order: infra-controllers first, then infra-configs, then platform-secrets, then platform, and finally apps. Apps pulls its chart and images from Harbor. Meanwhile, the image-automation controller scans Harbor for new tags and, when it finds one, commits the updated tag back to the GitHub repository, closing the loop so that a `docker push` alone triggers a full deployment.

The key idea: **the cluster is a function of the repository**. You never run `helm` or `kubectl apply` against it again: you commit, and Flux converges. Even automated image updates go through Git, so the history of every deployment is `git log`.

---

## Step 1: Prerequisites

```bash
# Kubernetes 1.34 or newer: Flux 2.9 supports 1.34, 1.35 and 1.36
kubectl version

# open-iscsi on every node (Longhorn)
iscsiadm --version

# Tools
helm version
kubeseal --version
docker version

# Flux CLI: optional, but it makes inspecting Flux much easier
curl -s https://fluxcd.io/install.sh | sudo bash
flux --version
```

You also need:

- **A GitHub fine-grained token** for this repository with *Contents: Read and write*. Read access lets Flux fetch the repository; write access lets image automation push commits. One token for both keeps the setup simple. Additional exercise 9 splits it so that only image automation can write.
- **The todo-app images built locally**, as in Phase 08:
  ```bash
  docker build -t frontend:1.0.0 ../../application/frontend
  docker build -t backend:1.0.0 ../../application/backend
  ```
- **Your LAN details**: a free IP range for MetalLB and one IP of that range for the Gateway.

---

## Step 2: Create the repository structure

Everything Flux applies must be pushed to the branch it syncs (`main`). Create this layout under `phases/09-automation-gitops/solution/`:

The `solution/` directory contains: `bootstrap/` with `bootstrap.sh` and `.env.example`; `clusters/prod/` with a `kustomization.yaml`, `cluster-settings.yaml`, a `flux-system/` folder (FluxInstance and Flux Operator self-management), and one Flux Kustomization file per layer (`infrastructure.yaml`, `platform.yaml`, `apps.yaml`, `image-automation.yaml`), plus `clusters/staging/.gitkeep` ready for a second environment; `infrastructure/controllers/` (one folder per component) and `infrastructure/configs/`; `platform-secrets/`; `platform/`; `apps/` with `base/todo-app/`, `prod/` and `staging/.gitkeep`; `image-automation/`; and `scripts/`.

Each component folder follows the same pattern: `namespace.yaml`, `repository.yaml` (where the chart comes from), `release.yaml` (the `HelmRelease`) and a `kustomization.yaml` listing them. The exception are the namespaces that receive a SealedSecret (`authentik`, `harbor`): they live in `platform-secrets/namespaces.yaml` (Step 6).

**Work on your own fork.** Flux syncs the repository in `flux-instance.yaml` (`spec.sync.url`), and image automation pushes commits to its `main` branch. Fork the repository, change that URL to your fork, and create the token for the fork.

**Tell Flux what to ignore.** The repository holds every phase plus the application source code, and Flux only needs `solution/`. A `.sourceignore` file at the repository root (same syntax as `.gitignore`) keeps the rest out of the artifact source-controller builds:

```gitignore
/*
!/phases/
/phases/*
!/phases/09-automation-gitops/
/phases/09-automation-gitops/*
!/phases/09-automation-gitops/solution/
```

Each `!` re-includes one directory level; a changed README or another phase no longer produces a new revision for the cluster.

Copy `bootstrap/.env.example` to `bootstrap/.env` and fill it in. Generate the random values with `openssl rand -hex`: Flux injects them through Helm's `--set` parser, where commas and backslashes are special, so the scripts only accept `A-Z a-z 0-9 . _ ~ -`.

---

## Step 3: Install Flux with the Flux Operator

### 3a: Give Flux access to the repository

This is the only credential created by hand in the whole phase:

```bash
source bootstrap/.env
kubectl create namespace flux-system
kubectl create secret generic flux-system -n flux-system \
  --from-literal=username="$GITHUB_USER" \
  --from-literal=password="$GITHUB_TOKEN"
```

### 3b: Install the operator

```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version 0.60.0 -n flux-system --wait
```

Use the same tag as `clusters/prod/flux-system/flux-operator.yaml`: that `HelmRelease` adopts this release, so from now on the operator upgrades itself through Git. The file is the single source of the version: `bootstrap.sh` reads it from there instead of keeping its own copy. Check the latest version on the [releases page](https://github.com/controlplaneio-fluxcd/flux-operator/releases).

### 3c: Describe Flux with a FluxInstance

**`clusters/prod/flux-system/flux-instance.yaml`**

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.9.5"          # exact release: a rebuild installs the same Flux
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  cluster:
    type: kubernetes
    multitenant: false
    networkPolicy: true
  sync:
    kind: GitRepository
    url: "https://github.com/cberdejo/kubernetes-deployment.git"
    ref: "refs/heads/main"
    path: "phases/09-automation-gitops/solution/clusters/prod"
    pullSecret: "flux-system"
```

A range such as `"2.9.x"` would follow patch releases on its own. Pinning the exact version keeps the rebuild of Step 13 reproducible, and upgrading Flux becomes a one-line commit that CI validates first (`validate.sh` uses the schemas of this exact version).

`sync.path` is the only directory Flux reads directly; everything else is reached from the `kustomization.yaml` there. If you build the layers step by step, start `clusters/prod/kustomization.yaml` with only `flux-system` and `cluster-settings.yaml`, and add each layer file (`infrastructure.yaml`, `platform.yaml`…) in the step that creates it. Listing a file that does not exist yet makes the whole `flux-system` Kustomization fail. Push the structure first, then apply:

```bash
kubectl apply -f clusters/prod/flux-system/flux-instance.yaml
kubectl wait fluxinstance/flux -n flux-system --for=condition=Ready --timeout=10m
```

### 3d: Verify

```bash
kubectl get pods -n flux-system
# Expected: source, kustomize, helm, notification, image-reflector and
#           image-automation controllers Running

flux get sources git
# Expected: flux-system   main@sha1:…   True   stored artifact for revision …

flux get kustomizations
# Expected: flux-system Ready, and the layer Kustomizations appearing
```

---

## Step 4: Layer 1 (infrastructure controllers)

Translate each Phase 08 wrapper chart into a source plus a `HelmRelease`. Here is cert-manager, whose chart is published in an OCI registry:

**`infrastructure/controllers/cert-manager/repository.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 12h
  url: oci://quay.io/jetstack/charts/cert-manager
  ref:
    tag: v1.20.1               # same version as Phase 08
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
```

**`infrastructure/controllers/cert-manager/release.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 30m
  releaseName: cert-manager
  chartRef:
    kind: OCIRepository
    name: cert-manager
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    crds:
      enabled: true
      keep: true
```

Note what changed from `apps/cert-manager/values/prod-values.yaml`: the values are no longer nested under a `cert-manager:` key, because there is no wrapper chart anymore.

Charts published in a classic repository (MetalLB, Longhorn, Sealed Secrets) use a `HelmRepository` and `spec.chart.spec` instead of `chartRef` (see `longhorn/release.yaml`). Two settings deserve attention:

- **`crds: CreateReplace`** on charts that ship CRDs in `crds/` (Envoy Gateway, Longhorn, MetalLB). Plain Helm never upgrades those CRDs.
- **`preUpgradeChecker.jobEnabled: false`** on Longhorn, as in previous phases. Its pre-upgrade Job blocks GitOps upgrades.

Finally, declare the layer in **`clusters/prod/infrastructure.yaml`**:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-controllers
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 2m
  timeout: 15m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./phases/09-automation-gitops/solution/infrastructure/controllers
  prune: true
  wait: true                   # Ready only when every HelmRelease is Ready
```

Commit, push, and watch:

```bash
flux get helmreleases -A --watch
```

---

## Step 5: Layer 2 (infrastructure configs)

These are the custom resources that were templates inside the wrapper charts, now plain manifests that depend on layer 1:

```yaml
# in clusters/prod/infrastructure.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-configs
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-controllers
  # … same fields as above, path: …/infrastructure/configs
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
```

Things to notice in `infrastructure/configs/`:

1. **No more Helm hooks.** In Phase 08, `IPAddressPool` carried `helm.sh/hook: post-install` so it was created after MetalLB's CRDs. `dependsOn` does that job now, so the hooks are gone.

2. **Variables from `cluster-settings`.** Edit `clusters/prod/cluster-settings.yaml` with your range and Gateway IP. Flux substitutes `${METALLB_POOL_RANGE}` and `${GATEWAY_IP}` before applying.

3. **A pinned Gateway IP.** `gateway/envoy-proxy.yaml` asks MetalLB for `${GATEWAY_IP}` through the `metallb.io/loadBalancerIPs` annotation, and the Gateway references it with `spec.infrastructure.parametersRef`. Your `/etc/hosts` entry will not change on a rebuild.

4. **In-cluster DNS for `.local`.** Flux fetches from `harbor.local` *from inside a Pod*. `coredns/coredns-custom.yaml` adds a CoreDNS server block for the four hostnames. Read the comment in that file before changing the zones: a generic `local` zone breaks cluster DNS.

5. **A CA bundle for Flux.** `flux/homelab-ca-bundle.yaml` is a `Certificate` in `flux-system` issued by `homelab-ca`. Its Secret's `ca.crt` key holds the homelab CA certificate, which Flux sources use through `certSecretRef`, without copying the CA private key around. The Secret also carries the leaf `tls.crt`/`tls.key`; the comment in the file explains why that is harmless.

Verify after pushing:

```bash
flux get kustomizations infra-configs
kubectl get certificate -A
# Expected: homelab-ca, gateway-tls and homelab-ca-bundle all True

kubectl get svc -n envoy-gateway
# Expected: the LoadBalancer Service has EXTERNAL-IP = your GATEWAY_IP
```

Point the hostnames at that IP on your machine now. Seeding Harbor in Step 8 runs from your laptop, where the CoreDNS entries do not apply. If Phase 08 used a different IP, replace the old line:

```bash
echo "<GATEWAY_IP>  todo.local longhorn.local authentik.local harbor.local" | sudo tee -a /etc/hosts
```

---

## Step 6: Secrets (seal, commit, back up the key)

### 6a: Back up the Sealed Secrets key first

The controller is running now (layer 1). Before sealing anything, export its private key **outside the repository**:

```bash
./scripts/backup-sealed-secrets-key.sh ~/.homelab/sealed-secrets-key.yaml
```

The script refuses to write inside the Git repository. Store the file somewhere safe (a password manager is fine). Without it, a rebuilt cluster cannot decrypt anything you seal today.

### 6b: Seal the platform credentials

```bash
./scripts/seal-platform-secrets.sh
```

It fetches the controller's public certificate and writes `platform-secrets/authentik-secrets.yaml` and `platform-secrets/harbor-secrets.yaml`, overwriting the ones that came with the repository (those were sealed with the author's key and cannot decrypt in your cluster). Open one: the values are ciphertext, safe to publish in a public repository.

Unlike Phase 04, **nothing is applied**. Commit the files; the commit is the deployment:

```bash
git add platform-secrets/
git commit -m "feat(phase-09): seal platform secrets"
git push
```

`platform-secrets/` has no `kustomization.yaml` on purpose: Flux generates one containing every manifest in the folder, so sealing a new secret never requires editing a resource list.

The folder also holds **`namespaces.yaml`**, with the `authentik` and `harbor` namespaces. A SealedSecret cannot be applied into a namespace that does not exist, and the `platform` layer that installs authentik and Harbor only starts after this one is Ready. If the namespaces lived in `platform/`, a clean cluster would wait forever. Flux applies Namespaces before any other object of the same Kustomization, so one layer is enough.

```bash
flux reconcile kustomization platform-secrets --with-source
kubectl get secret authentik-secrets -n authentik
kubectl get secret harbor-secrets -n harbor
# Expected: both exist, decrypted by the controller
```

---

## Step 7: Layer 3 (platform services)

The authentik and Harbor `HelmRelease`s read their credentials with `valuesFrom`, which replaces the `--set-string` flags of Phase 08:

```yaml
# platform/harbor/release.yaml (excerpt)
spec:
  valuesFrom:
    - kind: Secret
      name: harbor-secrets
      valuesKey: admin_password
      targetPath: harborAdminPassword
    - kind: Secret
      name: harbor-secrets
      valuesKey: secret_key
      targetPath: secretKey
```

The Longhorn UI routes and their `SecurityPolicy` live in `platform/longhorn-ui/`, not with the Longhorn controller: they need authentik, so they belong to the layer that depends on it.

Before this layer finishes, the node must trust the homelab CA so containerd can pull from Harbor later. Run the Phase 08 script (copied into `scripts/`), then restart CoreDNS so it loads the custom ConfigMap:

```bash
sudo -E ./scripts/trust-harbor-ca.sh
kubectl rollout restart deploy/coredns -n kube-system
```

Verify:

```bash
flux get kustomizations platform
flux get helmreleases -n authentik
flux get helmreleases -n harbor

# DNS from inside the cluster
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup harbor.local
# Expected: Address: <GATEWAY_IP>
```

---

## Step 8: Layer 4 (todo-app from Harbor OCI)

### 8a: Seed Harbor

Harbor is installed by Flux, so its first content has to be pushed once by hand, with the same steps as Phase 08. `harbor.local` must resolve to your `GATEWAY_IP` on this machine (see the end of Step 5):

```bash
# Create the public "todo" project (UI or API, see Phase 08 Step 5), then:
./scripts/push-images.sh
./scripts/publish-chart.sh
```

### 8b: The chart source

**`apps/base/todo-app/oci-repository.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: todo-app
  namespace: flux-system
spec:
  interval: 5m
  url: oci://harbor.local/todo/todo-app
  ref:
    tag: "0.1.0"               # pinned; prod overrides it (see 8c)
  certSecretRef:
    name: homelab-ca-bundle    # trust the homelab CA
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
```

### 8c: Base release and prod overlay

`apps/base/todo-app/release.yaml` holds the Phase 08 values that do not depend on the environment. It keeps `releaseName: my-app`, so Service names and your authentik providers stay valid, and it enables `driftDetection`.

`apps/prod/todo-app-values.yaml` is a Kustomize patch with what varies per cluster (the images):

```yaml
frontend:
  image:
    repository: harbor.local/todo/frontend # {"$imagepolicy": "flux-system:todo-frontend:name"}
    tag: "1.0.0" # {"$imagepolicy": "flux-system:todo-frontend:tag"}
```

The chart version is pinned the same way, in `apps/prod/todo-app-chart.yaml`, a patch on the `OCIRepository`:

```yaml
spec:
  ref:
    tag: "0.1.0" # {"$imagepolicy": "flux-system:todo-app-chart:tag"}
```

The comments are **image policy markers**, used in Step 9. Keep them on the same line as the value.

> Why not `semver: ">=0.1.0 <1.0.0"` on the `OCIRepository` directly? It works, and new charts would deploy on their own, but *without a commit*: Git would say `0.1.0`-something while the cluster runs `0.2.0`. Routing chart upgrades through image automation keeps the promise of the phase: every change to the cluster is a commit.

```bash
flux get sources oci -A
# Expected: todo-app   0.1.0@sha256:…   True

flux get helmreleases -n todo
kubectl get pods -n todo
curl -sk https://todo.local -o /dev/null -w "%{http_code}\n"
# Expected: 302 (redirect to authentik)
```

---

## Step 9: Image automation

Three kinds of resources in `image-automation/`, all in `flux-system`:

- **`ImageRepository`**: scans `harbor.local/todo/frontend`, `backend` and the `todo-app` chart every 5 minutes, trusting the CA through `certSecretRef`. A Helm chart in an OCI registry is just another artifact with tags, so the same controller tracks it.
- **`ImagePolicy`**: `semver: ">=1.0.0"` selects the newest stable image tag, ignoring `latest`, SHAs and pre-releases. The chart policy uses `">=0.1.0 <1.0.0"`: a `1.0.0` chart signals breaking changes and deserves a commit written by a human.
- **`ImageUpdateAutomation`**: rewrites the markers under `apps/prod/`, commits and pushes to `main` using the `flux-system` Git credential.

```bash
flux get images all -A
# Expected:
#   imagerepository/todo-frontend  … successful scan: found 1 tags
#   imagepolicy/todo-frontend      … Latest image tag for … resolved to 1.0.0
#   imagepolicy/todo-app-chart     … Latest image tag for … resolved to 0.1.0
```

> If `main` is protected by branch rules that require pull requests, the automation cannot push. Either allow the token to bypass the rule, or set `spec.git.push.branch` to a separate branch (e.g. `flux/image-updates`) and merge its pull requests.

---

## Step 10: Release a new version end to end

This is the payoff of the phase. Change something visible in the frontend (the page title, for instance), then:

```bash
docker build -t frontend:1.1.0 ../../application/frontend
docker tag frontend:1.1.0 harbor.local/todo/frontend:1.1.0
docker push harbor.local/todo/frontend:1.1.0
```

Now do nothing, and watch (or force each step with `flux reconcile …`):

```bash
flux get images all -A --watch          # the policy resolves to 1.1.0
git pull && git log -1                  # a commit by fluxcdbot: 1.0.0 -> 1.1.0
flux get helmreleases -n todo --watch   # upgrade to the new revision
kubectl get pods -n todo -w             # new frontend Pod rolled out
```

**Roll back with Git.** Revert the bot's commit and push:

```bash
git revert --no-edit HEAD && git push
```

Flux redeploys 1.0.0. The image policy still sees 1.1.0 as the latest, though, and will commit it again. To keep 1.0.0, suspend the automation first (`flux suspend image update todo-app`) or delete the bad tag from Harbor: a real-world lesson about how automation and rollbacks interact.

**Release a chart version the same way.** Bump `version` in `application/chart/Chart.yaml` to `0.2.0` (change a default, add a label), then publish it:

```bash
./scripts/publish-chart.sh
flux get images policy todo-app-chart   # resolves to 0.2.0
git pull && git log -1                  # fluxcdbot: 0.1.0 -> 0.2.0 in todo-app-chart.yaml
flux get sources oci todo-app           # 0.2.0@sha256:…
```

---

## Step 11: Experience drift correction

GitOps means manual changes do not survive. Try it:

```bash
# 1. Change an object rendered by the todo-app chart
kubectl scale deploy my-app-todo-app-frontend -n todo --replicas=3
flux reconcile helmrelease todo-app -n todo
kubectl get deploy my-app-todo-app-frontend -n todo
# Expected: back to 1 replica (helm-controller drift detection)

# 2. Delete a plain manifest managed by a Flux Kustomization
kubectl delete httproute longhorn-ui -n longhorn
flux reconcile kustomization platform
kubectl get httproute -n longhorn
# Expected: longhorn-ui recreated (kustomize-controller)

# 3. Emergency changes: suspend, fix, then fix Git and resume
flux suspend helmrelease todo-app -n todo
kubectl scale deploy my-app-todo-app-frontend -n todo --replicas=3   # now it sticks
flux resume helmrelease todo-app -n todo                              # and now it is reverted
```

---

## Step 12: Validate in CI

A broken manifest merged to `main` reaches the cluster within minutes, so validate before merging:

```bash
./scripts/validate.sh
```

It builds every overlay with Kustomize and validates all objects with kubeconform against the Kubernetes schemas, the Flux CRD schemas of the exact version in the `FluxInstance`, and a pinned commit of the community CRD catalog (cert-manager, MetalLB, Gateway API, Envoy Gateway, Flux Operator, Sealed Secrets). A kind without any schema fails the run instead of being skipped. Finally, it checks that every `$imagepolicy` marker names an `ImagePolicy` that exists: a typo there is only a YAML comment, so nothing else would catch it.

Break something on purpose (rename `interval` to `intervall` in a `HelmRelease`, or misspell a marker) and run it again to see the error.

The workflow at `.github/workflows/gitops-validate.yaml` (repository root) runs the same script, plus `shellcheck` on every script, on each pull request that touches a phase solution and on the commits image automation pushes to `main`. It discovers every phase that ships a `solution/scripts/validate.sh`, so later phases reuse it without editing the workflow.

---

## Step 13: The ultimate test, rebuild from scratch

A GitOps platform is only as good as its ability to come back. Destroy the cluster and rebuild it:

```bash
/usr/local/bin/k3s-uninstall.sh
# reinstall k3s, then:
./bootstrap/bootstrap.sh
```

Because the Sealed Secrets key backup is restored before Flux starts, the SealedSecrets already in Git decrypt without re-sealing. Time the rebuild: everything except seeding Harbor and configuring authentik happens without your intervention.

---

## Automated alternative: `bootstrap.sh`

`bootstrap/bootstrap.sh` performs Steps 3–10 in order: Git credential, key restore, Flux Operator, `FluxInstance`, waiting for each layer, sealing (only if the secrets are missing or were sealed with another key), CA trust, seeding Harbor, and verification. Compare it with the Phase 08 script: it contains no `helm upgrade` for any platform component, only the steps GitOps cannot do by itself.

---

## Day-2 cheatsheet

| Task | Command |
|---|---|
| Overall status | `flux get all -A` |
| Layer status | `flux get kustomizations` |
| What a layer manages | `flux tree kustomization infra-controllers` |
| Apply a commit now | `flux reconcile kustomization flux-system --with-source` |
| Retry a failed release | `flux reconcile helmrelease <name> -n <ns> --force` |
| Preview a change before pushing | `flux diff kustomization apps --path ./apps/prod` |
| Errors across controllers | `flux logs --all-namespaces --level=error` |
| Recent events | `flux events -A` |
| Pause / resume reconciliation | `flux suspend …` / `flux resume …` |
| Image automation status | `flux get images all -A` |

---

## Troubleshooting checklist

| Symptom | Likely cause | Fix |
|---|---|---|
| `FluxInstance` not Ready, sync fails with `authentication required` | Wrong or expired token in `flux-system` Secret | Recreate the Secret (Step 3a) |
| `infra-configs` fails with `no matches for kind "IPAddressPool"` | Missing `dependsOn`, or `infra-controllers` not Ready yet | Check `flux get kustomizations`; the retry fixes it once CRDs exist |
| `infra-configs` fails with `variable substitution failed` | `cluster-settings` missing or variable name typo | `kubectl get cm cluster-settings -n flux-system -o yaml` |
| authentik/Harbor HelmRelease: `could not find secret` | SealedSecrets not decrypted | `kubectl get sealedsecret -A`; if status shows *no key could decrypt*, restore the key backup or re-seal (Step 6) |
| `Kustomization` fails with `path not found` after a change | The path is excluded by `.sourceignore` | Keep every manifest under `solution/`, or re-include its directory in `.sourceignore` |
| `OCIRepository todo-app`: `no such host harbor.local` | CoreDNS has not loaded `coredns-custom` | `kubectl rollout restart deploy/coredns -n kube-system` |
| `OCIRepository todo-app`: `x509: certificate signed by unknown authority` | Missing `certSecretRef` or `homelab-ca-bundle` not issued | `kubectl get certificate homelab-ca-bundle -n flux-system` |
| todo-app Pods `ImagePullBackOff` with x509 errors | Node does not trust the homelab CA | Run `scripts/trust-harbor-ca.sh` on every node |
| Gateway Service without `EXTERNAL-IP` | `GATEWAY_IP` outside the MetalLB range | Fix `cluster-settings.yaml` and push |
| Image policy resolves but no commit appears | Token lacks write access, or `main` is protected | `kubectl describe imageupdateautomation todo-app -n flux-system` |
| A layer stays `Reconciliation in progress` | `wait: true` waiting for an unhealthy object | `flux tree kustomization <name>` and inspect the objects that are not Ready |

---

## Additional exercises

1. **Notifications**: create a Discord or Slack webhook, seal it as a Secret in `flux-system`, and add a `Provider` plus an `Alert` (`notification.toolkit.fluxcd.io/v1beta3`) for events of severity `error` from all Kustomizations and HelmReleases. Break a release on purpose and receive the alert.

2. **Renovate**: enable [Renovate](https://docs.renovatebot.com/modules/manager/flux/) on the repository. Its Flux manager detects `HelmRelease`, `HelmRepository` and `OCIRepository` versions and opens pull requests when cert-manager, Longhorn or authentik release new versions, and CI validates them before you merge.

3. **Webhook receiver**: instead of polling GitHub every minute, expose a notification-controller `Receiver` through the Gateway and configure a GitHub webhook, so pushes are applied within seconds. Think about how GitHub can reach a homelab (a tunnel is usually needed).

4. **A staging environment**: the `apps/staging/` and `clusters/staging/` directories are already in place. Add image policies that accept pre-releases (`>=1.0.0-0` for images, `>=0.1.0-0` for the chart) to the staging overlay and a `clusters/staging/` entrypoint with its own `cluster-settings`. Promote a release candidate to staging, then a final version to prod.

5. **A deterministic CA**: the homelab CA is regenerated on every rebuild, forcing you to re-run `trust-harbor-ca.sh`. Generate the CA key pair once, seal it as `homelab-ca-secret`, and drop the self-signed bootstrap issuer. Now the node trust survives rebuilds.

6. **SOPS instead of Sealed Secrets**: encrypt the platform secrets with SOPS and an age key, and configure `spec.decryption` on the `platform-secrets` Kustomization. Compare the review experience of the two approaches in a pull request.

7. **End-to-end CI**: the official example also runs an `e2e.yaml` workflow that creates a [kind](https://kind.sigs.k8s.io/) cluster, installs Flux and waits for every Kustomization to be Ready. Do the same for `infra-controllers` and `infra-configs` with a `clusters/ci/` entrypoint (Longhorn needs open-iscsi, which kind nodes lack: leave it out there). Now a broken chart version fails the pull request, not your cluster.

8. **Progressive delivery**: install [Flagger](https://flagger.app/) and turn the frontend rollout into a canary behind the Gateway: new versions receive a percentage of traffic and are promoted only if metrics stay healthy (combine with Phase 10 once Prometheus is running).

9. **Least-privilege Git access**: source-controller only needs to read the repository, yet the `flux-system` token can also push. `ImageUpdateAutomation` pushes with the credential of the `GitRepository` in its `sourceRef`, so it can have its own. Recreate the `flux-system` Secret with a *Contents: Read-only* token. Then add a second `GitRepository` (`flux-automation`, same URL and branch) to `image-automation/`, whose `secretRef` points to a Secret holding a *Contents: Read and write* token, and point the automation's `sourceRef` at it. Seal that Secret instead of creating it by hand. Now a compromised source-controller cannot write to Git, and revoking the write token stops automation without stopping delivery.


10. **Validate like upstream**: the official example validates with [flux-schema](https://github.com/fluxcd/flux-schema) and also runs `flux migrate -f . --yes` in CI, failing if it changes any file: that catches API versions Flux has deprecated before an upgrade removes them. Add both steps to `gitops-validate.yaml` and compare their errors with the ones `validate.sh` reports.

11. **One artifact per layer**: add `source-watcher` to the `FluxInstance` components and an `ArtifactGenerator` that splits the repository into `infrastructure`, `platform` and `apps` artifacts, then point each Flux `Kustomization` at its `ExternalArtifact`, as the current [flux2-kustomize-helm-example](https://github.com/fluxcd/flux2-kustomize-helm-example) does. Change an app value and check with `flux get kustomizations` that only `apps` reconciles.

---

## Success criteria

- No component was installed with the Helm CLI except the Flux Operator, and even that release is now managed by Flux
- `flux get kustomizations` shows `flux-system`, `infra-controllers`, `infra-configs`, `platform-secrets`, `platform`, `apps` and `image-automation` all Ready
- `flux get helmreleases -A` shows every platform component and the todo-app Ready
- The Gateway Service has the IP defined in `cluster-settings.yaml`
- `harbor.local` resolves from inside a Pod
- Only encrypted SealedSecrets are committed; the Sealed Secrets key backup exists outside the repository
- The todo-app chart is pulled from `oci://harbor.local/todo/todo-app`
- Pushing a new semver image or chart version to Harbor produces a commit by `fluxcdbot` and a rollout, with no manual step
- Manual changes to the cluster are reverted by Flux
- `scripts/validate.sh` passes and runs in CI
- The cluster can be destroyed and rebuilt with `bootstrap.sh`, reusing the SealedSecrets already in Git
