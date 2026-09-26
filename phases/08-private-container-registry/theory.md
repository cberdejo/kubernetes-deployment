# Phase 08 — Private Container Registry

Previous phases built and ran container images that were either pulled from public registries like Docker Hub or loaded directly into the node's container runtime. This works for learning, but in any real environment it creates problems: you depend on an external service's availability, you have no control over who can access your images, and there is no audit trail of what was deployed or when.

This phase adds a **private container registry** inside the cluster. Instead of pushing images to Docker Hub and pulling them from outside, images live next to the workloads that consume them. The registry becomes the single source of truth for every artifact the cluster runs — container images today, Helm charts tomorrow.

**Core concepts to master in this phase:**
- **Container registries**, what they store, how clients interact with them, and why they matter
- **The OCI Distribution Specification**, the standard protocol that makes registries interoperable
- **Image tagging and versioning**, how to identify and promote artifacts through environments
- **TLS trust chains for private registries**, why containerd rejects self-signed certs and how to fix it
- **Harbor architecture**, the components that make up an enterprise-grade registry
- **Harbor projects**, how access control scopes images into logical groups
- **OCI artifacts**, storing Helm charts and other non-image content in a registry

---

## Why a Private Registry Matters

Pulling from Docker Hub (or any public registry) is the default for most tutorials, but it introduces real operational risks once you move beyond a single developer's laptop:

