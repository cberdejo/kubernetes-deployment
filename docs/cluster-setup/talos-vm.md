# Cluster Setup — Talos Linux on VM / Bare Metal

Talos Linux is the production-like cluster option: fully declarative, immutable nodes, no SSH, everything managed through a gRPC API. This guide walks through setting up a Talos cluster on VMs or bare-metal machines using `talhelper`.

The cluster configuration lives in `docs/cluster-setup/talos/` alongside this guide.

---

## What is Talos Linux?

Talos Linux is a minimal, immutable Linux distribution designed exclusively to run Kubernetes. There is no shell, no SSH daemon, no package manager, no init system beyond the bare minimum. Every interaction with a Talos node happens through a gRPC API exposed by `talosctl`.

**The node is not a general-purpose machine you configure by hand — it is an appliance that runs exactly one workload.**

### Core properties

| Property | What it means |
|---|---|
| **Immutable** | The root filesystem is read-only. You cannot modify a running node, you apply a new machine config and it rebuilds itself. |
| **Declarative** | All node configuration lives in a single YAML file (`talconfig.yaml`). No imperative shell commands, no Ansible playbooks. |
| **API-driven** | No SSH. `talosctl` communicates with the Talos API over mTLS. |
| **Minimal attack surface** | No unused binaries, no package repos, no open ports except the Talos API and Kubernetes API. |
| **Ephemeral by default** | Nodes can be rebuilt from scratch with zero manual steps. Configuration is always in Git. |

---

## talhelper and talconfig.yaml

`talhelper` is a CLI tool that generates Talos machine configurations from a single declarative file, `talconfig.yaml`. Without talhelper, you would call `talosctl gen config` for each node and manage patches manually.

### talconfig.yaml structure

```yaml
clusterName: talos-k8s-lab        # Cluster name (used in generated kubeconfig)
talosVersion: v1.12.6             # Talos version for all nodes
kubernetesVersion: v1.35.3        # Kubernetes version
endpoint: https://<CP_IP>:6443   # API endpoint (control plane IP)
cniConfig:
  name: none                      # Install CNI manually (e.g. Cilium)

patches:                          # Applied to ALL nodes
  - |-
    machine:
      kubelet:
        extraArgs:
          rotate-server-certificates: "true"

controlPlane:
  patches:                        # Applied only to control plane nodes
    - |-
      cluster:
        proxy:
          disabled: true          # kube-proxy replaced by CNI

nodes:
  - hostname: controlplane-1
    ipAddress: <CP_IP>
    controlPlane: true
    schematic:
      customization:
        systemExtensions:
          officialExtensions:
            - siderolabs/iscsi-tools       # Required by Longhorn
            - siderolabs/util-linux-tools

  - hostname: worker-1
    ipAddress: <WORKER_IP>
    controlPlane: false
    schematic: *lab_schematic
```

The ready-to-use `talconfig.yaml` is at `docs/cluster-setup/talos/talconfig.yaml` — edit it with your actual IPs before running talhelper.

### talhelper workflow

```
talconfig.yaml  ──talhelper genconfig──►  clusterconfig/
                                            ├── talos-k8s-lab-controlplane-1.yaml
                                            └── talos-k8s-lab-worker-1.yaml
                                                        │
                                         talhelper gencommand apply
                                                        │
                                                        ▼
                                              talosctl apply-config
                                              (to each node by IP)
```

---

## Secrets management: SOPS + age

`talsecret.sops.yaml` holds the private CA keys and cluster bootstrap tokens. These must never be stored in plaintext.

1. **age** generates a key pair. The public key goes into `.sops.yaml`. The private key stays on your machine (never in Git).
2. **SOPS** encrypts `talsecret.sops.yaml` using the public key.
3. `talhelper genconfig` decrypts transparently when `SOPS_AGE_KEY_FILE` is set.

---

## Cluster Deployment

**Requirements:** 2 VMs (or physical machines), minimum 2 CPU / 2 GB RAM / 20 GB disk each.

Run all commands from the **`kubernetes_studying/`** project root. The cluster config lives in `docs/cluster-setup/talos/`.

### Step 1 — Install prerequisites

