# Phase 06 — Theory: Terraform / OpenTofu

Terraform (and its open-source fork OpenTofu) solves the orchestration problem that every Kubernetes bootstrap eventually hits: multiple components must be installed in a specific order, each depending on the previous one having completed successfully. This file explains what Terraform is, why it fits Phase 06, and how it connects to the more advanced GitOps setup in Phase 09.

---

## The problem this phase exposes

Phase 06 installs six components that have hard installation dependencies between them:

```
MetalLB
  └── IPAddressPool / L2Advertisement CRs
        (need MetalLB's own CRDs, registered when the controller starts)
             │
             ▼
       Envoy Gateway
         └── GatewayClass + Gateway resources
               (installs Gateway API CRDs: HTTPRoute, Gateway, GatewayClass)
                    │
                    ▼
              Longhorn
                └── HTTPRoute for the UI
                      (needs the Gateway API CRDs from Envoy Gateway)
                           │
                           ▼
                     Sealed Secrets
                       └── seal credentials
                                │
                                ▼
                          cert-manager
                            └── ClusterIssuer CR
                                  (needs cert-manager CRDs)
                                       │
                                       ▼
                                  todo-app
```

A shell script encodes this order implicitly — as sequential commands. There is no machine-readable dependency declaration, no dry-run, no state tracking, and no clean teardown. If it fails halfway, figuring out what was and wasn't installed requires manual inspection.

Terraform models each component as a **resource** with explicit `depends_on` declarations. The dependency graph is part of the configuration, not hidden in the order of lines in a script.

---

## Core concepts

### Providers

A provider is a plugin that knows how to talk to one specific API. In this project two providers are used:

- **`helm` provider** — wraps `helm upgrade --install`. Each `helm_release` resource is one Helm chart deployment.
- **`kubernetes` provider** — manages raw Kubernetes manifests for objects that are not part of any Helm chart.

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

Both read the same kubeconfig that `kubectl` uses.

### Resources

A resource describes one infrastructure object and the state it should be in. Terraform's job is to make reality match the declaration.

```hcl
resource "helm_release" "metallb" {
  name             = "cluster-metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = "0.15.3"
  namespace        = "metallb-system"
  create_namespace = true
  wait             = true
}
```

This is equivalent to `helm upgrade --install cluster-metallb metallb/metallb --version 0.15.3 -n metallb-system --create-namespace --wait`, but declarative and tracked.

### `depends_on` — solving the CRD ordering problem

The reason a bash bootstrap needs hooks or careful script ordering is that Helm has no native cross-release dependency mechanism. Terraform does:

```hcl
resource "helm_release" "envoy_gateway" {
  # ...
  depends_on = [helm_release.metallb]
}

resource "helm_release" "longhorn" {
  # ...
  # Gateway API CRDs installed by envoy_gateway are available here
  depends_on = [helm_release.envoy_gateway]
}

resource "helm_release" "cert_manager" {
  # ...
  depends_on = [helm_release.longhorn]
}
```

`depends_on` is not just about order — it also means `wait = true` on the dependency is respected before the dependent resource starts. Envoy Gateway's controller is fully running (and its CRDs registered) before Terraform attempts to install Longhorn.

This eliminates the need for Helm post-install hooks or manual `kubectl wait` calls in the bootstrap script.

### State

Terraform keeps a **state file** (`terraform.tfstate`) that records everything it has deployed. On subsequent runs, it compares the desired configuration against the state and the live cluster to compute a diff — and only touches what has actually changed.

```
Desired (HCL)  ──compare──►  State file  ──compare──►  Live cluster
                                                              │
                                                    Plan: change Y, skip X and Z
                                                              │
                                                       terraform apply
```

This makes Terraform **idempotent**: running `tofu apply` twice produces the same result. A failed run can be safely retried — Terraform knows what succeeded and what didn't.

State can be stored locally (fine for a homelab) or in a remote backend like S3/Minio (needed for shared or CI-driven environments, covered in Phase 09).

### Plan / Apply cycle

```bash
tofu init     # Download providers, initialise backend
tofu plan     # Show what would change — no side effects
tofu apply    # Execute the plan
tofu destroy  # Tear everything down cleanly and in reverse order
```

`tofu plan` is the key safety mechanism: it is a dry-run that shows exactly what will be created, changed, or deleted before anything happens. In a CI pipeline, the plan output is reviewed in a pull request before `apply` runs.

`tofu destroy` tears everything down in the correct reverse-dependency order. Destroying a bash-bootstrapped cluster requires manually remembering every `helm uninstall` and `kubectl delete` command.

---

## OpenTofu vs Terraform

