#!/usr/bin/env bash
# Restores a Sealed Secrets key backup into a (new) cluster.
#
# Run it BEFORE Flux installs the controller (bootstrap.sh does this
# automatically when the backup file exists). If the controller is already
# running, the script restarts it so it loads the restored keys.
#
# Usage: ./restore-sealed-secrets-key.sh [backup-file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../bootstrap/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }

IN="${1:-${SEALED_SECRETS_KEY_BACKUP:-$HOME/.homelab/sealed-secrets-key.yaml}}"
[[ -f "$IN" ]] || err "Backup not found: $IN"

# Drop server-managed fields so re-applying on a cluster that already has
# the key does not fail with a resourceVersion conflict.
sed -E '/^[[:space:]]+(resourceVersion|uid|creationTimestamp):/d' "$IN" | kubectl apply -f - >/dev/null
info "Restored Sealed Secrets key(s) from $IN"

if kubectl get deploy/sealed-secrets -n kube-system &>/dev/null; then
  info "Controller already running, restarting it to load the restored keys"
  kubectl rollout restart deploy/sealed-secrets -n kube-system
  kubectl rollout status deploy/sealed-secrets -n kube-system --timeout=120s
fi
