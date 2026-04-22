# Phase 05,  Distributed Persistent Storage

Choosing the right storage backend for Kubernetes is not optional when you run stateful workloads. Below is a deep dive into the three most common approaches for persistent storage in a self-hosted cluster: **Longhorn**, **Rook/Ceph**, and **NFS/hostPath**, what they are, how they work, and when to pick each.

**Core concepts to master in this phase:**
- **PersistentVolume / PersistentVolumeClaim / StorageClass**, the Kubernetes storage API
- **CSI (Container Storage Interface)**, how storage drivers plug into Kubernetes
- **Longhorn architecture**, control plane, data plane, replicas, engine
- **Dynamic provisioning**, how a StorageClass automatically creates volumes on demand
- **Volume access modes**, ReadWriteOnce vs ReadWriteMany and why it matters

---

## Kubernetes Storage Primitives

Before installing any storage backend, you need to understand the three-layer abstraction Kubernetes uses.

### PersistentVolume (PV)

A piece of actual storage in the cluster,  a disk, an NFS share, a Longhorn volume. Created by the cluster administrator or dynamically by a StorageClass. It has a lifecycle independent of any single Pod.

### PersistentVolumeClaim (PVC)

A request for storage by a workload. The workload says "I need 5Gi with ReadWriteOnce access." Kubernetes finds or creates a matching PV and binds the two together. The Pod references the PVC; it never needs to know what is backing it.

### StorageClass

The recipe for creating PVs on demand. It references a CSI driver (e.g. `driver.longhorn.io`) and sets defaults like replica count, reclaim policy, and filesystem type. When a PVC references a StorageClass, the provisioner runs and creates the PV automatically,  this is **dynamic provisioning**.

```
PVC requests storage (StorageClass: longhorn)
     ↓
StorageClass calls the Longhorn CSI provisioner
     ↓
Longhorn creates a replicated block volume across nodes
     ↓
A PV is created and bound to the PVC
     ↓
The Pod mounts the PVC at the specified mountPath
```

---

## Option 1,  hostPath (Development Only)

`hostPath` is the simplest possible storage backend: it maps a directory on the node's filesystem directly into a Pod. Minikube's built-in `standard` StorageClass uses this under the hood.

**How it works:**

```
Pod → PVC → PV (hostPath: /mnt/data on node-1)
```

There is no abstraction, no replication, no network involvement. The data lives in a directory on whichever node the Pod happens to be scheduled on.

**Why it breaks in production:**

If the Pod is rescheduled to a different node (node failure, rolling update, resource pressure), it loses access to its data entirely. There is no mechanism to move or replicate the data to another node. This makes `hostPath` fundamentally incompatible with multi-node clusters running stateful workloads.

It also offers no snapshots, no backups, and no reclaim policy beyond "delete the directory manually."

**When to use it:** Local development and single-node Minikube clusters only. Never in a production or multi-node setup.

---

## Option 2,  NFS (Simple Shared Storage)

NFS (Network File System) is a decades-old network protocol that lets multiple machines mount the same filesystem over a network. In Kubernetes, an NFS server (running inside or outside the cluster) exposes a share, and the NFS CSI driver makes it available as PVs.

**How it works:**

```
Pod A ──┐
Pod B ──┼──→ PVC (RWX) → PV → NFS Server → /exports/data
Pod C ──┘
```

Unlike `hostPath`, the data lives on a dedicated server, so any node can reach it. This is what enables **ReadWriteMany (RWX)**,  multiple Pods on different nodes mounting the same volume simultaneously with read-write access.

**Key characteristics:**

- **Simplicity**,  If you already have an NFS server, adding the CSI driver and a StorageClass is all you need. No distributed system to operate.
- **RWX native**,  The primary reason to choose NFS. Ideal for shared configuration, ML training datasets, or scaling out stateless-ish apps like WordPress where multiple instances need to write to the same filesystem.
- **No built-in redundancy**,  The NFS server itself is a single point of failure. If it goes down, all volumes are gone. High availability requires additional infrastructure (e.g. DRBD, Pacemaker, or a managed NAS).
- **Performance ceiling**,  NFS adds network latency to every I/O operation. It is not suitable for high-throughput databases (PostgreSQL, MySQL) or anything with heavy random-write patterns.
- **No snapshots or backups out of the box**,  You rely on the NFS server's own backup mechanism, which is external to Kubernetes.

