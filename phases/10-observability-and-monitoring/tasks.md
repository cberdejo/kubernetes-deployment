# Phase 10: Observability and Monitoring

This phase gives the platform eyes. You will add Prometheus, Alertmanager and Grafana (kube-prometheus-stack), Loki for logs and Alloy to collect them, make every platform component expose its metrics, and instrument the todo-app backend with its own metrics and structured logs. Grafana is the single entry point, with login through authentik. Everything arrives the Phase 09 way: as commits that Flux reconciles.

**Starting point:** a **clean cluster**, as in Phase 09. Phase 10 is the Phase 09 platform plus the observability stack, so a single `bootstrap.sh` builds all of it, and Flux reconciles it from `phases/10-observability-and-monitoring/solution/` from the first minute. Upgrading a running Phase 09 cluster in place, without a reinstall, is additional exercise 12.

**What you build in this phase:**

| Artifact | Purpose |
|---|---|
| `infrastructure/controllers/prometheus-operator-crds/` | `ServiceMonitor`, `PodMonitor`, `PrometheusRule`… CRDs in the first layer, so every chart can ship its own monitor |
| `infrastructure/controllers/{cert-manager,longhorn}/release.yaml` | Metrics and `ServiceMonitor`s enabled |
| `infrastructure/configs/flux/monitors.yaml`, `gateway/pod-monitor.yaml` | Scrape targets for Flux and the Envoy proxies |
| `infrastructure/configs/{gateway/certificate,coredns/coredns-custom}.yaml` | `grafana.local` added |
| `platform-secrets/namespaces.yaml` | The `monitoring` namespace, next to `authentik` and `harbor` |
| `platform-secrets/grafana-oidc-*.yaml` | The Grafana ↔ authentik OIDC client secret, sealed for both namespaces |
| `monitoring/kube-prometheus-stack/` | Prometheus, Alertmanager, Grafana (route, CA bundle, OIDC login) and the dashboards as `.json` files |
| `monitoring/loki/`, `monitoring/alloy/` | Log storage and log collection |
| `monitoring/kustomization.yaml`, `clusters/prod/monitoring.yaml` | The new `monitoring` layer: its own Flux `Kustomization`, next to `platform` |
| `platform/authentik/` | Metrics, plus a blueprint that declares the Grafana OIDC provider |
| `platform/harbor/release.yaml` | Metrics enabled |
| `apps/` | Chart `0.2.0` and images `1.1.0`, with the backend `ServiceMonitor` enabled |
| `application/backend/` | `prom-client` metrics on `/metrics`, a JSON access log, no more password in the logs |
| `application/chart/` | Chart `0.2.0`: named Service port and an optional `ServiceMonitor` |
| `.github/workflows/app-validate.yaml` | CI for the backend build and the chart |
| `bootstrap/`, `scripts/` | New secret in `.env`, sealing, bootstrap and validation updated |

Steps 1–3 bring the platform up. Steps 4–12 then walk through every change on top of Phase 09, file by file, and show how to check each piece on the running cluster. Steps 13–14 put it to work, and Step 15 validates it in CI. To list every change at once:

```bash
diff -r ../../09-automation-gitops/solution . --exclude=.env
```

Unless a command says otherwise, run it from `phases/10-observability-and-monitoring/solution/`.

---

## How it works

Every component publishes its current numbers on an HTTP `/metrics` endpoint. The Prometheus Operator reads `ServiceMonitor` and `PodMonitor` objects, which each chart ships next to its Deployment, and tells Prometheus what to scrape. Prometheus pulls those endpoints every 30 seconds, stores the samples on a Longhorn volume and evaluates the alerting rules, sending firing alerts to Alertmanager.

In parallel, one Alloy Pod per node follows the logs of every container on that node through the Kubernetes API and pushes them to Loki, which indexes only a few labels (namespace, pod, container, app, node) and stores the lines.

Grafana reads from Prometheus, Alertmanager and Loki, loads its dashboards from ConfigMaps generated from Git, and logs users in through authentik with OIDC. Prometheus and Alertmanager are not exposed; Grafana at `https://grafana.local` is the only door.

The CRDs go into `infra-controllers`, the Flux and Envoy monitors into `infra-configs`, and the OIDC secret and the `monitoring` namespace into `platform-secrets`. The observability stack itself gets **one new layer**, `monitoring`, which runs next to `platform`: `apps` and `image-automation` do not wait for it, so a broken Grafana never blocks a release. `theory.md` explains why it can live neither in `infrastructure/` nor in `platform/`.

---

## Step 1: Prerequisites

```bash
# A clean k3s cluster (Kubernetes >= 1.34) with open-iscsi on every node.
# If an earlier phase is still running: /usr/local/bin/k3s-uninstall.sh, then reinstall.
kubectl get nodes

# Your Sealed Secrets key backup (Phase 09, Step 6a). bootstrap.sh restores it,
# so the SealedSecrets you sealed for your cluster keep decrypting.
ls -l ~/.homelab/sealed-secrets-key.yaml

# Node.js 20 (optional): build the backend locally before building its image
node --version
```

**Capacity.** The observability stack is the largest workload added so far. Plan for roughly **3–4 GiB of memory** on top of Phase 09 (Prometheus up to 2 Gi, Grafana and Loki up to 1 Gi each, the rest a few hundred Mi) and **15 Gi more of Longhorn space** (10 Gi Prometheus, 5 Gi Loki):

```bash
free -h
df -h /var/lib/longhorn
```

---

## Step 2: Prepare the repository

**Your fork, Phase 10 paths.** As in Phase 09, Flux syncs your fork (`spec.sync.url` in `clusters/prod/flux-system/flux-instance.yaml`) and image automation pushes to its `main` branch. Every Flux path points at this phase: `spec.sync.path` in the `FluxInstance`, the layer `Kustomization`s in `clusters/prod/` and `update.path` in `image-automation/image-update-automation.yaml`.

`.sourceignore` (repository root) lets only this phase into the artifact Flux downloads:

```gitignore
/*
!/phases/
/phases/*
!/phases/10-observability-and-monitoring/
/phases/10-observability-and-monitoring/*
!/phases/10-observability-and-monitoring/solution/
```

Push all of it to `main` before bootstrapping: Flux only sees what is on that branch.

**Credentials.** Start from your Phase 09 `.env` and add the two values this phase needs (see `.env.example`):

```bash
cp ../../09-automation-gitops/solution/bootstrap/.env bootstrap/.env
sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=1.1.0/' bootstrap/.env
echo "GRAFANA_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)" >> bootstrap/.env
```

**Images.** Backend `1.1.0` brings the metrics endpoint (Step 11). The frontend is unchanged, but `push-images.sh` pushes both images with the same `IMAGE_TAG`:

```bash
docker build -t backend:1.1.0 ../../../application/backend
docker build -t frontend:1.1.0 ../../../application/frontend
```

**Hostnames.** Add `grafana.local` to the Gateway line of `/etc/hosts`:

```
<GATEWAY_IP>  todo.local longhorn.local authentik.local harbor.local grafana.local
```

Always open the homelab sites with `https://`. The Gateway also answers on port 80, but authentik and Grafana mark their cookies `Secure`, so over `http://` the browser drops them and every login or save fails.

---

## Step 3: Bootstrap

```bash
./bootstrap/bootstrap.sh
```

