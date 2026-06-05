#!/usr/bin/env bash
# Bootstraps Phase 06 from a clean cluster.
# Installs MetalLB, cert-manager, Envoy Gateway, Longhorn, Sealed Secrets,
# seals credentials, and deploys todo-app.
#
# Prerequisites:
#   - kubectl pointing at a running cluster with iscsiadm on every node
#   - helm installed
#   - .env filled in (copy from .env.example)
#
# Usage: ./bootstrap.sh
#
# Teardown (manual):
#   helm uninstall "$RELEASE_NAME" -n todo
#   helm uninstall sealed-secrets-prod -n sealed-secrets
#   helm uninstall cluster-longhorn -n longhorn
#   helm uninstall cluster-envoy-gateway -n envoy-gateway
#   helm uninstall cluster-cert-manager-issuers -n cert-manager
#   helm uninstall cluster-cert-manager -n cert-manager
#   helm uninstall cluster-metallb -n metallb-system
#   kubectl delete namespace todo sealed-secrets longhorn envoy-gateway cert-manager metallb-system
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$SCRIPT_DIR/.."
ENV_FILE="$SCRIPT_DIR/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${CYAN}━━━  %s  ━━━${NC}\n" "$*"; }

# ── Load credentials ──────────────────────────────────────────────
step "Loading configuration"
[[ -f "$ENV_FILE" ]] || err ".env not found — copy .env.example to .env and fill in your values."
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${POSTGRES_USER:?POSTGRES_USER not set in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"
: "${DOCKERHUB_USER:?DOCKERHUB_USER not set in .env}"
: "${IMAGE_TAG:?IMAGE_TAG not set in .env}"
RELEASE_NAME="${RELEASE_NAME:-my-app}"
info "Release name: $RELEASE_NAME"

# ── Check required tools ──────────────────────────────────────────
step "Checking prerequisites"
command -v kubectl &>/dev/null || err "kubectl not found — install it first."
command -v helm    &>/dev/null || err "helm not found — install it first."
kubectl cluster-info &>/dev/null || err "Cannot reach cluster. Check your kubectl context with: kubectl config current-context"
info "Cluster: $(kubectl config current-context)"
info "kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client | head -1)"
info "helm $(helm version --short)"

# ── Install kubeseal if missing ───────────────────────────────────
if ! command -v kubeseal &>/dev/null; then
  warn "kubeseal not found — installing..."
  KUBESEAL_VERSION="0.27.0"
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  [[ "$ARCH" == "x86_64" ]]  && ARCH="amd64"
  [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-${OS}-${ARCH}.tar.gz" \
    | tar -xz -C "$TMP"
  sudo install -m 755 "$TMP/kubeseal" /usr/local/bin/kubeseal
  info "kubeseal $(kubeseal --version) installed"
else
  info "kubeseal $(kubeseal --version)"
fi

# ── Step 1: Namespaces ────────────────────────────────────────────
step "Creating namespaces"

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
---
apiVersion: v1
kind: Namespace
metadata:
  name: envoy-gateway
---
apiVersion: v1
kind: Namespace
metadata:
  name: longhorn
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: privileged
    pod-security.kubernetes.io/warn-version: latest
    expose-via-gateway: "true"
---
apiVersion: v1
kind: Namespace
metadata:
  name: sealed-secrets
---
apiVersion: v1
kind: Namespace
metadata:
  name: todo
  labels:
    expose-via-gateway: "true"
EOF

info "Namespaces ready"

# ── Step 2: MetalLB ───────────────────────────────────────────────
step "Installing MetalLB"

helm repo add metallb https://metallb.github.io/metallb --force-update &>/dev/null
helm repo update metallb &>/dev/null
helm dependency update "$SOLUTION/apps/metallb"

helm upgrade --install cluster-metallb "$SOLUTION/apps/metallb" \
  -f "$SOLUTION/apps/metallb/values/prod-values.yaml" \
  -n metallb-system \
  --wait --timeout 3m

info "MetalLB installed"

# ── Step 3: cert-manager ──────────────────────────────────────────
step "Installing cert-manager"

helm dependency update "$SOLUTION/apps/cert-manager"

helm upgrade --install cluster-cert-manager "$SOLUTION/apps/cert-manager" \
  -f "$SOLUTION/apps/cert-manager/values/prod-values.yaml" \
  -n cert-manager \
  --wait --timeout 3m

info "cert-manager installed"

# ── Step 3.5: Wait for cert-manager CRDs ────────────────────────
step "Waiting for cert-manager CRDs"

kubectl wait --for=condition=Established \
  crd/certificates.cert-manager.io \
  crd/clusterissuers.cert-manager.io \
  --timeout=120s

info "cert-manager CRDs established"

# ── Step 4: cert-manager issuers ──────────────────────────────────
step "Installing cert-manager issuers"

helm dependency update "$SOLUTION/apps/cert-manager-issuers"

helm upgrade --install cluster-cert-manager-issuers "$SOLUTION/apps/cert-manager-issuers" \
  -n cert-manager \
  --wait --timeout 2m

info "cert-manager issuers installed"

# ── Step 5: Envoy Gateway ───────────────────────────────────────
step "Installing Envoy Gateway"

helm dependency update "$SOLUTION/apps/envoy-gateway"

helm upgrade --install cluster-envoy-gateway "$SOLUTION/apps/envoy-gateway" \
  -f "$SOLUTION/apps/envoy-gateway/values/prod-values.yaml" \
  -n envoy-gateway \
  --wait --timeout 3m

info "Envoy Gateway installed"

# ── Step 6: Longhorn ──────────────────────────────────────────────
step "Installing Longhorn"

if ! iscsiadm --version &>/dev/null 2>&1; then
  warn "iscsiadm not found on this machine."
  warn "On k3s/Linux: sudo apt install open-iscsi && sudo systemctl enable --now iscsid"
  warn "On Talos: rebuild nodes with the iscsi-tools extension from factory.talos.dev"
  err  "Fix iscsiadm first — Longhorn will crash without it."
fi

helm repo add longhorn https://charts.longhorn.io --force-update &>/dev/null
helm repo update longhorn &>/dev/null
helm dependency update "$SOLUTION/apps/longhorn"

helm upgrade --install cluster-longhorn "$SOLUTION/apps/longhorn" \
  -f "$SOLUTION/apps/longhorn/values/prod-values.yaml" \
  -n longhorn \
  --wait --timeout 5m

info "Longhorn installed"
kubectl get storageclass | grep longhorn || warn "longhorn StorageClass not found — check Longhorn pods"

# ── Step 7: Sealed Secrets controller ────────────────────────────
step "Installing Sealed Secrets controller"

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update &>/dev/null
helm repo update sealed-secrets &>/dev/null
helm dependency update "$SOLUTION/apps/sealed-secrets"

helm upgrade --install sealed-secrets-prod "$SOLUTION/apps/sealed-secrets" \
  -f "$SOLUTION/apps/sealed-secrets/values/prod-values.yaml" \
  -n sealed-secrets \
  --wait --timeout 2m

info "Sealed Secrets controller running"

# ── Step 8: Seal credentials ──────────────────────────────────────
step "Sealing PostgreSQL credentials"
"$SCRIPT_DIR/seal-credentials.sh"

# ── Step 9: Deploy todo-app ───────────────────────────────────────
step "Deploying todo-app"

helm upgrade --install "$RELEASE_NAME" "$SOLUTION/apps/todo-app" \
  -f "$SOLUTION/apps/todo-app/values/prod-values.yaml" \
  --set frontend.image.repository="docker.io/${DOCKERHUB_USER}/todo-frontend" \
  --set frontend.image.tag="${IMAGE_TAG}" \
  --set backend.image.repository="docker.io/${DOCKERHUB_USER}/todo-backend" \
  --set backend.image.tag="${IMAGE_TAG}" \
  -n todo \
  --wait --timeout 3m

info "todo-app deployed"

# ── Verify ────────────────────────────────────────────────────────
step "Verification"

echo ""
echo "MetalLB pods:"
kubectl get pods -n metallb-system --no-headers 2>/dev/null | awk '{printf "  %-50s %s\n", $1, $3}' || true

echo ""
echo "cert-manager pods:"
kubectl get pods -n cert-manager --no-headers | awk '{printf "  %-50s %s\n", $1, $3}'

echo ""
echo "Envoy Gateway pods:"
kubectl get pods -n envoy-gateway --no-headers | awk '{printf "  %-50s %s\n", $1, $3}'

echo ""
echo "Longhorn pods:"
kubectl get pods -n longhorn --no-headers | awk '{printf "  %-50s %s\n", $1, $3}'

echo ""
echo "Sealed Secrets:"
kubectl get pods -n sealed-secrets --no-headers | awk '{printf "  %-50s %s\n", $1, $3}'

echo ""
echo "todo-app pods:"
kubectl get pods -n todo --no-headers | awk '{printf "  %-50s %s\n", $1, $3}'

echo ""
echo "Gateway service:"
kubectl get svc -n envoy-gateway

GATEWAY_IP="$(kubectl get svc -n envoy-gateway -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "$GATEWAY_IP" ]]; then
  GATEWAY_IP="$(kubectl get svc -n envoy-gateway -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
fi

echo ""
info "Bootstrap complete."
if [[ -n "$GATEWAY_IP" ]]; then
  info "Add to /etc/hosts:  ${GATEWAY_IP}  todo.local longhorn.local"
else
  warn "Gateway EXTERNAL-IP not assigned yet — run: kubectl get svc -n envoy-gateway"
  warn "Then add to /etc/hosts:  <EXTERNAL-IP>  todo.local longhorn.local"
fi
