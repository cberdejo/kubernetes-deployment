#!/usr/bin/env bash
# Seals PostgreSQL credentials and patches the Helm template.
# Run this on first bootstrap and any time you rotate credentials.
# Usage: ./seal-credentials.sh [--redeploy]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"
SEALED_TEMPLATE="$SOLUTION/apps/todo-app/templates/database/postgres-sealedsecret.yaml"
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

POSTGRES_HOST="${RELEASE_NAME}-todo-app-postgres"
DATABASE_URI="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:5432/${POSTGRES_DB}"

# ── Wait for controller ───────────────────────────────────────────
info "Waiting for Sealed Secrets controller..."
kubectl rollout status deploy/sealed-secrets -n sealed-secrets --timeout=90s

# ── Temp files (auto-cleaned on exit) ─────────────────────────────
CERT_FILE="$(mktemp /tmp/sealed-secrets-cert.XXXXXX.pem)"
PLAIN_SECRET="$(mktemp /tmp/todo-db-secret.XXXXXX.yaml)"
SEALED_OUTPUT="$(mktemp /tmp/todo-db-sealedsecret.XXXXXX.yaml)"
PATCHED_TEMPLATE="$(mktemp /tmp/postgres-sealedsecret.XXXXXX.yaml)"
trap 'rm -f "$CERT_FILE" "$PLAIN_SECRET" "$SEALED_OUTPUT" "$PATCHED_TEMPLATE"' EXIT

# ── Fetch controller certificate ──────────────────────────────────
kubeseal --fetch-cert \
  --controller-name sealed-secrets \
  --controller-namespace sealed-secrets \
  > "$CERT_FILE"
info "Certificate fetched from controller"

# ── Create and seal the secret ────────────────────────────────────
kubectl create namespace todo --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic todo-db-secret \
  -n todo \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB" \
  --from-literal=DATABASE_URI="$DATABASE_URI" \
  --dry-run=client -o yaml > "$PLAIN_SECRET"

kubeseal \
  --format yaml \
  --cert "$CERT_FILE" \
  --scope namespace-wide \
  < "$PLAIN_SECRET" \
  > "$SEALED_OUTPUT"

info "Credentials sealed"

# ── Patch the Helm template ───────────────────────────────────────
python3 - "$SEALED_OUTPUT" "$SEALED_TEMPLATE" "$PATCHED_TEMPLATE" <<'PYEOF'
import sys, re, yaml

sealed_file, template_file, output_file = sys.argv[1], sys.argv[2], sys.argv[3]

with open(sealed_file) as f:
    sealed = yaml.safe_load(f)

encrypted = sealed["spec"]["encryptedData"]

with open(template_file) as f:
    content = f.read()

for key, value in encrypted.items():
    content, count = re.subn(
        rf"^(    {re.escape(key)}:)\s+.+$",
        rf"\1 {value}",
        content,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise SystemExit(f"expected exactly one template entry for {key}, found {count}")
    print(f"  patched: {key}")

with open(output_file, "w") as f:
    f.write(content)
PYEOF

cp "$PATCHED_TEMPLATE" "$SEALED_TEMPLATE"

info "Template patched: $SEALED_TEMPLATE"
warn "These encrypted blobs are cluster-specific — they can only be decrypted by this controller."
warn "They are safe to commit to Git."

# ── Optionally redeploy ───────────────────────────────────────────
if [[ "$REDEPLOY" == true ]]; then
  : "${DOCKERHUB_USER:?DOCKERHUB_USER not set in .env}"
  : "${IMAGE_TAG:?IMAGE_TAG not set in .env}"
  info "Redeploying todo-app..."
  helm upgrade --install "$RELEASE_NAME" "$SOLUTION/apps/todo-app" \
    -f "$SOLUTION/apps/todo-app/values/prod-values.yaml" \
    --set frontend.image.repository="docker.io/${DOCKERHUB_USER}/todo-frontend" \
    --set frontend.image.tag="${IMAGE_TAG}" \
    --set backend.image.repository="docker.io/${DOCKERHUB_USER}/todo-backend" \
    --set backend.image.tag="${IMAGE_TAG}" \
    -n todo \
    --wait --timeout 3m
  info "todo-app redeployed"
fi