It is the Phase 09 script with a few additions:

| File | Change |
|---|---|
| `.env.example` | `IMAGE_TAG=1.1.0`; new `GRAFANA_OIDC_CLIENT_SECRET` |
| `bootstrap.sh` | `PLATFORM_SECRETS` also waits for `authentik/grafana-oidc` and `monitoring/grafana-oidc`; `grafana.local` in the `/etc/hosts` hint; a final wait for the `monitoring` layer; Grafana listed in the final summary |

The `grafana-oidc` SealedSecrets do not exist in your fork yet (or were sealed with someone else's key), so the script seals them, together with the authentik and Harbor credentials, and stops until you commit and push `platform-secrets/`. The rest runs on its own. The new `monitoring` layer comes up in parallel with `platform` (Prometheus and Loki volumes, Grafana startup), and the script waits for it last.

```bash
kubectl get kustomizations -n flux-system   # every layer Ready, monitoring included
flux get helmreleases -A                    # includes prometheus-operator-crds, kube-prometheus-stack, loki and alloy
```

Open `https://grafana.local` and click **Sign in with authentik**. As `akadmin` you land as **Admin**: the OIDC provider came from a blueprint in Git, so there was nothing to click in authentik. The rest of the phase explains how each piece got there.

---

## Step 4: The namespaces live in `platform-secrets`

Phase 09 already declares `authentik` and `harbor` in `platform-secrets/namespaces.yaml`: a namespace belongs to the earliest layer that writes into it, and their SealedSecrets are applied by `platform-secrets`, before `platform` exists. The `monitoring` namespace receives a SealedSecret too (`grafana-oidc`), so it joins them (see *Namespaces in `platform-secrets`* in `theory.md`).

**`platform-secrets/namespaces.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: authentik
  labels:
    expose-via-gateway: "true"
---
apiVersion: v1
kind: Namespace
metadata:
  name: harbor
  labels:
    expose-via-gateway: "true"
---
# node-exporter needs the host network, PID namespace and filesystem.
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    expose-via-gateway: "true"
```

`platform-secrets/` has no `kustomization.yaml`, so Flux picks up every manifest in the folder on its own.

Check who owns the namespaces:

```bash
kubectl get ns authentik harbor monitoring -L kustomize.toolkit.fluxcd.io/name
# Expected: platform-secrets for all three
```

Early versions of Phase 09 declared `authentik` and `harbor` in `platform/`. Moving them on a running cluster needs care, because that layer has `prune: true` and deleting either namespace deletes the databases and the registry with it. Additional exercise 12 covers it.

---

## Step 5: Prometheus Operator CRDs (layer 1)

kube-prometheus-stack arrives in the monitoring layer, but cert-manager and Longhorn are in layer 1 and should ship their own `ServiceMonitor`s. Install only the CRDs, before everything else.

**`infrastructure/controllers/prometheus-operator-crds/repository.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: prometheus-operator-crds
  namespace: kube-system
spec:
  interval: 12h
  url: oci://ghcr.io/prometheus-community/charts/prometheus-operator-crds
  ref:
    # Same Prometheus Operator version as kube-prometheus-stack (their appVersion)
    tag: 32.0.1
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
```

**`infrastructure/controllers/prometheus-operator-crds/release.yaml`**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: prometheus-operator-crds
  namespace: kube-system
spec:
  interval: 30m
  releaseName: prometheus-operator-crds
  chartRef:
    kind: OCIRepository
    name: prometheus-operator-crds
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    crds:
      annotations:
        helm.sh/resource-policy: keep   # removing the release never deletes the CRDs
```

Without that annotation, deleting this `HelmRelease` (or the folder, with `prune: true`) would make Helm delete the CRDs, and Kubernetes would delete every `ServiceMonitor`, `PrometheusRule` and the `Prometheus` server object with them. It is the same protection as `crds.keep` on cert-manager.

The folder has the usual `kustomization.yaml`, and `prometheus-operator-crds` comes first in `infrastructure/controllers/kustomization.yaml`.

cert-manager and Longhorn enable their monitors. Both releases live in the same Flux `Kustomization` as the CRDs, so they are ordered with the **HelmRelease-level** `dependsOn`:

```yaml
# infrastructure/controllers/cert-manager/release.yaml (excerpt)
spec:
  dependsOn:
    - name: prometheus-operator-crds
      namespace: kube-system
  values:
    prometheus:
      enabled: true
      servicemonitor:
        enabled: true
```

```yaml
# infrastructure/controllers/longhorn/release.yaml (excerpt)
spec:
  dependsOn:
    - name: prometheus-operator-crds
      namespace: kube-system
  values:
    metrics:
      serviceMonitor:
        enabled: true
```

Verify:

```bash
flux get helmreleases -A
kubectl get crd | grep monitoring.coreos.com
# Expected: alertmanagers, podmonitors, probes, prometheuses, prometheusrules,
#           scrapeconfigs, servicemonitors, thanosrulers…
kubectl get servicemonitor -A
# Expected: cert-manager and longhorn among them
```

---

## Step 6: The monitoring layer and kube-prometheus-stack

The observability stack has its own layer. **`clusters/prod/monitoring.yaml`**:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: monitoring
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-configs      # Gateway, homelab CA issuer, Longhorn StorageClass
    - name: platform-secrets   # grafana-oidc client secret + monitoring namespace
  interval: 1h
  retryInterval: 2m
  timeout: 20m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./phases/10-observability-and-monitoring/solution/monitoring
  prune: true
  wait: true
```

It is listed in `clusters/prod/kustomization.yaml`, and **nothing depends on it**: `apps` and `image-automation` still depend on `platform` only. `monitoring/kustomization.yaml` lists the three components (`kube-prometheus-stack`, `loki`, `alloy`), and `monitoring/kube-prometheus-stack/` follows the usual pattern. The `monitoring` namespace comes from `platform-secrets` (Step 4).

**`monitoring/kube-prometheus-stack/repository.yaml`**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  interval: 12h
  url: oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack
  ref:
    tag: 91.8.2
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
```

**`monitoring/kube-prometheus-stack/release.yaml`**, without the Grafana login and Loki parts (Steps 8 and 10):

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  interval: 30m
  releaseName: kube-prometheus-stack
  timeout: 15m
  chartRef:
    kind: OCIRepository
    name: kube-prometheus-stack
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    fullnameOverride: kube-prometheus-stack
    crds:
      enabled: false                 # installed in layer 1 (Step 5)

    # k3s embeds these in the k3s process, without metrics endpoints
    kubeControllerManager: { enabled: false }
    kubeScheduler: { enabled: false }
    kubeProxy: { enabled: false }
    kubeEtcd: { enabled: false }
    defaultRules:
      rules:
        etcd: false
        kubeControllerManager: false
        kubeProxy: false
        kubeSchedulerAlerting: false
        kubeSchedulerRecording: false
        windows: false
    windowsMonitoring:
      enabled: false

    prometheusOperator:
      admissionWebhooks:
        certManager:
          enabled: true              # webhook certificates from cert-manager

    prometheus:
      prometheusSpec:
        # Load every monitor and rule, not only those labelled release=<this release>
        serviceMonitorSelectorNilUsesHelmValues: false
        podMonitorSelectorNilUsesHelmValues: false
        ruleSelectorNilUsesHelmValues: false
        probeSelectorNilUsesHelmValues: false
        scrapeConfigSelectorNilUsesHelmValues: false
        retention: 10d
        retentionSize: 8GB           # below the 10 Gi volume on purpose
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: longhorn
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 10Gi
        resources:
          requests: { cpu: 200m, memory: 1Gi }
          limits: { memory: 2Gi }

    alertmanager:
      alertmanagerSpec:
        resources:
          requests: { cpu: 10m, memory: 64Mi }
          limits: { memory: 256Mi }

    grafana:
      persistence:
        enabled: false               # everything comes from Git (Steps 8, 10, 12)
      adminUser: admin
      grafana.ini:
        server:
          root_url: https://grafana.local
      sidecar:
        dashboards:
          folderAnnotation: grafana_folder
          provider:
            foldersFromFilesStructure: true
      resources:
        requests: { cpu: 100m, memory: 256Mi }
        limits: { memory: 1Gi }     # Grafana 13 needs ~450Mi after startup

    kube-state-metrics:
      resources:
        requests: { cpu: 10m, memory: 64Mi }
        limits: { memory: 256Mi }
```

The file writes the same values in block style, with a comment on every decision.

Look around:

```bash
flux get helmreleases -n monitoring
kubectl get pods -n monitoring
# Expected: operator, prometheus-…-0, alertmanager-…-0, grafana, kube-state-metrics,
#           one node-exporter per node, all Running

kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090
# http://localhost:9090/targets: kubelet, cAdvisor, node-exporter, kube-state-metrics,
# the API server, CoreDNS… and the cert-manager and Longhorn ServiceMonitors from Step 5
```

Try a few queries in the Prometheus UI:

```promql
count by (job) (up)                                       # what is scraped
sum by (namespace) (container_memory_working_set_bytes)   # memory per namespace
certmanager_certificate_expiration_timestamp_seconds - time()   # seconds left per certificate
longhorn_volume_actual_size_bytes                         # real size of each volume
```

---

## Step 7: Expose Grafana at `grafana.local`

Two files in `infrastructure/configs/` and one in the platform:

1. `gateway/certificate.yaml` lists `grafana.local` in `dnsNames`, so the Gateway certificate covers it.
2. `coredns/coredns-custom.yaml` has `grafana.local` on both lines, so Pods can resolve it like the other homelab hostnames.
3. **`monitoring/kube-prometheus-stack/route.yaml`**, listed in that folder's `kustomization.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: public-gateway
      namespace: envoy-gateway
  hostnames:
    - grafana.local
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - kind: Service
          name: kube-prometheus-stack-grafana
          port: 80
```

No `SecurityPolicy`: Grafana has its own login (Step 8). Only Grafana is exposed. Prometheus and Alertmanager have no authentication, so they stay behind `kubectl port-forward`.

Check them (`bootstrap.sh` already restarted CoreDNS so it loads `coredns-custom`):

```bash
kubectl get certificate gateway-tls -n envoy-gateway       # Ready
kubectl get httproute grafana -n monitoring

# Break-glass admin password, generated once by the chart
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Open `https://grafana.local` and log in once as `admin` with the username and password form, below the authentik button. The chart's dashboards are there (*Dashboards → Kubernetes / Compute Resources / Cluster*, *Node Exporter / Nodes*…).

---

## Step 8: Log in with authentik (OIDC)

The local admin is for emergencies. People should log in with the same account as everywhere else in the homelab.

### 8a: Seal the client secret, twice

Grafana and authentik share one OIDC client secret, the value you set in `bootstrap/.env` in Step 2 (documented in `.env.example`):

```bash
# Grafana ↔ authentik OIDC client secret. Sealed twice, into authentik (read by
# the Grafana blueprint) and into monitoring (read by Grafana).
GRAFANA_OIDC_CLIENT_SECRET=<openssl rand -hex 32>
```

`scripts/seal-platform-secrets.sh` requires and validates it like the others, and seals it once per namespace. A SealedSecret only decrypts in the namespace it was sealed for:

```bash
: "${GRAFANA_OIDC_CLIENT_SECRET:?GRAFANA_OIDC_CLIENT_SECRET not set in .env (openssl rand -hex 32)}"
validate_safe "$GRAFANA_OIDC_CLIENT_SECRET"   GRAFANA_OIDC_CLIENT_SECRET

for ns in authentik monitoring; do
  kubectl create secret generic grafana-oidc -n "$ns" \
    --from-literal=client_secret="$GRAFANA_OIDC_CLIENT_SECRET" \
    --dry-run=client -o yaml \
    | seal "$OUT_DIR/grafana-oidc-${ns}.yaml"
done
```

`bootstrap.sh` ran it in Step 3 if your secrets were missing. Check both copies:

```bash
kubectl get sealedsecret -A
kubectl get secret grafana-oidc -n authentik
kubectl get secret grafana-oidc -n monitoring
```

### 8b: Declare the provider with an authentik blueprint

**`platform/authentik/blueprint-grafana.yaml`**: a ConfigMap holding the blueprint (abridged; read the full file in the solution):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-blueprint-grafana
  namespace: authentik
data:
  grafana.yaml: |
    version: 1
    metadata:
      name: Grafana OIDC
    entries:
      - model: authentik_core.group
        state: present
        identifiers:
          name: Grafana Editors

      - model: authentik_providers_oauth2.oauth2provider
        id: grafana-provider
        state: present
        identifiers:
          name: grafana
        attrs:
          client_type: confidential
          client_id: grafana
          client_secret: !Env GRAFANA_OIDC_CLIENT_SECRET
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
          redirect_uris:
            - matching_mode: strict
              url: https://grafana.local/login/generic_oauth
          property_mappings:   # openid, email and profile (profile carries the groups)
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]

      - model: authentik_core.application
        state: present
        identifiers:
          slug: grafana
        attrs:
          name: Grafana
          provider: !KeyOf grafana-provider
          meta_launch_url: https://grafana.local
