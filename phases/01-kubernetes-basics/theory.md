# Phase 01 — Kubernetes Basics

- **Core concepts to master in this phase**:
  - **Kubernetes**
  - **Minikube**
  - **Pods**
  - **Deployments**
  - **Services**
  - **NodePorts**


## What is Kubernetes?

Kubernetes (K8s) is an open-source container orchestration platform originally developed by Google. It automates the deployment, scaling, and management of containerized applications.

While Docker Compose manages containers on a single machine, Kubernetes manages containers across one or more nodes (machines), providing:

- Self-healing (restarts failed containers)
- Horizontal scaling
- Service discovery and load balancing
- Declarative configuration
- Rolling updates and rollbacks

---

## Cluster Architecture

A Kubernetes cluster consists of two types of components:

### Control Plane

The brain of the cluster. It makes global decisions (scheduling, detecting failures, etc.). Key components:

- **kube-apiserver** — the front door of the cluster. All communication (kubectl, internal components) goes through the API server.
- **etcd** — a distributed key-value store that holds the entire cluster state.
- **kube-scheduler** — decides which node should run a newly created Pod based on resource availability and constraints.
- **kube-controller-manager** — runs controllers that watch cluster state and make changes to move toward the desired state (e.g., ensuring the right number of replicas).

### Worker Nodes

The machines where your workloads actually run. Each node runs:

- **kubelet** — an agent that ensures containers described by Pod specs are running and healthy.
- **kube-proxy** — manages network rules on the node so that Pods can communicate with each other and with the outside world.
- **container runtime** — the software that runs containers (containerd, CRI-O, etc.).

---

## Minikube

Minikube is a tool that creates a single-node Kubernetes cluster locally. It is designed for learning and development.

It runs the entire control plane and a worker node inside a VM or container on your machine.

### Key commands

```bash
minikube start          # create and start the cluster
minikube status         # check cluster status
minikube stop           # stop the cluster (preserves state)
minikube delete         # destroy the cluster completely
minikube dashboard      # open the Kubernetes web dashboard
```

---

## kubectl

`kubectl` is the command-line tool used to interact with the Kubernetes API server. It is the primary way to manage a cluster.

### Syntax

```
kubectl [command] [resource_type] [name] [flags]
```

### Essential commands

```bash
kubectl cluster-info                  # show cluster endpoints
kubectl get nodes                     # list nodes in the cluster
kubectl get pods                      # list pods in the default namespace
kubectl get deployments               # list deployments
kubectl get services                  # list services
kubectl describe pod <name>           # detailed info about a pod
kubectl logs <pod-name>               # view container logs
kubectl exec -it <pod-name> -- bash   # open a shell inside a container
kubectl apply -f <file.yaml>          # apply a configuration file
kubectl delete -f <file.yaml>         # delete resources defined in a file
```

### Useful flags

- `-n <namespace>` — target a specific namespace
- `-o wide` — show additional columns (node, IP, etc.)
- `-o yaml` — output the full resource definition in YAML
- `--watch` — watch for real-time changes

---

## Pod

A Pod is the smallest deployable unit in Kubernetes. It represents one or more containers that share:

- Network namespace (same IP address, same ports)
- Storage volumes
- Lifecycle

In most cases, a Pod runs a single container. Multi-container Pods are used for tightly coupled helper processes (sidecars).

### Pod lifecycle

1. **Pending** — the Pod has been accepted but containers are not yet running (image pull, scheduling).
2. **Running** — at least one container is running.
3. **Succeeded** — all containers exited successfully (exit code 0).
4. **Failed** — at least one container exited with an error.
5. **Unknown** — the state cannot be determined.

### Example Pod manifest

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
```

> **Important:** You rarely create Pods directly. Instead, you use higher-level abstractions like Deployments that manage Pods for you.

---

## Deployment

A Deployment is a higher-level resource that manages a set of identical Pods. It provides:

- **Desired state declaration** — you declare how many replicas you want, and Kubernetes ensures that number is running.
- **Rolling updates** — updates Pods gradually to avoid downtime.
- **Rollbacks** — reverts to a previous version if something goes wrong.
- **Self-healing** — if a Pod dies, the Deployment controller creates a new one.

Under the hood, a Deployment creates a **ReplicaSet**, which is the controller responsible for maintaining the desired number of Pods.

```
Deployment → ReplicaSet → Pod(s)
```

### Example Deployment manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
```

### Key fields

| Field | Purpose |
|---|---|
| `replicas` | Number of identical Pods to maintain |
| `selector.matchLabels` | How the Deployment finds which Pods it owns |
| `template` | The Pod specification used to create new Pods |

### Common operations

```bash
kubectl apply -f deployment.yaml             # create or update
kubectl get deployments                       # list deployments
kubectl rollout status deployment/nginx       # watch rollout progress
kubectl rollout undo deployment/nginx         # rollback to previous version
kubectl scale deployment/nginx --replicas=5   # scale manually
```

---

## Service

Pods are ephemeral — they can be created, destroyed, and rescheduled at any time. Their IP addresses are not stable. A **Service** provides a stable network endpoint to access a group of Pods.

A Service uses **label selectors** to determine which Pods receive traffic.

### Service types

| Type | Description |
|---|---|
| **ClusterIP** (default) | Exposes the Service on an internal cluster IP. Only reachable from within the cluster. |
| **NodePort** | Exposes the Service on a static port on each node's IP. Accessible from outside the cluster via `<NodeIP>:<NodePort>`. |
| **LoadBalancer** | Provisions an external load balancer (cloud providers). Exposes the Service externally. |

### Example Service manifest (ClusterIP)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

### Example Service manifest (NodePort)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-nodeport
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      nodePort: 30080
```

### How traffic flows

```
Client → Service (stable IP/DNS) → one of the matching Pods
```

Kubernetes uses internal DNS so that Pods can reach a Service by name:

```
http://nginx-service:80
```

---

## Labels and Selectors

Labels are key-value pairs attached to Kubernetes objects. They are the primary mechanism for organizing and selecting resources.

```yaml
metadata:
  labels:
    app: nginx
    environment: development
```

Selectors filter resources by their labels:

```bash
kubectl get pods -l app=nginx
kubectl get pods -l environment=development
```

Deployments use `selector.matchLabels` to know which Pods they manage. Services use `spec.selector` to know which Pods receive traffic.

---

## Namespaces

Namespaces provide logical isolation within a cluster. They are useful for separating environments (dev, staging, prod) or teams.

```bash
kubectl get namespaces                    # list namespaces
kubectl get pods -n kube-system           # list pods in kube-system namespace
kubectl create namespace dev              # create a namespace
```

Default namespaces in every cluster:

| Namespace | Purpose |
|---|---|
| `default` | Where resources go if no namespace is specified |
| `kube-system` | Kubernetes internal components |
| `kube-public` | Publicly accessible data |
| `kube-node-lease` | Node heartbeat data |

---

## Declarative vs Imperative

Kubernetes supports two approaches:

**Imperative** — you tell Kubernetes what to do step by step:

```bash
kubectl run nginx --image=nginx:1.27
kubectl expose pod nginx --port=80
```

**Declarative** — you describe the desired state in YAML files and let Kubernetes figure out how to achieve it:

```bash
kubectl apply -f deployment.yaml
```

> **Best practice:** Always use the declarative approach. YAML files can be version-controlled, reviewed, and reproduced.
