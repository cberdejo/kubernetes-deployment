# Glossary - Phase 04: Secure Secrets Management

### SealedSecret

A custom Kubernetes resource (`bitnami.com/v1alpha1`) that stores encrypted secret data safely in Git.
The Sealed Secrets controller decrypts it inside the cluster and creates a regular Kubernetes `Secret`.

---

### kubeseal

A CLI tool used to encrypt a plaintext Kubernetes `Secret` into a `SealedSecret`.
It uses the cluster public certificate so only the matching controller private key can decrypt the data.

---

### Sealed Secrets Controller

The in-cluster controller that watches `SealedSecret` resources and decrypts them into native Kubernetes `Secret` objects.
It is the component that holds the private key material required for decryption.

---

### Asymmetric Encryption

An encryption model that uses a public key to encrypt and a private key to decrypt.
In Sealed Secrets, developers seal data with the public key, and only the cluster controller can unseal it with the private key.

---

### External Secrets Operator (ESO)

A Kubernetes operator that syncs secrets from external providers (such as AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, or Vault) into Kubernetes `Secret` resources.
It enables GitOps references to external secret sources without storing secret values in Git.

---

### HashiCorp Vault

A centralized secret management platform that provides secure storage, fine-grained access control, auditing, and dynamic credentials.
In Kubernetes, it can be integrated through agents, CSI, or operators such as ESO.

---

### Secret Rotation

The process of periodically replacing secret values (passwords, tokens, keys) to reduce risk if credentials are exposed.
Rotation can be manual (for example, resealing values) or automated when using external secret backends.

---

### Encryption at Rest

A security mechanism that keeps stored data encrypted on disk.
For Kubernetes secrets, this refers to encrypting secret data in etcd rather than storing it as plain Base64-encoded values.
