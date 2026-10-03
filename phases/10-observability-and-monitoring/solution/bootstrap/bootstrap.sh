#!/usr/bin/env bash
# Bootstraps Phase 10 on a clean cluster: installs the Flux Operator, points
# Flux at this repository, and lets Flux build the whole platform from Git.
#
# Compare with Phase 08: there, this script ran `helm upgrade --install` eight
# times in the right order. Here it only installs Flux; the order, the
# versions and the configuration all live in Git and Flux applies them.
# The remaining imperative steps are the ones GitOps cannot do by definition:
# creating the first credentials, trusting the CA on the node, and seeding Harbor.
#
# Prerequisites:
#   - A clean k3s cluster (Kubernetes >= 1.34) with open-iscsi on every node
#   - kubectl, helm, kubeseal, docker, curl installed
#   - This phase pushed to the branch Flux syncs (main)
#   - Application images built locally: frontend:<tag>, backend:<tag>
#   - .env filled in (copy from .env.example)
#   - /etc/hosts mapping todo.local, longhorn.local, authentik.local,
#     harbor.local and grafana.local to GATEWAY_IP (clusters/prod/cluster-settings.yaml)
#
# Usage: ./bootstrap.sh
#
# Teardown: GitOps objects are removed by removing them from Git. To wipe the
# cluster completely on k3s: /usr/local/bin/k3s-uninstall.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
FLUX_NS=flux-system

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${CYAN}━━━  %s  ━━━${NC}\n" "$*"; }

# Waits until a Flux Kustomization exists and reports Ready.
wait_ks() {
  local name="$1" timeout="${2:-20m}"
  info "Waiting for Kustomization/$name (timeout $timeout)"
  for _ in $(seq 1 60); do
    kubectl get kustomization "$name" -n "$FLUX_NS" &>/dev/null && break
    sleep 5
  done
  kubectl wait kustomization/"$name" -n "$FLUX_NS" \
    --for=condition=Ready --timeout="$timeout" \
    || err "Kustomization/$name not Ready. Inspect with: kubectl describe kustomization $name -n $FLUX_NS"
}

# Asks Flux to reconcile an object now instead of waiting for its interval.
reconcile() {
  kubectl annotate --overwrite "$1" -n "$2" \
    reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null
}

# The platform credentials, decrypted by the Sealed Secrets controller.
PLATFORM_SECRETS=(
  authentik/authentik-secrets
  harbor/harbor-secrets
  authentik/grafana-oidc
  monitoring/grafana-oidc
)

platform_secrets_ready() {
  local ref
  for ref in "${PLATFORM_SECRETS[@]}"; do
    kubectl get secret "${ref#*/}" -n "${ref%/*}" &>/dev/null || return 1
  done
}

# True when the controller reported that it cannot decrypt a SealedSecret
# (sealed for another cluster's key): no point in waiting any longer.
platform_secrets_undecryptable() {
  local ref synced
  for ref in "${PLATFORM_SECRETS[@]}"; do
    synced="$(kubectl get sealedsecret "${ref#*/}" -n "${ref%/*}" \
      -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || true)"
    [[ "$synced" == "False" ]] && return 0
  done
  return 1
}

# Waits up to $1 seconds for the platform Secrets to be decrypted. Gives up
# early on a decryption error unless $2 is "no-fail-fast" (right after
# re-sealing, the old error is still reported until the new commit lands).
wait_platform_secrets() {
  local timeout="$1" fail_fast="${2:-fail-fast}" waited=0
  while (( waited < timeout )); do
    platform_secrets_ready && return 0
    [[ "$fail_fast" == "fail-fast" ]] && platform_secrets_undecryptable && return 1
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# ── Load configuration ────────────────────────────────────────────
step "Loading configuration"
[[ -f "$ENV_FILE" ]] || err ".env not found. Copy .env.example to .env and fill in your values."
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${GITHUB_USER:?GITHUB_USER not set in .env}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN not set in .env}"
: "${IMAGE_TAG:?IMAGE_TAG not set in .env}"
: "${HARBOR_ADMIN_PASSWORD:?HARBOR_ADMIN_PASSWORD not set in .env}"
# Single source of truth for the operator version: the HelmRelease that
# adopts this installation (so bootstrap and Git can never disagree).
FLUX_OPERATOR_VERSION="$(awk '$1 == "tag:" { gsub(/"/, "", $2); print $2; exit }' \
  "$SOLUTION/clusters/prod/flux-system/flux-operator.yaml")"
