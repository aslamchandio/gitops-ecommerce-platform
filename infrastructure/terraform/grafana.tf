# =============================================================================
# IAM for Grafana → Google Managed Prometheus.
#
# Grafana itself runs as plain open-source `grafana/grafana` in the cluster
# (cheap, no GCP egress for the UI). The piece that talks to GCP is the
# GMP "query frontend" — an auth proxy that accepts standard Prometheus
# HTTP API calls from Grafana and forwards them to monitoring.googleapis.com
# with proper authentication.
#
# Flow:
#   Grafana pod → http://frontend:9090/api/v1/query
#     → frontend (runs as KSA gmp-frontend, bound to GSA grafana_gmp_reader)
#       → impersonates GSA via Workload Identity
#         → calls monitoring.googleapis.com PromQL endpoint
#
# That keeps the IAM surface tiny: one read-only SA scoped to the project's
# monitoring metrics, no JSON keys, nothing public.
# =============================================================================

resource "google_service_account" "grafana_gmp_reader" {
  account_id   = "grafana-gmp-reader"
  display_name = "Grafana → GMP read-only access"
}

# monitoring.viewer is the minimum needed to query metrics under the
# prometheus_target monitored resource (and any other Cloud Monitoring
# series, but the frontend only exposes the prometheus API).
resource "google_project_iam_member" "grafana_gmp_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.grafana_gmp_reader.email}"
}

# Workload Identity: bind the in-cluster KSA `gmp-frontend` in the `ecom`
# namespace to the GCP SA above. The KSA carries the
# `iam.gke.io/gcp-service-account` annotation in k8s/95-gmp-frontend.yaml.
resource "google_service_account_iam_member" "grafana_gmp_reader_wi" {
  service_account_id = google_service_account.grafana_gmp_reader.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[ecom/gmp-frontend]"
}
