terraform {
  required_version = ">= 1.6"

  # Backend config lives in backend.tf (environment-specific, separated so
  # multi-env or wrapper-tool changes don't touch this file).

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.gke_region # default region for region-scoped operations
}

# Fetch a short-lived OAuth token for the current gcloud identity. The helm
# and kubernetes providers below use this to authenticate to the GKE control
# plane — no static kubeconfig required.
data "google_client_config" "default" {}

# try() defaults let `terraform destroy` finish cleanly after the cluster
# has already been removed from state. Without them the provider tries to
# resolve google_container_cluster.primary.endpoint, sees null, and fails
# to construct a REST client with "no client config" — even when there
# are no kubernetes/helm resources left to manage. At apply-time the
# real cluster reference always wins (try evaluates left-to-right).
provider "kubernetes" {
  host                   = try("https://${google_container_cluster.primary.endpoint}", "https://placeholder")
  token                  = try(data.google_client_config.default.access_token, "placeholder")
  cluster_ca_certificate = try(base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate), "")
}

provider "helm" {
  kubernetes {
    host                   = try("https://${google_container_cluster.primary.endpoint}", "https://placeholder")
    token                  = try(data.google_client_config.default.access_token, "placeholder")
    cluster_ca_certificate = try(base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate), "")
  }
}
