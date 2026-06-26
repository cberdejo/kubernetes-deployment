# Phase 05 — Distributed Persistent Storage with Longhorn

This phase adds real persistent storage to the todo-app. You will create a Longhorn wrapper chart and wire the canonical `application/chart` Helm chart to a Longhorn-backed PVC so data survives Pod restarts and node rescheduling.

**What you build in this phase:**

| Artifact | Purpose |
|---|---|
| `apps/longhorn/` | Helm wrapper chart that installs the Longhorn CSI driver |
| `application/chart/` | Canonical todo-app Helm chart used from this phase onward |
| `solution/apps/todo-app/values/prod-values.yaml` | Phase 05 values file for the canonical chart |
| Updated todo-app chart | Adds a PVC template, mounts it in PostgreSQL, and bootstraps the DB Secret in-cluster |

Compare your work with `solution/` when you are done.

---

## How it works

```
Longhorn DaemonSet runs on each node and registers the CSI driver
     ↓
A StorageClass named "longhorn" is available cluster-wide
     ↓
postgres-pvc.yaml requests a 1 Gi volume from the "longhorn" StorageClass
     ↓
Longhorn provisions a replicated block volume and binds the PVC
     ↓
PostgreSQL mounts the volume at /var/lib/postgresql/data/pgdata
     ↓
Data survives Pod restarts and node rescheduling
```

The key idea: **PostgreSQL is decoupled from the node where it runs**. The volume follows the workload anywhere in the cluster.

---

## Step 0 — Choose your cluster

From this phase onwards, **Minikube is no longer enough**. Longhorn's V1 data engine requires `iscsiadm` on every node — a kernel-level iSCSI tool that Minikube does not expose. You need a real cluster where you control the nodes.

Pick one option below, follow its setup guide, and come back once `kubectl get nodes` shows all nodes as `Ready`.

| Option | Setup guide | Best for |
|--------|-------------|----------|
| **k3s on Linux** | [docs/cluster-setup/k3s.md](../../docs/cluster-setup/k3s.md) | Fastest — runs on your existing Linux machine |
| **Talos Linux on VM/bare metal** | [docs/cluster-setup/talos-vm.md](../../docs/cluster-setup/talos-vm.md) | Production-like, fully declarative |
| **Managed cloud** (EKS, GKE, AKS, DigitalOcean) | Provider docs | Existing cloud cluster — ensure `open-iscsi` on workers |
| **Any CNCF-certified cluster** | — | `sudo apt install open-iscsi` on each node |

**Minimum per node:** 2 CPU, 4 GB RAM, 20 GB free disk.

---

## Step 1 — Prerequisites

```bash
# All nodes should be Ready
kubectl get nodes -o wide

# Helm is available
helm version --short

# iscsiadm must be present on every storage node
iscsiadm --version                                    # k3s / standard Linux
talosctl -n <NODE_IP> ls /usr/sbin/iscsiadm           # Talos
```

If `longhorn-manager` crashes with `failed to execute iscsiadm: No such file or directory`, the binary is missing on the node. Fix the node first, then restart the pods:

```bash
kubectl delete pod -n longhorn -l app=longhorn-manager
kubectl rollout status daemonset/longhorn-manager -n longhorn
```

---

## Step 2 — Create the Longhorn wrapper chart

Create the following directory structure. Each file is shown with its full content below.

```
apps/longhorn/
├── Chart.yaml
├── values/
│   └── prod-values.yaml
└── templates/
    ├── namespace.yaml
    └── route.yaml
```

**`apps/longhorn/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-longhorn
type: application
version: 1.0.0
dependencies:
  - name: longhorn
    version: 1.11.0
    repository: https://charts.longhorn.io
```

**`apps/longhorn/values/prod-values.yaml`**

```yaml
longhorn:
  persistence:
    defaultClassReplicaCount: 1
  defaultSettings:
    defaultReplicaCount: '{"v1":"1","v2":"1"}'
  preUpgradeChecker:
    jobEnabled: false

# Enable in Phase 06 once Envoy Gateway is installed.
gatewayRoute:
  enabled: false
  gateway:
    name: public-gateway
    namespace: envoy-gateway
  hostname: "longhorn.talos.local"
  pathPrefix: /
```

**`apps/longhorn/templates/namespace.yaml`**

Longhorn DaemonSet pods need `privileged` access to mount block devices. Pod Security Admission (PSA) labels on the namespace allow this — without them Kubernetes blocks pod startup.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: longhorn
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: privileged
    pod-security.kubernetes.io/warn-version: latest
