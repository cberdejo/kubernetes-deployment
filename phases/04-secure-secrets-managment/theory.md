# Phase 04 — Secure Management & Templating

Choosing the right secret management tool is critical for the GitOps workflow. The current three heavyweights: **Sealed Secrets**, **External Secrets Operator (ESO)**, and **HashiCorp Vault**.

I recommend reading [Kubernetes Secrets Management: Vault vs Sealed Secrets vs External Secrets (2025)](https://atmosly.com/blog/kubernetes-secrets-management-vault-vs-sealed-secrets-vs-external-secrets-2025)

- **Core concepts to master in this phase**:
  - **Threat Model of Kubernetes Secrets** (Base64 vs real encryption at rest)
  - **Sealed Secrets flow** (public/private key and Git-safe manifests)
  - **External Secrets Operator (ESO)** (sync from external secret providers)
  - **Secret Rotation Strategy** (manual, automatic, and dynamic credentials)
  - **Tool Selection Trade-offs** (complexity, compliance, and cloud dependency)

--- 

## Kubernetes Secrets Management

The core problem remains: **Native Kubernetes Secrets are only Base64 encoded**, not encrypted. Storing them in Git is a security breach. Here is how the top three solutions solve this:

### 1. Sealed Secrets (Bitnami)

- **Concept:** Uses asymmetric encryption to let you safely store secrets in Git.
- **How it works:** You encrypt a secret locally with a **public key** (`kubeseal`). Only the **Sealed Secrets Controller** inside the cluster has the **private key** to decrypt it back into a standard K8s Secret.
- **Best for:** * Small to medium teams.
  - Pure GitOps workflows where "Git is the single source of truth."
  - Simple setups with no external dependencies (like AWS or Vault).
- **Pros:** Lightweight, free, and decentralized.
- **Cons:** Secrets are static (no auto-rotation). If you lose the cluster's private key, you lose access to all your secrets.

### 2. External Secrets Operator (ESO)

- **Concept:** A "bridge" that fetches secrets from professional providers (AWS Secrets Manager, Google Secret Manager, Azure Key Vault, or Vault) and syncs them into Kubernetes.
- **How it works:** You define an `ExternalSecret` manifest in Git. The operator sees this, authenticates with your Cloud Provider, pulls the value, and creates a local K8s Secret.
- **Best for:** * Cloud-native environments.
  - Teams already using a Cloud KMS (Key Management Service).
- **Pros:** Supports **automatic secret rotation** and centralized auditing.
- **Cons:** Requires an external provider (can add costs or cloud lock-in).

### 3. HashiCorp Vault

- **Concept:** The "Gold Standard" for enterprise security. It isn't just a storage box; it’s a complete identity and security engine.
- **How it works:** Vault manages the secrets. You can access them via an **Agent Injector** (sidecar), the **CSI Driver**, or **ESO**.
- **Best for:** Large enterprises and high-compliance environments (PCI-DSS, SOC2).
  - Multi-cluster environments.
  - **Dynamic Secrets:** Vault can generate "on-the-fly" credentials for a database that expire after 1 hour.
- **Pros:** Advanced auditing, fine-grained RBAC, and dynamic credential generation.
- **Cons:** Highly complex to manage and "heavy" for simple hobbyist projects.

---

### Quick Comparison Table


| Feature              | Sealed Secrets             | External Secrets (ESO)  | HashiCorp Vault             |
| -------------------- | -------------------------- | ----------------------- | --------------------------- |
| **Source of Truth**  | Git (Encrypted)            | External Cloud/Vault    | Vault Server                |
| **Rotation**         | Manual                     | Automatic (from Source) | Automatic & Dynamic         |
| **Complexity**       | Low                        | Medium                  | High                        |
| **Cloud Dependency** | None                       | Yes (usually)           | None (Self-hosted/HCP)      |
| **Best Use Case**    | Simple GitOps             | Production on AWS/GCP   | Enterprise / Security First |


---

