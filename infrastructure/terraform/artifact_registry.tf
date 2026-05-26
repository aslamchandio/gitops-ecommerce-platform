resource "google_artifact_registry_repository" "images" {
  location      = var.gke_region
  repository_id = var.artifact_repo
  description   = "Docker images for ${local.name}"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-recent-${var.ar_keep_recent_count}"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.ar_keep_recent_count
    }
  }

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "${var.ar_untagged_ttl_seconds}s"
    }
  }

  depends_on = [google_project_service.enabled]
}
