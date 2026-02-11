
`kubernetes` `argocd` `longhorn` `docker` `harbor`
# Kubernetes Studying

## Table of Contents

- [Introduction](#introduction)
- [Technologies](#technologies)
  - [Kubernetes](#kubernetes)
  - [ArgoCD](#argocd)
  - [Longhorn](#longhorn)
  - [Docker](#docker)
  - [Harbor](#harbor)
- [How They Work Together](#how-they-work-together)
- [Installation Guide](#installation-guide)
  - [Prerequisites](#prerequisites)
  - [Installing Kubernetes](#installing-kubernetes)
  - [Installing Docker](#installing-docker)
  - [Installing ArgoCD](#installing-argocd)
  - [Installing Longhorn](#installing-longhorn)
  - [Installing Harbor](#installing-harbor)


## Introduction

This repository is a comprehensive guide for studying and implementing a production-grade Kubernetes stack. It covers the essential technologies needed to build, deploy, and manage containerized applications with a focus on GitOps practices, persistent storage, and container registry management.

---

## Technologies

### Kubernetes

**Kubernetes** (K8s) is an open-source container orchestration platform originally developed by Google. It automates the deployment, scaling, and management of containerized applications.

**Key Features:**
- **Container Orchestration:** Manages containers across multiple hosts
- **Self-Healing:** Automatically restarts failed containers and reschedules them on healthy nodes
- **Service Discovery & Load Balancing:** Built-in DNS and load balancing for services
- **Automated Rollouts & Rollbacks:** Progressively rolls out changes and can roll back if issues arise
- **Storage Orchestration:** Automatically mounts storage systems (local, cloud, network)
- **Secret & Configuration Management:** Manages sensitive information and application configuration
- **Horizontal Scaling:** Scales applications up or down based on resource usage

**Core Concepts:**
- **Pods:** The smallest deployable units that contain one or more containers
- **Services:** Abstract way to expose applications running on Pods
- **Deployments:** Declarative updates for Pods and ReplicaSets
- **Namespaces:** Virtual clusters for resource isolation
- **ConfigMaps & Secrets:** Configuration and sensitive data management

---

### ArgoCD

**ArgoCD** is a declarative, GitOps continuous delivery tool for Kubernetes. It follows the GitOps pattern of using Git repositories as the source of truth for defining the desired application state.

**Key Features:**
- **Automated Deployment:** Monitors Git repositories and automatically syncs changes to Kubernetes clusters
- **Application Definitions:** Supports various configuration management tools (Kustomize, Helm, plain YAML)
- **Multi-Cluster Support:** Manages applications across multiple Kubernetes clusters
- **Health Status:** Real-time monitoring of application health and sync status
- **Rollback Capability:** Easy rollback to previous application states
- **SSO Integration:** Supports OIDC, LDAP, SAML for authentication
- **RBAC:** Fine-grained access control for different teams and environments
- **Web UI & CLI:** Both graphical and command-line interfaces

**GitOps Benefits:**
- Single source of truth in Git
- Declarative infrastructure
- Audit trail through Git history
- Easy disaster recovery and cluster replication

---

### Longhorn

**Longhorn** is a lightweight, reliable, and easy-to-use distributed block storage system for Kubernetes. Developed by Rancher Labs (now part of SUSE), it provides persistent storage for stateful applications.

**Key Features:**
- **Distributed Storage:** Creates replicated block storage from local disks across cluster nodes
- **Incremental Snapshots:** Space-efficient snapshots with incremental backup
- **Disaster Recovery:** Cross-cluster backup and restore capabilities
- **Volume Management:** Easy volume creation, deletion, attachment, and detachment
- **Storage Classes:** Integration with Kubernetes StorageClasses for dynamic provisioning
- **Volume Backup:** Backups to NFS or S3-compatible object storage
- **Volume Cloning:** Fast volume cloning from snapshots
- **Web UI:** Intuitive dashboard for storage management
- **CSI Driver:** Fully compliant Container Storage Interface implementation

**Use Cases:**
- Database persistent volumes
- Stateful application storage
- Shared storage across pods
- Backup and disaster recovery

---

### Docker

**Docker** is a platform for developing, shipping, and running applications in containers. It packages applications and their dependencies into standardized units called containers.

**Key Features:**
- **Containerization:** Encapsulates applications with all dependencies
- **Portability:** "Build once, run anywhere" philosophy
- **Isolation:** Each container runs in its own isolated environment
- **Efficiency:** Containers share the host OS kernel, making them lightweight
- **Version Control:** Docker images are versioned and easily shareable
- **Docker Hub:** Public registry with thousands of pre-built images
- **Dockerfile:** Simple DSL for defining container images
- **Docker Compose:** Multi-container application orchestration

**Components:**
- **Docker Engine:** Runtime that builds and runs containers
- **Docker Images:** Read-only templates for creating containers
- **Docker Containers:** Runnable instances of images
- **Docker Registry:** Storage and distribution system for images
- **Dockerfile:** Text file with instructions to build images

---

### Harbor

**Harbor** is an open-source container image registry that secures images with policies and role-based access control. It extends Docker Registry with enterprise features.

**Key Features:**
- **Security & Vulnerability Scanning:** Scans images for known vulnerabilities
- **Image Signing:** Content trust and image signing with Notary
- **RBAC:** Role-based access control for projects and repositories
- **Multi-Tenancy:** Project-based organization for teams
- **Replication:** Image replication between Harbor instances (multi-datacenter)
- **Webhook Integration:** Notifications for image push, pull, delete events
- **Helm Chart Repository:** Stores and serves Helm charts
- **OCI Compliance:** Fully compliant with OCI (Open Container Initiative) standards
- **Quota Management:** Storage quota limits per project
- **Audit Logging:** Comprehensive logs for compliance and troubleshooting

**Enterprise Features:**
- Policy-based image retention
- Tag immutability to prevent overwriting
- Proxy cache for external registries (Docker Hub, ECR, GCR)
- LDAP/AD/OIDC authentication
- Garbage collection for storage optimization

---

## How They Work Together

These technologies form a complete ecosystem for modern cloud-native application development and deployment:

### 1. **Development Phase (Docker)**
- Developers containerize applications using **Docker**, creating Docker images with application code and dependencies
- Images are built locally and tested using Docker Compose for multi-container setups
- Dockerfiles define the build process and environment for consistent builds

### 2. **Storage & Registry (Harbor)**
- Docker images are pushed to **Harbor**, the private container registry
- Harbor scans images for vulnerabilities before they reach production
- Images are signed and verified to ensure integrity
- Teams have isolated projects with RBAC controlling who can push/pull images
- Harbor replicates images across multiple regions/clusters for high availability

### 3. **Orchestration & Runtime (Kubernetes)**
- **Kubernetes** pulls container images from Harbor to run applications
- Pods are created from these images and scheduled across cluster nodes
- Kubernetes manages scaling, load balancing, and self-healing
- Services expose applications internally or externally
- ConfigMaps and Secrets (potentially stored in Harbor as well) configure applications

### 4. **Persistent Storage (Longhorn)**
- **Longhorn** provides distributed block storage for stateful applications in Kubernetes
- Database pods, file storage, and other stateful workloads use Longhorn volumes
- Volumes are automatically replicated across nodes for data durability
- Snapshots and backups protect against data loss
- Storage is dynamically provisioned when pods request PersistentVolumeClaims

### 5. **Continuous Deployment (ArgoCD)**
- **ArgoCD** implements GitOps by monitoring Git repositories for changes
- Kubernetes manifests (YAML files, Helm charts, Kustomize) are stored in Git
- When developers commit changes to Git, ArgoCD detects them automatically
- ArgoCD syncs the desired state from Git to the Kubernetes cluster
- Applications are deployed, updated, or rolled back based on Git commits
- ArgoCD pulls the correct image versions from Harbor as specified in manifests

### **Complete Workflow Example:**

```
1. Developer writes code → Commits to Git
2. CI pipeline builds Docker image → Pushes to Harbor
3. Harbor scans image → Stores securely
4. Developer updates Kubernetes manifest in Git (new image tag)
5. ArgoCD detects Git change → Syncs to Kubernetes
6. Kubernetes pulls image from Harbor → Creates pods
7. Longhorn provides persistent volumes for databases/storage
8. Application runs with automatic scaling and self-healing
9. ArgoCD continuously monitors and maintains desired state
```

This architecture provides:
- **Security:** Harbor's image scanning and RBAC
- **Reliability:** Kubernetes self-healing + Longhorn replication
- **Automation:** ArgoCD GitOps deployment
- **Auditability:** Git history + ArgoCD tracking
- **Scalability:** Kubernetes horizontal scaling
- **Disaster Recovery:** Longhorn backups + ArgoCD from Git

---

## Installation Guide

### Prerequisites

Before installing the stack, ensure you have:

- [ ] A Linux-based system (Ubuntu 20.04+ or similar recommended)
- [ ] At least 8GB RAM (16GB+ recommended for production)
- [ ] 4+ CPU cores
- [ ] 100GB+ available disk space
- [ ] Root or sudo access
- [ ] Internet connectivity
- [ ] Basic knowledge of Linux command line

---

### Installing Kubernetes

<!-- Add your Kubernetes installation steps here -->

**Installation Steps:**

```bash
# Your installation commands will go here
```

**Verification:**

```bash
kubectl version
kubectl get nodes
```

---

### Installing Docker

<!-- Add your Docker installation steps here -->

**Installation Steps:**

```bash
# Your installation commands will go here
```

**Verification:**

```bash
docker --version
docker run hello-world
```

---

### Installing ArgoCD

<!-- Add your ArgoCD installation steps here -->

**Installation Steps:**

```bash
# Your installation commands will go here
```

**Verification:**

```bash
kubectl get pods -n argocd
```

**Access the UI:**

```bash
# Your commands to access ArgoCD UI
```

---

### Installing Longhorn

<!-- Add your Longhorn installation steps here -->

**Installation Steps:**

```bash
# Your installation commands will go here
```

**Verification:**

```bash
kubectl get pods -n longhorn-system
```

**Access the UI:**

```bash
# Your commands to access Longhorn UI
```

---

### Installing Harbor

<!-- Add your Harbor installation steps here -->

**Installation Steps:**

```bash
# Your installation commands will go here
```

**Verification:**

```bash
# Your verification commands
```

**Access the UI:**

```bash
# Your commands to access Harbor UI
# Default credentials: admin/Harbor12345
```

---

## Contributing

Feel free to contribute to this study repository by submitting pull requests or opening issues.

## License

This project is for educational purposes.
