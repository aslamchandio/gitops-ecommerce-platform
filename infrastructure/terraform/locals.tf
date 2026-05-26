# =============================================================================
# Standard naming + CIDR layout for the whole project.
#
# Adopting <business_division>-<environment_name> as the canonical prefix
# means every resource name reads as "what + where" in two tokens:
#   it-prod-vpc
#   it-prod-private-us-central1
#   it-prod-standard          (cluster: var.cluster_name = "standard")
#
# Switching environments is now a tfvars edit, not a code change.
# =============================================================================

locals {
  owners      = var.business_division             # e.g. "it"
  environment = var.environment_name              # e.g. "prod"
  name        = "${var.business_division}-${var.environment_name}"

  common_tags = {
    owners      = local.owners
    environment = local.environment
  }

  # Cluster name = prefix + suffix.   it-prod-standard
  gke_cluster_name = "${local.name}-${var.cluster_name}"

  # ---------------------------------------------------------------------------
  # CIDR slicing per region.
  #
  # Each region's vpc_cidr (e.g. 10.0.0.0/16) is sliced into:
  #   gke_cidr  = cidrsubnet(vpc_cidr, subnet_newbits, 1)   -> 10.0.1.0/24
  #   vm_cidr   = cidrsubnet(vpc_cidr, subnet_newbits, 2)   -> 10.0.2.0/24
  # proxy_cidr comes straight from var.regions (size + placement are
  # GCP-prescribed for REGIONAL_MANAGED_PROXY subnets).
  # ---------------------------------------------------------------------------
  region_subnets = {
    for region, cfg in var.regions : region => {
      gke_cidr = cidrsubnet(cfg.vpc_cidr, cfg.subnet_newbits, 1)
      vm_cidr  = cidrsubnet(cfg.vpc_cidr, cfg.subnet_newbits, 2)
    }
  }

  # First three zones per region — used by NAP / instance placement.
  region_zones = {
    for region, zones_data in data.google_compute_zones.available :
    region => slice(zones_data.names, 0, 3)
  }

  # Flat list of every region's vpc_cidr — for firewall rules that need
  # to allow all internal traffic across the VPC.
  all_region_cidrs = [for cfg in var.regions : cfg.vpc_cidr]
}
