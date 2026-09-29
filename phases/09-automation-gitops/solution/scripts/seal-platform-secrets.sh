#!/usr/bin/env bash
# Encrypts the authentik and Harbor credentials from bootstrap/.env into
# SealedSecret manifests under platform-secrets/, ready to commit.
#
# Unlike Phase 04, this script does NOT apply anything to the cluster:
# in GitOps the only way to change the cluster is a commit. Flux applies the
# SealedSecrets, and the controller decrypts them into regular Secrets that
# the authentik and Harbor HelmReleases read through valuesFrom.
#
# Prerequisites:
#   - kubeseal installed
#   - The sealed-secrets controller running (infra-controllers Ready)
#   - bootstrap/.env filled in
#
# Usage: ./seal-platform-secrets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTION/../../.." && pwd)"
ENV_FILE="$SOLUTION/bootstrap/.env"
OUT_DIR="$SOLUTION/platform-secrets"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }

# Flux injects these values with Helm's --set parser, where commas, braces and
# backslashes have special meaning. Restricting the charset avoids surprises.
validate_safe() {
  local value="$1" name="$2"
  [[ "$value" =~ ^[A-Za-z0-9._~-]+$ ]] || err "$name must only contain: A-Z a-z 0-9 . _ ~ -  (tip: openssl rand -hex 24)"
}

command -v kubeseal &>/dev/null || err "kubeseal not found — install it first (see Phase 04)."
command -v kubectl  &>/dev/null || err "kubectl not found"
[[ -f "$ENV_FILE" ]] || err ".env not found — copy bootstrap/.env.example to bootstrap/.env first."
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${AUTHENTIK_SECRET_KEY:?AUTHENTIK_SECRET_KEY not set in .env}"
: "${AUTHENTIK_BOOTSTRAP_PASSWORD:?AUTHENTIK_BOOTSTRAP_PASSWORD not set in .env}"
: "${AUTHENTIK_PG_PASSWORD:?AUTHENTIK_PG_PASSWORD not set in .env}"
: "${HARBOR_ADMIN_PASSWORD:?HARBOR_ADMIN_PASSWORD not set in .env}"
: "${HARBOR_SECRET_KEY:?HARBOR_SECRET_KEY not set in .env}"
AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-}"

validate_safe "$AUTHENTIK_SECRET_KEY"         AUTHENTIK_SECRET_KEY
validate_safe "$AUTHENTIK_BOOTSTRAP_PASSWORD" AUTHENTIK_BOOTSTRAP_PASSWORD
validate_safe "$AUTHENTIK_PG_PASSWORD"        AUTHENTIK_PG_PASSWORD
validate_safe "$HARBOR_ADMIN_PASSWORD"        HARBOR_ADMIN_PASSWORD
validate_safe "$HARBOR_SECRET_KEY"            HARBOR_SECRET_KEY
[[ ${#HARBOR_SECRET_KEY} -eq 16 ]] || err "HARBOR_SECRET_KEY must be exactly 16 characters (openssl rand -hex 8)"

# ── Controller certificate ────────────────────────────────────────
info "Waiting for the Sealed Secrets controller"
kubectl rollout status deploy/sealed-secrets -n kube-system --timeout=120s

CERT_FILE="$(mktemp /tmp/sealed-secrets-cert.XXXXXX.pem)"
trap 'rm -f "$CERT_FILE"' EXIT
kubeseal --fetch-cert \
  --controller-name sealed-secrets \
  --controller-namespace kube-system > "$CERT_FILE"
info "Public certificate fetched from the controller"

seal() {
  # $1 = output file; stdin = plaintext Secret manifest (never touches disk).
  # kubeseal emits "creationTimestamp: null", which the strict SealedSecret
  # schema used by validate.sh rejects. Dropping it does not affect decryption.
  kubeseal --format yaml --cert "$CERT_FILE" \
    | sed '/^[[:space:]]*creationTimestamp: null$/d' > "$1"
  info "Written: ${1#"$REPO_ROOT"/}"
}

mkdir -p "$OUT_DIR"

# ── authentik ─────────────────────────────────────────────────────
AUTHENTIK_ARGS=(
  --from-literal=secret_key="$AUTHENTIK_SECRET_KEY"
  --from-literal=bootstrap_password="$AUTHENTIK_BOOTSTRAP_PASSWORD"
  --from-literal=postgresql_password="$AUTHENTIK_PG_PASSWORD"
)
if [[ -n "$AUTHENTIK_BOOTSTRAP_EMAIL" ]]; then
  AUTHENTIK_ARGS+=(--from-literal=bootstrap_email="$AUTHENTIK_BOOTSTRAP_EMAIL")
fi
kubectl create secret generic authentik-secrets -n authentik \
  "${AUTHENTIK_ARGS[@]}" --dry-run=client -o yaml \
  | seal "$OUT_DIR/authentik-secrets.yaml"

# ── Harbor ────────────────────────────────────────────────────────
kubectl create secret generic harbor-secrets -n harbor \
  --from-literal=admin_password="$HARBOR_ADMIN_PASSWORD" \
  --from-literal=secret_key="$HARBOR_SECRET_KEY" \
  --dry-run=client -o yaml \
  | seal "$OUT_DIR/harbor-secrets.yaml"

echo ""
warn "Nothing was applied to the cluster. Commit the encrypted files to deploy them:"
echo "  git add ${OUT_DIR#"$REPO_ROOT"/}"
echo "  git commit -m 'feat(phase-09): seal platform secrets'"
echo "  git push"
