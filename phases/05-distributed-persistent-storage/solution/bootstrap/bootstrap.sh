#!/usr/bin/env bash
# Bootstraps Phase 05 from a clean cluster.
# Installs Longhorn, Sealed Secrets, seals credentials, and deploys todo-app.
#
# Prerequisites:
#   - kubectl pointing at a running cluster with iscsiadm on every node
#   - helm installed
#   - .env filled in (copy from .env.example)
#
# Usage: ./bootstrap.sh
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

# ── Step 1: Longhorn ──────────────────────────────────────────────
step "Installing Longhorn"

# Verify iscsiadm is reachable before wasting time on the install
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
  --create-namespace \
  --wait --timeout 5m

info "Longhorn installed"
kubectl get storageclass | grep longhorn || warn "longhorn StorageClass not found — check Longhorn pods"

# ── Step 2: Sealed Secrets controller ────────────────────────────
step "Installing Sealed Secrets controller"

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update &>/dev/null
helm repo update sealed-secrets &>/dev/null
helm dependency update "$SOLUTION/apps/sealed-secrets"

helm upgrade --install sealed-secrets-prod "$SOLUTION/apps/sealed-secrets" \
  -f "$SOLUTION/apps/sealed-secrets/values/prod-values.yaml" \
  -n sealed-secrets \
  --create-namespace \
  --wait --timeout 2m

info "Sealed Secrets controller running"

# ── Step 3: Seal credentials ──────────────────────────────────────
step "Sealing PostgreSQL credentials"
"$SCRIPT_DIR/seal-credentials.sh"

# ── Step 4: Deploy todo-app ───────────────────────────────────────
step "Deploying todo-app"

kubectl create namespace todo --dry-run=client -o yaml | kubectl apply -f -

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
echo "Nodes:"
kubectl get nodes -o wide

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
echo "PVC:"
kubectl get pvc -n todo

echo ""
info "Bootstrap complete."
info "Frontend NodePort: $(kubectl get svc -n todo -o jsonpath='{.items[?(@.spec.type=="NodePort")].spec.ports[0].nodePort}' 2>/dev/null || echo 'check kubectl get svc -n todo')"
