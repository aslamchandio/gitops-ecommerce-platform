#!/usr/bin/env bash
# =============================================================================
# Bootstrap the terraform-runner service account used by the
# .github/workflows/terraform-{plan,apply,destroy}.yml workflows.
#
# This SA is intentionally NOT managed by terraform — that would create a
# chicken-and-egg: the SA terraform CI impersonates can't be created by the
# terraform CI workflow that needs it. Bootstrap with gcloud once per
# project; the SA + bindings persist across infra rebuilds (they're outside
# the terraform state).
#
# Idempotent — safe to re-run. Handles:
#   - SA already exists -> skip create
#   - SA in soft-delete (after a previous teardown) -> undelete
#   - Bindings already in place -> no-op
#
# Prerequisites:
#   - gcloud authenticated against an account with project-IAM-admin rights
#   - WIF pool 'github-pool' already exists in the project (created by
#     `terraform apply` against github_oidc.tf; or by a manual bootstrap)
#
# Usage:
#   ./scripts/create-tf-runner.sh
#   # or with overrides:
#   PROJECT_ID=foo PROJECT_NUMBER=123 REPO=owner/repo ./scripts/create-tf-runner.sh
#
# After running, set the GitHub secret so the workflows can find the SA:
#   gh secret set TF_RUNNER_SA --repo $REPO --body $SA_EMAIL
# =============================================================================

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-terraform-project-883456}"
PROJECT_NUMBER="${PROJECT_NUMBER:-367483097634}"
REPO="${REPO:-aslamchandio/web-app-project}"
SA_ID="terraform-runner"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_ID="github-pool"
ROLE="roles/owner"

echo "===== Bootstrap terraform-runner ====="
echo "Project:  $PROJECT_ID  (number $PROJECT_NUMBER)"
echo "Repo:     $REPO"
echo "SA:       $SA_EMAIL"
echo "WIF pool: $POOL_ID"
echo "Role:     $ROLE"
echo ""

# Sanity check: WIF pool must exist (terraform-managed via github_oidc.tf).
if ! gcloud iam workload-identity-pools describe "$POOL_ID" \
       --project="$PROJECT_ID" --location=global >/dev/null 2>&1; then
  echo "ERROR: WIF pool '$POOL_ID' not found in $PROJECT_ID." >&2
  echo "       Run 'terraform apply' in infrastructure/terraform/ first." >&2
  exit 1
fi

# ---- 1. Service account (create / undelete / skip) ----
echo "[1/3] Service account..."
if gcloud iam service-accounts describe "$SA_EMAIL" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "  already exists, skipping create"
else
  # Look for a soft-deleted SA with the same email (30-day undelete window).
  DELETED_UID=$(gcloud iam service-accounts list \
    --project="$PROJECT_ID" --show-deleted \
    --filter="email:${SA_EMAIL} AND -enabled" \
    --format="value(uniqueId)" 2>/dev/null | head -1)
  if [[ -n "$DELETED_UID" ]]; then
    echo "  soft-deleted (uid=$DELETED_UID), undeleting..."
    gcloud iam service-accounts undelete "$DELETED_UID" --project="$PROJECT_ID"
  else
    echo "  creating new..."
    gcloud iam service-accounts create "$SA_ID" \
      --project="$PROJECT_ID" \
      --display-name="Terraform CI runner (managed by gcloud, not terraform)" \
      --description="Impersonated by .github/workflows/terraform-*.yml via WIF"
  fi
fi

# ---- 2. Project-level role (idempotent) ----
echo "[2/3] Grant ${ROLE}..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="$ROLE" \
  --condition=None \
  --quiet >/dev/null
echo "  granted"

# ---- 3. WIF binding (idempotent) ----
echo "[3/3] WIF binding -> repo $REPO..."
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${REPO}" \
  --quiet >/dev/null
echo "  bound"

echo ""
echo "===== Done ====="
echo "Now set the GitHub secret so the workflows can impersonate this SA:"
echo "  gh secret set TF_RUNNER_SA --repo $REPO --body '$SA_EMAIL'"
