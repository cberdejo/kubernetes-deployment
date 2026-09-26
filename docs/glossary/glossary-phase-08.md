# Glossary - Phase 08: Private Container Registry

### Container Registry

An HTTP service that stores and distributes OCI artifacts, primarily container images, but also Helm charts and other packaged content.
Clients interact with it via the OCI Distribution Specification: `docker push` uploads images, and container runtimes like containerd pull them to run workloads.

---

### OCI (Open Container Initiative)

A Linux Foundation project that defines three open standards for containers: the Image Spec (image format), the Runtime Spec (how containers execute), and the Distribution Spec (the registry HTTP API).
These specifications ensure interoperability, the same image works across Docker, containerd, CRI-O, and any compliant registry.

---

### OCI Distribution Specification

The HTTP API standard that all compliant container registries implement under the `/v2/` path.
It defines how clients push, pull, list, and delete artifacts. When you run `docker push`, Docker speaks this protocol, the same protocol whether the target is Docker Hub, Harbor, GHCR, or Zot.

---

### OCI Artifact

Any content stored in an OCI-compliant registry using the manifest/blob format, not limited to container images.
By changing the `mediaType` field in the manifest, registries can store Helm charts, signatures, SBOMs, or WASM modules. This is how `helm push` works with OCI registries.

---

### Image Manifest

A JSON document that lists a container image's layers, configuration, and media types. Its SHA-256 digest is the image's immutable identity.
Tags point to manifests, since tags are mutable, the manifest digest is the only truly reliable reference to a specific image.

---

### Image Layer (Blob)

A compressed tar archive containing a diff of the container filesystem. Layers are content-addressable by their SHA-256 digest.
Two images that share a layer store it only once in the registry, making pushes and pulls more efficient.

---

### Image Tag

A human-readable label that points to a specific image manifest in the registry (e.g., `frontend:1.0.0`).
Tags are mutable, the same tag can be reassigned to a different manifest at any time, which is why digests are the only immutable reference.

---

### Image Digest

An immutable, content-addressable identifier for an image manifest, expressed as `sha256:<hash>`.
Unlike tags, a digest always refers to exactly the same image bytes. Referencing images by digest guarantees reproducibility.

---

### Harbor

A CNCF-graduated, open-source container registry that extends the basic OCI registry with access control, vulnerability scanning (Trivy), replication, robot accounts, and a web UI.
It runs as a multi-component system: nginx (proxy), Core (auth and API), Registry (Docker Distribution), Portal (React UI), Job Service (async tasks), PostgreSQL, and Redis.

---

### Harbor Project

Harbor's unit of access control and image organization. Every image lives inside a project (e.g., `harbor.local/todo/frontend:1.0.0`, `todo` is the project).
Projects can be public (anyone can pull) or private (credentials required for pulls), and access is managed per project.

---

### Robot Account

A Harbor service account designed for programmatic access, CI pipelines, k3s containerd, or automation scripts.
Robot accounts are scoped to specific projects with limited permissions (pull-only, push-only, or both), use token-based credentials, and are named with a `robot$` prefix for easy identification in audit logs.

---

### Harbor Core

The central component of Harbor that handles authentication, authorization, project management, webhook notifications, and the REST API (`/api/v2.0/*`).
Every push and pull operation passes through Core for access control before reaching the underlying Docker Distribution registry.

---

### Harbor Registry

The Docker Distribution registry embedded inside Harbor that stores and serves image manifests and blobs.
It is the same open-source registry project that Docker Hub uses. Harbor's Core sits in front of it to enforce project-level permissions.

---

### Trivy

An open-source vulnerability scanner integrated into Harbor that scans every pushed image for known CVEs.
When enabled, scan results are displayed in the Harbor UI alongside each image tag, providing visibility into supply chain risks before images reach production.

---

### `externalURL` (Harbor)

A Harbor configuration field that specifies the URL clients use to reach the registry from outside the cluster (e.g., `https://harbor.local`).
Harbor uses this to generate Docker registry token URLs and OAuth redirect URLs. If it does not match the actual hostname, `docker login` and `docker push` fail with authentication errors.

---

### `registries.yaml` (k3s)

A configuration file at `/etc/rancher/k3s/registries.yaml` that tells k3s's embedded containerd how to reach private registries.
It defines mirrors (which endpoint to use for a given hostname) and TLS/auth settings. k3s must be restarted after modifying this file because containerd reads it only at startup.

---

### CA Trust Store

The system-wide directory (`/usr/local/share/ca-certificates/` on Debian/Ubuntu) where trusted Certificate Authority certificates are installed.
After adding a CA certificate, running `update-ca-certificates` updates the trust store so that CLI tools like `curl`, `helm`, and `docker` accept certificates signed by that CA.

---

### Docker `certs.d`

A Docker-specific directory at `/etc/docker/certs.d/<registry-hostname>/` where per-registry CA certificates are installed.
Placing the homelab CA certificate as `ca.crt` in this directory allows `docker push` and `docker pull` to trust the private registry's TLS certificate.

---

### `docker tag`

A Docker CLI command that creates a new tag for an existing local image, typically to add the registry hostname and project path before pushing.
For example, `docker tag frontend:1.0.0 harbor.local/todo/frontend:1.0.0` prepares the image for pushing to Harbor's `todo` project.

---

### `docker push` / `docker pull`

Docker CLI commands that upload and download container images to and from a registry using the OCI Distribution Specification protocol.
A push uploads blobs (layers) and the manifest; a pull resolves a tag to a manifest, downloads missing layers, and assembles the filesystem locally.

---

### `helm push` (OCI)

A Helm CLI command that packages a chart as an OCI artifact and uploads it to an OCI-compliant registry.
The chart tarball becomes a blob, and Helm creates a manifest with Helm-specific media types. This eliminates the need for a separate chart repository like ChartMuseum.

---

### Supply Chain Visibility

The ability to trace every artifact running in a cluster back to its source, knowing exactly what image bytes a pod is running and where they came from.
Public registry tags are mutable (the publisher can overwrite them), so a private registry with known digests provides a verifiable chain of custody.

---

### Rate Limiting (Docker Hub)

Restrictions on how many image pulls a user can perform within a time window, Docker Hub allows 100 pulls per 6 hours for anonymous users, 200 for authenticated free accounts.
A private registry eliminates this dependency, ensuring image availability during incidents when pods restart frequently.

---

### Pull-Through Cache

A registry feature where the registry acts as a transparent proxy for an upstream registry (e.g., Docker Hub).
The first pull fetches the image from upstream and caches it locally; subsequent pulls are served from the cache, reducing external traffic and avoiding rate limits.

---

### Zot

A lightweight, OCI-native container registry written in Go (~30 MB memory) that focuses solely on the OCI Distribution Spec.
It has no built-in UI, user management, or scanning, ideal for edge deployments, IoT, or as a minimal pull-through cache.

---

### Docker Distribution (CNCF Distribution)

The open-source registry implementation (CNCF sandbox) that Docker Hub and Harbor both build upon.
It provides a raw, standards-compliant OCI registry with no UI or access control, a building block rather than a product.
