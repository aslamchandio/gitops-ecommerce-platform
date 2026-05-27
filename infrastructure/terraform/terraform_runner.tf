# =============================================================================
# Dedicated service account for terraform CI runs.
#
# Separate from github-actions-ci (which only has
# roles/artifactregistry.writer for the image build/push path) so the
# blast radius of each identity stays bounded:
#
#   github-actions-ci   -> CI compromise can push rogue images,
#                          can't touch infra
#   terraform-runner    -> Terraform-pipeline compromise can change
#                          infra, can't push rogue images
#
# Both bind to the SAME GitHub WIF provider — the repo-scoped
# attribute_condition (configured in github_oidc.tf at the provider
# level) is the security perimeter for both.
# =============================================================================

resource "google_service_account" "terraform_runner" {
  account_id   = "terraform-runner"
  display_name = "Terraform CI runner (managed by GitHub Actions)"
}

# Project-level roles needed to plan / apply / destroy this stack.
# roles/owner is a footgun in shared environments; here it's bounded
# to the dedicated learning project, only impersonable by THIS repo
# (WIF attribute_condition), and reads as one line in audit logs.
# Tighten by replacing with the curated list below when you outgrow it.
locals {
  terraform_runner_roles = [
    "roles/owner",
    # Curated alternative — remove the owner line above and uncomment:
    # "roles/compute.admin",
    # "roles/container.admin",
    # "roles/cloudsql.admin",
    # "roles/redis.admin",
    # "roles/iam.serviceAccountAdmin",
    # "roles/resourcemanager.projectIamAdmin",
    # "roles/iam.workloadIdentityPoolAdmin",
    # "roles/secretmanager.admin",
    # "roles/certificatemanager.editor",
    # "roles/artifactregistry.admin",
    # "roles/servicenetworking.networksAdmin",
    # "roles/serviceusage.serviceUsageAdmin",
    # "roles/storage.admin",
  ]
}

resource "google_project_iam_member" "terraform_runner" {
  for_each = toset(local.terraform_runner_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.terraform_runner.email}"
}

# WIF binding — any OIDC token from the configured repo (attribute
# condition enforced on the provider in github_oidc.tf) can impersonate
# this SA. principalSet form binds to the repo claim, not a specific
# branch/ref, so plan-on-PR + apply-on-main both work.
resource "google_service_account_iam_member" "terraform_runner_wif" {
  service_account_id = google_service_account.terraform_runner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
