#!/usr/bin/env bash
# Tags and pushes the todo-app container images to the Harbor registry.
#
# Prerequisites:
#   - Docker CLI installed and running
#   - Harbor CA trusted (run scripts/trust-harbor-ca.sh first)
#   - Harbor is running and the project exists
#   - Images built locally: frontend:<tag>, backend:<tag>
#
# Usage: ./push-images.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SOLUTION/bootstrap/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || err ".env not found; copy bootstrap/.env.example first."
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${IMAGE_TAG:?IMAGE_TAG not set in .env}"
: "${HARBOR_ADMIN_PASSWORD:?HARBOR_ADMIN_PASSWORD not set in .env}"
HARBOR_HOST="${HARBOR_HOST:-harbor.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-todo}"
HARBOR_USER="${HARBOR_USER:-admin}"

command -v docker &>/dev/null || err "docker CLI not found"

# ── Docker login ─────────────────────────────────────────────────
info "Logging in to $HARBOR_HOST"
echo "$HARBOR_ADMIN_PASSWORD" | docker login "$HARBOR_HOST" \
  --username "$HARBOR_USER" --password-stdin \
  || err "Docker login failed — did you run scripts/trust-harbor-ca.sh?"

# ── Tag and push ─────────────────────────────────────────────────
IMAGES=("frontend" "backend")

for img in "${IMAGES[@]}"; do
  LOCAL="${img}:${IMAGE_TAG}"
  REMOTE="${HARBOR_HOST}/${HARBOR_PROJECT}/${img}:${IMAGE_TAG}"

  info "Tagging $LOCAL → $REMOTE"
  docker tag "$LOCAL" "$REMOTE" \
    || err "Failed to tag $LOCAL — is the image built locally?"

  info "Pushing $REMOTE"
  docker push "$REMOTE" \
    || err "Failed to push $REMOTE"
done

info "All images pushed to $HARBOR_HOST/$HARBOR_PROJECT"
info "  frontend: ${HARBOR_HOST}/${HARBOR_PROJECT}/frontend:${IMAGE_TAG}"
info "  backend:  ${HARBOR_HOST}/${HARBOR_PROJECT}/backend:${IMAGE_TAG}"
