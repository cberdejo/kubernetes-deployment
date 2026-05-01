# Kubernetes Learning Roadmap

This repository tracks a practical learning journey to build a modern Kubernetes-based platform.

## End Goal

Deploy and operate real-world applications using:

- Kubernetes
- Helm
- Argo CD (GitOps)
- Harbor (private container registry)
- Prometheus + Grafana + Loki + Alloy (observability)
- Sealed Secrets (secure secret management)
- Envoy Gateway + cert-manager (routing and TLS)
- authentik (identity provider and SSO)

By the end of the roadmap, the platform should be structured and operated with production-ready practices.

## Learning Approach

The roadmap is divided into incremental phases, starting with local container orchestration and progressing to a complete Kubernetes platform.

---

## Learning Phases

### Phase 00 - Local Docker Compose

**Objective**

- Understand the application architecture
- Understand how containers communicate
- Work with environment variables
- Understand data persistence

**Technologies**

- Docker
- Docker Compose
- Container networking

**Expected Outcome**

Run the full application locally with:

- Frontend
- Backend
- PostgreSQL

---

### Phase 01 - Kubernetes Basics

**Objective**

- Set up a local Kubernetes cluster (Minikube)
- Understand Pods
- Understand Deployments
- Understand Services
- Use `kubectl` effectively

**Technologies**

- Kubernetes
- Minikube
- `kubectl`

**Expected Outcome**

Understand core Kubernetes resources and operate a local cluster confidently.

---

### Phase 02 - Kubernetes Application

**Objective**

- Deploy the [application](../application/) in Kubernetes
- Model application components as Kubernetes resources

**Technologies**

- Deployments
- Services
- ConfigMaps
- Secrets
- PersistentVolumeClaims

**Expected Outcome**

Run the application on Kubernetes with configuration, networking, and persistence managed natively by the cluster.

---

### Phase 03 - Package Management and Templating

**Objective**

- Stop writing repetitive static YAML
- Learn to package and configure applications dynamically
- Prepare to install and manage third-party tools consistently

**Technologies**

- Helm

**Expected Outcome**

Deploy applications through reusable and configurable Helm charts.

---

### Phase 04 - Secure Secrets Management

**Objective**

- Encrypt passwords, tokens, and certificates
- Store encrypted secrets safely in source control

**Technologies**

- Sealed Secrets (Bitnami)

**Expected Outcome**

Manage secrets through Git without exposing sensitive values in plaintext.

---

### Phase 05 - Distributed Persistent Storage

**Objective**

- Provide resilient cluster storage
- Ensure stateful applications keep data across Pod restarts and rescheduling

**Technologies**

- Longhorn

**Expected Outcome**

Use persistent volumes backed by distributed storage for Kubernetes workloads.

---

### Phase 06 - Routing and Traffic Exposure

**Objective**

- Centralize and secure external traffic management
- Replace manual `NodePort` exposure with domain-based routing policies
- Terminate TLS automatically with signed certificates

**Technologies**

- Envoy Gateway
- Kubernetes Gateway API
- cert-manager (automatic TLS via Let's Encrypt or self-signed CA)
- MetalLB (bare metal / on-prem clusters only — provides `LoadBalancer` IPs without a cloud provider)

**Expected Outcome**

Expose services through managed HTTPS routing with automatic certificate provisioning. On bare metal clusters, MetalLB replaces the cloud load balancer so `LoadBalancer` services get real IPs.

---

### Phase 07 - Identity and Access Management

**Objective**

- Centralize authentication and access control
- Add SSO to the application using a dedicated identity provider
- Protect internal platform UIs such as Longhorn behind authenticated access

**Technologies**

- authentik
- OpenID Connect (OIDC)
- OAuth2
- Forward auth / identity-aware proxy patterns

**Expected Outcome**

Use authentik as the platform identity provider, with application login and protected access to internal services such as the Longhorn UI.

---

### Phase 08 - Private Container Registry

**Objective**

- Host container images privately inside your infrastructure
- Reduce dependency on public registries

**Technologies**

- Harbor
- Longhorn (persistent image storage)

**Expected Outcome**

Build, store, and pull private images reliably from an internal registry.

---

### Phase 09 - Automation and GitOps

**Objective**

- Eliminate manual deployments
- Use Git as the single source of truth for cluster state

**Technologies**

- Argo CD
- Git (GitHub/GitLab)

**Expected Outcome**

Automatically synchronize cluster configuration from version-controlled manifests.

---

### Phase 10 - Observability and Monitoring

**Objective**

- Gain visibility into health, performance, and resource usage
- Collect and query both metrics and logs from a single platform
- Integrate monitoring as part of the GitOps workflow

**Technologies**

- `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager)
- Loki (log aggregation)
- Grafana Alloy (unified collector — ships logs to Loki and metrics to Prometheus)
- metrics-server (prerequisite — enables `kubectl top` and Horizontal Pod Autoscaler)

**Expected Outcome**

Operate the platform with metrics, logs, dashboards, and alerting. Query application logs and cluster metrics from a single Grafana instance. Understand the full observability stack: collect → store → query → alert.
