# Glossary

## Phase 00 - Local Compose

### Container

An executable unit that packages an application and all its dependencies.

Containers enable software to run reproducibly across different environments.

---

### Docker Compose

A tool for defining and running multi-container applications using a YAML file.

It allows you to manage networking, volumes, and environment variables.

---

### Environment Variables

Variables used to configure applications without modifying the code.

---

### Image

An immutable template used to create containers.

Images contain the base system, dependencies, and application code.

---

### Service (Docker Compose)

The definition of a container within a multi-container application.

---

### Volume

A mechanism to persist data outside the lifecycle of a container.

---

## Phase 01 - Kubernetes Basics

### Cluster

A set of machines (nodes) that run containerized applications managed by Kubernetes.
It consists of a control plane and one or more worker nodes.

---

### ClusterIP

The default Service type. Exposes the Service on an internal IP reachable only from within the cluster.

---

### Control Plane

The set of components that make global decisions about the cluster
(scheduling, detecting failures, responding to events).
Includes the API server, etcd, scheduler, and controller manager.

---

### Declarative Configuration

An approach where you describe the desired state of resources in YAML files and let Kubernetes reconcile the actual state to match.

---

### Deployment

A higher-level resource that manages a set of identical Pods.
It provides declarative updates, rolling updates, rollbacks, and self-healing.

---

### etcd

A distributed key-value store that holds the entire state of the Kubernetes cluster.

---

### Kubernetes (K8s)

An open-source container orchestration platform that automates deployment,
scaling, and management of containerized applications across a cluster of machines.

---

### kube-apiserver

The front-end of the Kubernetes control plane.
All communication from kubectl, internal components, and external clients goes through the API server.

---

### kubectl

The command-line tool used to interact with the Kubernetes API server.
It is the primary way to manage resources in a cluster.

---

### kubelet

An agent running on each worker node that ensures containers described by Pod specs are running and healthy.

---

### kube-proxy

A network component on each node that maintains network rules so Pods can communicate with each other and with the outside world.

---

### Label

A key-value pair attached to Kubernetes objects used for identification and grouping.
Labels enable selectors to filter and target resources.

---

### LoadBalancer

A Service type that provisions an external load balancer (on cloud providers) to expose the Service to the internet.

---

### Minikube

A tool that creates a single-node Kubernetes cluster locally, designed for learning and development.

---

### Namespace

A logical partition within a cluster that provides isolation for resources.
Useful for separating environments or teams.

---

### NodePort

A Service type that exposes the Service on a static port on every node's IP,
making it accessible from outside the cluster.

---

### Pod

The smallest deployable unit in Kubernetes.
A Pod encapsulates one or more containers that share network, storage, and lifecycle.

---

### ReplicaSet

A controller that ensures a specified number of Pod replicas are running at any given time.
Deployments manage ReplicaSets automatically.

---

### Selector

A query that filters Kubernetes objects by their labels.
Used by Deployments to manage Pods and by Services to route traffic.

---

### Service

A stable network endpoint that exposes a group of Pods.
It provides load balancing and DNS-based service discovery,
decoupling consumers from individual Pod IPs.

---

### Worker Node

A machine in the cluster that runs application workloads.
Each node runs a kubelet, kube-proxy, and a container runtime.

---

## Phase 02 - Kubernetes Application

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

---

## Phase 03 - Package Management

### Helm

A package manager for Kubernetes that simplifies installing, upgrading, and managing applications.
It combines templating and release management to avoid maintaining many static YAML files.

---

### Helm Chart

The package format used by Helm to describe a Kubernetes application.
A chart contains metadata, default values, and templates for Kubernetes resources.

---

### Chart.yaml

The metadata file inside a Helm chart.
It defines information such as chart name, version, description, and dependencies.

---

### values.yaml

The default configuration file for a Helm chart.
It provides variable values that templates consume to render environment-specific manifests.

---

### Template (Helm)

A Kubernetes manifest written with Go Template syntax and placeholders.
Templates are rendered into final YAML using chart values at install or upgrade time.

---

### Release

A deployed instance of a Helm chart in a Kubernetes cluster.
The same chart can produce multiple releases with different names and values.

---

### Revision

A version in the history of a Helm release.
Each successful upgrade creates a new revision that can be inspected or rolled back to.

---

### Rollback (Helm)

The operation that restores a release to a previous revision.
It is used to recover quickly when a new deployment introduces issues.

---

### helm install

A Helm command that creates a new release from a chart.
It can use default values or custom values files for a target environment.

---

### helm upgrade

A Helm command that updates an existing release with new templates or values.
It applies controlled configuration changes while preserving release history.