# Remote terraform state on GCS.
#
# Why this is separate from versions.tf:
#   - Backend config is environment-specific (different prefix per env);
#     keeping it in its own file makes a future "promote to staging" or
#     "add a dev workspace" a single-file edit rather than touching the
#     core provider config.
#   - It's also the file most likely to be templated by a wrapper (e.g.
#     terragrunt) or generated, so isolating it minimizes blast radius.
#
# Why GCS:
#   - Lock file held in Cloud Storage's object generation — two concurrent
#     `terraform apply` calls fail loudly instead of corrupting state.
#   - Versioning enabled on the bucket (gs://aslam-terraform-bucket) so
#     a bad apply can be rolled back via object generation history.
#
# Bucket layout:
#   gs://aslam-terraform-bucket/
#     └── prod/
#         └── ecommerce-project/
#             └── default.tfstate          <-- this module's state
#
# Onboarding a new contributor:
#   cd infrastructure/terraform && terraform init
terraform {
  backend "gcs" {
    bucket = "aslam-terraform-bucket"
    prefix = "prod/ecommerce-project"
  }
}
