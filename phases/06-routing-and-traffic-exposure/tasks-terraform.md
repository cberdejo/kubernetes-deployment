# Phase 06 — Bootstrap with Terraform / OpenTofu

This guide uses OpenTofu to orchestrate the Phase 06 installation. `depends_on` makes the graph explicit and `wait = true` enforces readiness before the next resource starts.

---

## Directory structure

```
bootstrap/terraform/
├── versions.tf              # required provider versions only
├── backend.tf               # state backend (local for Phase 06, S3 in production)
├── providers.tf             # provider configuration blocks
├── variables.tf             # input declarations
├── main.tf                  # all helm_release resources
├── .gitignore               # excludes .terraform/, state files, *.tfvars
├── terraform.tfvars         # your actual values (gitignored)
└── terraform.tfvars.example
```

### Why split into four config files?

The production pattern separates concerns so each file answers one question:

| File | Question it answers |
|------|---------------------|
| `versions.tf` | Which providers and what version constraints? |
| `backend.tf` | Where is the state stored? |
| `providers.tf` | How do we connect to Kubernetes? |
| `variables.tf` | What values does the operator supply? |
| `main.tf` | What infrastructure exists? |

Keeping backend config in its own file makes it trivial to swap `backend "local"` for `backend "s3"` in Phase 09 without touching the provider or version declarations.

The Helm chart files in `apps/` are unchanged — Terraform references the same wrapper charts pointing at the same `values/prod-values.yaml` files.

---

## Install order and dependency graph

```
                                                              ┌──►  cert_manager      ──┐
metallb  ──►  envoy_gateway  ──►  longhorn  ──►  sealed_secrets                         ──►  todo_app
                                                              └──►  seal_credentials  ──┘
```

Each `depends_on` in `main.tf` encodes one arrow. Terraform resolves the graph, runs what it can in parallel where there are no dependencies, and waits for each release to be fully deployed before starting the next. `cert_manager` and `seal_credentials` (the `local-exec` that runs `seal-credentials.sh`) run in parallel after `sealed_secrets` is ready — `todo_app` waits for both.

---

## `versions.tf`

Only provider requirements — no backend, no provider config.

```hcl
terraform {
  required_providers {
    helm = {
      source  = "opentofu/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "opentofu/kubernetes"
      version = "~> 2.0"
    }
    null = {
      source  = "opentofu/null"
      version = "~> 3.0"
    }
  }
}
```

---

## `backend.tf`

State is stored locally for Phase 06. This could later be stored in S3 backend pointing at a MinIO instance running inside the cluster, for example.

```hcl
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
```

---

## `providers.tf`

Provider configuration is isolated here. Both providers read the current kubeconfig, the same cluster that `kubectl` uses.

```hcl
provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}
```

---

## `variables.tf`

```hcl
variable "dockerhub_user" {
  type        = string
  description = "Docker Hub username — images must already be pushed"
}

variable "image_tag" {
  type    = string
  default = "1.0.0"
}

variable "postgres_user" {
  type    = string
  default = "admin"
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "postgres_db" {
  type    = string
  default = "domain"
}

variable "release_name" {
  type    = string
  default = "my-app"
}
```

---

## `main.tf`

Every release has `lifecycle { ignore_changes = all }`. This tells Terraform: after the initial install, stop tracking drift on this release. The real source of truth is the cluster, and in Phase 09 ArgoCD takes over reconciliation. Establishing the pattern now means the hand-off is seamless.

