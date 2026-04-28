# Phase 05 - Distributed Persistent Storage with Longhorn

This guide explains how to install Longhorn using a Helm wrapper chart and how to update the `todo-app` chart so PostgreSQL uses Longhorn as its storage backend.

**Conventions used in this guide:**


| Key                   | Value              |
| --------------------- | ------------------ |
| Longhorn chart name   | `cluster-longhorn` |
| Longhorn namespace    | `longhorn-system`  |
| App chart name        | `todo-app`         |
| App release name      | `my-app`           |
| App namespace         | `todo`             |
| Longhorn StorageClass | `longhorn`         |


---

## How it works

```
Helm installs the Longhorn chart as a dependency
     ↓
Longhorn DaemonSet runs on each node and registers the CSI driver
     ↓
A StorageClass named "longhorn" is available cluster-wide
     ↓
todo-app's postgres-pvc requests storage from the "longhorn" StorageClass
     ↓
Longhorn provisions a replicated block volume and binds the PVC
     ↓
PostgreSQL mounts the volume at /var/lib/postgresql/data/pgdata
     ↓
Data survives Pod restarts and node rescheduling
```

The key idea: **PostgreSQL is decoupled from the node where it runs**. The volume follows the workload anywhere in the cluster.

---

## Step 0 - Cluster requirements

This phase requires a real multi-node cluster. Lightweight local solutions (single-node clusters, container-based nodes) will not work because Longhorn V1 requires `iscsiadm` to be present and executable on every storage node.

**Minimum: 3 nodes** — 1 control plane + 2 workers. Three nodes allow Longhorn to schedule replicas across failure domains, which is the whole point of distributed storage.

**Node requirement:** `iscsiadm` must be available on each node that will store data:

```bash
# Run on each node — must return a version, not "command not found"
iscsiadm --version
```

How you provision the cluster (bare metal, VMs, cloud instances) is up to you. The only hard requirement is that `iscsiadm` is present on the nodes before installing Longhorn.

---

## Step 1 - Prerequisites

Verify your tools and cluster before you begin.

```bash
# 3 nodes should be Ready (1 control plane + 2 workers)
kubectl get nodes -o wide

# Helm is available
helm version --short

# iscsiadm must be present on every storage node
# SSH or exec into each node and run:
iscsiadm --version
# Expected output: iscsiadm version X.X.X
```

Longhorn's default V1 data engine calls `iscsiadm` directly on the host to manage iSCSI connections. If the binary is missing, `longhorn-manager` will crash on startup with:

```
failed to execute iscsiadm: No such file or directory
```

How `iscsiadm` gets onto a node depends on the OS. On Debian/Ubuntu nodes it comes from the `open-iscsi` package. On immutable OS distributions it must be included in the node image before boot — it cannot be installed at runtime.

If `longhorn-manager` is already in `CrashLoopBackOff`, fix the node prerequisite first, then restart the pods:

```bash
kubectl delete pod -n longhorn-system -l app=longhorn-manager
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
```

---

## Step 2 - Install the Longhorn controller

The `longhorn/` wrapper chart declares Longhorn as a Helm dependency, pins the version, and makes installs reproducible.

```
longhorn/
├── Chart.yaml    ← declares longhorn as a dependency (version 1.11.0)
├── values.yaml   ← default configuration for a local cluster
└── templates/
    ├── namespace.yaml  ← creates longhorn-system with required PSA labels
    └── route.yaml      ← HTTPRoute for Longhorn UI (requires Phase 06)
```

```bash
# Add Longhorn Helm repository
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Download dependency into charts/
helm dependency update ./longhorn

# Install Longhorn in its own namespace
helm upgrade --install cluster-longhorn ./longhorn \
  -n longhorn-system \
  --create-namespace

# Wait until all Longhorn pods are Running
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
kubectl get pods -n longhorn-system

# Confirm StorageClass is available
kubectl get storageclass | grep longhorn
# Expected: longhorn (default)
```

Your cluster might already have another default StorageClass. Because this phase explicitly sets `storageClassName: longhorn` in the PostgreSQL PVC, that is not fatal. If you want Longhorn to be the only default class, identify the existing default and patch it:

```bash
kubectl get storageclass
kubectl patch storageclass <existing-default-class> \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

> **Why use a wrapper chart?** Same reason as in Phase 04 for Sealed Secrets: version pinning in Git, pull request-driven updates, and reproducible installs across environments.

> **Why PSA labels on the namespace?** Longhorn DaemonSet pods need `privileged` access to mount block devices. Pod Security Admission labels on `longhorn-system` allow this. Without them, Kubernetes would block pod startup.

---

## Step 3 - Update todo-app to use Longhorn storage

The only required change is the StorageClass name in `values.yaml`. The PVC template already reads this value dynamically:

```yaml
# values.yaml - before
postgres:
  persistence:
    storageClassName: <previous-storage-class>   # old local or previous default class

# values.yaml - after
postgres:
  persistence:
    storageClassName: longhorn   # Distributed Longhorn storage
