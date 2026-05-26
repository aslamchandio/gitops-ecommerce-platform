# Remote terraform state on GCS.
#
# Why this is separate from versions.tf:
#   - Backend config is environment-specific (different prefix per env);
#     keeping it in its own file makes a future "promote to staging" or
#     "add a dev workspace" a single-file edit rather than touching the
#     core provider config.
#
# Why GCS:
#   - Lock file held in Cloud Storage's object generation — two concurrent
#     `terraform apply` calls fail loudly instead of corrupting state.
#   - Versioning enabled on the state bucket so a bad apply can be rolled
#     back via object generation history.
#
# Naming convention:
#   - "c1-" prefix on the config path identifies this as cluster #1 /
#     config #1 — a short, sortable tag that's easy to filter on in the
#     bucket browser when more configs land alongside it.
#   - "prod/" groups by environment; future "staging/" or "dev/" envs
#     live as siblings, e.g. staging/c1-ecommerce-project/.
#
# Onboarding a new contributor:
#   cd infrastructure/terraform && terraform init
terraform {
  backend "gcs" {
    bucket = "aslam-terraform-bucket"        # bucket is account-specific
    prefix = "prod/c1-ecommerce-project"
  }
}
