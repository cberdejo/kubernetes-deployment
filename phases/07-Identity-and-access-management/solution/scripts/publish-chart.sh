#!/usr/bin/env bash
# Packages and publishes the canonical todo-app Helm chart to an OCI registry.
#
# This is the OCI bridge introduced in Phase 06: it pushes to Docker Hub
# (registry-1.docker.io) as a temporary registry. Phase 08 replaces Docker Hub
# with a self-hosted Harbor by pointing CHART_REGISTRY at the Harbor domain;
# the script itself does not change. Phase 06 deploys from the local chart by
# default, so running this is optional until you want to exercise the OCI path.
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

: "${DOCKERHUB_USER:?DOCKERHUB_USER not set in bootstrap/.env}"
CHART_REGISTRY="${CHART_REGISTRY:-registry-1.docker.io/${DOCKERHUB_USER}}"

CHART_NAME="$(awk -F': *' '$1 == "name" { gsub(/"/, "", $2); print $2; exit }' "$CHART_DIR/Chart.yaml")"
CHART_FILE_VERSION="$(awk -F': *' '$1 == "version" { gsub(/"/, "", $2); print $2; exit }' "$CHART_DIR/Chart.yaml")"
CHART_VERSION="${CHART_VERSION:-$CHART_FILE_VERSION}"

[[ -n "$CHART_NAME" ]] || err "Could not read chart name from $CHART_DIR/Chart.yaml"
[[ -n "$CHART_FILE_VERSION" ]] || err "Could not read chart version from $CHART_DIR/Chart.yaml"
[[ "$CHART_VERSION" == "$CHART_FILE_VERSION" ]] || err "CHART_VERSION=$CHART_VERSION must match Chart.yaml version=$CHART_FILE_VERSION"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info "Linting $CHART_NAME"
helm lint "$CHART_DIR"

info "Packaging $CHART_NAME $CHART_VERSION"
helm package "$CHART_DIR" --destination "$TMP_DIR"

info "Pushing to oci://$CHART_REGISTRY"
helm push "$TMP_DIR/${CHART_NAME}-${CHART_VERSION}.tgz" "oci://$CHART_REGISTRY"

info "Published: oci://$CHART_REGISTRY/$CHART_NAME --version $CHART_VERSION"
