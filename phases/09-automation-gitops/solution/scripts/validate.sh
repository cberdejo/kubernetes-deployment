#!/usr/bin/env bash
# Validates the Phase 09 GitOps manifests offline — the same checks CI runs
# on every pull request (.github/workflows/gitops-validate.yaml).
#
#   1. Every YAML file parses
#   2. Every top-level kustomize overlay builds
#   3. The rendered objects match their schemas: Kubernetes core, the Flux CRD
#      schemas of the Flux version pinned in the FluxInstance, and the community
#      CRD catalog for everything else (cert-manager, MetalLB, Gateway API,
#      Envoy Gateway, Flux Operator, Sealed Secrets…). A kind without a schema
#      is an error, not a silent skip.
#   4. Every "$imagepolicy" marker points to an ImagePolicy that exists
#
# Requires: kustomize, kubeconform, curl, python3 with PyYAML
# Usage: ./scripts/validate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLUTION="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${CYAN}━━━  %s  ━━━${NC}\n" "$*"; }

command -v kustomize   &>/dev/null || err "kustomize not found"
command -v kubeconform &>/dev/null || err "kubeconform not found"
command -v curl        &>/dev/null || err "curl not found"
python3 -c 'import yaml' 2>/dev/null || err "python3 with PyYAML not found (pip install pyyaml)"

# Validate against the schemas of the Flux version the cluster actually runs.
FLUX_VERSION="$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$SOLUTION/clusters/prod/flux-system/flux-instance.yaml")"
[[ "$FLUX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || err "FluxInstance version must be an exact release (found: '${FLUX_VERSION}')"
SCHEMA_DIR="${SCHEMA_DIR:-${TMPDIR:-/tmp}/flux-crd-schemas}/v${FLUX_VERSION}"
# Pinned commit of the community CRD catalog: tracking its main branch would
# let CI results change without any change in this repository. Bump it
# deliberately when a chart upgrade brings a new CRD version.
CRDS_CATALOG_REF="${CRDS_CATALOG_REF:-d373c2da9702bc9509a004db83e57263fe3bdfc1}"

KUBECONFORM_FLAGS=(
  -strict
  -schema-location default
  -schema-location "$SCHEMA_DIR"
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRDS_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  -summary
)

# ── Schemas ───────────────────────────────────────────────────────
step "Downloading Flux ${FLUX_VERSION} OpenAPI schemas"
if [[ -d "$SCHEMA_DIR/master-standalone-strict" ]]; then
  info "Using cached schemas in $SCHEMA_DIR"
else
  mkdir -p "$SCHEMA_DIR/master-standalone-strict"
  curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/crd-schemas.tar.gz" \
    | tar zxf - -C "$SCHEMA_DIR/master-standalone-strict" \
    || { rm -rf "$SCHEMA_DIR"; err "Could not download the Flux ${FLUX_VERSION} schemas"; }
  info "Schemas stored in $SCHEMA_DIR"
fi

# ── YAML syntax ───────────────────────────────────────────────────
step "Validating YAML syntax"
while IFS= read -r -d '' file; do
  python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$file" \
    || err "Invalid YAML: ${file#"$SOLUTION"/}"
done < <(find "$SOLUTION" -type f -name '*.yaml' -print0)
info "All YAML files parse"

# ── Overlays ──────────────────────────────────────────────────────
# One entry per Flux Kustomization path (plus the cluster entrypoint).
OVERLAYS=(
  clusters/prod
  infrastructure/controllers
  infrastructure/configs
  platform
  apps/prod
  image-automation
)

step "Building and validating overlays"
for rel in "${OVERLAYS[@]}"; do
  out="$(kustomize build "$SOLUTION/$rel")" || err "kustomize build failed: $rel"
  printf "  %-28s " "$rel"
  echo "$out" | kubeconform "${KUBECONFORM_FLAGS[@]}" || err "Schema validation failed: $rel"
done

# platform-secrets has no kustomization.yaml (Flux generates one), so its
# SealedSecrets are validated file by file.
if compgen -G "$SOLUTION/platform-secrets/*.yaml" >/dev/null; then
  printf "  %-28s " "platform-secrets"
  kubeconform "${KUBECONFORM_FLAGS[@]}" "$SOLUTION"/platform-secrets/*.yaml \
    || err "Schema validation failed: platform-secrets"
fi

# ── Image policy markers ──────────────────────────────────────────
# A typo in a marker is not a schema error: it is just a YAML comment, and
# image automation would silently never update that field.
step "Checking image policy markers"
python3 - "$SOLUTION" <<'PY' || err "Image policy markers reference unknown ImagePolicies"
import pathlib, re, sys, yaml

root = pathlib.Path(sys.argv[1])
policies = set()
for f in (root / "image-automation").glob("*.yaml"):
    for doc in yaml.safe_load_all(f.read_text()):
        if doc and doc.get("kind") == "ImagePolicy":
            meta = doc["metadata"]
            policies.add(f'{meta["namespace"]}:{meta["name"]}')

markers, broken = 0, []
for f in sorted((root / "apps").rglob("*.yaml")):
    for ref in re.findall(r'"\$imagepolicy":\s*"([^"]+)"', f.read_text()):
        markers += 1
        if ":".join(ref.split(":")[:2]) not in policies:
            broken.append(f"  {f.relative_to(root)}: {ref}")

if broken:
    print("\n".join(broken), file=sys.stderr)
    sys.exit(1)
print(f"  {markers} markers, all pointing to existing ImagePolicies")
PY

step "Done"
info "All manifests are valid"
