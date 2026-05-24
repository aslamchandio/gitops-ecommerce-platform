# Dedicated service account for GKE nodes. Avoids using the default Compute SA
# (which is over-privileged) and lets us scope IAM roles narrowly.
resource "google_service_account" "gke_nodes" {
  account_id   = var.gke_node_sa_id
  display_name = "GKE node service account"
}

# Minimal roles the kubelet / NAP-provisioned nodes need:
#  - logging + monitoring writers for Cloud Ops
#  - metadata writer so kubelet can publish node metadata
#  - artifact registry reader so nodes can pull our images
locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset(local.gke_node_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.gke_nodes.email}"
}
