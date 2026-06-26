#!/usr/bin/env bash
# Seals PostgreSQL credentials into a standalone SealedSecret manifest and
# applies it to the cluster. Run this on first bootstrap and any time you
# rotate credentials.
#
# Unlike the rest of the secrets progression (Phase 05+ generates the Secret
# in-cluster with the chart's bootstrap hook), Phase 04 deliberately teaches the
# SealedSecret approach: the *encrypted* blob is committed to Git and the
# controller decrypts it into the `todo-db-secret` Secret in-cluster. The
# canonical chart consumes it via `postgres.existingSecret: todo-db-secret`
# (set in apps/todo-app/values/prod-values.yaml), which disables the chart's
# own bootstrap hook for this phase.
#
# Usage: ./seal-credentials.sh [--redeploy]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTION/../../.." && pwd)"
CHART_DIR="$REPO_ROOT/application/chart"
CHART_VALUES="$SOLUTION/apps/todo-app/values/prod-values.yaml"
# Committed, encrypted-at-rest SealedSecret manifest (safe to push to Git).
SEALED_DIR="$SOLUTION/sealed"
SEALED_MANIFEST="$SEALED_DIR/todo-db-sealedsecret.yaml"
ENV_FILE="$SCRIPT_DIR/.env"
REDEPLOY=false
[[ "${1:-}" == "--redeploy" ]] && REDEPLOY=true

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }

# ── Load credentials ──────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || err ".env not found — copy .env.example to .env and fill in your values."
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${POSTGRES_USER:?POSTGRES_USER not set in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB not set in .env}"
RELEASE_NAME="${RELEASE_NAME:-my-app}"

# Postgres service name matches the chart fullname convention: <release>-todo-app-postgres
POSTGRES_HOST="${RELEASE_NAME}-todo-app-postgres"
DATABASE_URI="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:5432/${POSTGRES_DB}"

# ── Wait for controller ───────────────────────────────────────────
info "Waiting for Sealed Secrets controller..."
kubectl rollout status deploy/sealed-secrets -n kube-system --timeout=90s

# ── Temp files (auto-cleaned on exit) ─────────────────────────────
CERT_FILE="$(mktemp /tmp/sealed-secrets-cert.XXXXXX.pem)"
PLAIN_SECRET="$(mktemp /tmp/todo-db-secret.XXXXXX.yaml)"
trap 'rm -f "$CERT_FILE" "$PLAIN_SECRET"' EXIT

# ── Fetch controller certificate ──────────────────────────────────
kubeseal --fetch-cert \
  --controller-name  sealed-secrets \
  --controller-namespace kube-system \
  > "$CERT_FILE"
info "Certificate fetched from controller"

# ── Build the plaintext Secret (never written to Git) ─────────────
kubectl create namespace todo --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic todo-db-secret \
  -n todo \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB" \
  --from-literal=DATABASE_URI="$DATABASE_URI" \
  --dry-run=client -o yaml > "$PLAIN_SECRET"

# ── Seal into a standalone, committable manifest ──────────────────
mkdir -p "$SEALED_DIR"
kubeseal \
  --format yaml \
  --cert "$CERT_FILE" \
  --scope namespace-wide \
  < "$PLAIN_SECRET" \
  > "$SEALED_MANIFEST"

info "SealedSecret written: ${SEALED_MANIFEST#"$REPO_ROOT"/}"
warn "The encrypted blob is cluster-specific and safe to commit to Git."

# ── Apply it; the controller decrypts it into todo-db-secret ──────
kubectl apply -f "$SEALED_MANIFEST"
info "Applied — waiting for the controller to materialize todo-db-secret..."
for _ in $(seq 1 30); do
  if kubectl get secret todo-db-secret -n todo &>/dev/null; then
    info "Secret todo-db-secret is ready in namespace todo"
    break
  fi
  sleep 2
done
kubectl get secret todo-db-secret -n todo &>/dev/null \
  || err "todo-db-secret was not created — check the controller logs in kube-system."

# ── Optionally redeploy ───────────────────────────────────────────
if [[ "$REDEPLOY" == true ]]; then
  : "${DOCKERHUB_USER:?DOCKERHUB_USER not set in .env}"
  : "${IMAGE_TAG:?IMAGE_TAG not set in .env}"
  info "Redeploying todo-app from the canonical chart..."
  helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    -f "$CHART_VALUES" \
    --set frontend.image.repository="docker.io/${DOCKERHUB_USER}/todo-frontend" \
    --set frontend.image.tag="${IMAGE_TAG}" \
    --set backend.image.repository="docker.io/${DOCKERHUB_USER}/todo-backend" \
    --set backend.image.tag="${IMAGE_TAG}" \
    -n todo \
    --wait --timeout 3m
  info "todo-app redeployed"
fi