```hcl
locals {
  apps = "${path.module}/../../apps"
}

# ── 1. MetalLB ────────────────────────────────────────────────────
resource "helm_release" "metallb" {
  name             = "cluster-metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = "0.15.3"
  namespace        = "metallb-system"
  create_namespace = true
  wait             = true
  timeout          = 180

  values = [file("${local.apps}/metallb/values/prod-values.yaml")]

  lifecycle {
    ignore_changes = all
  }
}

# ── 2. Envoy Gateway ──────────────────────────────────────────────
# Must come before Longhorn: its chart installs the Gateway API CRDs
# (HTTPRoute, Gateway, GatewayClass) that Longhorn's route.yaml needs.
resource "helm_release" "envoy_gateway" {
  name             = "cluster-envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "1.6.4"
  namespace        = "envoy-gateway"
  create_namespace = true
  wait             = true
  timeout          = 180

  values     = [file("${local.apps}/envoy-gateway/values/prod-values.yaml")]
  depends_on = [helm_release.metallb]

  lifecycle {
    ignore_changes = all
  }
}

# ── 3. Longhorn ───────────────────────────────────────────────────
resource "helm_release" "longhorn" {
  name             = "cluster-longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = "1.11.0"
  namespace        = "longhorn"
  create_namespace = true
  wait             = true
  timeout          = 300

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

  values     = [file("${local.apps}/sealed-secrets/values/prod-values.yaml")]
  depends_on = [helm_release.longhorn]

  lifecycle {
    ignore_changes = all
  }
}

# ── 5. cert-manager ───────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cluster-cert-manager"
  repository       = "oci://quay.io/jetstack/charts"
  chart            = "cert-manager"
  version          = "v1.20.1"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 180

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
  triggers = {
    postgres_user     = var.postgres_user
    postgres_password = var.postgres_password
    postgres_db       = var.postgres_db
    release_name      = var.release_name
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
```

### `lifecycle { ignore_changes = all }` explained

Once a Helm release is deployed, Terraform's job for that release is done. Future changes come from two sources:

- **Immediate:** editing a values file and re-running `tofu apply`, still works because `ignore_changes` only suppresses drift detection, not explicit resource updates from plan changes.
- **Phase 09:** ArgoCD continuously reconciles chart state from Git. Without `ignore_changes`, every `tofu plan` would show spurious diffs because ArgoCD may have applied its own annotations or resource patches. With it, Terraform bootstraps once and steps aside.

---

## `terraform.tfvars.example`

```hcl
dockerhub_user    = "your-dockerhub-username"
image_tag         = "1.0.0"
postgres_user     = "admin"
postgres_password = "changeme"
postgres_db       = "domain"
release_name      = "my-app"
```

Copy to `terraform.tfvars` and fill in your values. `*.tfvars` is gitignored by `.gitignore`.

---

## Usage
[Install open tofu](https://opentofu.org/docs/intro/install/)

```bash
cd bootstrap/terraform

# 1. Initialise providers
tofu init

# 2. Preview what will be created
tofu plan -var-file=terraform.tfvars

# 3. Install everything (MetalLB → Envoy Gateway → Longhorn → Sealed Secrets → cert-manager + seal-credentials → todo-app)
tofu apply -var-file=terraform.tfvars

# 4. Add Gateway IP to /etc/hosts
kubectl get svc -n envoy-gateway
# Then add to /etc/hosts:  <EXTERNAL-IP>  todo.local longhorn.local
```

> **How sealing is automated:** `null_resource.seal_credentials` runs `seal-credentials.sh` via `local-exec` after the Sealed Secrets controller is ready, in parallel with cert-manager. If you change a credential in `terraform.tfvars` and re-run `tofu apply`, the `triggers` block detects the change and re-seals automatically.

---

## Teardown

```bash
tofu destroy -var-file=terraform.tfvars
```

Terraform tears everything down in the correct reverse-dependency order: todo-app → cert-manager → Sealed Secrets → Longhorn → Envoy Gateway → MetalLB. No manual `helm uninstall` hunting.

---

## What changes in Phase 09

Phase 09 replaces the local bootstrap with a full GitOps setup. The structural changes are minimal — this is why the pattern is established now:

| Aspect | Phase 06 | Phase 09 |
|--------|----------|----------|
| `backend.tf` | `backend "local"` | `backend "s3"` → MinIO in-cluster |
| Releases managed | MetalLB + Envoy GW + Longhorn + Sealed Secrets + cert-manager + todo-app | Cilium + ArgoCD + argocd-apps only |
| Post-bootstrap | Manual `helm upgrade` to change app config | ArgoCD syncs from Git automatically |
| `ignore_changes` | Established here | Still present — ArgoCD owns reconciliation |

---

## Success criteria

- `tofu apply` completes without errors
- `kubectl get pods -A` shows all components Running
- `kubectl get httproute -A` shows both routes Accepted
- `http://todo.local` loads the todo-app
- `http://longhorn.local` loads the Longhorn UI
- `tofu destroy` removes everything cleanly