**When to use it:** Shared storage for multiple Pods (RWX use cases), or when you already operate an NFS/NAS server and want to expose it to Kubernetes with minimal overhead. Not for databases.

---

## Option 3,  Longhorn (Self-Hosted Production)

Longhorn is a cloud-native distributed block storage system built specifically for Kubernetes. It runs entirely inside the cluster as Kubernetes-native components and requires no external storage infrastructure.

### Control Plane

- **Longhorn Manager** (DaemonSet),  runs on every node, communicates with the Kubernetes API, and manages volume lifecycle.
- **Longhorn UI** (Deployment),  a web dashboard to inspect and manage volumes, nodes, and backups.
- **CSI Driver** (DaemonSet),  exposes Longhorn volumes to Kubernetes Pods via the standard CSI interface.

### Data Plane

Each Longhorn Volume has its own dedicated **Longhorn Engine** process. The engine handles all I/O and synchronously replicates writes to N replicas (default: 3). Each replica is a directory on a different node's disk.

```
Pod writes to /data  →  PVC  →  CSI  →  Longhorn Engine
                                               ↓
                                   Replica A (node-1)
                                   Replica B (node-2)
                                   Replica C (node-3)
```

If a node goes down, the engine continues with the surviving replicas and marks the missing one as degraded. When the node recovers, Longhorn automatically rebuilds the replica.

### Key Longhorn Concepts

**Replica Count**,  Controls how many copies of your data exist across nodes. Default is 3. For a single-node learning cluster, set it to 1.

**Volume Access Mode**,  Longhorn supports ReadWriteOnce (RWO) natively for databases. ReadWriteMany (RWX) is supported via an NFS layer that Longhorn manages internally.

**`subPath` for PostgreSQL**,  When mounting a Longhorn volume into PostgreSQL's data directory, always use `subPath: pgdata`. PostgreSQL fails to initialize if the mount root contains anything (some filesystems create `lost+found`). `subPath` makes PostgreSQL write into a clean subdirectory.

```yaml
volumeMounts:
  - name: postgres-pvc
    mountPath: /var/lib/postgresql/data
    subPath: pgdata
```

**Reclaim Policy:**
- `Delete` (default),  the volume is destroyed when the PVC is deleted.
- `Retain`,  the volume persists. Use this for databases in production.

**When to use it:** The default choice for self-hosted production clusters. Easy to operate, great UI, built-in backups to S3, and no external dependencies. Not ideal for extremely high-throughput workloads where raw IOPS matter most.

---

## Option 4,  Rook / Ceph (Enterprise Scale)

Rook is a Kubernetes operator that deploys and manages **Ceph**, a battle-tested distributed storage system originally developed for large-scale data centers. Ceph itself is the storage system; Rook is the Kubernetes-native control layer on top of it.

### What Ceph provides

Ceph is unique because it offers three storage protocols from a single system:

- **RBD (RADOS Block Device)**,  block storage, equivalent to Longhorn's volumes. Used for databases and stateful apps.
- **CephFS**,  a POSIX-compliant distributed filesystem. Native RWX support without the NFS layer.
- **RGW (RADOS Gateway)**,  an S3/Swift-compatible object storage API. You can replace MinIO or AWS S3 with this.

Running all three from a single Ceph cluster means one storage system for all your workload types.

### How Rook manages it

Rook deploys Ceph via Kubernetes CRDs. You define a `CephCluster` manifest, and Rook handles the rest:

- **MON (Monitor) pods**,  maintain the cluster map (which OSDs exist, which are healthy).
- **OSD (Object Storage Daemon) pods**,  one per disk. These are the actual storage processes that hold data.
- **MGR (Manager) pods**,  expose metrics, the dashboard, and handle orchestration tasks.
- **MDS pods**,  metadata servers for CephFS (only needed if you use the filesystem protocol).

```
Rook Operator watches CRDs
     ↓
Deploys MON + OSD + MGR pods across nodes
     ↓
Ceph distributes data using CRUSH algorithm
     ↓
CSI driver exposes RBD/CephFS volumes to Pods
```