```

**`apps/longhorn/templates/route.yaml`**

This template is disabled for now — it wires the Longhorn UI into Envoy Gateway, which you install in Phase 06.

```yaml
{{- if .Values.gatewayRoute.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: longhorn-ui
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: {{ .Values.gatewayRoute.gateway.name }}
      namespace: {{ .Values.gatewayRoute.gateway.namespace }}
  rules:
    - backendRefs:
        - kind: Service
          name: longhorn-frontend
          port: 80
      matches:
        - path:
            type: PathPrefix
            value: {{ .Values.gatewayRoute.pathPrefix }}
{{- end }}
```

**Install Longhorn:**

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm dependency update ./apps/longhorn

helm upgrade --install cluster-longhorn ./apps/longhorn \
  -f ./apps/longhorn/values/prod-values.yaml \
  -n longhorn \
  --create-namespace

kubectl rollout status daemonset/longhorn-manager -n longhorn
kubectl get storageclass | grep longhorn
# Expected: longhorn   (default)
```

> **Why a wrapper chart?** It pins the Longhorn version in Git, lets you track upgrades via pull requests, and makes the install reproducible across clusters.

If your cluster already has a different default StorageClass, remove its default annotation so Longhorn is the sole default:

```bash
kubectl patch storageclass <existing-default> \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

---

## Step 3 — Use the canonical todo-app chart

From this phase onward, the todo-app chart lives at the repository root:

```text
application/chart/
├── Chart.yaml
├── templates/
└── values/
    └── prod-values.yaml
```

The phase solution keeps only `solution/apps/todo-app/values/prod-values.yaml`. The chart templates live in `application/chart`, while each phase owns only the values it needs for that phase.

The chart creates `todo-db-secret` with a `pre-install,pre-upgrade` Helm hook when no `postgres.existingSecret` is configured. If `postgres.bootstrap.credentials.password` is omitted or empty, the hook generates one alphanumeric password once in-cluster and leaves any existing Secret unchanged on upgrades.

---

## Step 4 — Update the todo-app chart for persistent storage

Starting from the canonical `application/chart`, make the following changes.

### 5a — Add the PVC template

Create `application/chart/templates/database/postgres-pvc.yaml`:

```yaml
{{- if .Values.postgres.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "todo-app.fullname" . }}-postgres-pvc
  labels:
    {{- include "todo-app.labels" . | nindent 4 }}
    app.kubernetes.io/component: postgres
spec:
  storageClassName: {{ .Values.postgres.persistence.storageClassName }}
  accessModes:
    {{- toYaml .Values.postgres.persistence.accessModes | nindent 4 }}
  resources:
    requests:
      storage: {{ .Values.postgres.persistence.size }}
{{- end }}
```

### 5b — Mount the PVC in the PostgreSQL deployment

In `application/chart/templates/database/postgres-deployment.yaml`, add the `volumeMounts` and `volumes` blocks inside the container spec (guarded by the `persistence.enabled` flag):

```yaml
      containers:
        - name: postgres
          ...
          {{- if .Values.postgres.persistence.enabled }}
          volumeMounts:
            - name: postgres-pvc
              mountPath: /var/lib/postgresql/data
              subPath: pgdata
          {{- end }}
      {{- if .Values.postgres.persistence.enabled }}
      volumes:
        - name: postgres-pvc
          persistentVolumeClaim:
            claimName: {{ include "todo-app.fullname" . }}-postgres-pvc
      {{- end }}
```

> **Why `subPath: pgdata`?** PostgreSQL requires an empty directory at mount time. Without `subPath`, the PVC root becomes the data directory and PostgreSQL refuses to initialise.

Also add `strategy: type: Recreate` to the Deployment spec — this prevents a second PostgreSQL Pod from starting while the first is still holding the PVC, which would cause a mount conflict:

```yaml
spec:
  replicas: {{ .Values.postgres.replicaCount }}
  strategy:
    type: Recreate
```

### 5c — Add persistence values

In `solution/apps/todo-app/values/prod-values.yaml`, keep the Phase 05 deployment values. This file is complete enough to install the canonical chart from Docker Hub OCI, while disabling Gateway routing until Phase 06:

```yaml
frontend:
  service:
    type: NodePort
    port: 3000
    targetPort: 80
    nodePort: 30080
  gatewayRoute:
    enabled: false

postgres:
  persistence:
    storageClassName: longhorn
```

---

## Step 6 — Publish app images to Docker Hub

```bash
export DOCKERHUB_USER="<your-dockerhub-user>"
export IMAGE_TAG="1.0.0"

docker login

docker build \
  -t docker.io/${DOCKERHUB_USER}/todo-backend:${IMAGE_TAG} \
  ./application/backend
docker push docker.io/${DOCKERHUB_USER}/todo-backend:${IMAGE_TAG}

docker build \
  --build-arg VITE_API_URL=/api/v1 \
  -t docker.io/${DOCKERHUB_USER}/todo-frontend:${IMAGE_TAG} \
  ./application/frontend
docker push docker.io/${DOCKERHUB_USER}/todo-frontend:${IMAGE_TAG}
```

The bootstrap script overrides the image repositories from `.env`, so you do not need to commit your Docker Hub username into the values file.

---

## Step 7 — Deploy the todo-app

```bash
helm upgrade --install my-app \
  oci://registry-1.docker.io/<dockerhub-user>/todo-app \
  --version 0.1.0 \
  -f ./apps/todo-app/values/prod-values.yaml \
  -n todo \
  --create-namespace
```

---

## Step 8 — Verify

```bash
# PVC should be Bound to a Longhorn volume
kubectl get pvc -n todo
# Expected: my-app-todo-app-postgres-pvc   Bound   ...   longhorn

# Longhorn created a volume object
kubectl get volumes.longhorn.io -n longhorn

# All pods running
kubectl get pods -n todo

# No DB connection errors in backend logs
kubectl logs deploy/my-app-todo-app-backend -n todo --tail=100
```

Access the Longhorn UI before Phase 06 via port-forward:

```bash
kubectl port-forward svc/longhorn-frontend 8080:80 -n longhorn
# Open http://localhost:8080
```

---

## Troubleshooting checklist

- `iscsiadm --version` (Linux) or `talosctl -n <ip> ls /usr/sbin/iscsiadm` (Talos) succeeds on every storage node before installing Longhorn
- `longhorn-manager` in `CrashLoopBackOff` with `failed to execute iscsiadm` — on Linux: `sudo apt install open-iscsi && sudo systemctl enable --now iscsid`; on Talos: re-create node with the correct ISO from factory.talos.dev
- `longhorn` StorageClass exists: `kubectl get storageclass`
- PVC is `Bound`; if `Pending`: `kubectl describe pvc -n todo`
- `subPath: pgdata` is present in the postgres Deployment
- `todo-db-secret` exists after Helm runs the bootstrap hook: `kubectl get secret todo-db-secret -n todo`
- If the OCI chart cannot be pulled, run `helm registry login registry-1.docker.io` and confirm the chart version was pushed

---

## Credential rotation

Set a new `POSTGRES_PASSWORD` in `bootstrap/.env` before the first install if you need deterministic credentials. Existing Secrets are not rotated automatically; delete or replace `todo-db-secret` deliberately if you want to rotate credentials. The Longhorn volume persists through credential rotations.

---

## Additional exercises

1. **Replica verification** — open Longhorn UI, find the PostgreSQL volume, confirm replicas. Compare "healthy" vs "degraded" states.
2. **Pod eviction test** — delete the PostgreSQL Pod. Confirm Kubernetes reschedules it and the PVC reattaches with data intact.
3. **Reclaim policy test** — set StorageClass `reclaimPolicy: Retain`, delete the PVC, observe the Longhorn volume remains. Then delete it manually.
4. **Snapshot** — create a volume snapshot in Longhorn UI. Insert test data. Delete the data. Restore from snapshot and confirm data returns.
5. **Single vs multiple replicas** — change `defaultClassReplicaCount` in `prod-values.yaml` and observe volume health in the UI.
6. **Node drain** — drain a node (`kubectl drain <node> --ignore-daemonsets`). Observe Longhorn rebuilding replicas on remaining nodes. Uncordon and observe rebalancing.

---

## Further reading

- [Longhorn documentation](https://longhorn.io/docs/latest/)
- [CSI specification](https://github.com/container-storage-interface/spec)
- [Kubernetes storage documentation](https://kubernetes.io/docs/concepts/storage/)

---

## Success criteria


- `apps/longhorn/` wrapper chart installed, all Longhorn pods Running
- `longhorn` StorageClass is the default
- `solution/apps/todo-app` contains only the Phase 05 values file
- `application/chart/templates/database/postgres-pvc.yaml` exists and references `storageClassName: longhorn` through values
- PostgreSQL Deployment uses `strategy: Recreate` and mounts the PVC with `subPath: pgdata`
- PVC is `Bound` and backed by a Longhorn volume
- Todos created before a Pod restart survive the restart
- Longhorn UI reachable and volume shows healthy replicas