```

`!Find` looks up existing objects, `!KeyOf` references an entry of the same blueprint, and `!Env` reads an environment variable of the worker. The file is listed in `platform/authentik/kustomization.yaml`, and the release gives the worker the variable and mounts the blueprint:

```yaml
# platform/authentik/release.yaml (excerpt, under spec.values)
    worker:
      replicas: 1
      env:
        - name: GRAFANA_OIDC_CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: grafana-oidc
              key: client_secret
    blueprints:
      configMaps:
        - authentik-blueprint-grafana
```

Check in authentik (*Admin interface*):

- *Customization → Blueprints*: **Grafana OIDC**, status *successful*
- *Applications → Applications*: **Grafana**, with the `grafana` provider
- *Directory → Groups*: **Grafana Editors**

If the blueprint shows an error, the worker logs explain it: `kubectl logs -n authentik deploy/authentik-worker | grep -i blueprint`.

### 8c: Configure Grafana

Grafana's server calls `https://authentik.local` itself, so it needs to trust the homelab CA. A small certificate in `monitoring` provides it, as for Flux in Phase 09. Its Secret carries the CA's public certificate in `ca.crt`:

**`monitoring/kube-prometheus-stack/homelab-ca.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-ca-bundle
  namespace: monitoring
spec:
  secretName: homelab-ca-bundle
  commonName: monitoring.homelab
  duration: 8760h
  issuerRef:
    name: homelab-ca
    kind: ClusterIssuer
```