OpenTofu is a community-maintained fork of Terraform created in 2023 after HashiCorp changed Terraform's license from MPL 2.0 (open source) to BUSL 1.1 (source-available, restricted for competing products). OpenTofu is a **drop-in replacement** — configuration files and providers are 100% compatible.

This project uses OpenTofu (`tofu` CLI):

| Terraform | OpenTofu |
|---|---|
| `terraform init` | `tofu init` |
| `terraform plan` | `tofu plan` |
| `terraform apply` | `tofu apply` |
| `terraform destroy` | `tofu destroy` |

---

## HCL syntax you will use in this phase

**Provider and version requirements (`versions.tf`):**
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
  }
}
```

**Input variables (`variables.tf`):**
```hcl
variable "dockerhub_user" {
  type        = string
  description = "Docker Hub username for todo-app images"
}

variable "postgres_password" {
  type      = string
  sensitive = true
}
```

**Referencing a local values file:**
```hcl
resource "helm_release" "longhorn" {
  values = [file("${path.module}/../../apps/longhorn/values/prod-values.yaml")]
}
```

**Passing per-release overrides inline:**
```hcl
resource "helm_release" "todo_app" {
  set = [
    {
      name  = "frontend.image.repository"
      value = "docker.io/${var.dockerhub_user}/todo-frontend"
    },
    {
      name  = "backend.image.repository"
      value = "docker.io/${var.dockerhub_user}/todo-backend"
    }
  ]
}
```

**Explicit dependency:**
```hcl
depends_on = [helm_release.envoy_gateway, helm_release.sealed_secrets]
```

---

## Backends: where state lives

**Local (this phase — homelab):**
```hcl
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
```

**S3/Minio (Phase 09 — shared clusters or CI):**
```hcl
terraform {
  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "cluster/bootstrap/terraform.tfstate"
    endpoint                    = "https://minio.your-domain.com"
    region                      = "main"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}
```

The state file can contain sensitive values (Helm release values may include passwords). The `.gitignore` must exclude `*.tfstate`, `*.tfstate.backup`, and `*.tfvars`.

---

## How this connects to Phase 09

In Phase 06, Terraform bootstraps the networking and storage layer so the cluster is usable. It runs once and is not run again unless you rebuild the cluster.

In Phase 09, Terraform takes on a larger scope:

```
Phase 06 (this phase)           Phase 09
────────────────────────        ─────────────────────────────
MetalLB                         MetalLB (same)
Envoy Gateway                   Envoy Gateway (same)
Longhorn                        Longhorn (same)
Sealed Secrets                  Sealed Secrets (same)
cert-manager                    cert-manager (same)
todo-app via helm_release        todo-app via ArgoCD Application
                                 ArgoCD (new — manages everything else)
                                 Remote S3 backend for shared state
```

In Phase 09, ArgoCD takes over management of the application layer. Terraform installs ArgoCD itself (the same chicken-and-egg problem ArgoCD cannot solve for itself), then hands off. The `lifecycle { ignore_changes = all }` block on ArgoCD's `helm_release` tells Terraform not to reconcile it on future runs — ArgoCD owns it from that point.

This is the standard GitOps bootstrap pattern: Terraform handles what GitOps cannot bootstrap itself, and GitOps handles everything that follows.

---

## Terraform vs. alternatives

| Tool | Approach | Strengths | Weaknesses |
|---|---|---|---|
| **Terraform / OpenTofu** | Declarative, state-based | Multi-provider, explicit dependency graph, plan safety, idempotent | State file management, extra tooling |
| **Helmfile** | Helm-native orchestration | `needs:` for ordering, stays in Helm ecosystem | Helm-only, no state tracking |
| **Shell scripts** | Imperative | Simple, no tooling needed | Not idempotent, no state, no dependency declaration |
| **Ansible** | Imperative playbooks | Agentless, good for OS-level config | Not declarative, no state |
| **Pulumi** | Declarative in real code (Python, Go, TS) | Type safety, testing, familiar languages | Steeper learning curve, smaller ecosystem |

For a multi-component Kubernetes bootstrap where CRD ordering matters and clean teardown is a requirement, Terraform is the right tool. For purely Helm-based orchestration without state needs, Helmfile is the simpler alternative.

---

## Further reading

- [OpenTofu documentation](https://opentofu.org/docs/)
- [Helm Terraform provider](https://registry.terraform.io/providers/opentofu/helm/latest/docs)
- [Kubernetes Terraform provider](https://registry.terraform.io/providers/opentofu/kubernetes/latest/docs)
- [Terraform language reference](https://developer.hashicorp.com/terraform/language) (syntax identical to OpenTofu)
- [OpenTofu vs Terraform — the license change](https://opentofu.org/blog/opentofu-is-going-ga/)
