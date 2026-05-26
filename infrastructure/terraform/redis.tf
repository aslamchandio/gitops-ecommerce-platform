resource "google_redis_instance" "cart" {
  name           = "${local.name}-${var.redis_instance_name}"
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_gb
  region         = var.gke_region

  authorized_network      = google_compute_network.vpc.id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  redis_version           = var.redis_version
  transit_encryption_mode = "DISABLED" # private VPC — keep simple
  depends_on              = [google_service_networking_connection.private_vpc]
}