It is listed in the folder's `kustomization.yaml`, **in the same Kustomization as the release**. The Grafana Pod mounts this Secret, so if the Certificate came from a later layer, Grafana would never start and the release would never be Ready.

The `grafana:` values add the login:

```yaml
    grafana:
      envValueFrom:
        GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
          secretKeyRef:
            name: grafana-oidc
            key: client_secret
      extraSecretMounts:
        - name: homelab-ca
          secretName: homelab-ca-bundle
          mountPath: /etc/grafana/homelab-ca
          readOnly: true
      grafana.ini:
        server:
          root_url: https://grafana.local
        auth:
          signout_redirect_url: https://authentik.local/application/o/grafana/end-session/
        auth.generic_oauth:
          enabled: true
          name: authentik
          client_id: grafana
          scopes: openid profile email
          auth_url: https://authentik.local/application/o/authorize/
          token_url: https://authentik.local/application/o/token/
          api_url: https://authentik.local/application/o/userinfo/
          tls_client_ca: /etc/grafana/homelab-ca/ca.crt
          use_pkce: true
          allow_sign_up: true
          login_attribute_path: preferred_username
          name_attribute_path: name
          email_attribute_path: email
          groups_attribute_path: groups
          role_attribute_path: >-
            contains(groups[*], 'authentik Admins') && 'Admin' ||
            contains(groups[*], 'Grafana Editors') && 'Editor' ||
            'Viewer'
```

`root_url` and the blueprint's `redirect_uris` must agree exactly (`https://grafana.local/login/generic_oauth`). authentik uses `strict` matching.

Test it:

1. Open `https://grafana.local` in a private window and click **Sign in with authentik**. As `akadmin` (member of *authentik Admins*), you land as **Admin**.
2. Create a test user in authentik and log in with it: **Viewer**. Add it to *Grafana Editors*, log out and back in: **Editor**.
3. *Sign out* in Grafana also ends the authentik session (`signout_redirect_url`).

---

## Step 9: Scrape the rest of the platform

Besides Kubernetes itself, cert-manager and Longhorn, every other component needs one change.

**authentik and Harbor**, in their `HelmRelease` values:

```yaml
# platform/authentik/release.yaml, under server:
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
```

```yaml
# platform/harbor/release.yaml, under values:
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
```

**Flux.** Flux was installed before the CRDs existed, so its monitors are plain manifests, kept with the rest of the Flux configuration in **`infrastructure/configs/flux/monitors.yaml`**:

```yaml
# The Flux Operator: flux_resource_info{kind, name, ready, suspended…} for every Flux object
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  namespaceSelector:
    matchNames: [flux-system]
  selector:
    matchLabels:
      app.kubernetes.io/name: flux-operator
      app.kubernetes.io/instance: flux-operator
  endpoints:
    - port: http
      path: /metrics
      interval: 60s
---
# The controllers: reconciliation durations, queues, Go runtime
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: flux-controllers
  namespace: flux-system
spec:
  namespaceSelector:
    matchNames: [flux-system]
  selector:
    matchExpressions:
      - key: app.kubernetes.io/part-of
        operator: In
        values: [flux]
  podMetricsEndpoints:
    - port: http-prom
```

**Envoy.** Every request to a `.local` hostname goes through the Envoy proxies, which Envoy Gateway creates at runtime. They are scraped through **`infrastructure/configs/gateway/pod-monitor.yaml`**:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: envoy-proxy
  namespace: envoy-gateway
spec:
  namespaceSelector:
    matchNames: [envoy-gateway]
  selector:
    matchLabels:
      app.kubernetes.io/name: envoy
      app.kubernetes.io/component: proxy
      app.kubernetes.io/managed-by: envoy-gateway
  podMetricsEndpoints:
    - port: metrics
      path: /stats/prometheus
```

Both files are listed in `infrastructure/configs/kustomization.yaml`. `infra-configs` runs variable substitution from `cluster-settings`, so these files must not contain `${...}` (they need none).

Check in Grafana *Explore* (datasource *Prometheus*):

```promql
count by (job) (up == 1)
# Expected among others: cert-manager, longhorn-backend, authentik…, harbor…,
#                        flux-operator, flux-system/flux-controllers, envoy-gateway/envoy-proxy

count by (kind, ready) (flux_resource_info)          # Flux objects per kind and state
sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total[5m]))   # requests per route backend
```

---

## Step 10: Logs with Loki and Alloy

### 10a: Loki

The Loki chart moved to the `grafana-community` organisation. `monitoring/loki/` holds `repository.yaml`, `release.yaml` and `kustomization.yaml`:

```yaml
# monitoring/loki/repository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: loki
  namespace: monitoring
spec:
  interval: 12h
  url: oci://ghcr.io/grafana-community/helm-charts/loki
  ref:
    tag: 18.13.7
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
```

```yaml
# monitoring/loki/release.yaml (values)
  values:
    deploymentMode: Monolithic
    loki:
      auth_enabled: false            # single tenant
      commonConfig:
        replication_factor: 1
      storage:
        type: filesystem
      schemaConfig:
        configs:
          - from: "2024-04-01"
            store: tsdb
            object_store: filesystem
            schema: v13
            index:
              prefix: loki_index_
              period: 24h
      limits_config:
        retention_period: 168h       # 7 days
      compactor:
        retention_enabled: true
        delete_request_store: filesystem
    singleBinary:
      replicas: 1
      persistence:
        enabled: true
        storageClass: longhorn
        size: 5Gi
      resources:
        requests: { cpu: 100m, memory: 256Mi }
        limits: { memory: 1Gi }
    # Zero out the scalable modes and the extras they need
    backend: { replicas: 0 }
    read: { replicas: 0 }
    write: { replicas: 0 }
    chunksCache: { enabled: false }
    resultsCache: { enabled: false }
    gateway: { enabled: false }
    lokiCanary: { enabled: false }
    test: { enabled: false }
    monitoring:
      serviceMonitor:
        enabled: true
```

The rest of the `HelmRelease` (interval, `chartRef`, remediation) is the same as for kube-prometheus-stack.

### 10b: Alloy

Alloy comes from the classic Grafana Helm repository, in `monitoring/alloy/`:

```yaml
# monitoring/alloy/repository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: grafana
  namespace: monitoring
spec:
  interval: 12h
  url: https://grafana.github.io/helm-charts
```

```yaml
# monitoring/alloy/release.yaml (excerpt)
spec:
  chart:
    spec:
      chart: alloy
      version: 1.13.0
      sourceRef:
        kind: HelmRepository
        name: grafana
  dependsOn:
    - name: loki                     # pushing logs needs Loki up first
  values:
    crds:
      create: false                  # PodLogs CRD not used
    controller:
      type: daemonset                # one collector per node
    serviceMonitor:
      enabled: true
    alloy:
      resources:
        requests: { cpu: 20m, memory: 64Mi }
        limits: { memory: 256Mi }
      configMap:
        content: |
          discovery.kubernetes "pods" {
            role = "pod"
            selectors {
              role  = "pod"
              field = "spec.nodeName=" + sys.env("HOSTNAME")
            }
          }

          discovery.relabel "pods" {
            targets = discovery.kubernetes.pods.targets
            rule {
              source_labels = ["__meta_kubernetes_namespace"]
              target_label  = "namespace"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_name"]
              target_label  = "pod"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_container_name"]
              target_label  = "container"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
              target_label  = "app"
            }
            rule {
              source_labels = ["__meta_kubernetes_pod_node_name"]
              target_label  = "node"
            }
          }

          loki.source.kubernetes "pods" {
            targets    = discovery.relabel.pods.output
            forward_to = [loki.write.default.receiver]
          }

          loki.write "default" {
            endpoint {
              url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
            }
          }
