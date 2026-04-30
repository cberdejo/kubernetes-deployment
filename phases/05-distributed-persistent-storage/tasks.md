# Phase 05 — Distributed Persistent Storage with Longhorn

This phase adds real persistent storage to the todo-app. You will create a Longhorn wrapper chart, update the Sealed Secrets controller to its own namespace, and wire PostgreSQL to a Longhorn-backed PVC so data survives Pod restarts and node rescheduling.

**What you build in this phase:**

| Artifact | Purpose |
|---|---|
| `apps/longhorn/` | Helm wrapper chart that installs the Longhorn CSI driver |
| `apps/sealed-secrets/` | Updated wrapper — controller moves to `sealed-secrets` namespace |
| Updated `apps/todo-app/` | Adds a PVC template and mounts it in the PostgreSQL deployment |

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

## Step 3 & 4 — Install Sealed Secrets and seal the PostgreSQL credentials

Follow **[phases/04-secure-secrets-managment/tasks.md](../04-secure-secrets-managment/tasks.md)** for the full process.

Two differences apply in Phase 05:

| | Phase 04 | Phase 05 |
|---|---|---|
| Controller namespace | `kube-system` | `sealed-secrets` |
| Helm release name | `sealed-secrets` | `sealed-secrets-prod` |

Create the wrapper chart `apps/sealed-secrets/` with the files below, then install it.

**`apps/sealed-secrets/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-sealed-secrets
description: Installs the Bitnami Sealed Secrets controller
type: application
version: 1.0.0
dependencies:
  - name: sealed-secrets
    version: 2.18.3
    repository: https://bitnami-labs.github.io/sealed-secrets
```

**`apps/sealed-secrets/values/prod-values.yaml`**

```yaml
sealed-secrets:
  # fullnameOverride keeps the controller name stable across release name changes.
  # kubeseal uses this name via --controller-name.
  fullnameOverride: sealed-secrets
```

**Install the controller:**

```bash
helm dependency update ./apps/sealed-secrets

helm upgrade --install sealed-secrets-prod ./apps/sealed-secrets \
  -f ./apps/sealed-secrets/values/prod-values.yaml \
  -n sealed-secrets \
  --create-namespace

kubectl get pods -n sealed-secrets
```

**Seal credentials:**

When you reach the `kubeseal` commands in Phase 04, add `--controller-namespace sealed-secrets` to every call:

```bash
kubeseal --fetch-cert \
  --controller-name sealed-secrets \
  --controller-namespace sealed-secrets \
  > /tmp/sealed-secrets-cert.pem
```

Paste the four encrypted blobs into `apps/todo-app/templates/database/postgres-sealedsecret.yaml` (created in the next step).

---

## Step 5 — Update the todo-app chart for persistent storage

Starting from your Phase 04 `todo-app` chart, make the following changes.

### 5a — Add the PVC template

Create `apps/todo-app/templates/database/postgres-pvc.yaml`:

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

In `apps/todo-app/templates/database/postgres-deployment.yaml`, add the `volumeMounts` and `volumes` blocks inside the container spec (guarded by the `persistence.enabled` flag):

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

In `apps/todo-app/values/prod-values.yaml`, add the persistence block under `postgres`:

```yaml
postgres:
  ...
  secretName: "todo-db-secret"
  existingSecret: ""
  persistence:
    enabled: true
    size: 1Gi
    accessModes:
      - ReadWriteOnce
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

Update `repository` values in `apps/todo-app/values/prod-values.yaml` with your Docker Hub username before deploying.

---

## Step 7 — Deploy the todo-app

```bash
helm upgrade --install my-app ./apps/todo-app \
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
- `postgres-sealedsecret.yaml` has real encrypted blobs, not `cipher value` placeholders
- Sealed Secrets controller is Running in `sealed-secrets` namespace before sealing
- SealedSecret was sealed against this cluster — blobs from another cluster will not decrypt

---

## Credential rotation

Rotating DB credentials follows the same process as Phase 04 (re-seal with `kubeseal` and redeploy). The Longhorn volume persists through credential rotations.

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
- `apps/sealed-secrets/` installed in the `sealed-secrets` namespace
- `postgres-sealedsecret.yaml` contains real encrypted blobs
- `postgres-pvc.yaml` template exists and references `storageClassName: longhorn`
- PostgreSQL Deployment uses `strategy: Recreate` and mounts the PVC with `subPath: pgdata`
- PVC is `Bound` and backed by a Longhorn volume
- Todos created before a Pod restart survive the restart
- Longhorn UI reachable and volume shows healthy replicas
