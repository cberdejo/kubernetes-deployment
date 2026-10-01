#!/usr/bin/env bash
# Packages and publishes the canonical todo-app Helm chart to Harbor's OCI registry.
#
# This script pushes the chart from application/chart/ into Harbor so that
# bootstrap.sh can install it via oci://harbor.local/todo/todo-app.
#
# Prerequisites:
#   - Harbor CA trusted (run scripts/trust-harbor-ca.sh first)
#   - Harbor is running and the project exists
#   - bootstrap/.env filled in
#
# Usage: ./publish-chart.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SOLUTION/../../.." && pwd)"
ENV_FILE="$SOLUTION/bootstrap/.env"
CHART_DIR="$REPO_ROOT/application/chart"

err() { printf '[x] %s\n' "$*" >&2; exit 1; }
info() { printf '[+] %s\n' "$*"; }

[[ -f "$ENV_FILE" ]] || err ".env not found; copy bootstrap/.env.example to bootstrap/.env first."
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${HARBOR_ADMIN_PASSWORD:?HARBOR_ADMIN_PASSWORD not set in bootstrap/.env}"
HARBOR_HOST="${HARBOR_HOST:-harbor.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-todo}"
HARBOR_USER="${HARBOR_USER:-admin}"
CHART_REGISTRY="${CHART_REGISTRY:-${HARBOR_HOST}/${HARBOR_PROJECT}}"

CHART_NAME="$(awk -F': *' '$1 == "name" { gsub(/"/, "", $2); print $2; exit }' "$CHART_DIR/Chart.yaml")"
CHART_FILE_VERSION="$(awk -F': *' '$1 == "version" { gsub(/"/, "", $2); print $2; exit }' "$CHART_DIR/Chart.yaml")"
CHART_VERSION="${CHART_VERSION:-$CHART_FILE_VERSION}"

[[ -n "$CHART_NAME" ]] || err "Could not read chart name from $CHART_DIR/Chart.yaml"
[[ -n "$CHART_FILE_VERSION" ]] || err "Could not read chart version from $CHART_DIR/Chart.yaml"
[[ "$CHART_VERSION" == "$CHART_FILE_VERSION" ]] || err "CHART_VERSION=$CHART_VERSION must match Chart.yaml version=$CHART_FILE_VERSION"

info "Logging in to $HARBOR_HOST OCI registry"
echo "$HARBOR_ADMIN_PASSWORD" | helm registry login "$HARBOR_HOST" \
  --username "$HARBOR_USER" --password-stdin \
  || err "Helm registry login failed. Did you run scripts/trust-harbor-ca.sh?"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info "Linting $CHART_NAME"
helm lint "$CHART_DIR"

info "Packaging $CHART_NAME $CHART_VERSION"
helm package "$CHART_DIR" --destination "$TMP_DIR"

info "Pushing to oci://$CHART_REGISTRY"
helm push "$TMP_DIR/${CHART_NAME}-${CHART_VERSION}.tgz" "oci://$CHART_REGISTRY"

info "Published: oci://$CHART_REGISTRY/$CHART_NAME --version $CHART_VERSION"
