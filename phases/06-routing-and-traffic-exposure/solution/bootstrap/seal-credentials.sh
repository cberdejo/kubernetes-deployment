#!/usr/bin/env bash
# Seals PostgreSQL credentials and patches the Helm template.
# Reads values from bootstrap/terraform/terraform.tfvars.
# Run after Sealed Secrets is deployed and before todo-app.
#
# Usage: ./seal-credentials.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"
SEALED_TEMPLATE="$SOLUTION/apps/todo-app/templates/database/postgres-sealedsecret.yaml"
TFVARS="$SCRIPT_DIR/terraform/terraform.tfvars"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }

# ── Dependency checks ─────────────────────────────────────────────
command -v kubectl  >/dev/null 2>&1 || err "kubectl is required but not installed"
command -v kubeseal >/dev/null 2>&1 || err "kubeseal is required but not installed"
command -v python3  >/dev/null 2>&1 || err "python3 is required but not installed"

# ── Read values from terraform.tfvars ────────────────────────────
[[ -f "$TFVARS" ]] || err "terraform.tfvars not found at $TFVARS"

tfvar() {
  # Extracts: key = "value"  →  value
  # NOTE: values containing literal double-quotes are not supported by this parser.
  local raw
  raw="$(grep -E "^${1}\s*=" "$TFVARS" | sed -E 's/^[^=]+=\s*"(.*)"\s*$/\1/')"
  printf '%s' "$raw"
}

POSTGRES_USER="$(tfvar postgres_user)"
POSTGRES_PASSWORD="$(tfvar postgres_password)"
POSTGRES_DB="$(tfvar postgres_db)"
RELEASE_NAME="$(tfvar release_name)"
RELEASE_NAME="${RELEASE_NAME:-my-app}"

[[ -n "$POSTGRES_USER" ]]     || err "postgres_user not found or empty in terraform.tfvars"
[[ -n "$POSTGRES_PASSWORD" ]] || err "postgres_password not found or empty in terraform.tfvars"
[[ -n "$POSTGRES_DB" ]]       || err "postgres_db not found or empty in terraform.tfvars"

POSTGRES_HOST="${RELEASE_NAME}-todo-app-postgres"
DATABASE_URI="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:5432/${POSTGRES_DB}"

# ── Wait for controller ───────────────────────────────────────────
# Controller deployment name is determined by fullnameOverride: sealed-secrets in values.
info "Waiting for Sealed Secrets controller..."
kubectl rollout status deploy/sealed-secrets -n sealed-secrets --timeout=90s

# ── Temp files (auto-cleaned on exit) ─────────────────────────────
CERT_FILE="$(mktemp /tmp/sealed-secrets-cert.XXXXXX.pem)"
PLAIN_SECRET="$(mktemp /tmp/todo-db-secret.XXXXXX.yaml)"
SEALED_OUTPUT="$(mktemp /tmp/todo-db-sealedsecret.XXXXXX.yaml)"
PATCHED_TEMPLATE="$(mktemp /tmp/postgres-sealedsecret.XXXXXX.yaml)"
trap 'rm -f "$CERT_FILE" "$PLAIN_SECRET" "$SEALED_OUTPUT" "$PATCHED_TEMPLATE"' EXIT

# ── Fetch controller certificate ──────────────────────────────────
# Controller name matches fullnameOverride in sealed-secrets values.
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
# Write to a temp file first; only replace the target if patching succeeds
# and the result is valid YAML, preventing half-patched corrupt state.
python3 - "$SEALED_OUTPUT" "$SEALED_TEMPLATE" "$PATCHED_TEMPLATE" <<'PYEOF'
import sys, re, yaml

sealed_file, template_file, output_file = sys.argv[1], sys.argv[2], sys.argv[3]

with open(sealed_file) as f:
    sealed = yaml.safe_load(f)

encrypted = sealed["spec"]["encryptedData"]

with open(template_file) as f:
    content = f.read()

for key, value in encrypted.items():
    content = re.sub(
        rf"^(    {re.escape(key)}:)\s+.+$",
        rf"\1 {value}",
        content,
        flags=re.MULTILINE,
    )
    print(f"  patched: {key}")

# Validate the patched output is parseable YAML before writing
yaml.safe_load(content)

with open(output_file, "w") as f:
    f.write(content)
PYEOF

# Atomically replace the template only after successful patch + YAML validation
cp "$PATCHED_TEMPLATE" "$SEALED_TEMPLATE"

info "Template patched: $SEALED_TEMPLATE"
warn "These encrypted blobs are cluster-specific — they can only be decrypted by this controller."
warn "They are safe to commit to Git."
