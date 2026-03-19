## Phase 02 — Kubernetes Application (Theory)

The goal of this phase is to **deploy the** [application](../../application) **with Kubernetes**, gaining an understanding of the essential resources needed for a typical web app (frontend + backend + database) to work properly inside a Kubernetes cluster.

- **Core concepts to master in this phase**:
  - **ConfigMaps**
  - **Secrets**
  - **PersistentVolumeClaims (PVCs)**

It's not just about “making it work”, but understanding **why** these Kubernetes objects exist and how they connect.

---

## 1. ConfigMaps

A **ConfigMap** stores **non-sensitive configuration**:

- URLs,
- database names,
- environment flags,
- plain-text configuration, etc.

In Docker Compose, env variables are store like:

```env
BACKEND_URL=http://backend:8080
POSTGRES_DB=app_db
```

In Kubernetes,is it possible:

- Store these values in a ConfigMap,
- Mount them as:
  - **environment variables** into the Pod, or
  - **files** in a directory inside the container.

Mental rules:

- **Non-secret config → ConfigMap**.
- **Secret config (passwords, tokens, keys) → Secret**.

Benefits:

- Separates **image** (your code) from **configuration**.
- You can change config without rebuilding images.

---

## 2. Secrets

A **Secret** stores **sensitive data**:

- database passwords,
- API tokens,
- certificates,
- JWT private keys, etc.

By default in Kubernetes:

- Data in Secrets is **base64-encoded** (not encrypted, just encoded).
- The cluster can integrate with stronger solutions (e.g., Sealed Secrets, Vault)—we'll see this in later phases.

Typical usage:

- Create a Secret with your database password.
- Reference the Secret in:
  - environment variables in your containers, or
  - files mounted as volumes.

Practical rule:

- **If you'd put it in `.env` but would be afraid to commit it to Git, it should go in a Secret.**

---

## 3. PersistentVolumeClaims (PVCs)

Pods are ephemeral: if a Pod is killed and recreated, **the container's local filesystem is lost**.

To keep data persistent (e.g., database data), you need:

- a **PersistentVolume (PV)**—cluster resource representing actual storage (local disk, NFS, cloud disk, etc.),
- a **PersistentVolumeClaim (PVC)**—a Pod's request to claim persistent storage.

In this phase, we'll mostly work with **PVCs**:

- specify how much storage is needed,
- define access mode (`ReadWriteOnce`, etc.),
- mount the PVC as a volume into the container (e.g., at `/var/lib/postgresql/data`).

How this maps to Docker Compose:

- `volumes` in Compose ≈ `PersistentVolume` + `PersistentVolumeClaim` + `volumeMounts` in the Pod.

---

## 4. How Everything Connects in Your App

For a classic **frontend + backend + database** app in Kubernetes:

- **Database (postgres):**
  - Deployment/StatefulSet (for now, Deployment is enough to understand the flow),
  - PVC for persistent data,
  - ClusterIP Service (`postgres`),
  - Secret for username/password.

- **Backend:**
  - Deployment (multiple replicas if needed),
  - ConfigMaps for non-secret config (e.g., DB name, Service host for Postgres),
  - Secrets for credentials,
  - ClusterIP Service (`backend`).

- **Frontend:**
  - Deployment,
  - ConfigMap for backend URL (if required at build/runtime),
  - ClusterIP Service (`frontend`).

Networking flow:

- `frontend` calls the `backend` Service,
- `backend` calls the `postgres` Service.

In this phase, **you don't expose anything externally** (no Ingress/LoadBalancer yet)—that's for the next phase.
---
