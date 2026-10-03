#!/usr/bin/env bash
# Extracts the homelab CA certificate from the cluster and installs it so that
# Docker, Helm, and k3s containerd all trust harbor.local over HTTPS.
#
# What it does:
#   1. Reads the CA cert from the cert-manager Secret (homelab-ca-secret)
#   2. Adds it to the OS trust store (/usr/local/share/ca-certificates)
#   3. Adds it to Docker's per-registry trust (/etc/docker/certs.d/harbor.local)
#   4. Creates /etc/rancher/k3s/registries.yaml so containerd can pull from Harbor
#   5. Restarts k3s to pick up the new registries config
#
# Requires: kubectl (connected to the cluster), sudo
# Usage: sudo -E ./trust-harbor-ca.sh
#   (-E preserves KUBECONFIG / kubectl context from the calling user)
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || err "This script must be run as root (sudo -E ./trust-harbor-ca.sh)"
command -v kubectl &>/dev/null || err "kubectl not found"

# ── Extract CA from the cluster ──────────────────────────────────
info "Extracting homelab CA certificate from the cluster"
CA_CERT="$(kubectl get secret homelab-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null)" \
  || err "Could not read homelab-ca-secret in cert-manager namespace"

[[ -n "$CA_CERT" ]] || err "CA cert is empty. Is cert-manager running?"
CA_PEM="$(echo "$CA_CERT" | base64 -d)"

# ── System trust store (Ubuntu/Debian) ──────────────────────────
info "Installing CA into system trust store"
echo "$CA_PEM" > /usr/local/share/ca-certificates/homelab-ca.crt
update-ca-certificates 2>/dev/null || true

# ── Docker per-registry trust ───────────────────────────────────
info "Installing CA for Docker (harbor.local)"
mkdir -p /etc/docker/certs.d/harbor.local
echo "$CA_PEM" > /etc/docker/certs.d/harbor.local/ca.crt

# ── k3s containerd registry config ──────────────────────────────
info "Configuring k3s containerd to trust harbor.local"
mkdir -p /etc/rancher/k3s
CA_PATH="/etc/rancher/k3s/harbor-ca.crt"
echo "$CA_PEM" > "$CA_PATH"

if [[ -f /etc/rancher/k3s/registries.yaml ]]; then
  info "Existing registries.yaml found, backing it up before replacing it"
  cp /etc/rancher/k3s/registries.yaml "/etc/rancher/k3s/registries.yaml.bak.$(date +%s)"
fi

cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  harbor.local:
    endpoint:
      - "https://harbor.local"
configs:
  "harbor.local":
    tls:
      ca_file: "$CA_PATH"
EOF

# ── Restart k3s ─────────────────────────────────────────────────
info "Restarting k3s to apply registry configuration"
systemctl restart k3s
info "Waiting for k3s to be ready"
until kubectl get nodes &>/dev/null 2>&1; do sleep 2; done

info "Done: harbor.local is now trusted by Docker, Helm, and k3s containerd"
