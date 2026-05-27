#!/usr/bin/env bash
# =============================================================================
# Tear down the terraform-runner identity stack created by
# scripts/create-tf-runner.sh.
#
# Two modes:
#
#   ./scripts/delete-tf-runner.sh            (default — SA only)
#       Removes:
#         - terraform-runner project-level roles/owner binding
#         - terraform-runner service account (soft-delete, 30-day undelete)
#       Keeps the WIF pool + provider intact, because github-actions-ci
#       (the image-push SA used by ci.yml) is also bound to that pool.
#
#   ./scripts/delete-tf-runner.sh --full     (nuke everything)
#       In addition to the above, also:
#         - soft-deletes the github-provider WIF provider
#         - soft-deletes the github-pool WIF pool
#       Use this only if you're tearing down WIF entirely AND you've
#       also confirmed github-actions-ci doesn't need them anymore
#       (i.e. you're decommissioning the whole project).
#
# Idempotent — safe to re-run.
#
# Usage:
#   ./scripts/delete-tf-runner.sh
#   ./scripts/delete-tf-runner.sh --full
#   PROJECT_ID=foo REPO=owner/repo ./scripts/delete-tf-runner.sh
# =============================================================================

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-terraform-project-883456}"
REPO="${REPO:-aslamchandio/web-app-project}"
POOL_ID="github-pool"
PROVIDER_ID="github-provider"
SA_ID="terraform-runner"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
ROLE="roles/owner"

MODE="default"
[[ "${1:-}" == "--full" ]] && MODE="full"

echo "===== Teardown terraform-runner identity stack ====="
echo "Project: $PROJECT_ID"
echo "Mode:    $MODE  $([[ $MODE == full ]] && echo '(nukes WIF pool + provider too)')"
echo "SA:      $SA_EMAIL"
echo ""

# ---- 1. Project IAM binding (best-effort) ----
echo "[1/3] Remove ${ROLE} project binding..."
if gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
     --member="serviceAccount:${SA_EMAIL}" \
     --role="$ROLE" \
     --condition=None \
     --quiet >/dev/null 2>&1; then
  echo "  removed"
else
  echo "  (no binding present)"
fi

# ---- 2. Service Account ----
# SA-level IAM (the WIF binding) is removed automatically when the SA
# goes away. The SA enters soft-delete state for 30 days.
echo "[2/3] Delete service account..."
if gcloud iam service-accounts describe "$SA_EMAIL" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "$SA_EMAIL" \
    --project="$PROJECT_ID" --quiet
  echo "  deleted (soft-delete, 30-day undelete window)"
else
  echo "  (already absent)"
fi

# ---- 3. WIF pool + provider (only in --full mode) ----
if [[ "$MODE" == "full" ]]; then
  echo "[3/3] WIF provider + pool..."
  if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
       --project="$PROJECT_ID" --location=global \
       --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools providers delete "$PROVIDER_ID" \
      --project="$PROJECT_ID" --location=global \
      --workload-identity-pool="$POOL_ID" --quiet
    echo "  provider '$PROVIDER_ID' deleted (soft-delete)"
  else
    echo "  (provider already absent)"
  fi
  if gcloud iam workload-identity-pools describe "$POOL_ID" \
       --project="$PROJECT_ID" --location=global >/dev/null 2>&1; then
    gcloud iam workload-identity-pools delete "$POOL_ID" \
      --project="$PROJECT_ID" --location=global --quiet
    echo "  pool '$POOL_ID' deleted (soft-delete)"
  else
    echo "  (pool already absent)"
  fi
else
  echo "[3/3] WIF pool + provider — KEPT (github-actions-ci still uses them)"
  echo "       Re-run with --full to remove them too."
fi

echo ""
echo "===== Done ====="
echo "The GitHub secret can stay (it just points at a soft-deleted SA);"
echo "remove explicitly if cleaning up:"
echo "  gh secret delete TF_RUNNER_SA --repo '$REPO'"
echo ""
echo "To restore:  ./scripts/create-tf-runner.sh"
echo "Within 30 days the script undeletes the SA (preserving uniqueId);"
echo "after 30 days it creates fresh."
