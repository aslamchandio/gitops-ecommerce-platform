# =============================================================================
# terraform.auto.tfvars — committed defaults loaded automatically.
#
# Terraform variable precedence (low -> high):
#   1. environment variables (TF_VAR_*)
#   2. terraform.tfvars             <- gitignored, for local overrides
#   3. *.auto.tfvars (this file)
#   4. -var / -var-file CLI flags
#
# Two variables stay out of this file deliberately:
#   - project_id              : sourced from GH variable PROJECT_ID
#                               via TF_VAR_project_id in the CI workflows.
#                               Locally, set in your own terraform.tfvars.
#   - master_authorized_networks
#                             : CI runners have no fixed egress IP, so the
#                               workflows set TF_VAR_master_authorized_networks='[]'
#                               (cluster reachable only via DNS endpoint + IAM).
#                               Locally, your terraform.tfvars sets your home IP.
# =============================================================================

# ---- Naming ----
business_division = "it"
environment_name  = "prod"

# ---- Regions ----
gke_region = "us-central1"

regions = {
  us-central1 = {
    vpc_cidr          = "192.168.0.0/16"
    subnet_newbits    = 4
    gke_pods_cidr     = "10.244.0.0/14"
    gke_services_cidr = "10.32.0.0/20"
  }
  us-west1 = {
    vpc_cidr       = "172.26.0.0/16"
    subnet_newbits = 8
    vm_subnet      = true
  }
}

# ---- Naming suffixes ----
cluster_name                = "standard"
artifact_repo               = "ecom-microservices"
private_services_range_name = "private-services"
system_pool_name            = "system-pool"
gke_node_sa_id              = "ecom-gke-nodes"
db_instance_name            = "ecom-postgres"
redis_instance_name         = "ecom-redis"
gateway_address_name        = "ecom-ip"
workload_sa_id              = "ecom-workload-sa"
k8s_workload_sa_name        = "ecom-workload"
gsm_db_password_secret_name = "ecom-db-password"

# ---- Networking ----
private_services_address       = "10.77.0.0"
private_services_prefix_length = 16
master_ipv4_cidr_block         = "172.16.0.0/28"

# ---- GKE ----
release_channel     = "REGULAR"
gateway_api_channel = "CHANNEL_STANDARD"

system_node_machine_type = "e2-small"
system_node_count        = 1
system_node_disk_size_gb = 30
system_node_disk_type    = "pd-standard"

nap_cpu_limit       = 16
nap_memory_limit_gb = 64
nap_disk_size_gb    = 50
nap_disk_type       = "pd-standard"

# ---- Cloud SQL ----
db_version           = "POSTGRES_16"
db_edition           = "ENTERPRISE"
db_tier              = "db-f1-micro"
db_availability_type = "ZONAL"
db_disk_size_gb      = 10
db_disk_type         = "PD_HDD"
db_backup_start_time = "03:00"
db_user              = "ecom"
db_password_length   = 24
db_name_catalog      = "catalog"
db_name_orders       = "orders"

# ---- Memorystore Redis ----
redis_tier      = "BASIC"
redis_memory_gb = 1
redis_version   = "REDIS_7_0"

# ---- Artifact Registry cleanup ----
ar_keep_recent_count    = 10
ar_untagged_ttl_seconds = 604800 # 7 days

# ---- ArgoCD ----
argocd_namespace     = "argocd"
argocd_chart_version = "9.5.15"

# ---- GitOps source ----
gitops_repo_ssh_url  = "git@github.com:aslamchandio/web-app-project.git"
gitops_repo_path     = "k8s"
gitops_repo_branch   = "main"
gitops_app_namespace = "ecom"

# ---- TLS / public domain ----
domain                     = "shop.nativeops.site"
tls_certificate_name       = "my-certificate"
certificate_map_name       = "my-certificate"
certificate_map_entry_name = "my-certificate-shop-entry"

# ---- GitHub Actions (WIF) ----
github_repo            = "aslamchandio/web-app-project"
github_wif_pool_id     = "github-pool"
github_wif_provider_id = "github-provider"
github_actions_sa_id   = "github-actions-ci"
