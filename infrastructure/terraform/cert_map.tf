# =============================================================================
# Certificate Map for the Gateway's HTTPS listener.
#
# GKE Gateway API on `gke-l7-global-external-managed` doesn't reference
# Certificate Manager certificates directly. The supported pattern is:
#
#   Gateway --(annotation: networking.gke.io/certmap)--> CertificateMap
#   CertificateMap --has--> CertificateMapEntry --references--> Certificate
#
# We only manage the map + entry here. The certificate itself (var.tls_
# certificate_name) was created out-of-band — terraform just references it.
#
# Apply order matters: terraform creates the map BEFORE the Gateway tries to
# look it up (the Gateway in k8s/60-gateway.yaml carries the annotation; if
# the map doesn't exist, the LB rejects the listener).
# =============================================================================

resource "google_certificate_manager_certificate_map" "ecom" {
  name        = var.certificate_map_name
  description = "Cert map used by ecom-gateway for the HTTPS listener"

  depends_on = [google_project_service.enabled]
}

resource "google_certificate_manager_certificate_map_entry" "shop" {
  name        = var.certificate_map_entry_name
  description = "Binds ${var.domain} to ${var.tls_certificate_name}"
  map         = google_certificate_manager_certificate_map.ecom.name
  hostname    = var.domain

  # Cert path is the canonical resource name. We don't manage the certificate
  # itself with terraform — it was created beforehand and is referenced by
  # name. Fetch the status anytime with:
  #   gcloud certificate-manager certificates describe ${var.tls_certificate_name}
  certificates = [
    "projects/${var.project_id}/locations/global/certificates/${var.tls_certificate_name}",
  ]
}
