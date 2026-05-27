output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_region" {
  value = google_container_cluster.primary.location
}

output "kubectl_connect_command" {
  description = "Run this to point kubectl at the new cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${google_container_cluster.primary.location} --project ${var.project_id}"
}

output "artifact_registry_url" {
  description = "Base path for docker tags. Append /<service>:<tag>."
  value       = "${var.gke_region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "postgres_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}

output "redis_host" {
  value = google_redis_instance.cart.host
}

output "gateway_ip" {
  description = "Public IP that the Kubernetes Gateway pins to (DNS A-record target)."
  value       = google_compute_global_address.gateway.address
}

output "gateway_ip_name" {
  description = "Name of the reserved address resource. Used by k8s/60-gateway.yaml addresses[].value."
  value       = google_compute_global_address.gateway.name
}

output "db_password" {
  description = "Generated DB password (also written to k8s/generated-secrets.yaml)."
  value       = random_password.db_password.result
  sensitive   = true
}

# ---- ArgoCD ----
output "argocd_url" {
  description = "ArgoCD UI URL — restricted to master_authorized_networks."
  value       = try("http://${data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].ip}", "pending — re-run `terraform refresh` after the LB IP is assigned")
}

output "argocd_password_command" {
  description = "Run this to retrieve the initial ArgoCD admin password (then change it via the UI)."
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

# ---- GitHub Actions WIF — paste these into GitHub repo secrets ----
output "github_actions_wif_provider" {
  description = "Paste this into GitHub Actions secret GCP_WIF_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_actions_sa_email" {
  description = "Paste this into GitHub Actions secret GCP_SERVICE_ACCOUNT."
  value       = google_service_account.github_actions.email
}

output "terraform_runner_sa_email" {
  description = "Paste this into GitHub Actions secret TF_RUNNER_SA — used by the terraform plan/apply/destroy workflows."
  value       = google_service_account.terraform_runner.email
}
