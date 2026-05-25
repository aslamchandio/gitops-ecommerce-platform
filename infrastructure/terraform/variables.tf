# =============================================================================
# Variable DECLARATIONS only.
# All values live in terraform.tfvars — there are NO defaults here on purpose,
# so a missing/typo'd variable fails fast at `terraform plan` instead of
# silently picking up a hardcoded fallback.
# =============================================================================

# ---- Project + region ----
variable "project_id" {
  type        = string
  description = "GCP project ID where everything is provisioned."
}

variable "region" {
  type        = string
  description = "Primary region — pick one close to your users."
}

# ---- Naming ----
variable "cluster_name" {
  type = string
}

variable "artifact_repo" {
  type = string
}

variable "vpc_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "nat_router_name" {
  type = string
}

variable "nat_name" {
  type = string
}

variable "private_services_range_name" {
  type = string
}

variable "system_pool_name" {
  type = string
}

variable "gke_node_sa_id" {
  type = string
}

variable "workload_sa_id" {
  type        = string
  description = "GCP service account ID used by app pods (bound via Workload Identity to read GSM secrets)."
}

variable "k8s_workload_sa_name" {
  type        = string
  description = "Name of the Kubernetes ServiceAccount in the ecom namespace that pods run as."
}

variable "gsm_db_password_secret_name" {
  type        = string
  description = "Name of the GCP Secret Manager secret that stores the DB password."
}

variable "db_instance_name" {
  type = string
}

variable "redis_instance_name" {
  type = string
}

variable "gateway_address_name" {
  type        = string
  description = "Name of the reserved global IP that the Gateway pins to."
}

# ---- Networking — CIDRs ----
variable "subnet_cidr" {
  type = string
}

variable "pods_cidr" {
  type = string
}

variable "services_cidr" {
  type = string
}

variable "private_services_prefix_length" {
  type        = number
  description = "Prefix length for the reserved range used by Cloud SQL & Memorystore private services access."
}

variable "master_ipv4_cidr_block" {
  type        = string
  description = "/28 used by the GKE control plane in the peered VPC. Must not overlap any subnet."
}

variable "master_authorized_networks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the (public) control-plane endpoint."
}

# ---- GKE ----
variable "release_channel" {
  type        = string
  description = "REGULAR | RAPID | STABLE. RAPID gets ComputeClass/Gateway features first."
}

variable "gateway_api_channel" {
  type        = string
  description = "Gateway API channel. CHANNEL_STANDARD is the GA stream."
}

variable "system_node_machine_type" {
  type = string
}

variable "system_node_count" {
  type        = number
  description = "Nodes per zone in the system pool (regional cluster → 3× this total)."
}

variable "system_node_disk_size_gb" {
  type = number
}

variable "system_node_disk_type" {
  type = string
}

variable "nap_cpu_limit" {
  type        = number
  description = "Max total vCPUs that Node Auto-Provisioning may allocate."
}

variable "nap_memory_limit_gb" {
  type        = number
  description = "Max total memory (GB) that Node Auto-Provisioning may allocate."
}

variable "nap_disk_size_gb" {
  type = number
}

variable "nap_disk_type" {
  type = string
}

# ---- Cloud SQL — Postgres ----
variable "db_version" {
  type = string
}

variable "db_edition" {
  type        = string
  description = "ENTERPRISE allows shared-core tiers; ENTERPRISE_PLUS requires db-perf-optimized-*."
}

variable "db_tier" {
  type        = string
  description = "Cloud SQL machine tier. db-f1-micro is the cheapest shared-core."
}

variable "db_availability_type" {
  type        = string
  description = "ZONAL or REGIONAL (REGIONAL = HA, ~2× cost)."
}

variable "db_disk_size_gb" {
  type = number
}

variable "db_disk_type" {
  type = string
}

variable "db_backup_start_time" {
  type        = string
  description = "Daily backup window start (UTC, HH:MM)."
}

variable "db_user" {
  type = string
}

variable "db_password_length" {
  type = number
}

variable "db_name_catalog" {
  type = string
}

variable "db_name_orders" {
  type = string
}

# ---- Memorystore — Redis ----
variable "redis_tier" {
  type        = string
  description = "BASIC (no replica, cheapest) or STANDARD_HA."
}

variable "redis_memory_gb" {
  type = number
}

variable "redis_version" {
  type = string
}

# ---- Artifact Registry — cleanup policy ----
variable "ar_keep_recent_count" {
  type        = number
  description = "Keep this many most-recent image versions per service."
}

variable "ar_untagged_ttl_seconds" {
  type        = number
  description = "Delete untagged images older than this (in seconds)."
}

# ---- ArgoCD (GitOps) ----
variable "argocd_namespace" {
  type        = string
  description = "Namespace ArgoCD is installed into."
}

variable "argocd_chart_version" {
  type        = string
  description = "argo-cd Helm chart version (https://github.com/argoproj/argo-helm/releases)."
}

variable "gitops_repo_ssh_url" {
  type        = string
  description = "SSH URL of the private git repo ArgoCD pulls from."
}

variable "gitops_repo_path" {
  type        = string
  description = "Path inside the repo containing K8s manifests ArgoCD should sync."
}

variable "gitops_repo_branch" {
  type        = string
  description = "Git branch (or revision) ArgoCD tracks."
}

variable "gitops_app_namespace" {
  type        = string
  description = "Namespace ArgoCD deploys the app workloads into."
}

# ---- TLS / domain ----
variable "domain" {
  type        = string
  description = "Public hostname users hit. Must already DNS-resolve to the Gateway IP."
}

variable "tls_certificate_name" {
  type        = string
  description = "Name of an existing Google Cloud Certificate Manager certificate covering var.domain."
}

variable "certificate_map_name" {
  type        = string
  description = "Name of the Certificate Map the Gateway references via the networking.gke.io/certmap annotation."
}

variable "certificate_map_entry_name" {
  type        = string
  description = "Name of the Map Entry that binds var.domain to var.tls_certificate_name."
}
