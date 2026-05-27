#!/usr/bin/env bash
# =============================================================================
# Tear down the terraform-runner service account + bindings created by
# scripts/create-tf-runner.sh.
#
# Removes:
#   - The project-level roles/owner binding for terraform-runner
#   - The terraform-runner service account itself (goes to soft-delete;
#     undeleteable for 30 days via create-tf-runner.sh)
#
# Does NOT remove (managed by terraform — use `terraform destroy` instead):
#   - The WIF pool (github-pool)
#   - The WIF provider (github-provider)
#   - The github-actions-ci SA (used by ci.yml for image push)
#
# Idempotent — safe to re-run.
#
# Usage:
#   ./scripts/delete-tf-runner.sh
#   # or with overrides:
#   PROJECT_ID=foo REPO=owner/repo ./scripts/delete-tf-runner.sh
# =============================================================================

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-terraform-project-883456}"
REPO="${REPO:-aslamchandio/web-app-project}"
SA_ID="terraform-runner"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
ROLE="roles/owner"

echo "===== Teardown terraform-runner ====="
echo "Project: $PROJECT_ID"
echo "SA:      $SA_EMAIL"
echo ""

if ! gcloud iam service-accounts describe "$SA_EMAIL" \
       --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Service account doesn't exist (already deleted, or never created)."
  echo "Nothing to do."
  exit 0
fi

# ---- 1. Remove project-level role binding ----
echo "[1/2] Remove ${ROLE} binding..."
if gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
     --member="serviceAccount:${SA_EMAIL}" \
     --role="$ROLE" \
     --condition=None \
     --quiet >/dev/null 2>&1; then
  echo "  removed"
else
  echo "  (no binding present)"
fi

# ---- 2. Delete the SA ----
# SA-level IAM policies (the WIF binding) are removed automatically when
# the SA goes away. The SA itself enters soft-delete (30-day undelete).
echo "[2/2] Delete service account..."
gcloud iam service-accounts delete "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --quiet

echo ""
echo "===== Done ====="
echo "The GitHub secret can stay (it just points at a non-existent SA);"
echo "remove it explicitly if you want to clean up:"
echo "  gh secret delete TF_RUNNER_SA --repo $REPO"
echo ""
echo "To restore: ./scripts/create-tf-runner.sh"
echo "(Within 30 days the script will undelete; after that it'll create fresh.)"