```

Read the pipeline top to bottom: discover the Pods on this node, keep five low-cardinality labels, follow their logs through the API, push them to Loki.

### 10c: Loki as a Grafana datasource

```yaml
# monitoring/kube-prometheus-stack/release.yaml, under grafana:
      additionalDataSources:
        - name: Loki
          uid: loki                  # fixed uid, referenced by the dashboards
          type: loki
          access: proxy
          url: http://loki.monitoring.svc.cluster.local:3100
          jsonData:
            maxLines: 1000
```

Both are listed in `monitoring/kustomization.yaml`. Verify:

```bash
flux get helmreleases -n monitoring
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide   # one per node
kubectl logs -n monitoring ds/alloy | tail                               # no push errors
```

In Grafana, *Explore → Loki*:

```logql
{namespace="flux-system"}                              # Flux controller logs
{namespace="flux-system", app="helm-controller"} |= "error"
{namespace="todo"}                                     # the todo-app, all containers
```

---

## Step 11: Instrument the todo-app

Until now the platform could only see the todo-app from the outside (CPU, memory, Envoy requests). This step changes the application itself, in `application/` at the repository root.

### 11a: Backend metrics

The backend depends on `prom-client` 15 (`application/backend/package.json`). npm may print a deprecation notice pointing to `@prometheus-io/client`. The solution stays on `prom-client` 15, the version every Express guide documents.

**`application/backend/src/config/metrics.ts`** (new):

```ts
import type { NextFunction, Request, Response } from "express";
import client from "prom-client";

/** Prometheus metrics for the API, served on /metrics (outside /api/v1). */
export const registry = new client.Registry();

// Node.js process metrics: CPU, memory, event loop lag, GC.
client.collectDefaultMetrics({ register: registry });

const httpRequests = new client.Counter({
  name: "http_requests_total",
  help: "HTTP requests handled by the API",
  labelNames: ["method", "route", "status_code"],
  registers: [registry],
});

const httpDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [registry],
});

export const observeRequests = (req: Request, res: Response, next: NextFunction) => {
  const end = httpDuration.startTimer();

  res.on("finish", () => {
    if (req.path === "/metrics") return;

    // The route pattern (/api/v1/:name), never the real path: one series per
    // note name would grow without limit.
    const route = req.route ? `${req.baseUrl}${req.route.path}` : "unmatched";
    const labels = { method: req.method, route, status_code: String(res.statusCode) };
    const seconds = end(labels);
    httpRequests.inc(labels);

    // One JSON access log line per request, for Loki
    console.log(
      JSON.stringify({
        level: res.statusCode >= 500 ? "error" : "info",
        msg: "request",
        method: req.method,
        path: req.originalUrl,
        route,
        status_code: res.statusCode,
        duration_ms: Math.round(seconds * 1000),
      })
    );
  });

  next();
};
```

Three design decisions to notice:

- **The `route` label is the pattern, the log line has the real path.** Labels must stay low-cardinality; the log line can hold anything.
- **The middleware measures on `finish`**, when the status code is known and the time includes the whole handler.
- **`/metrics` is excluded** so Prometheus's own scrapes do not count as traffic.

**`application/backend/src/index.ts`**: register the middleware before the routes, and serve the registry outside `/api/v1`:

```ts
import { observeRequests, registry } from "./config/metrics";

app.use(observeRequests);
app.use(express.json());
app.use("/api/v1", noteRoutes);

// Scraped by Prometheus inside the cluster. The frontend only proxies
// /api/v1*, so this endpoint is not reachable from todo.local.
app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", registry.contentType);
  res.send(await registry.metrics());
});
```

### 11b: Stop logging the database password

The backend used to print `Connected to ${env.DATABASE_URI}`, password included. With every log line now in Loki, anyone with Grafana access could read it. Log only the parts that identify the database:

```ts
// Never log DATABASE_URI itself: it contains the password, and every log
// line ends up in Loki, readable by anyone with access to Grafana.
const db = new URL(env.DATABASE_URI);
console.log(`Connected to ${db.hostname}:${db.port || "5432"}${db.pathname}`);
```

Backend `1.0.0` never ran with Loki in this phase, so the password never reached it. If an older backend ever runs while Alloy collects logs, `{namespace="todo", container="backend"} |= "Connected"` finds the line, and the password must be rotated: a leaked secret stays leaked.

Build and check locally:

```bash
(cd ../../../application/backend && npm ci && npm run build)
```

### 11c: Chart 0.2.0

Three changes in `application/chart/`:

**`Chart.yaml`**: `version: 0.2.0`, `appVersion: "1.1.0"`.

**`templates/backend/backend-service.yaml`**: name the port. `ServiceMonitor` endpoints refer to ports by name:

```yaml
  ports:
    - name: http
      port: {{ .Values.backend.service.port }}
      targetPort: {{ .Values.backend.service.targetPort }}
      protocol: TCP
