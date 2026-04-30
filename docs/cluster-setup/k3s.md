# Cluster Setup — k3s on Linux

k3s installs as a single binary on any Linux machine — no extra VMs required. It is the fastest path to a Kubernetes cluster for learning and local development.

**Requirements:** Linux machine (or VM) with at least 2 CPU cores, 4 GB RAM, 20 GB free disk. Works on Ubuntu, Debian, Fedora, RHEL, etc.

---

## How it differs from Talos

| | Talos | k3s |
|---|---|---|
| OS | Immutable, Kubernetes-only | Standard Linux |
| SSH | No | Yes |
| Package manager | No | Yes (apt/dnf/etc.) |
| Node config | Declarative (talconfig.yaml) | Flags + per-node config.yaml |
| `iscsiadm` | Baked into image via extension | `apt install open-iscsi` |
| Cluster creation | talhelper + ISO boot | Single curl command |

---

## Step 1 — Install Longhorn prerequisites

Longhorn's V1 data engine requires `iscsiadm` on every node. On standard Linux this is a regular package:

```bash
# Ubuntu / Debian
sudo apt update
sudo apt install -y open-iscsi nfs-common

# Fedora / RHEL / Rocky
sudo dnf install -y iscsi-initiator-utils nfs-utils

# Enable and start the iSCSI service
sudo systemctl enable --now iscsid

# Verify
iscsiadm --version
```

---

## Step 2 — Install k3s

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --write-kubeconfig-mode 644
```

`--disable traefik` skips k3s's bundled ingress controller so you can install your own later.

Set up kubectl access:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER ~/.kube/config

kubectl get nodes -o wide
```

Expected:
```
NAME        STATUS   ROLES                  AGE   VERSION
<hostname>  Ready    control-plane,master   1m    v1.35.x+k3s1
```

---

## Step 3 — Handle the default StorageClass

k3s ships with a `local-path` StorageClass set as default. If your workloads set `storageClassName` explicitly this is not a blocker, but it is cleaner to remove the default annotation:

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

kubectl get storageclass
```

---

## Step 4 — Verify and return

```bash
kubectl get nodes
iscsiadm --version
systemctl is-active iscsid
```

All checks should pass. Return to the guide that sent you here and continue from the Longhorn installation step.

---

## Teardown

```bash
/usr/local/bin/k3s-uninstall.sh
```

This removes k3s, all Kubernetes resources, and the CNI network interfaces. Data stored by Longhorn on disk is also deleted.

---

## Multi-node k3s (optional)

If you have multiple machines available, add workers after the control plane is up:

```bash
# On the control plane — get the node token
sudo cat /var/lib/rancher/k3s/server/node-token

# On each worker — also run Step 1 (open-iscsi) first
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<CONTROL_PLANE_IP>:6443 \
  K3S_TOKEN=<NODE_TOKEN> sh -
```

With multiple nodes you can increase Longhorn's replica count and observe actual distributed storage behavior.

---

## Further reading

- [k3s documentation](https://docs.k3s.io/)
- [Longhorn prerequisites](https://longhorn.io/docs/latest/deploy/install/#installation-requirements)
