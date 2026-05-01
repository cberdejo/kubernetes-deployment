# Glossary - Phase 01: Kubernetes Basics

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
