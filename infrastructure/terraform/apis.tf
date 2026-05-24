# Enable the GCP APIs we need. disable_on_destroy=false so a terraform destroy
# doesn't kill APIs other workloads in the project may depend on.
locals {
  required_apis = [
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "servicenetworking.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.required_apis)
  service            = each.value
  disable_on_destroy = false
}