[[ -n "$FLUX_OPERATOR_VERSION" ]] || err "Could not read the Flux Operator version from clusters/prod/flux-system/flux-operator.yaml"
SEALED_SECRETS_KEY_BACKUP="${SEALED_SECRETS_KEY_BACKUP:-$HOME/.homelab/sealed-secrets-key.yaml}"
HARBOR_PROJECT="${HARBOR_PROJECT:-todo}"
HARBOR_HOST="${HARBOR_HOST:-harbor.local}"
HARBOR_USER="${HARBOR_USER:-admin}"

# ── Check prerequisites ───────────────────────────────────────────
step "Checking prerequisites"
for tool in kubectl helm kubeseal docker curl; do
  command -v "$tool" &>/dev/null || err "$tool not found. Install it first."
done
kubectl cluster-info &>/dev/null || err "Cannot reach cluster. Check: kubectl config current-context"
info "Cluster: $(kubectl config current-context)"

SERVER_MINOR="$(kubectl version -o json | sed -n '/serverVersion/,/}/s/.*"minor": *"\([0-9]*\).*/\1/p')"
[[ -n "$SERVER_MINOR" && "$SERVER_MINOR" -ge 34 ]] \
  || err "Flux 2.9 requires Kubernetes >= 1.34 (server minor version: ${SERVER_MINOR:-unknown}). Upgrade k3s first."
info "Kubernetes 1.${SERVER_MINOR}, supported by Flux 2.9"

if ! iscsiadm --version &>/dev/null; then
  warn "iscsiadm not found on this machine. Longhorn needs open-iscsi on every node:"
  warn "  sudo apt install open-iscsi && sudo systemctl enable --now iscsid"
fi
if command -v flux &>/dev/null; then
  info "flux CLI $(flux version --client 2>/dev/null | head -1) (optional, handy for debugging)"
else
  warn "flux CLI not installed (optional, but recommended): curl -s https://fluxcd.io/install.sh | sudo bash"
fi

# ── Step 1: Git credentials for Flux ──────────────────────────────
step "Creating Git credentials for Flux"
kubectl create namespace "$FLUX_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic flux-system -n "$FLUX_NS" \
  --from-literal=username="$GITHUB_USER" \
  --from-literal=password="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
info "Secret $FLUX_NS/flux-system ready (the only credential created by hand)"

# ── Step 2: Restore the Sealed Secrets key ────────────────────────
step "Restoring the Sealed Secrets key"
if [[ -f "$SEALED_SECRETS_KEY_BACKUP" ]]; then
  bash "$SOLUTION/scripts/restore-sealed-secrets-key.sh" "$SEALED_SECRETS_KEY_BACKUP"
  info "Existing SealedSecrets in Git will decrypt in this cluster"
else
  warn "No backup at $SEALED_SECRETS_KEY_BACKUP. The controller will generate a new key."
  warn "Any SealedSecret already in Git will need to be re-sealed (handled below)."
fi

# ── Step 3: Flux Operator ─────────────────────────────────────────
step "Installing the Flux Operator ${FLUX_OPERATOR_VERSION}"
helm upgrade --install flux-operator \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version "$FLUX_OPERATOR_VERSION" \
  -n "$FLUX_NS" --wait --timeout 5m
info "Flux Operator installed; Flux will adopt this release from Git"

# ── Step 4: FluxInstance ──────────────────────────────────────────
step "Creating the FluxInstance"
kubectl apply -f "$SOLUTION/clusters/prod/flux-system/flux-instance.yaml"
kubectl wait fluxinstance/flux -n "$FLUX_NS" --for=condition=Ready --timeout=10m \
  || err "FluxInstance not Ready. Check: kubectl describe fluxinstance flux -n $FLUX_NS"
info "Flux is running and syncing $(kubectl get fluxinstance flux -n "$FLUX_NS" -o jsonpath='{.spec.sync.url}')"

# ── Step 5: Infrastructure layers ─────────────────────────────────
step "Waiting for the infrastructure layers"
wait_ks infra-controllers 20m
wait_ks infra-configs 10m

# ── Step 6: Platform secrets ──────────────────────────────────────
step "Platform secrets"
if [[ ! -f "$SEALED_SECRETS_KEY_BACKUP" ]]; then
  bash "$SOLUTION/scripts/backup-sealed-secrets-key.sh" "$SEALED_SECRETS_KEY_BACKUP"
fi

if platform_secrets_ready; then
  info "Platform secrets already decrypted in the cluster"