The **CRUSH algorithm** is how Ceph decides where to place data. It calculates placement based on a topology map of your hardware (racks, hosts, disks), ensuring replicas or erasure-coded shards never land on the same failure domain.

### Why it's complex

Rook/Ceph is operationally demanding:

- Minimum 3 nodes with dedicated disks (OSDs should not share disks with the OS).
- You need to understand CRUSH maps when rebalancing or replacing hardware.
- Upgrades are multi-step and require careful sequencing.
- Debugging Ceph requires learning Ceph-specific tooling (`ceph status`, `ceph osd tree`, `ceph pg stat`).

Rook/Ceph is the right call when you own hardware, need multiple protocols (block for databases, filesystem for shared workloads, S3 for object storage) without deploying three separate products, and are willing to budget the time to learn CRUSH maps and automate OSD lifecycle.

**When to use it:** Large-scale bare-metal clusters where you need multi-protocol storage, maximum throughput, or erasure coding for storage efficiency. Not recommended for small teams or clusters under ~5 nodes.

---

## Storage Solution Comparison

| Feature            | hostPath          | NFS                    | Longhorn               | Rook / Ceph               |
|--------------------|-------------------|------------------------|------------------------|---------------------------|
| **Complexity**     | None              | Low                    | Low–Medium             | Very High                 |
| **Redundancy**     | None              | Depends on NFS server  | Yes (replicated)       | Yes (distributed/erasure) |
| **Snapshots**      | No                | Vendor-dependent       | Yes                    | Yes                       |
| **Backups**        | No                | Manual                 | Yes (S3)               | Yes                       |
| **Multi-node**     | No                | Yes                    | Yes                    | Yes                       |
| **RWX support**    | No                | Yes (native)           | Yes (via NFS layer)    | Yes (CephFS native)       |
| **Object storage** | No                | No                     | No                     | Yes (S3-compatible RGW)   |
| **Performance**    | Local disk speed  | Network-limited        | Good (iSCSI)           | Excellent (NVMe-optimized)|
| **Best for**       | Local dev only    | Simple shared storage  | Self-hosted production | Large-scale enterprise    |

### Decision flowchart

```
Do you need shared RWX across many Pods?
├── Yes, and simplicity matters → NFS
├── Yes, and you're already using Ceph → CephFS
└── No, block storage is fine →
    Is this a production multi-node cluster?
    ├── No (dev/Minikube) → hostPath
    └── Yes →
        Do you need multi-protocol (block + file + object)?
        ├── Yes, and you have dedicated hardware + ops time → Rook/Ceph
        └── No → Longhorn
```

---

## Further Reading & Comparisons

These are worth bookmarking for a deeper understanding of the trade-offs:

- **[Kubernetes Storage Layers: Ceph vs. Longhorn vs. Everything Else](https://oneuptime.com/blog/post/2025-11-27-choosing-kubernetes-storage-layers/view)** (OneUptime, Nov 2025),  Architecture-first decision guide covering failure modes, performance profiles, and a practical flowchart.
- **[Kubernetes Storage Comparison: Ceph, Longhorn, OpenEBS & GlusterFS](https://kubedo.com/kubernetes-storage-comparison/)** (Kubedo, Jun 2025),  Includes real benchmark numbers (IOPS, throughput) on a 3-node NVMe cluster.
- **[Top Kubernetes Storage Solutions in 2026](https://simplyblock.io/blog/5-storage-solutions-for-kubernetes-in-2025/)** (Simplyblock),  Good overview of NFS's RWX use case and Longhorn's trade-offs for edge/SMB.
- **[Battle of Bytes: Comparing Kubernetes Storage Solutions](https://rajputvaibhav.medium.com/battle-of-bytes-comparing-kubernetes-storage-solutions-583aa53ddd16)** (Medium),  Hands-on benchmark article with Rook/Ceph, Longhorn, and OpenEBS deployed and tested side by side.
- **[Official Kubernetes Persistent Volumes docs](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)**,  The canonical reference for PV/PVC/StorageClass concepts.
- **[What is Longhorn](https://longhorn.io/docs/latest/what-is-longhorn/)**,  Longhorn's own architecture overview.

