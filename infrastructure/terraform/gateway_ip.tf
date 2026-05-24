# Reserved global IPv4 address that the Kubernetes Gateway pins to.
#
# The Gateway resource (k8s/60-gateway.yaml) references this address by NAME
# (`spec.addresses[].value = "ecom-ip"`), so the Gateway controller looks up
# this google_compute_global_address by its `name` attribute in the project.
#
# If you already created this manually with `gcloud compute addresses create`,
# import it into state instead of recreating:
#
#   terraform import google_compute_global_address.gateway \
#     projects/${var.project_id}/global/addresses/${var.gateway_address_name}
resource "google_compute_global_address" "gateway" {
  name         = var.gateway_address_name
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
  # NOTE: do NOT set `description` — it's immutable on existing addresses
  # and adding it to an imported resource would force destroy+recreate
  # (which changes the IP value and breaks the live Gateway).

  depends_on = [google_project_service.enabled]
}