else
  if compgen -G "$SOLUTION/platform-secrets/*.yaml" >/dev/null; then
    info "Sealed files found in Git, waiting for the controller to decrypt them"
    reconcile kustomization/platform-secrets "$FLUX_NS"
    wait_platform_secrets 180 || true
  fi
  if ! platform_secrets_ready; then
    warn "Platform secrets are missing or were sealed for another cluster key."
    bash "$SOLUTION/scripts/seal-platform-secrets.sh"
    echo ""
    read -rp "Commit and push platform-secrets/, then press Enter to continue… "
    reconcile gitrepository/flux-system "$FLUX_NS"
    reconcile kustomization/platform-secrets "$FLUX_NS"
    wait_platform_secrets 300 no-fail-fast \
      || err "Platform secrets not decrypted. Check: kubectl get sealedsecrets -A"
  fi
  info "Platform secrets decrypted"
fi
wait_ks platform-secrets 5m

# ── Step 7: Node trust + in-cluster DNS ───────────────────────────
step "Trusting the homelab CA on the node"
info "Running trust-harbor-ca.sh (requires sudo, restarts k3s)"
sudo -E bash "$SOLUTION/scripts/trust-harbor-ca.sh"
kubectl wait --for=condition=Ready nodes --all --timeout=120s
info "Restarting CoreDNS so it loads the coredns-custom ConfigMap"
kubectl rollout restart deploy/coredns -n kube-system
kubectl rollout status deploy/coredns -n kube-system --timeout=120s

# ── Step 8: Platform services ─────────────────────────────────────
step "Waiting for the platform layer (authentik, Harbor)"
wait_ks platform 25m

# ── Step 9: Seed Harbor ───────────────────────────────────────────
step "Seeding Harbor with the first images and chart"
# Seeding runs on this machine, so harbor.local must resolve here; the
# CoreDNS entries only help Pods inside the cluster.
GATEWAY_IP="$(kubectl get configmap cluster-settings -n "$FLUX_NS" -o jsonpath='{.data.GATEWAY_IP}')"
RESOLVED_IP="$(getent hosts "$HARBOR_HOST" | awk '{ print $1; exit }' || true)"
[[ "$RESOLVED_IP" == "$GATEWAY_IP" ]] \
  || err "$HARBOR_HOST resolves to '${RESOLVED_IP:-nothing}', expected $GATEWAY_IP. Add to /etc/hosts and re-run:  ${GATEWAY_IP}  todo.local longhorn.local authentik.local harbor.local grafana.local"
info "$HARBOR_HOST resolves to the Gateway ($GATEWAY_IP)"

HARBOR_URL="https://${HARBOR_HOST}"
for i in $(seq 1 60); do
  curl -sk "${HARBOR_URL}/api/v2.0/health" | grep -q '"status":"healthy"' && break
  [[ $i -eq 60 ]] && err "Harbor API did not become healthy within 2 minutes"
  sleep 2
done
info "Harbor API is healthy"

HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
  -u "${HARBOR_USER}:${HARBOR_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -X POST "${HARBOR_URL}/api/v2.0/projects" \
  -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"metadata\":{\"public\":\"true\"}}")
case "$HTTP_CODE" in
  201) info "Project '${HARBOR_PROJECT}' created" ;;
  409) info "Project '${HARBOR_PROJECT}' already exists" ;;
  *)   err "Failed to create project (HTTP $HTTP_CODE)" ;;
esac

bash "$SOLUTION/scripts/push-images.sh"
bash "$SOLUTION/scripts/publish-chart.sh"

# ── Step 10: Applications ─────────────────────────────────────────
step "Waiting for the applications"
reconcile ocirepository/todo-app "$FLUX_NS"
wait_ks apps 15m
wait_ks image-automation 5m

# ── Step 11: Observability ────────────────────────────────────────
# Deployed in parallel with the platform layer; usually Ready by now.
step "Waiting for the monitoring layer (Prometheus, Grafana, Loki, Alloy)"
wait_ks monitoring 20m

# ── Verify ────────────────────────────────────────────────────────
step "Verification"
echo ""
echo "Flux Kustomizations:"
kubectl get kustomizations -n "$FLUX_NS"
echo ""
echo "Helm releases managed by Flux:"
kubectl get helmreleases -A
echo ""
echo "Image automation:"
kubectl get imagepolicies -n "$FLUX_NS"

echo ""
info "Bootstrap complete. From now on, the cluster changes only through Git."
echo ""
info "Services:"
info "  todo-app:     https://todo.local"
info "  Harbor UI:    https://harbor.local  (admin / your HARBOR_ADMIN_PASSWORD)"
info "  Longhorn UI:  https://longhorn.local"
info "  Authentik:    https://authentik.local  (akadmin / your bootstrap password)"
info "  Grafana:      https://grafana.local    (\"Sign in with authentik\")"
echo ""
info "Next steps:"
info "  1. Configure the authentik providers (same as Phase 07)"
info "  2. Release a new image and watch Flux deploy it (tasks.md, Step 10)"
warn "Store $SEALED_SECRETS_KEY_BACKUP somewhere safe and offline."