**Rate limits and availability.** Docker Hub enforces [pull rate limits](https://docs.docker.com/docker-hub/usage/pulls/) — 100 pulls per 6 hours for anonymous users, 200 for authenticated free accounts. A cluster restarting its pods during an incident can exhaust these limits exactly when you need images most. A private registry inside your network has no such limits and no dependency on external DNS, TLS, or CDN availability.

**Supply chain visibility.** When a Deployment references `nginx:1.25`, you trust that Docker Hub still hosts the exact image you tested. But public tags are mutable — the publisher can push a different image under the same tag at any time. A private registry gives you control: you pull an image once, push it to your registry with a known digest, and every subsequent pull returns the exact bytes you verified.

**Access control.** Public registries are... public. Anyone can pull your images if they know the name. Proprietary application code, internal tooling, and images containing configuration should not be world-readable. A private registry lets you define who can push and pull, with audit logs for every operation.

**Network locality.** Pulling a 500 MB image from Docker Hub over the internet takes meaningfully longer than pulling it from a registry on the same LAN. For large images or frequent deployments, the difference adds up — and in air-gapped environments, external registries are simply unreachable.

**Regulatory and compliance requirements.** Many organizations require that production workloads only run images from approved registries. A private registry provides the control point: vulnerability scanning before images are made available, signed images with provenance metadata, and an immutable audit trail.

---

## Container Registries — The Basics

A container registry is an HTTP service that stores and distributes **OCI artifacts** — primarily container images, but increasingly also Helm charts, WASM modules, and other packaged content. The interaction model is simple:

```
Developer / CI pipeline                    Container Runtime (containerd, CRI-O)
        │                                            │
        │  docker push / crane push                  │  kubelet: pull image
        │  ──────────────────────►                   │  ──────────────────────►
        │                          ┌──────────────┐  │
        │                          │   Registry    │  │
        │                          │              │  │
        │                          │  ┌─────────┐ │  │
        │                          │  │ manifests│ │  │
        │                          │  │ blobs    │ │  │
        │                          │  │ tags     │ │  │
        │                          │  └─────────┘ │  │
        │                          └──────────────┘  │
        │  ◄──────────────────────                   │  ◄──────────────────────
        │  image digest (sha256:…)                   │  image layers
```

### What a registry stores

A container image is not a single file. It consists of:

- **A manifest** — a JSON document that lists the image's layers and configuration. The manifest's SHA-256 digest is the image's immutable identity.
- **Layers (blobs)** — compressed tar archives, each containing a diff of the filesystem. Layers are content-addressable: two images that share a layer store it only once.
- **A configuration object** — JSON metadata describing the image (environment variables, entrypoint, architecture, OS).
- **Tags** — human-readable pointers to manifests. `frontend:1.0.0` points to `sha256:abc123…`. Tags are mutable — the same tag can point to different manifests over time, which is why digests are the only truly immutable reference.

### How push and pull work

The registry API follows the [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec) (see next section). A simplified push flow:

1. **Check if the blob exists** — `HEAD /v2/<name>/blobs/<digest>`. If the registry already has this layer, skip the upload.
2. **Upload the blob** — `POST /v2/<name>/blobs/uploads/` starts an upload session, `PUT` completes it. The registry verifies the digest matches.
3. **Upload the manifest** — `PUT /v2/<name>/manifests/<reference>` with the manifest JSON. The reference can be a tag or a digest.

A pull flow:

1. **Resolve the tag to a manifest** — `GET /v2/<name>/manifests/<tag>` returns the manifest and its digest.
2. **Download missing layers** — for each layer in the manifest, `GET /v2/<name>/blobs/<digest>`. The container runtime checks its local cache first.
3. **Unpack and run** — the runtime assembles the filesystem from the layers and starts the container.

This is the same protocol whether the registry is Docker Hub, GitHub Container Registry, Harbor, or a minimal implementation like Zot. The OCI spec ensures interoperability.

---

## The OCI Standards

The [Open Container Initiative (OCI)](https://opencontainers.org/) defines three specifications that together standardize how containers are built, stored, and run:

| Specification | What it defines |
|---|---|
| **[Image Spec](https://github.com/opencontainers/image-spec)** | The format of container images: manifest, layers, configuration, and media types |
| **[Runtime Spec](https://github.com/opencontainers/runtime-spec)** | How a container is executed: filesystem bundle, lifecycle, and process configuration |
| **[Distribution Spec](https://github.com/opencontainers/distribution-spec)** | The HTTP API that registries implement: push, pull, list, and delete operations |

The Distribution Spec is the one most relevant to this phase. It defines the `/v2/` API that every compliant registry exposes. When you run `docker push harbor.local/todo/frontend:1.0.0`, Docker speaks the Distribution Spec protocol to Harbor's registry component. When containerd inside k3s pulls that image, it speaks the exact same protocol.

### OCI artifacts — beyond container images

The OCI Image Spec was designed for container images, but its manifest format is generic enough to store any content. The key insight: a manifest is just a list of blobs with metadata. If you change the `mediaType` field, you can store Helm charts, signatures, SBOMs, or anything else.

This is how `helm push` works with OCI registries. When you run:

```bash
helm push todo-app-0.1.0.tgz oci://harbor.local/todo
```

Helm packages the chart as an OCI artifact, uploads the chart tarball as a blob, and creates a manifest with Helm-specific media types. The registry stores it exactly like an image. `helm pull oci://harbor.local/todo/todo-app --version 0.1.0` reverses the process.

This means a single registry — Harbor, in our case — can serve as the artifact store for both container images and Helm charts. No separate chart repository (like ChartMuseum) is needed.

---

## Image Tagging and Versioning

Tags are how humans refer to images, but they are **mutable pointers**. Understanding tagging strategy is critical for production operations.

### Tag types

| Tag | Example | Use case | Risk |
|---|---|---|---|
| **Semantic version** | `frontend:1.2.3` | Release builds | Low — specific version, easy to audit |
| **Git SHA** | `frontend:a1b2c3d` | CI builds | Low — immutable reference to source |
| **latest** | `frontend:latest` | Development | High — no way to know which build it points to |
| **Branch name** | `frontend:main` | Staging/preview | Medium — changes with every push |

### The `latest` trap

`latest` is not a special tag — it is just a convention. Docker tags images as `latest` when no tag is specified. This creates problems:

- **Two developers push different code as `latest`** — the second overwrites the first with no warning.
- **`imagePullPolicy: Always`** is required to get new versions, which defeats caching and can hit rate limits.
- **Rollback is impossible** — there is no record of what `latest` pointed to yesterday.

### Recommended workflow

1. Build the image and tag it with both a semantic version and the git SHA:
   ```bash
   docker build -t frontend:1.2.0 -t frontend:$(git rev-parse --short HEAD) .
   ```
2. Push both tags to the registry:
   ```bash
   docker tag frontend:1.2.0 harbor.local/todo/frontend:1.2.0
   docker push harbor.local/todo/frontend:1.2.0
   ```
3. Update the Deployment to reference the new tag:
   ```bash
   helm upgrade my-app ./chart --set frontend.image.tag=1.2.0
   ```
4. To roll back, deploy the previous version:
   ```bash
   helm upgrade my-app ./chart --set frontend.image.tag=1.1.0
   ```

The registry retains all versions. The Deployment always references an explicit tag. Rollbacks are instant because the old image layers are already cached.

---

## TLS Trust for Private Registries

Container runtimes (containerd, CRI-O, Docker) refuse to pull images over HTTPS from registries whose TLS certificate is not trusted. In our homelab, certificates are issued by a private CA (cert-manager's `homelab-ca`), which is not in any system's default trust store.

This creates a chicken-and-egg problem: the cluster needs the CA to pull images, but the CA is managed by a tool running inside the cluster.

### The trust chain

```
cert-manager (in-cluster)
     │
     │  issues certificate for harbor.local
     │  signed by homelab-ca
     ▼
Gateway (Envoy) terminates TLS
     │
     │  HTTPS with homelab-ca cert
     ▼
containerd (on the node)
     │
     │  "I don't trust this CA" → pull fails
     │
     └─── FIX: install CA cert + configure registries.yaml
```

### What needs to trust the CA

| Component | Configuration | Purpose |
|---|---|---|
| **System trust store** | `/usr/local/share/ca-certificates/` + `update-ca-certificates` | `curl`, `helm`, and other CLI tools |
| **Docker daemon** | `/etc/docker/certs.d/harbor.local/ca.crt` | `docker push` / `docker pull` |
| **k3s containerd** | `/etc/rancher/k3s/registries.yaml` with `tls.ca_file` | Pod image pulls via kubelet |

### k3s `registries.yaml`

k3s uses a [registry configuration file](https://docs.k3s.io/installation/private-registry) at `/etc/rancher/k3s/registries.yaml` to configure containerd's registry mirrors and TLS settings:

```yaml
mirrors:
  harbor.local:
    endpoint:
      - "https://harbor.local"
configs:
  "harbor.local":
    tls:
      ca_file: "/etc/rancher/k3s/harbor-ca.crt"
```

- **`mirrors`** tells containerd where to find images for a given hostname. When a Pod requests `harbor.local/todo/frontend:1.0.0`, containerd uses this endpoint.
- **`configs.tls.ca_file`** points to the CA certificate that signed Harbor's TLS cert. Containerd uses it to verify the HTTPS connection.
- **k3s must be restarted** after modifying `registries.yaml` — containerd reads this file only at startup.

For registries that require authentication for pulls (private projects), you would also add:

```yaml
configs:
  "harbor.local":
    auth:
      username: robot$pull-account
      password: <token>
    tls:
      ca_file: "/etc/rancher/k3s/harbor-ca.crt"
```

In this phase, the Harbor project is public, so authentication is not needed for pulls — only for pushes.

---

## Harbor — The Registry

[Harbor](https://goharbor.io/) is an open-source, CNCF-graduated container registry. Originally created by VMware in 2016, it has become the de facto standard for self-hosted enterprise registries. It extends the basic OCI registry with access control, vulnerability scanning, image signing, replication, and a web UI.

### Architecture

Harbor is a multi-component system. In a Kubernetes deployment via the official Helm chart, these components run as separate pods:

```
┌──────────────────────────────────────────────────────────────┐
│                        nginx                                 │
│  (reverse proxy — routes /v2/ to registry, /api/ to core)    │
└────────────────────────┬─────────────────────────────────────┘
                         │
         ┌───────────────┼────────────────┐
         │               │                │
    ┌────▼─────┐   ┌─────▼──────┐   ┌────▼──────┐
    │   Core   │   │  Registry  │   │   Portal  │
    │          │   │  (Docker   │   │  (React   │
    │  API,    │   │  Distribu- │   │   web UI) │
    │  auth,   │   │  tion)     │   │           │
    │  projects│   │            │   │           │
    └────┬─────┘   └────────────┘   └───────────┘
         │
    ┌────┼──────────────┐
    │    │              │
┌───▼──┐ ┌──▼────────┐  ┌──▼───┐
│ DB   │ │ Job Service│  │ Redis│
│(PG)  │ │ (async     │  │      │
│      │ │  tasks)    │  │      │
└──────┘ └───────────┘  └──────┘
```

| Component | Role |
|---|---|
| **nginx** | Front door. Routes `/v2/*` to the Docker Distribution registry, `/api/*` to Core, and `/` to the Portal UI. In our setup, TLS terminates at Envoy Gateway, so nginx handles only HTTP internally. |
| **Core** | The brain. Handles authentication, authorization, project management, webhook notifications, and the REST API (`/api/v2.0/*`). Every operation — push, pull, delete, scan — goes through Core for access control. |
| **Registry** | A standard Docker Distribution registry (the same open-source project that Docker Hub uses). It stores and serves image manifests and blobs. Core sits in front of it to enforce permissions. |
| **Portal** | A React single-page application. The web UI for managing projects, images, users, robot accounts, and replication rules. |
| **Job Service** | Executes asynchronous tasks: garbage collection, replication between registries, vulnerability scanning, and webhook delivery. |
| **PostgreSQL** | Stores all metadata: projects, users, access logs, scan results, replication policies. Images themselves are not in the database — they live in the registry's storage backend. |
| **Redis** | Session cache, temporary job data, and rate limiting. |
| **Trivy** (optional) | Vulnerability scanner. When enabled, it scans every pushed image for known CVEs and displays results in the UI. Disabled in this phase to reduce resource usage. |

### Harbor's service name

The Helm chart's `expose.clusterIP.name` field controls the Kubernetes Service name for Harbor's nginx component. In our setup:

```yaml
harbor:
  expose:
    type: clusterIP
    clusterIP:
      name: harbor
```

This creates a Service named `harbor` on port 80 — the backend for the HTTPRoute. This is **not** prefixed with the Helm release name because Harbor's chart uses the `name` field directly.

### How a push flows through Harbor

```
docker push harbor.local/todo/frontend:1.0.0
     │
     ▼
Envoy Gateway (TLS termination)
     │ HTTP → harbor:80
     ▼
nginx (Harbor's internal proxy)
     │ /v2/todo/frontend/… → Registry
     │ token auth check → Core
     ▼
Core: "Does this user have push permission on project 'todo'?"
     │ YES → issue a short-lived token
     ▼
Registry: receives blobs and manifest
     │ stores in PVC (registry PersistentVolumeClaim)
     ▼
Core: records metadata in PostgreSQL
     │ triggers scan job if Trivy is enabled
```

---

## Harbor Projects

A **project** is Harbor's unit of access control and organization. Every image lives inside a project:

```
harbor.local / todo    / frontend : 1.0.0
               ▲         ▲          ▲
               project    repository  tag
```

### Public vs. private projects

| | **Public project** | **Private project** |
|---|---|---|
| **Pull** | Anyone can pull without authentication | Requires valid credentials or robot account |
| **Push** | Requires authentication | Requires authentication |
| **k3s config** | Only `tls.ca_file` needed in `registries.yaml` | Also needs `auth.username` / `auth.password` in `registries.yaml`, or a Kubernetes `imagePullSecret` |
| **Use case** | Internal images shared across teams, open-source builds | Proprietary code, pre-release images |

In this phase, the project is **public** — this simplifies the k3s configuration because containerd can pull without credentials. In production, you would use a private project with a **robot account** (a service account with scoped, revocable credentials) for pull access.

### Robot accounts

Robot accounts are Harbor's way of providing programmatic access without sharing human user credentials:

- **Scoped to a project** — a robot account can only access the projects it is assigned to.
- **Limited permissions** — you can grant pull-only, push-only, or both.
- **Token-based** — the credential is a long-lived token, not a password. Revoke the token without affecting human users.
- **Named with a prefix** — `robot$my-puller` makes it obvious in audit logs that this was an automated pull, not a human.

---

## Alternatives to Harbor

### Docker Hub

[Docker Hub](https://hub.docker.com/) is the default public registry. For private images, it offers paid tiers with team management, automated builds, and vulnerability scanning.

**Strengths:** ubiquitous (every tool knows how to talk to it), CDN-backed for fast pulls worldwide, official images curated and scanned.

**Limitations:** rate limits on free accounts, data lives outside your network, no self-hosting option, limited access control granularity.

**When to use:** public open-source images, small teams that do not need to self-host, CI pipelines that push to a known public location.

### GitHub Container Registry (GHCR)

[GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) integrates directly with GitHub repositories. Images live alongside the code that produces them.

**Strengths:** free for public images, integrates with GitHub Actions, permissions inherit from the repository, no separate account needed.

**Limitations:** tied to GitHub, rate limits on free usage, not self-hosted, limited visibility and management UI compared to Harbor.

**When to use:** GitHub-based projects that want CI/CD integration without a separate registry, open-source projects.

### Zot

[Zot](https://zotregistry.dev/) is a lightweight, OCI-native registry written in Go. It focuses on the OCI Distribution Spec and nothing else — no web UI, no user management, no scanning.

**Strengths:** minimal footprint (single binary, ~30 MB memory), fully OCI-compliant, supports OCI artifacts natively, designed for edge and IoT use cases.

**Limitations:** no built-in UI, no user management (relies on external auth), no scanning, no replication.

**When to use:** environments where you need a fast, minimal registry and handle auth/scanning externally. Good for edge deployments or as a pull-through cache.

### Docker Distribution (CNCF Distribution)

[Distribution](https://distribution.github.io/distribution/) is the open-source registry that Docker Hub and Harbor both build on. It is a CNCF project (sandbox). You can deploy it standalone as a pure OCI registry.

**Strengths:** the reference implementation of the Distribution Spec, lightweight, battle-tested (it powers Docker Hub's backend).

**Limitations:** no UI, no access control (beyond token auth), no scanning, no project organization. It is a building block, not a product.

**When to use:** when you want a raw registry to build on, or as a pull-through cache for Docker Hub.

### Comparison at a glance

| | **Harbor** | **Docker Hub** | **GHCR** | **Zot** | **Distribution** |
|---|---|---|---|---|---|
| **Type** | Self-hosted | SaaS | SaaS | Self-hosted | Self-hosted |
| **CNCF** | Graduated | — | — | — | Sandbox |
| **Web UI** | Full | Full | GitHub UI | None | None |
| **Vulnerability scanning** | Trivy (built-in) | Paid tier | Dependabot | External | None |
| **Access control** | RBAC + robot accounts | Teams (paid) | GitHub permissions | External | Token auth |
| **OCI artifacts** | Yes | Yes | Yes | Yes (native) | Yes |
| **Replication** | Yes (multi-registry) | No | No | Sync | No |
| **Footprint** | ~500 MB+ (multi-pod) | — | — | ~30 MB | ~50 MB |
| **Best for** | Enterprise self-hosted | Public images | GitHub workflows | Minimal / edge | Building block |

---

## How Harbor Fits Into the Cluster

In our architecture, Harbor follows the same pattern as every other service:

```
Browser / Docker CLI / containerd
     │
     ▼
Envoy Gateway (TLS termination, harbor.local)
     │  HTTPRoute → harbor:80
     ▼
Harbor (nginx → Core / Registry / Portal)
     │
     ▼
Longhorn PVCs (image layers, database, redis)
```

- **No authentik forward-auth** on Harbor. Unlike Longhorn, Harbor has its own authentication system (the Core component handles user login, token issuance, and API auth). Adding a `SecurityPolicy` with ext-auth would break the Docker registry API protocol — `docker push` and `docker pull` use HTTP-level token negotiation (`401 → GET /service/token → retry with Bearer`), which is incompatible with redirect-based forward auth.
- **ClusterIP + HTTPRoute**, the same pattern as authentik and Longhorn. TLS terminates at Envoy; Harbor sees plain HTTP internally.
- **Longhorn storage** for all persistent data. Image layers, the PostgreSQL database, and Redis all use Longhorn PVCs, so data survives pod restarts and node rescheduling.

---

## Further Reading

- **[Harbor documentation](https://goharbor.io/docs/)** — official docs covering installation, configuration, and administration
- **[Harbor architecture overview](https://goharbor.io/docs/2.12.0/install-config/harbor-components/)** — detailed breakdown of each component and how they interact
- **[OCI Distribution Specification](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)** — the HTTP API standard that all registries implement
- **[OCI Image Specification](https://github.com/opencontainers/image-spec/blob/main/spec.md)** — how container images are structured (manifests, layers, config)
- **[k3s Private Registry Configuration](https://docs.k3s.io/installation/private-registry)** — how to configure containerd to use private registries in k3s
- **[Harbor Helm Chart](https://github.com/goharbor/harbor-helm)** — the official Helm chart used to deploy Harbor on Kubernetes
- **[CNCF Harbor graduation announcement](https://www.cncf.io/announcements/2020/06/23/cloud-native-computing-foundation-announces-harbor-graduation/)** — context on Harbor's place in the cloud-native ecosystem
- **[Helm OCI support](https://helm.sh/docs/topics/registries/)** — how Helm stores and retrieves charts in OCI-compliant registries
- **[crane — go-containerregistry](https://github.com/google/go-containerregistry/tree/main/cmd/crane)** — lightweight CLI for interacting with registries without a Docker daemon
- **[Docker Hub rate limits](https://docs.docker.com/docker-hub/usage/pulls/)** — official documentation on pull rate limits and how to avoid them
- **[Zot registry](https://zotregistry.dev/)** — documentation for the lightweight OCI-native alternative
