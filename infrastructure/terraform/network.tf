# =============================================================================
# Global VPC, fanned out across every region in var.regions.
#
# Per-region resources (subnets, router, NAT) use for_each so adding a third
# region is a one-line tfvars change. Single-region resources (Cloud SQL,
# Memorystore, GKE) anchor to var.gke_region.
#
# Each region gets THREE subnets:
#   <name>-gke-<region>     primary range for GKE nodes; secondary ranges
#                           for pods + services live ONLY in the GKE region
#   <name>-vm-<region>      primary range for normal VMs / future workloads
#   <name>-proxy-<region>   reserved for REGIONAL_MANAGED_PROXY (regional
#                           internal LBs / Gateways). No workloads here.
#
# Private services access (Cloud SQL + Redis VPC peering) is a single
# *global* reservation — one /16 covers every region.
# =============================================================================

# ---- VPC ----
resource "google_compute_network" "vpc" {
  name                            = "${local.name}-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = false
  description                     = "VPC for ${local.name} spanning ${length(var.regions)} region(s)"
  depends_on                      = [google_project_service.enabled]
}

# ---- GKE subnet (only in regions that set both gke_*_cidr) ----
# Primary range sliced from vpc_cidr; secondary ranges for pods + services
# attached only in var.gke_region (the cluster lives there). Other regions
# can declare gke_*_cidr too — the secondary ranges flip on automatically
# when their region matches var.gke_region.
resource "google_compute_subnetwork" "gke" {
  for_each = {
    for region, cfg in var.regions : region => cfg
    if cfg.gke_pods_cidr != null && cfg.gke_services_cidr != null
  }

  name                     = "${local.name}-gke-${each.key}"
  ip_cidr_range            = local.region_subnets[each.key].gke_cidr
  region                   = each.key
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  dynamic "secondary_ip_range" {
    for_each = each.key == var.gke_region ? [1] : []
    content {
      range_name    = "${local.name}-gke-pods"
      ip_cidr_range = each.value.gke_pods_cidr
    }
  }

  dynamic "secondary_ip_range" {
    for_each = each.key == var.gke_region ? [1] : []
    content {
      range_name    = "${local.name}-gke-services"
      ip_cidr_range = each.value.gke_services_cidr
    }
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---- Plain VM subnet (only in regions that set vm_subnet = true) ----
# Primary range only. Use for Compute Engine instances, GCE-style
# workloads, or anything that's not GKE nodes.
resource "google_compute_subnetwork" "vm" {
  for_each = {
    for region, cfg in var.regions : region => cfg
    if cfg.vm_subnet == true
  }

  name                     = "${local.name}-vm-${each.key}"
  ip_cidr_range            = local.region_subnets[each.key].vm_cidr
  region                   = each.key
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---- Proxy-only subnet (per region, optional) ----
# Required by regional internal HTTPS / TCP load balancers (Envoy fleet).
# Exactly ONE proxy-only subnet per (region, VPC); GCP rejects a second.
# Workloads cannot be placed here — this range is reserved for managed
# proxies. role=ACTIVE means in-use (vs BACKUP during migrations).
# Note: log_config is not supported on this subnet type.
#
# Skipped for regions that don't set proxy_cidr — no point reserving a
# /23 in a region that has no regional LB. Flip a proxy on later by
# adding proxy_cidr to that region's entry in var.regions.
resource "google_compute_subnetwork" "proxy" {
  for_each = {
    for region, cfg in var.regions : region => cfg
    if cfg.proxy_cidr != null
  }

  name          = "${local.name}-proxy-${each.key}"
  ip_cidr_range = each.value.proxy_cidr
  region        = each.key
  network       = google_compute_network.vpc.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# ---- Cloud Routers + NAT (only in regions that have at least one
#       NAT-eligible subnet — gke or vm) ----
# Private nodes have no external IPs. Cloud NAT gives them outbound
# internet for image pulls, googleapis.com, OS updates. Each region
# needs its own router + NAT (both are regional).
#
# In var.gke_region the NAT additionally translates the pod secondary
# range so pods without external IPs can reach the internet.
# Proxy-only subnets are intentionally excluded — proxies don't egress.
locals {
  nat_regions = {
    for region, cfg in var.regions : region => cfg
    if (cfg.gke_pods_cidr != null && cfg.gke_services_cidr != null) || cfg.vm_subnet == true
  }
}

resource "google_compute_router" "router" {
  for_each = local.nat_regions

  name    = "${local.name}-router-${each.key}"
  region  = each.key
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  for_each = local.nat_regions

  name                               = "${local.name}-nat-${each.key}"
  router                             = google_compute_router.router[each.key].name
  region                             = each.key
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  # NAT the GKE subnet only if this region actually has one.
  dynamic "subnetwork" {
    for_each = (each.value.gke_pods_cidr != null && each.value.gke_services_cidr != null) ? [1] : []
    content {
      name = google_compute_subnetwork.gke[each.key].id

      source_ip_ranges_to_nat = (
        each.key == var.gke_region
      ) ? ["PRIMARY_IP_RANGE", "LIST_OF_SECONDARY_IP_RANGES"] : ["ALL_IP_RANGES"]

      secondary_ip_range_names = (
        each.key == var.gke_region
      ) ? ["${local.name}-gke-pods"] : []
    }
  }

  # NAT the VM subnet only if this region opted into one.
  dynamic "subnetwork" {
    for_each = each.value.vm_subnet == true ? [1] : []
    content {
      name                    = google_compute_subnetwork.vm[each.key].id
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---- Private services access (Cloud SQL + Memorystore) ----
# Single global reservation — one /16 is plenty for the producer to carve
# out the per-instance /28s it needs. Cloud SQL + Memorystore use this for
# VPC peering to their tenant projects.
resource "google_compute_global_address" "private_services" {
  name          = "${local.name}-${var.private_services_range_name}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = var.private_services_address
  prefix_length = var.private_services_prefix_length
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]

  # See full rationale in the original network.tf:
  # ABANDON skips the API delete that loops on
  # FLOW_SN_DC_RESOURCE_PREVENTING_DELETE_CONNECTION; the sibling
  # null_resource severs the consumer-side peering on destroy.
  deletion_policy = "ABANDON"
}

resource "null_resource" "private_vpc_peering_cleanup" {
  triggers = {
    network = google_compute_network.vpc.name
    project = var.project_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = "gcloud compute networks peerings delete servicenetworking-googleapis-com --network=${self.triggers.network} --project=${self.triggers.project} --quiet || true"
  }

  depends_on = [google_service_networking_connection.private_vpc]
}
