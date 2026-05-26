# =============================================================================
# Variable DECLARATIONS only.
# All values live in terraform.tfvars — there are NO defaults here on purpose,
# so a missing/typo'd variable fails fast at `terraform plan` instead of
# silently picking up a hardcoded fallback.
# =============================================================================

# ---- Project + naming ----
variable "project_id" {
  type        = string
  description = "GCP project ID where everything is provisioned."
}

variable "business_division" {
  type        = string
  description = "Owner / team — e.g. 'it', 'platform'. Used as a naming prefix."
}

variable "environment_name" {
  type        = string
  description = "Environment — e.g. 'dev', 'staging', 'prod'. Combined with business_division to prefix every resource name."
}

# ---- Region selection ----
# Single-region resources (Cloud SQL, Redis, GKE, ArgoCD) live in gke_region.
# The VPC fans out across every key in var.regions; only gke_region gets the
# GKE secondary ranges and the cluster itself.
variable "gke_region" {
  type        = string
  description = "Primary region that hosts the GKE cluster and the regional data plane. Must be a key in var.regions."
}

variable "regions" {
  description = "Map of GCP region -> per-region network config. Each subnet type is independently opt-in so a region can carry only the subnets it actually needs (e.g. a GKE region with no VMs, or a VM-only region with no GKE)."
  type = map(object({
    vpc_cidr          = string                # /16 used by cidrsubnet for whichever primary ranges this region carries
    subnet_newbits    = number                # how many bits to add when slicing vpc_cidr (8 -> /24s, 4 -> /20s)

    # GKE subnet (primary + secondary pods/services). Created when BOTH
    # secondary CIDRs are set. The cluster itself anchors to var.gke_region.
    gke_pods_cidr     = optional(string)
    gke_services_cidr = optional(string)

    # Plain VM subnet primary range (sliced from vpc_cidr at position 2).
    # Set vm_subnet = true to opt this region in for Compute Engine / non-GKE workloads.
    vm_subnet         = optional(bool, false)

    # Proxy-only subnet for REGIONAL_MANAGED_PROXY (regional internal LB).
    # Set proxy_cidr only in regions that host a regional Gateway/LB.
    proxy_cidr        = optional(string)
  }))
}

# ---- Naming ----
variable "cluster_name" {
  type        = string
  description = "Suffix appended after the <biz>-<env>- prefix to form the cluster name (e.g. 'standard' -> 'it-prod-standard')."
}

variable "artifact_repo" {
  type = string
}

variable "private_services_range_name" {
  type        = string
  description = "Name of the reserved /16 used for Cloud SQL + Memorystore private services access (a single global range covers all regions)."
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
# Per-region subnet/secondary CIDRs now live in var.regions (declared above).
# Only the cross-region / global ranges stay top-level here.

variable "private_services_address" {
  type        = string
  description = "Starting IP for the reserved global range used by Cloud SQL & Memorystore private services access (e.g. 10.77.0.0). Pinning this explicitly — instead of letting GCP auto-allocate — keeps the range deterministic across rebuilds and prevents accidental overlap with other VPC peering tenants."
}

variable "private_services_prefix_length" {
  type        = number
  description = "Prefix length for the private services range. /16 = 65k addresses, plenty of headroom for the producer to carve out per-instance /28s."
}

variable "master_ipv4_cidr_block" {
  type        = string
  description = "/28 used by the GKE control plane in the peered VPC. Must not overlap any subnet primary or secondary range."
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

# ---- GitHub Actions (Workload Identity Federation) ----
variable "github_repo" {
  type        = string
  description = "GitHub repo in <owner>/<name> form. The WIF provider will ONLY trust OIDC tokens from this repo."
}

variable "github_wif_pool_id" {
  type        = string
  description = "ID of the Workload Identity Pool that holds the GitHub OIDC provider."
}

variable "github_wif_provider_id" {
  type        = string
  description = "ID of the GitHub OIDC provider inside the pool."
}

variable "github_actions_sa_id" {
  type        = string
  description = "GCP service account ID that GitHub Actions impersonates (Artifact Registry writer only)."
}
