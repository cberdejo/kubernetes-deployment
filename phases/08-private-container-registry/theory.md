# Phase 08 - Private Container Registry

Previous phases pulled container images from public registries or loaded them directly into the node's runtime. This works for learning, but creates real problems: dependency on external availability, no control over who accesses your images, and no audit trail of what was deployed.

This phase adds a **private container registry** inside the cluster. Images live next to the workloads that consume them, and the registry becomes the single source of truth for every artifact, container images and Helm charts alike.

**Core concepts to master in this phase:**
- **Container registries**, what they store and how clients interact with them
- **The OCI Distribution Specification**, the protocol that makes registries interoperable
- **Image tagging and versioning**, how to identify and promote artifacts through environments
- **TLS trust chains**, why containerd rejects self-signed certs and how to fix it
- **Harbor**, the components that make up an enterprise-grade registry
- **OCI artifacts**, storing Helm charts and other non-image content in a registry

---

## Why a Private Registry Matters

**Rate limits and availability.** Docker Hub enforces [pull rate limits](https://docs.docker.com/docker-hub/usage/pulls/), 100 pulls per 6 hours for anonymous users, 200 for authenticated free accounts. A cluster restarting pods during an incident can exhaust these limits exactly when you need images most.

**Supply chain visibility.** Public tags are mutable, the publisher can push a different image under the same tag at any time. A private registry gives you control: pull an image once, push it with a known digest, and every subsequent pull returns the exact bytes you verified.

**Access control and compliance.** A private registry lets you define who can push and pull, with audit logs for every operation. Many organizations require that production workloads only run images from approved, scanned registries.

**Network locality.** Pulling from a registry on the same LAN is faster than from Docker Hub, and in air-gapped environments, external registries are simply unreachable.

---

## Container Registries - The Basics

A container registry is an HTTP service that stores and distributes **OCI artifacts**, primarily container images, but also Helm charts, WASM modules, and other packaged content.

### What a registry stores

A container image is not a single file. It consists of:

- **A manifest**, a JSON document listing the image's layers and configuration. Its SHA-256 digest is the image's immutable identity.
- **Layers (blobs)**, compressed tar archives containing filesystem diffs. Content-addressable: two images sharing a layer store it only once.
- **A configuration object**, JSON metadata (environment variables, entrypoint, architecture, OS).
- **Tags**, mutable, human-readable pointers to manifests. `frontend:1.0.0` points to `sha256:abc123…`, but the same tag can be reassigned at any time, digests are the only truly immutable reference.

### How push and pull work

The registry API follows the [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec). A push checks whether each layer already exists, uploads missing blobs, then uploads the manifest. A pull resolves the tag to a manifest, downloads missing layers, and assembles the filesystem. This is the same protocol whether the registry is Docker Hub, Harbor, GHCR, or Zot.

---

## The OCI Standards

The [Open Container Initiative (OCI)](https://opencontainers.org/) defines three specifications:

| Specification | What it defines |
|---|---|
| **[Image Spec](https://github.com/opencontainers/image-spec)** | The format of container images: manifest, layers, configuration, and media types |
| **[Runtime Spec](https://github.com/opencontainers/runtime-spec)** | How a container is executed: filesystem bundle, lifecycle, and process configuration |
| **[Distribution Spec](https://github.com/opencontainers/distribution-spec)** | The HTTP API that registries implement: push, pull, list, and delete operations |

The Distribution Spec is the most relevant here, it defines the `/v2/` API that every compliant registry exposes.

### OCI artifacts - beyond container images

The manifest format is generic enough to store any content. A manifest is just a list of blobs with metadata, change the `mediaType` field and you can store Helm charts, signatures, SBOMs, or anything else.

This is how `helm push` works with OCI registries: Helm packages the chart as an OCI artifact and uploads it with Helm-specific media types. A single registry can serve both container images and Helm charts, no separate chart repository (like ChartMuseum) needed.

---

## Image Tagging and Versioning

Tags are how humans refer to images, but they are **mutable pointers**. Understanding tagging strategy is critical for production operations.

| Tag | Example | Use case | Risk |
|---|---|---|---|
| **Semantic version** | `frontend:1.2.3` | Release builds | Low, specific, auditable |
| **Git SHA** | `frontend:a1b2c3d` | CI builds | Low, immutable source reference |
| **latest** | `frontend:latest` | Development | High, no traceability |
| **Branch name** | `frontend:main` | Staging/preview | Medium, changes with every push |

### The `latest` trap

`latest` is not special, it is just a convention. Docker tags images as `latest` when no tag is specified. Two developers pushing different code as `latest` overwrite each other silently. `imagePullPolicy: Always` is required to get new versions (defeating caching), and rollback is impossible because there is no record of what `latest` pointed to yesterday.

**Best practice:** always tag with a semantic version (and optionally the git SHA). The registry retains all versions, the Deployment references an explicit tag, and rollbacks are instant because old layers are already cached.

---

## TLS Trust for Private Registries

Container runtimes (containerd, CRI-O, Docker) refuse to pull from registries whose TLS certificate is not trusted. In our homelab, certificates are issued by a private CA (`homelab-ca`), which is not in any system's default trust store.

Three components need to trust the CA:

| Component | Configuration | Purpose |
|---|---|---|
| **System trust store** | `/usr/local/share/ca-certificates/` + `update-ca-certificates` | `curl`, `helm`, and other CLI tools |
| **Docker daemon** | `/etc/docker/certs.d/harbor.local/ca.crt` | `docker push` / `docker pull` |
| **k3s containerd** | `/etc/rancher/k3s/registries.yaml` with `tls.ca_file` | Pod image pulls via kubelet |

k3s uses a [registry configuration file](https://docs.k3s.io/installation/private-registry) at `/etc/rancher/k3s/registries.yaml` to configure containerd's registry mirrors and TLS settings. k3s must be restarted after modifying this file, containerd reads it only at startup.

---

## Harbor - The Registry

[Harbor](https://goharbor.io/) is a CNCF-graduated, open-source container registry originally created by VMware in 2016. It extends a standard OCI registry with access control, vulnerability scanning, image signing, replication, and a web UI.

Harbor runs as a multi-component system, each component is a separate pod when deployed via the official Helm chart:

| Component | Role |
|---|---|
| **nginx** | Internal reverse proxy. Routes `/v2/*` to Registry, `/api/*` to Core, `/` to Portal |
| **Core** | Authentication, authorization, project management, REST API. Every push/pull goes through Core for access control |
| **Registry** | Standard Docker Distribution registry, stores and serves manifests and blobs |
| **Portal** | React web UI for managing projects, images, users, and robot accounts |
| **Job Service** | Async tasks: garbage collection, replication, scanning, webhooks |
| **PostgreSQL** | All metadata, projects, users, access logs, scan results. Images are not in the DB |
| **Redis** | Session cache, job data, rate limiting |
| **Trivy** (optional) | Vulnerability scanner, scans pushed images for known CVEs |

### Harbor projects

A **project** is Harbor's unit of access control. Every image lives inside a project: `harbor.local/todo/frontend:1.0.0`, where `todo` is the project, `frontend` the repository, and `1.0.0` the tag.

Projects can be **public** (anyone can pull, push requires auth) or **private** (both pull and push require credentials). For private projects, k3s needs auth credentials in `registries.yaml` or a Kubernetes `imagePullSecret`.

### Robot accounts

Robot accounts provide programmatic access without sharing human credentials. They are scoped to specific projects, support limited permissions (pull-only, push-only, or both), use token-based credentials, and are named with a `robot$` prefix for easy identification in audit logs.

---

## Alternatives to Harbor

### Docker Hub

The default public registry. Ubiquitous and CDN-backed, but rate-limited on free accounts, not self-hostable, and limited access control. Best for public open-source images.

### GitHub Container Registry (GHCR)

[GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) integrates with GitHub repositories, permissions inherit from the repo, free for public images. Tied to GitHub and not self-hosted. Best for GitHub-based projects.

### Zot

A [lightweight OCI-native registry](https://zotregistry.dev/) written in Go (~30 MB memory). No UI, user management, or scanning, just the Distribution Spec. Best for edge deployments or as a pull-through cache.

### Docker Distribution (CNCF Distribution)

The [open-source registry](https://distribution.github.io/distribution/) that Docker Hub and Harbor both build on (CNCF sandbox). A raw building block with no UI or access control.

### Comparison at a glance

| | **Harbor** | **Docker Hub** | **GHCR** | **Zot** | **Distribution** |
|---|---|---|---|---|---|
| **Type** | Self-hosted | SaaS | SaaS | Self-hosted | Self-hosted |
| **CNCF** | Graduated |, |, |, | Sandbox |
| **Web UI** | Full | Full | GitHub UI | None | None |
| **Vulnerability scanning** | Trivy | Paid tier | Dependabot | External | None |
| **Access control** | RBAC + robot accounts | Teams (paid) | GitHub permissions | External | Token auth |
| **OCI artifacts** | Yes | Yes | Yes | Yes (native) | Yes |
| **Replication** | Multi-registry | No | No | Sync | No |
| **Footprint** | ~500 MB+ |, |, | ~30 MB | ~50 MB |
| **Best for** | Enterprise self-hosted | Public images | GitHub workflows | Minimal / edge | Building block |

---

## Further Reading

- **[Harbor documentation](https://goharbor.io/docs/)**, official docs covering installation, configuration, and administration
- **[Harbor architecture overview](https://goharbor.io/docs/2.12.0/install-config/harbor-components/)**, detailed breakdown of each component
- **[OCI Distribution Specification](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)**, the HTTP API standard that all registries implement
- **[OCI Image Specification](https://github.com/opencontainers/image-spec/blob/main/spec.md)**, how container images are structured
- **[k3s Private Registry Configuration](https://docs.k3s.io/installation/private-registry)**, how to configure containerd for private registries
- **[Harbor Helm Chart](https://github.com/goharbor/harbor-helm)**, the official Helm chart for Kubernetes deployment
- **[CNCF Harbor graduation announcement](https://www.cncf.io/announcements/2020/06/23/cloud-native-computing-foundation-announces-harbor-graduation/)**, context on Harbor's place in the cloud-native ecosystem
- **[Helm OCI support](https://helm.sh/docs/topics/registries/)**, how Helm stores and retrieves charts in OCI registries
- **[crane](https://github.com/google/go-containerregistry/tree/main/cmd/crane)**, lightweight CLI for interacting with registries without a Docker daemon
- **[Docker Hub rate limits](https://docs.docker.com/docker-hub/usage/pulls/)**, official documentation on pull rate limits
- **[Zot registry](https://zotregistry.dev/)**, documentation for the lightweight OCI-native alternative
