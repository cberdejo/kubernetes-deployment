# Glossary - Phase 02: Kubernetes Application

### ConfigMap

A Kubernetes resource used to store non-sensitive configuration as key-value pairs.
It allows applications to read configuration through environment variables, command arguments, or mounted files.

---

### Secret

A Kubernetes resource used to store sensitive data such as passwords, tokens, or keys.
Secrets can be consumed by Pods as environment variables or mounted volumes.

---

### PersistentVolumeClaim (PVC)

A request for persistent storage made by a Pod.
A PVC abstracts the underlying storage implementation and lets workloads keep data across Pod restarts.

---

### Access Mode (ReadWriteOnce)

A storage access policy that defines how a volume can be mounted.
`ReadWriteOnce` means the volume can be mounted as read-write by a single node at a time.

---

### storageClassName

A field in a PVC that selects which StorageClass should provision the volume.
It controls characteristics such as performance tier, provisioner, and reclaim behavior.

---

### StatefulSet

A Kubernetes workload resource for stateful applications that need stable network identity and persistent storage.
Unlike Deployments, StatefulSets provide ordered creation, scaling, and termination guarantees.

---

### envFrom

A Pod specification field used to load all key-value pairs from a ConfigMap or Secret as environment variables.
It is useful for injecting grouped configuration without listing each variable individually.

---

### imagePullPolicy

A container setting that controls when Kubernetes pulls an image from a registry.
`IfNotPresent` avoids pulling if the image already exists on the node.

---

### port-forward

A `kubectl` command that forwards local traffic to a Pod or Service port inside the cluster.
It is commonly used for local debugging and quick validation without exposing resources externally.

---

### Internal DNS Name

The cluster DNS identity used for Service-to-Service communication.
Within the same namespace, applications can use the Service name (for example, `postgres`);
the fully qualified form is `<service>.<namespace>.svc.cluster.local`.
