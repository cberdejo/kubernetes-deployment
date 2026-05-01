locals {
  apps = "${path.module}/../../apps"
}

# ── 1. MetalLB ────────────────────────────────────────────────────
# Local wrapper chart bundles upstream metallb + IPAddressPool + L2Advertisement.
resource "helm_release" "metallb" {
  name             = "cluster-metallb"
  chart            = "${local.apps}/metallb"
  version          = "1.0.0"
  namespace        = "metallb-system"
  create_namespace = true
  wait             = true
  timeout          = 180
  take_ownership   = true
  upgrade_install  = true

  values = [file("${local.apps}/metallb/values/prod-values.yaml")]

  lifecycle {
    ignore_changes = all
  }
}

# ── 2. Envoy Gateway ──────────────────────────────────────────────
# Local wrapper chart bundles upstream gateway-helm + GatewayClass + Gateway.
# Must complete before Longhorn, which contains an HTTPRoute template.
resource "helm_release" "envoy_gateway" {
  name             = "cluster-envoy-gateway"
  chart            = "${local.apps}/envoy-gateway"
  version          = "1.0.0"
  namespace        = "envoy-gateway"
  create_namespace = true
  wait             = true
  timeout          = 180
  take_ownership   = true
  upgrade_install  = true

  values     = [file("${local.apps}/envoy-gateway/values/prod-values.yaml")]
  depends_on = [helm_release.metallb]

  lifecycle {
    ignore_changes = all
  }
}

# ── 3. Longhorn ───────────────────────────────────────────────────
# Local wrapper chart bundles upstream longhorn + HTTPRoute + Namespace
# (with expose-via-gateway label required by the Gateway's namespace selector).
resource "helm_release" "longhorn" {
  name             = "cluster-longhorn"
  chart            = "${local.apps}/longhorn"
  version          = "1.0.0"
  namespace        = "longhorn"
  create_namespace = true
  wait             = true
  timeout          = 300
  take_ownership   = true
  upgrade_install  = true

  values     = [file("${local.apps}/longhorn/values/prod-values.yaml")]
  depends_on = [helm_release.envoy_gateway]

  lifecycle {
    ignore_changes = all
  }
}

# ── 4. Sealed Secrets ─────────────────────────────────────────────
resource "helm_release" "sealed_secrets" {
  name             = "sealed-secrets-prod"
  repository       = "https://bitnami-labs.github.io/sealed-secrets"
  chart            = "sealed-secrets"
  version          = "2.18.3"
  namespace        = "sealed-secrets"
  create_namespace = true
  wait             = true
  timeout          = 120
  take_ownership   = true

  values     = [file("${local.apps}/sealed-secrets/values/prod-values.yaml")]
  depends_on = [helm_release.longhorn]

  lifecycle {
    ignore_changes = all
  }
}

# ── 5. cert-manager ───────────────────────────────────────────────
# Local wrapper chart bundles upstream cert-manager + selfsigned ClusterIssuer.
resource "helm_release" "cert_manager" {
  name             = "cluster-cert-manager"
  chart            = "${local.apps}/cert-manager"
  version          = "1.0.0"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 180
  take_ownership   = true
  upgrade_install  = true

  values     = [file("${local.apps}/cert-manager/values/prod-values.yaml")]
  depends_on = [helm_release.sealed_secrets]

  lifecycle {
    ignore_changes = all
  }
}

# ── 5.5. Seal Credentials ────────────────────────────────────────
# Fetches the Sealed Secrets controller public key, encrypts the
# PostgreSQL credentials, and patches the Helm template on disk.
# Runs in parallel with cert_manager (both depend on sealed_secrets).
# Re-runs automatically when any credential variable changes.
resource "null_resource" "seal_credentials" {
  # Use a hash of credential values so the trigger fires on changes but avoids
  # storing plaintext passwords in Terraform state (state files are unencrypted
  # for local backends).
  triggers = {
    credential_hash = sha256("${var.postgres_user}:${var.postgres_password}:${var.postgres_db}:${var.release_name}")
  }

  provisioner "local-exec" {
    command = "${path.module}/../seal-credentials.sh"
  }

  depends_on = [helm_release.sealed_secrets]
}

# ── 6. todo-app ───────────────────────────────────────────────────
resource "helm_release" "todo_app" {
  name             = var.release_name
  chart            = "${local.apps}/todo-app"
  namespace        = "todo"
  create_namespace = true
  wait             = true
  timeout          = 180
  take_ownership   = true

  values = [file("${local.apps}/todo-app/values/prod-values.yaml")]

  set = [
    {
      name  = "frontend.image.repository"
      value = "docker.io/${var.dockerhub_user}/todo-frontend"
    },
    {
      name  = "frontend.image.tag"
      value = var.image_tag
    },
    {
      name  = "backend.image.repository"
      value = "docker.io/${var.dockerhub_user}/todo-backend"
    },
    {
      name  = "backend.image.tag"
      value = var.image_tag
    },
  ]

  depends_on = [helm_release.cert_manager, null_resource.seal_credentials]

  lifecycle {
    ignore_changes = all
  }
}