```

**`templates/backend/backend-servicemonitor.yaml`** (new), rendered only on request:

```yaml
{{- if .Values.backend.metrics.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "todo-app.fullname" . }}-backend
  labels:
    {{- include "todo-app.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
    {{- with .Values.backend.metrics.serviceMonitor.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "todo-app.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: backend
  endpoints:
    - port: http
      path: {{ .Values.backend.metrics.path }}
      interval: {{ .Values.backend.metrics.serviceMonitor.interval }}
{{- end }}
```

**`values.yaml`**, under `backend:`:

```yaml
  # The backend always serves Prometheus metrics on this path (backend 1.1.0+).
  metrics:
    path: /metrics
    serviceMonitor:
      # Renders a ServiceMonitor; needs the Prometheus Operator CRDs.
      enabled: false
      interval: 30s
      # Extra labels, if your Prometheus only selects labelled monitors.
      labels: {}
```

`enabled: false` by default: the chart must still install in a cluster without the Prometheus Operator. The `labels` value is for clusters whose Prometheus keeps the default `release=` selector.

```bash
helm lint ../../../application/chart
helm template my-app ../../../application/chart --set backend.metrics.serviceMonitor.enabled=true | grep -A12 'kind: ServiceMonitor'
```

### 11d: CI for the application

Phase 09's `gitops-validate.yaml` checks the manifests, but a broken backend build or chart template would only fail once Flux tries to deploy it. **`.github/workflows/app-validate.yaml`** runs on pull requests and pushes that touch `application/backend/**` or `application/chart/**`, with two jobs:

- **backend**: Node.js 20 (same major version as the Dockerfile), `npm ci` and `npm run build` (type-check and compile)
- **chart**: `helm lint`, then `helm template` with **every optional feature enabled** (`gatewayRoute`, `auth`, `metrics.serviceMonitor`) piped into `kubeconform` with the same pinned version and CRD catalog as `gitops-validate.yaml`, so every template, including the `ServiceMonitor`, is validated

Open a pull request that touches the application to see it run.

### 11e: Version 1.1.0 and chart 0.2.0 in prod

`bootstrap.sh` pushed the images you built in Step 2 as `1.1.0` (`IMAGE_TAG`) and published chart `0.2.0` from `application/chart/`. `apps/prod/` pins exactly those versions, with the image policy markers that let image automation bump them later:

```bash
flux get images policy -A          # todo-backend → 1.1.0, todo-app-chart → 0.2.0
```

The environment-independent release enables the `ServiceMonitor`, and the base `OCIRepository` pins chart `0.2.0` too: the base enables a value that only exists from 0.2.0 on, so a new overlay without a chart patch should not fall back to 0.1.0:

```yaml
# apps/base/todo-app/release.yaml, under values.backend:
      # Prometheus scrapes the backend's /metrics (chart 0.2.0+, backend 1.1.0+).
      metrics:
        serviceMonitor:
          enabled: true
```

```yaml
# apps/base/todo-app/oci-repository.yaml
  ref:
    tag: "0.2.0"
```

Verify:

```bash
flux get helmreleases -n todo
kubectl get servicemonitor -n todo
# Expected: my-app-todo-app-backend

kubectl port-forward -n todo svc/my-app-todo-app-backend 8080:8080 &
curl -s localhost:8080/metrics | grep -E '^http_requests_total|^nodejs_version_info'
curl -sk https://todo.local/metrics -o /dev/null -w '%{http_code}\n'   # not exposed outside
kill %1
```

In Prometheus: `up{namespace="todo"}` returns 1 for the backend.

The next backend change ships the Phase 09 way: build and push a new version, and image automation commits it.

```bash
docker build -t harbor.local/todo/backend:1.1.1 ../../../application/backend
docker push harbor.local/todo/backend:1.1.1
flux get images policy todo-backend   # resolves to 1.1.1
git pull && git log -1                # fluxcdbot: 1.1.0 -> 1.1.1 in apps/prod/todo-app-values.yaml
```

---

## Step 12: Dashboards as code

The chart's dashboards cover Kubernetes and the nodes. The solution adds two of its own: one for Flux, one for the todo-app.

Dashboards are plain Grafana JSON files. A Kustomize `configMapGenerator` turns each one into a ConfigMap labelled `grafana_dashboard: "1"`, which the Grafana sidecar loads into the folder named by the `grafana_folder` annotation. This is the same approach as Flux's own [monitoring example](https://github.com/fluxcd/flux2-monitoring-example).

They live in `monitoring/kube-prometheus-stack/dashboards/`, and the generator is in that folder's `kustomization.yaml`:

```yaml
generatorOptions:
  disableNameSuffixHash: true      # stable ConfigMap names
  labels:
    grafana_dashboard: "1"
configMapGenerator:
  - name: dashboard-flux
    namespace: monitoring
    files:
      - dashboards/flux.json
    options:
      annotations:
        grafana_folder: Platform
  - name: dashboard-todo-app
    namespace: monitoring
    files:
      - dashboards/todo-app.json
    options:
      annotations:
        grafana_folder: Applications
```

What is in them:

| Dashboard | Panels | Data |
|---|---|---|
| **Flux** (*Platform*) | Objects, not Ready, suspended; table of every Flux object; p95 reconciliation duration per kind; controller CPU | `flux_resource_info`, `gotk_reconcile_duration_seconds`, cAdvisor |
| **todo-app** (*Applications*) | Requests/s, 5xx ratio, p95 latency, backend up; requests by route and status; p50/p95 per route; CPU and memory; backend logs | The backend's `/metrics`, cAdvisor, Loki |

Panels reference the datasources by `uid` (`prometheus` from the chart, `loki` from Step 10c), which is why the Loki datasource has a fixed `uid`.

**The editing workflow.** Change a provisioned dashboard in the UI (add a panel), then *Export → Export as JSON* (leave *Export for sharing externally* off, so the datasource uids stay), save it over the `.json` file and commit. The pull request diff is the dashboard change. Anything you only save in the UI is gone the next time the Grafana Pod restarts, because Grafana has no persistence.

```bash
kubectl get cm -n monitoring -l grafana_dashboard=1
# Expected: dashboard-flux, dashboard-todo-app and the chart's own dashboards
```

---

## Step 13: Hands-on with logs and metrics

The stack is complete. Now use it: generate traffic, break things on purpose, and follow each event in both signals.

### 13a: Use the todo-app and watch the access log

Open `https://todo.local`, log in through authentik, and create, edit and delete a few notes. Then in Grafana *Explore → Loki*:

```logql
# Every request the backend handled
{namespace="todo", container="backend"} | json | msg="request"

# Readable one-liners
{namespace="todo", container="backend"} | json | msg="request"
  | line_format "{{.method}} {{.path}} → {{.status_code}} ({{.duration_ms}} ms)"
```

Each `PUT /api/v1/shopping-list` in the log has `route="/api/v1/:name"`: the real path stays in the log, while the metric only knows the pattern. Open the **todo-app** dashboard: the same requests appear in *Requests by route and status*.

Now generate traffic and every status code the API can return. A port-forward reaches the backend directly, without the authentik login:

```bash
kubectl port-forward -n todo svc/my-app-todo-app-backend 8080:8080 &

curl -s localhost:8080/api/v1/does-not-exist                    # 404
curl -s -X POST localhost:8080/api/v1/ \
  -H 'Content-Type: application/json' -d '{}'                    # 400
curl -s -X POST localhost:8080/api/v1/ \
  -H 'Content-Type: application/json' -d '{"name":"demo","content":"x"}'   # 201
curl -s -X POST localhost:8080/api/v1/ \
  -H 'Content-Type: application/json' -d '{"name":"demo","content":"x"}'   # 409
for i in $(seq 1 300); do curl -s -o /dev/null localhost:8080/api/v1/; done  # load
```

Compare the two views of the same traffic over the last 5 minutes. They should agree:

```logql
sum by (status_code) (count_over_time({namespace="todo", container="backend"} | json | msg="request" [5m]))
```

```promql
sum by (status_code) (increase(http_requests_total{namespace="todo"}[5m]))
```

Then look at the Envoy side: `sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total[5m]))`. Your clicks on `todo.local` are there; the `curl` loop is not, because the port-forward bypassed the Gateway. Each data source only sees the traffic that passes through it.

### 13b: Delete a Pod and follow it in the logs

```bash
kubectl get pods -n todo -l app.kubernetes.io/component=backend
kubectl delete pod -n todo -l app.kubernetes.io/component=backend
kubectl logs -n todo <old-pod-name>
# Error: pods "<old-pod-name>" not found
```

`kubectl logs` can only read containers that still exist. Loki kept everything:

```logql
{namespace="todo", container="backend"} != "\"msg\":\"request\""
```

You see the old Pod's last lines and the new Pod's startup (`Server running at…`, `Connected to my-app-todo-app-postgres:5432/…`, without a password). Group by Pod to see the handover: `sum by (pod) (count_over_time({namespace="todo", container="backend"}[1m]))`.

On the metrics side:

```promql
# A new process: the start time changed
changes(process_start_time_seconds{namespace="todo"}[15m])

# Counters restarted from 0 in the new Pod, rate() handles the reset
sum(rate(http_requests_total{namespace="todo"}[5m]))

# Not a restart: a new Pod is not a container restart
sum by (pod) (kube_pod_container_status_restarts_total{namespace="todo"})
```

Repeat with a Pod of another component (`kubectl delete pod -n authentik -l app.kubernetes.io/component=server`) and find its shutdown and startup in `{namespace="authentik"}`.

### 13c: Break the database, find out why

The todo-app `HelmRelease` has drift detection, so suspend it first, as in Phase 09 Step 11:

```bash
flux suspend helmrelease todo-app -n todo
kubectl scale deploy my-app-todo-app-postgres -n todo --replicas=0
for i in $(seq 1 100); do curl -s -o /dev/null localhost:8080/api/v1/; sleep 0.5; done
```

On the **todo-app** dashboard, *Errors (5xx)* climbs and the latency panels change shape. In Loki:

```logql
{namespace="todo", container="backend"} | json | level="error"
```

You get one line per failed request, `status_code: 500`, but **no reason**: the note controller catches the exception and answers 500 without logging it. Metrics told you *that* it fails, the access log tells you *which* requests, and nothing tells you *why*. Fixing that is additional exercise 2.

Restore the database by resuming the release. Drift detection scales PostgreSQL back to 1:

```bash
flux resume helmrelease todo-app -n todo
kubectl get deploy my-app-todo-app-postgres -n todo
kill %1   # the port-forward
```

---

## Step 14: Alerts

kube-prometheus-stack ships around a hundred rules as `PrometheusRule` objects:

```bash
kubectl get prometheusrules -n monitoring
```

In Grafana, *Alerting → Alert rules* lists them under *Data source-managed*, grouped by file. Two things to notice:

- **`Watchdog` is always firing.** That is on purpose: it proves the pipeline from Prometheus to Alertmanager works. In production it goes to a dead man's switch service.
- **Nothing about the k3s control plane** (`KubeSchedulerDown`…) fires, because Step 6 disabled those rules.

Make a real alert fire with a Pod that crashes forever, in a scratch namespace that Flux does not manage:

```bash
kubectl create namespace alert-test
kubectl run crasher -n alert-test --image=busybox:1.36 -- sh -c 'echo "about to fail"; exit 1'
```

Watch `KubePodCrashLooping` in *Alerting → Alert rules*. It turns **Pending** within a few minutes and **Firing** after its `for: 15m`. Meanwhile:

```logql
{namespace="alert-test"}          # "about to fail", once per restart
```

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093
# http://localhost:9093: the firing alerts, grouped by labels; silence KubePodCrashLooping
```

No notification arrives anywhere: there are no receivers (additional exercise 1). Clean up:

```bash
kubectl delete namespace alert-test
```

---

## Step 15: Validate in CI

`scripts/validate.sh` lists `monitoring` among its overlays, one entry per Flux `Kustomization` path. It also validates more kinds now: `ServiceMonitor`, `PodMonitor` and `PrometheusRule` come from the pinned community CRD catalog, and the dashboard ConfigMaps come from the generator:

```bash
./scripts/validate.sh
```

Break something on purpose (write `podMetricEndpoints` instead of `podMetricsEndpoints` in `pod-monitor.yaml`, or put a typo in a dashboard file name in the generator) and run it again.

`gitops-validate.yaml` discovers every phase that ships `solution/scripts/validate.sh`, so it already validates Phase 10. `app-validate.yaml` (Step 11d) covers the application.

---

## Day-2 cheatsheet

| Task | Command / query |
|---|---|
| Prometheus UI | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090` |
| Alertmanager UI | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093` |
| Break-glass Grafana admin | `kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' \| base64 -d` |
| What is scraped | `count by (job) (up)` |
| Targets down | `up == 0` |
| Firing alerts | `ALERTS{alertstate="firing"}` |
| Flux objects not Ready | `flux_resource_info{ready="False"}` |
| Certificates expiring within 14 days | `certmanager_certificate_expiration_timestamp_seconds - time() < 14*24*3600` |
| Memory vs limit per Pod | *Kubernetes / Compute Resources / Pod* dashboard |
| Errors of one namespace | `{namespace="<ns>"} \|~ "(?i)error"` |
| todo-app 5xx requests | `{namespace="todo", container="backend"} \| json \| status_code >= 500` |
| Log volume per namespace | `sum by (namespace) (bytes_over_time({namespace=~".+"}[1h]))` |
| Monitors in the cluster | `kubectl get servicemonitors,podmonitors -A` |
| Prometheus storage used | `prometheus_tsdb_storage_blocks_bytes` |

---

## Troubleshooting checklist

| Symptom | Likely cause | Fix |
|---|---|---|
| `flux-system` fails with `path not found` | `.sourceignore` does not re-include `phases/10-observability-and-monitoring/solution/`, or the paths still say Phase 09 | Step 2 |
| authentik or Grafana: `CSRF Failed: CSRF cookie not set`, or every save fails | Browser on `http://`: the Gateway also answers on port 80, and the browser drops the `Secure` cookies | Always use `https://` |
| `infra-controllers`: cert-manager or Longhorn `no matches for kind "ServiceMonitor"` | Missing HelmRelease `dependsOn` on `prometheus-operator-crds` | Add it (Step 5) |
| kube-prometheus-stack install fails on existing CRDs | `crds.enabled` not set to `false` | The CRDs belong to `prometheus-operator-crds` |
| `apps` waits for `monitoring` | `dependsOn` added to `clusters/prod/apps.yaml` | Remove it: applications must not depend on the observability stack |
| Monitoring Pods rejected by Pod Security | `monitoring` namespace without the `privileged` labels | Check `platform-secrets/namespaces.yaml` |
| Grafana Pod stuck in `ContainerCreating` | `homelab-ca-bundle` Secret missing | `kubectl get certificate -n monitoring`; it must be in the same folder as the release |
| Grafana Pod `CreateContainerConfigError` | `monitoring/grafana-oidc` not decrypted | Seal it (`./scripts/seal-platform-secrets.sh`, Step 8a); `kubectl get sealedsecret -n monitoring` |
| authentik worker `CreateContainerConfigError` | `authentik/grafana-oidc` not decrypted | Same as above, in `authentik` |
| Grafana answers 504 or is very slow | Memory close to the limit, GC burning CPU | Limit at 1 Gi (Step 6); check *Compute Resources / Pod* |
| Login: `redirect_uri` error in authentik | `root_url` and the blueprint's `redirect_uris` differ | Both must be `https://grafana.local/login/generic_oauth` |
| Login fails, Grafana logs `x509: certificate signed by unknown authority` | `tls_client_ca` not mounted | Check `extraSecretMounts` and the `homelab-ca-bundle` Secret |
| Login fails, Grafana logs `no such host authentik.local` | CoreDNS has not reloaded `coredns-custom` | `kubectl rollout restart deploy/coredns -n kube-system` |
| Blueprint not listed or failing | ConfigMap not mounted, or `!Find` target missing | `kubectl logs -n authentik deploy/authentik-worker \| grep -i blueprint` |
| Everybody logs in as Viewer | `groups` claim missing or user not in the group | Scope `profile` in the provider; check the user's groups in authentik |
| `ServiceMonitor` exists but no target | Selector or port name mismatch | The Service port must be named `http` (chart 0.2.0); `kubectl get endpoints -n todo` |
| todo-app target `down` with 404 | Backend image older than 1.1.0 | `kubectl get deploy -n todo -o wide`; check the image policy |
| Alerts `KubeSchedulerDown`/`KubeControllerManagerDown` firing | k3s components not disabled | Step 6 values |
| No logs in Explore | Alloy cannot push, or Loki not ready | `kubectl logs -n monitoring ds/alloy`; `flux get hr loki -n monitoring` |
| Logs of only some Pods | Alloy not running on that node | `kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide` |
| PVC of Prometheus or Loki `Pending` | Longhorn out of space or node not schedulable | Longhorn UI → Nodes; reduce sizes or add disk |
| Dashboard edits disappear | Grafana has no persistence by design | Export the JSON and commit it (Step 12) |

---

## Additional exercises

1. **Notifications**: add an Alertmanager receiver (Discord, Slack, Telegram or email). Seal the webhook URL or SMTP password as a Secret in `monitoring`, reference it from `alertmanager.alertmanagerSpec.secrets`, and route `severity=critical` there with `alertmanager.config`. Route `Watchdog` to a dead man's switch service such as [healthchecks.io](https://healthchecks.io/). Repeat the crash loop from Step 14 and receive the notification.

2. **Log the cause of errors**: Step 13c showed 500s with no reason. Log the caught exception in the note controller as a JSON line (`level: "error"`, `msg`, `error.message`, but never the request body or credentials), release `1.2.0`, and repeat the experiment until Loki tells you *why*.

3. **Your own alerts**: write a `PrometheusRule` in the todo-app chart (behind a value, like the `ServiceMonitor`) with two alerts: 5xx ratio above 5 % for 5 minutes, and p95 latency above 500 ms for 10 minutes. Break the database again and watch them fire.

4. **SLOs**: define a 99 % availability objective for the todo-app API and generate multi-window burn-rate alerts with [Sloth](https://sloth.dev/) or [Pyrra](https://github.com/pyrra-dev/pyrra) from the same `http_requests_total` metric.

5. **Flux alerts**: add a `PrometheusRule` that fires when `flux_resource_info{ready="False"}` persists for 15 minutes. Compare it with Flux's own notification-controller (Phase 09 exercise 1): which one would tell you that Flux itself is down?

6. **Traces**: add [Tempo](https://grafana.com/docs/tempo/latest/) in monolithic mode, instrument the backend with the OpenTelemetry Node.js SDK (HTTP, Express and pg auto-instrumentation), send OTLP to an `otelcol.receiver.otlp` component in Alloy, and link traces to logs in Grafana by putting the `trace_id` in the JSON access log.

7. **Database metrics**: run [postgres_exporter](https://github.com/prometheus-community/postgres_exporter) as a sidecar of the todo-app PostgreSQL (behind a chart value) with a `ServiceMonitor`, and add connections, transactions and database size to the todo-app dashboard.

8. **Community dashboards**: import dashboards for cert-manager, Longhorn and Envoy Gateway from [grafana.com/dashboards](https://grafana.com/grafana/dashboards/) as `.json` files in the generator. Fix their datasource references to the `prometheus` uid so they work without manual selection.

9. **Restrict Grafana access**: today every authentik user can log in as Viewer. Add a policy binding in the blueprint so that only members of a *Grafana Users* group can open the application, and test it with a user outside the group.

10. **Long-term storage**: Prometheus keeps 10 days. Add [Thanos](https://thanos.io/) sidecar or Grafana Mimir with object storage (MinIO on Longhorn) to keep a year of downsampled metrics, and move Loki to the same object storage.

11. **Progressive delivery**: with Prometheus in place, finish Phase 09 exercise 8. Flagger can now promote a frontend canary only while the Envoy 5xx rate and latency stay within limits.

12. **Upgrade in place instead of reinstalling**: GitOps promises that the next version of a platform is a series of commits, not a reinstall. Prove it: start from a running Phase 09 cluster and move it to Phase 10 without wiping it.
    - Seal your secrets for Phase 10 (`./scripts/seal-platform-secrets.sh`), commit and push.
    - If your Phase 09 cluster still declares `authentik` and `harbor` in `platform/` (early versions of Phase 09 did), protect them first: `kubectl annotate namespace authentik harbor kustomize.toolkit.fluxcd.io/prune=disabled`. They move from `platform` (with `prune: true`) to `platform-secrets`, and a namespace pruned by mistake takes its databases with it (*Namespaces in `platform-secrets`* in `theory.md`).
    - Re-include **both** phases in `.sourceignore`, commit and push: if Flux saw only Phase 10, the path it currently syncs would vanish before the switch.
    - `kubectl apply -f clusters/prod/flux-system/flux-instance.yaml` once. The Phase 09 `FluxInstance` in Git cannot point Flux elsewhere by itself; from now on Flux reconciles the Phase 10 copy. If `kubectl get kustomization flux-system -n flux-system -o jsonpath='{.spec.path}'` flips back to Phase 09, apply again.
    - Check that the three namespaces are owned by `platform-secrets` (`kubectl get ns -L kustomize.toolkit.fluxcd.io/name`), remove the annotation if you set it, and drop Phase 09 from `.sourceignore`.

    The new `monitoring` layer is installed, and only the releases whose values changed (metrics, the blueprint) are upgraded; nothing is reinstalled and no PersistentVolumeClaim is lost. If Phase 09 Step 10 already pushed `1.1.0` or chart `0.2.0` to Harbor, release this phase as the next free versions instead (`1.2.0`, `0.3.0`): the image policies cannot see new content under an existing tag, and nodes with `IfNotPresent` keep the old image.

---

## Success criteria

- Flux syncs `phases/10-observability-and-monitoring/solution/clusters/prod`, and `.sourceignore` only includes Phase 10
- Every Kustomization is Ready; `flux get helmreleases -A` includes `prometheus-operator-crds`, `kube-prometheus-stack`, `loki` and `alloy`
- The `authentik`, `harbor` and `monitoring` namespaces are owned by `platform-secrets`
- The observability stack lives in its own `monitoring` layer, and `apps` and `image-automation` do not depend on it
- Deleting the `prometheus-operator-crds` release would not delete the CRDs (`helm.sh/resource-policy: keep`)
- Prometheus scrapes Kubernetes, cert-manager, Longhorn, authentik, Harbor, Flux, the Envoy proxies, Loki, Alloy and the todo-app backend
- `https://grafana.local` logs in through authentik, with roles mapped from authentik groups, and the OIDC provider comes from a blueprint in Git
- Prometheus and Alertmanager are not reachable through the Gateway
- Loki contains the logs of every namespace, including Pods that no longer exist
- The backend exposes `http_requests_total` and `http_request_duration_seconds` with route patterns, writes a JSON access log, and no longer logs the database password
- The todo-app runs chart `0.2.0` and backend `1.1.0`, or a newer backend delivered by an image automation commit
- The Flux and todo-app dashboards are `.json` files in Git, loaded into the *Platform* and *Applications* folders
- You followed a deleted Pod, a broken database and a crash-looping Pod through metrics, logs and alerts
- `scripts/validate.sh` passes, and `app-validate.yaml` validates the backend and the chart in CI
- The whole platform, observability included, builds from a clean cluster with `bootstrap.sh`
