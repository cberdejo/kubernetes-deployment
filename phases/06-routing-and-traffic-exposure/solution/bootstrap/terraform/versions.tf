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
