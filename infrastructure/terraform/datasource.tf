# =============================================================================
# Datasources
#
# google_compute_zones runs once per region (for_each over var.regions) so
# every regional resource — NAP location list, instance placement, GKE
# auto_provisioning_locations — can look up the current zone list for its
# region without hardcoding zone names. New zones added by GCP are picked
# up on the next `terraform apply`.
# =============================================================================

data "google_compute_zones" "available" {
  for_each = var.regions
  region   = each.key
  status   = "UP"
}
