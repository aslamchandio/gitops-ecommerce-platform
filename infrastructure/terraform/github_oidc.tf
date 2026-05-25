# =============================================================================
# Workload Identity Federation for GitHub Actions.
#
# Lets .github/workflows/ci.yml exchange its short-lived GitHub OIDC token for
# a short-lived GCP access token scoped to one service account — no JSON keys
# stored anywhere.
#
# Tokens are accepted ONLY from this repo (attribute_condition), and the SA can
# write to ONLY the ecom-microservices Artifact Registry repo (no project-wide
# IAM).
# =============================================================================

# Pool: a logical grouping of external identity providers.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = var.github_wif_pool_id
  display_name              = "GitHub Actions"
  description               = "OIDC identities from GitHub Actions for CI"

  depends_on = [google_project_service.enabled]
}

# Provider: trusts GitHub's OIDC issuer; maps OIDC claims -> GCP attributes
# we can match against in IAM bindings.
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.github_wif_provider_id
  display_name                       = "GitHub Actions Provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  # Hard gate: only OIDC tokens from THIS repo can use the pool.
  # Without this, any github.com workflow could impersonate the SA below.
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Service account that the workflow impersonates after the OIDC exchange.
resource "google_service_account" "github_actions" {
  account_id   = var.github_actions_sa_id
  display_name = "GitHub Actions CI"
  description  = "Impersonated by .github/workflows/ci.yml to push images to Artifact Registry"
}

# Bind the WIF pool member (scoped to this exact repo) -> the SA.
# Only github.com/<var.github_repo> workflows can mint tokens for this SA.
resource "google_service_account_iam_member" "github_wif" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# Push permission ONLY on the ecom-microservices repo, not project-wide.
# Keeps blast radius tight if the workflow is ever compromised.
resource "google_artifact_registry_repository_iam_member" "github_push" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.github_actions.email}"
}
