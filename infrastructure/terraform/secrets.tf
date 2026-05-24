# Renders Kubernetes manifests that depend on terraform-known values:
#   - ConfigMap with non-sensitive connection info (DB host/user/jdbc, Redis host/port)
#   - K8s ServiceAccount annotated for Workload Identity → GCP SA mapping
#   - SecretProviderClass that pulls the DB password from GSM and syncs it
#     into a regular K8s Secret named `ecom-db-password`.
#
# The DB password itself NEVER touches this file. It lives in GCP Secret
# Manager (managed in secret_manager.tf) and is fetched at pod startup by
# the Secret Manager CSI driver running on the cluster.
resource "local_file" "k8s_config" {
  filename = "${path.module}/../../k8s/generated-config.yaml"
  content  = <<-EOT
    # ---------------------------------------------------------------------------
    # Non-sensitive connection info — Postgres + Redis hosts, db names, JDBC URL
    # ---------------------------------------------------------------------------
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ecom-db-config
      namespace: ecom
    data:
      DB_HOST: "${google_sql_database_instance.postgres.private_ip_address}"
      DB_USER: "${google_sql_user.app.name}"
      DB_PORT: "5432"
      DB_NAME_CATALOG: "${google_sql_database.catalog.name}"
      DB_NAME_ORDERS: "${google_sql_database.orders.name}"
      JDBC_ORDERS_URL: "jdbc:postgresql://${google_sql_database_instance.postgres.private_ip_address}:5432/${google_sql_database.orders.name}"
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ecom-redis-config
      namespace: ecom
    data:
      REDIS_HOST: "${google_redis_instance.cart.host}"
      REDIS_PORT: "${google_redis_instance.cart.port}"
    ---
    # ---------------------------------------------------------------------------
    # Workload Identity-enabled ServiceAccount. The annotation tells GKE which
    # GCP service account this K8s SA is allowed to impersonate.
    # ---------------------------------------------------------------------------
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: ${var.k8s_workload_sa_name}
      namespace: ecom
      annotations:
        iam.gke.io/gcp-service-account: ${google_service_account.workload.email}
    ---
    # ---------------------------------------------------------------------------
    # SecretProviderClass — instructs the CSI driver to fetch the GSM secret
    # and mount it as a file at /var/secrets/db-password inside each pod.
    #
    # NO `secretObjects:` block — that feature would sync the value into a
    # regular K8s Secret, but doing so requires granting the driver SA
    # cluster-wide Secret-management RBAC. Reading from the file directly is
    # the more secure pattern: the password lives only in the pod's tmpfs,
    # never as a K8s API object.
    # ---------------------------------------------------------------------------
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: ecom-db-password
      namespace: ecom
    spec:
      provider: gke
      parameters:
        secrets: |
          - resourceName: "projects/${var.project_id}/secrets/${google_secret_manager_secret.db_password.secret_id}/versions/latest"
            fileName: "db-password"
  EOT

  file_permission = "0644"

  # Ensure all referenced resources exist before we render the manifest.
  depends_on = [
    google_sql_database_instance.postgres,
    google_sql_user.app,
    google_redis_instance.cart,
    google_service_account.workload,
    google_secret_manager_secret.db_password,
  ]
}
