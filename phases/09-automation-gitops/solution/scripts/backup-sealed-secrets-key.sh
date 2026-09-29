#!/usr/bin/env bash
# Exports the Sealed Secrets private key(s) so a rebuilt cluster can decrypt
# the SealedSecrets already committed to Git.
#
# Without this backup, a new cluster generates a new key pair and every
# SealedSecret in the repository becomes undecryptable.
#
# NEVER commit the backup file. Store it outside the repository
# (password manager, encrypted USB drive, etc.).
#
# Usage: ./backup-sealed-secrets-key.sh [output-file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../bootstrap/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }

OUT="${1:-${SEALED_SECRETS_KEY_BACKUP:-$HOME/.homelab/sealed-secrets-key.yaml}}"
REPO_TOP="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
mkdir -p "$(dirname "$OUT")"
OUT_DIR_ABS="$(cd "$(dirname "$OUT")" && pwd)"
if [[ -n "$REPO_TOP" && "$OUT_DIR_ABS/" == "$REPO_TOP/"* ]]; then
  err "Refusing to write the private key inside the Git repository: $OUT"
fi

# The controller rotates keys every 30 days and keeps the old ones, so export
# every key (active and inactive), not just the newest.
COUNT="$(kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key \
  --no-headers 2>/dev/null | wc -l)"
[[ "$COUNT" -gt 0 ]] || err "No Sealed Secrets keys found in kube-system — is the controller running?"

umask 077
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$OUT"
chmod 600 "$OUT"

info "Backed up $COUNT key(s) to $OUT"
warn "This file can decrypt every SealedSecret in the repository. Keep it offline."
warn "Re-run this script after key rotations (every 30 days by default)."
