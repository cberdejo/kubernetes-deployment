# Cluster Setup — Minikube

Minikube runs a single-node Kubernetes cluster locally inside a VM or container. It is the recommended setup for phases 01–04 of this project.

---

## Install Minikube

**Linux (amd64):**
```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
```

**macOS:**
```bash
brew install minikube
```

**Windows:**
```powershell
winget install Kubernetes.minikube
```

Minikube also requires a driver. Docker is the simplest option on all platforms:

```bash
# Verify Docker is running
docker info

# Or install kubectl separately if not already present
# https://kubernetes.io/docs/tasks/tools/
```

---

## Start the cluster

```bash
minikube start
```

By default Minikube allocates 2 CPU and 2 GB RAM. For phases with Helm charts and multiple workloads, increase the limits:

```bash
minikube start --cpus 4 --memory 4096
```

---

## Verify

```bash
minikube status
kubectl cluster-info
kubectl get nodes
```

Expected output from `kubectl get nodes`:
```
NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   1m    v1.x.x
```

---

## Common operations

```bash
# Stop the cluster (preserves state)
minikube stop

# Delete the cluster completely
minikube delete

# Open the Kubernetes dashboard
minikube dashboard

# Get the cluster IP (used for NodePort services)
minikube ip

# SSH into the node
minikube ssh
```

---

## Driver options

| Driver | Requires | Notes |
|--------|----------|-------|
| `docker` | Docker | Default, works on all platforms |
| `kvm2` | KVM | Linux only, better isolation |
| `virtualbox` | VirtualBox | Cross-platform, slower |
| `hyperkit` | macOS | Built-in hypervisor on older Macs |

To use a specific driver:
```bash
minikube start --driver=docker
```

---

## Further reading

- [Minikube documentation](https://minikube.sigs.k8s.io/docs/)
- [kubectl installation](https://kubernetes.io/docs/tasks/tools/)