```

`postgres-deployment.yaml` also uses `subPath: pgdata` in the volume mount. This is required because Longhorn formats the volume root with a filesystem that can include a `lost+found` directory, which causes PostgreSQL initialization to fail. `subPath` makes PostgreSQL write to a clean subdirectory.

```yaml
# postgres-deployment.yaml
volumeMounts:
  - name: postgres-pvc
    mountPath: /var/lib/postgresql/data
    subPath: pgdata
```

---

## Step 4 - Publish app images to Docker Hub

Until the private registry phase is implemented, use Docker Hub as the external image registry. This replaces the old local-cluster flow where images were built locally and loaded into Minikube.

From the repository root:

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

Then update the answer chart values so Kubernetes pulls the images from Docker Hub instead of expecting local node images:

```yaml
# answer/todo-app/values.yaml
frontend:
  image:
    repository: "docker.io/<your-dockerhub-user>/todo-frontend"
    tag: "1.0.0"
  imagePullPolicy: IfNotPresent

backend:
  image:
    repository: "docker.io/<your-dockerhub-user>/todo-backend"
    tag: "1.0.0"
  imagePullPolicy: IfNotPresent
```

The Deployment templates do not need hardcoded image changes. They already read the image repository and tag from `values.yaml`:

```yaml
image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
```

---

## Step 5 - Deploy the updated todo-app

```bash
helm upgrade --install my-app ./todo-app \
  -n todo \
  --create-namespace \
  -f ./todo-app/values.yaml
```

---

## Step 6 - Verify

```bash
# PVC should be Bound to a Longhorn volume
kubectl get pvc -n todo
# Expected: my-app-todo-app-postgres-pvc   Bound   ...   longhorn

# Verify Longhorn volume was created
kubectl get volumes.longhorn.io -n longhorn-system

# All pods should be Running
kubectl get pods -n todo

# Inspect backend logs for DB connection errors
kubectl logs deploy/my-app-todo-app-backend -n todo --tail=100
```

To access the Longhorn UI before Phase 06 (Envoy Gateway), use port-forward:

```bash
kubectl port-forward svc/longhorn-frontend 8080:80 -n longhorn-system
# Open http://localhost:8080
```

---

## Troubleshooting checklist

- `iscsiadm --version` succeeds on every storage node before installing Longhorn
- `longhorn-manager` in `CrashLoopBackOff` with `failed to execute iscsiadm: No such file or directory` means the binary is missing from the node — fix the node, then delete the manager pods to let them restart
- Longhorn pods in `longhorn-system` are all Running (`kubectl get pods -n longhorn-system`)
- `longhorn` StorageClass exists (`kubectl get storageclass`)
- PVC is `Bound`; if it is `Pending`, inspect it: `kubectl describe pvc -n todo`
- `subPath: pgdata` is present in `postgres-deployment.yaml`; without it PostgreSQL init fails
- No stale PVCs from a previous install; delete and redeploy if you switched StorageClass

---

## Credential rotation

Longhorn is stateless from the application's perspective. Rotating DB credentials follows the same process as Phase 04 (re-seal with `kubeseal` and redeploy). The Longhorn volume persists through credential rotations.

---

## Additional exercises

These are optional, but they help you truly understand Longhorn behavior.

1. **Replica verification** - after deployment, open Longhorn UI, locate the PostgreSQL volume, and confirm replicas exist on each node. Compare "healthy" vs "degraded" states.
2. **Pod eviction test** - delete the PostgreSQL Pod. Observe Kubernetes rescheduling. Confirm PVC reattaches and data is intact (todos created before deletion still exist).
3. **Reclaim policy test** - set StorageClass `reclaimPolicy` to `Retain`, delete the PVC, and observe the Longhorn volume remains. Then delete it manually.
4. **Snapshot** - create a PostgreSQL volume snapshot in Longhorn UI. Insert test data. Delete the data. Restore from snapshot and confirm data returns.
5. **Single vs multiple replicas** - change `longhorn.persistence.defaultClassReplicaCount` in `values.yaml` and observe volume health in UI. Use `1` for a single-node lab; use `3` when you have at least three storage nodes.
6. **Node drain** - drain a node (`kubectl drain <node> --ignore-daemonsets`). Observe Longhorn rebuilding replicas on remaining nodes. Uncordon and observe rebalancing.

---

## Further reading

- [Longhorn documentation](https://longhorn.io/docs/latest/) - official docs covering all features
- [CSI specification](https://github.com/container-storage-interface/spec) - the interface Longhorn implements
- [Kubernetes storage documentation](https://kubernetes.io/docs/concepts/storage/) - deep dive into PV, PVC, and StorageClass

---

## Success criteria

- Longhorn controller installed with a Helm wrapper chart and all pods Running
- `longhorn` StorageClass available in the cluster
- `todo-app` `values.yaml` uses `storageClassName: longhorn`
- PostgreSQL deployment uses `subPath: pgdata` in volume mount
- PVC is `Bound` and backed by a Longhorn volume
- End-to-end deployment works: todos can be created and survive Pod restart
- Longhorn UI is reachable and volume shows healthy replicas
- Additional exercises completed and findings documented