| Tool | Install guide |
|------|--------------|
| `talosctl` | [Getting started](https://www.talos.dev/v1.12/introduction/getting-started/#installing-talosctl) |
| `talhelper` | [Installation](https://budimanjojo.github.io/talhelper/latest/getting-started/installation/) |
| `sops` | [GitHub](https://github.com/getsops/sops) |
| `age` | [GitHub](https://github.com/FiloSottile/age) |

```bash
talosctl version --client && talhelper --version && sops --version && age-keygen --version
```

### Step 2 — Download the Talos ISO with extensions

Longhorn v1 requires `iscsiadm`. On Talos this must be baked into the node image as an extension.

1. Open [factory.talos.dev](https://factory.talos.dev)
2. Select **Bare-metal Machine** → version **`v1.12.6`** → **amd64**
3. Skip SecureBoot and Customization
4. In the **System Extensions** step, add:
   - `siderolabs/iscsi-tools`
   - `siderolabs/util-linux-tools`
5. Download the **ISO** from the final screen

Boot both VMs from this ISO. When each node boots it displays its IP in **maintenance mode** — note these IPs.

### Step 3 — Update talconfig.yaml with your VM IPs

Edit `docs/cluster-setup/talos/talconfig.yaml` and replace the placeholder IPs:

```yaml
endpoint: https://<CONTROL_PLANE_IP>:6443

nodes:
  - hostname: controlplane-1
    ipAddress: <CONTROL_PLANE_IP>
    ...
  - hostname: worker-1
    ipAddress: <WORKER_IP>
    ...
```

### Step 4 — Set up SOPS encryption

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Copy the public key from the output (`# public key: age1...`) into `docs/cluster-setup/talos/.sops.yaml`:

```yaml
creation_rules:
  - age: age1<YOUR_PUBLIC_KEY>
```

Generate and encrypt the Talos cluster secrets:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

cd docs/cluster-setup/talos
talhelper gensecret | sops --encrypt /dev/stdin > talsecret.sops.yaml
cd -
```

### Step 5 — Generate and apply Talos configuration

```bash
cd docs/cluster-setup/talos
talhelper genconfig
talhelper gencommand apply --extra-flags "--insecure" | bash
cd -
```

`--insecure` is required on fresh nodes before TLS is established. The nodes reboot and reconfigure automatically after receiving the config.

### Step 6 — Bootstrap the cluster

> **Run only once.** Running this on an already-initialized cluster wipes etcd.

Wait ~60 seconds after the nodes reboot, then:

```bash
cd docs/cluster-setup/talos
talhelper gencommand bootstrap | bash
cd -
```

### Step 7 — Get kubeconfig

```bash
cd docs/cluster-setup/talos
talhelper gencommand kubeconfig | bash
cd -

kubectl get nodes -o wide
```

Expected:
```
NAME              STATUS   ROLES           AGE   VERSION
controlplane-1    Ready    control-plane   2m    v1.35.3
worker-1          Ready    <none>          2m    v1.35.3
```

### Step 8 — Verify iscsi-tools

```bash
talosctl -n <CONTROL_PLANE_IP> ls /usr/sbin/iscsiadm
talosctl -n <WORKER_IP> ls /usr/sbin/iscsiadm
```

Both should return the file path without error. Then return to the guide that sent you here.

### Teardown

Shut down or delete the VMs. To reset a node to maintenance mode (wipes disk):

```bash
talosctl -n <NODE_IP> reset --graceful=false
```

---

## Exercises

### Exercise 1 — Read the generated machine config

After `talhelper genconfig`, inspect one of the generated files:

```bash
cat docs/cluster-setup/talos/clusterconfig/talos-k8s-lab-controlplane-1.yaml
```

Find and note what each section contains:
- `machine.network` — what IP and gateway are set?
- `cluster.etcd` — what certificate is embedded?
- `cluster.apiServer.certSANs` — what additional names is the API cert valid for?

### Exercise 2 — Apply a patch

Add a patch to `talconfig.yaml` that sets the NTP server:

```yaml
patches:
  - |-
    machine:
      time:
        servers:
          - pool.ntp.org
```

Regenerate and apply:

```bash
cd docs/cluster-setup/talos
talhelper genconfig
talhelper gencommand apply | bash
cd -
```

### Exercise 3 — Add a node label

Add a `nodeLabels` block to the worker in `talconfig.yaml`:

```yaml
- hostname: worker-1
  ...
  nodeLabels:
    node-role: storage
```

Regenerate, apply, and verify:
```bash
kubectl get node worker-1 --show-labels
```

### Exercise 4 — Rotate secrets

Research what happens if `talsecret.sops.yaml` is lost:
- If the cluster is running, it continues — the file is only needed to generate new configs or add nodes.
- To rotate the CA: `talosctl rotate-ca`. Research when this is needed and what it does.

---

## Talos vs alternatives

| | Talos | k3s | RKE2 | kubeadm | MicroK8s |
|---|---|---|---|---|---|
| **OS type** | Immutable, minimal | Standard Linux | Standard Linux | Standard Linux | Ubuntu snap |
| **SSH access** | No | Yes | Yes | Yes | Yes |
| **Declarative node config** | Yes (talconfig.yaml) | Partial | Partial | No | No |
| **Built for Kubernetes only** | Yes | Yes | Yes | No | Yes |
| **Complexity** | Medium | Low | Medium | High | Low |
| **Good for production** | Yes | Yes (edge/small) | Yes | Yes (with effort) | No |
| **CIS compliance** | Strong (by design) | Needs config | Built-in | Needs config | Needs config |

---

## Further reading

- [Talos Linux documentation](https://www.talos.dev/v1.12/)
- [talhelper documentation](https://budimanjojo.github.io/talhelper/latest/)
- [Talos Image Factory](https://factory.talos.dev/)
- [SOPS documentation](https://github.com/getsops/sops)
- [age encryption](https://age-encryption.org/)
