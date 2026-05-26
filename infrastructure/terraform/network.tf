resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.enabled]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = var.subnet_name
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Reserved range for Cloud SQL & Memorystore private services access.
resource "google_compute_global_address" "private_services" {
  name          = var.private_services_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.private_services_prefix_length
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]

  # After Cloud SQL + Memorystore are deleted, GCP's producer-tenant
  # project still holds the peering open for a 10-30 min internal-cleanup
  # window. Trying to delete the connection via the API during that
  # window fails with FLOW_SN_DC_RESOURCE_PREVENTING_DELETE_CONNECTION
  # and blocks the rest of the teardown.
  #
  # The structural fix is two parts:
  #   1. ABANDON so terraform doesn't make the failing API call.
  #   2. A null_resource sibling (below) whose destroy provisioner does
  #      the *consumer*-side VPC peering delete via gcloud — that's the
  #      side we own. The producer-tenant connection then self-reaps
  #      whenever GCP's cleanup catches up.
  deletion_policy = "ABANDON"
}

# Destroy-time companion to google_service_networking_connection above.
# Lives as a separate resource so the destroy provisioner can be ordered
# correctly: this resource depends_on the connection, so on apply it's
# created after, and on destroy it's destroyed BEFORE — which means the
# gcloud peering delete runs while terraform still thinks the connection
# exists, satisfying the prerequisite.
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

# ---- Cloud NAT for the private GKE nodes ----
# Private nodes have no external IP. Cloud NAT gives them outbound internet so
# they can pull container images (DockerHub, gcr.io), reach googleapis.com,
# fetch OS updates, etc. Inbound from the internet is still blocked.
resource "google_compute_router" "nat_router" {
  name    = var.nat_router_name
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = var.nat_name
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
