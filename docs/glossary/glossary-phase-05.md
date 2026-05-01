# Glossary - Phase 05: Distributed Persistent Storage

### PersistentVolume (PV)

A piece of storage in the cluster provisioned by an administrator or dynamically by a StorageClass.
A PV has a lifecycle independent of any Pod — it exists before a workload claims it and can outlive it.

---

### StorageClass

A cluster-wide resource that defines how storage is provisioned.
It names a provisioner (such as Longhorn), sets default parameters (replica count, filesystem type), and controls reclaim behavior.
When a PVC references a StorageClass, Kubernetes asks that provisioner to create the volume automatically.

---

### Dynamic Provisioning

The automatic creation of a PersistentVolume when a PVC is submitted.
Without it, an admin must manually create PVs before workloads can use them.
StorageClasses enable dynamic provisioning by delegating volume creation to a provisioner.

---

### CSI (Container Storage Interface)

A standardized API that allows storage vendors to write drivers that plug into any CSI-compatible container orchestrator.
Longhorn implements the CSI spec, which is why Kubernetes can use it to provision, attach, mount, and snapshot volumes without storage-specific code in the Kubernetes core.

---

### Longhorn

A distributed block storage system designed for Kubernetes.
It runs as a DaemonSet on each node, stores volume data as files on the node's disk, and replicates each volume across multiple nodes for durability.
Longhorn exposes a StorageClass, a CSI driver, and a web UI for volume management.

---

### Volume Replica

A copy of a Longhorn volume stored on a different node.
With three replicas, the volume survives the loss of two nodes without data loss.
Replicas are rebuilt automatically when a node comes back online.

---

### Reclaim Policy

The behavior Kubernetes applies to a PV after its PVC is deleted.
`Delete` removes the PV and its underlying storage automatically.
`Retain` keeps the PV and its data, requiring manual cleanup before the storage can be reused.

---

### ReadWriteMany (RWX)

A volume access mode that allows multiple nodes to mount the volume simultaneously for read and write.
Contrast with `ReadWriteOnce` (single node). Block storage backends like Longhorn support RWX only through a share layer; native RWX typically requires a file-based backend such as NFS or CephFS.

---

### subPath

A volume mount field that mounts a subdirectory of a volume rather than its root.
Used with Longhorn (and other block storage backends) because formatting a new volume creates a `lost+found` directory at the root, which prevents PostgreSQL from initializing its data directory. Mounting via `subPath: pgdata` gives PostgreSQL a clean, empty subdirectory.
