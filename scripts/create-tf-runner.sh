#!/usr/bin/env bash
# =============================================================================
# Self-contained bootstrap for the terraform-runner identity stack used by
# the .github/workflows/terraform-{plan,apply,destroy}.yml workflows.
#
# Creates (idempotently):
#   1. Workload Identity Pool      github-pool
#   2. Workload Identity Provider  github-provider     (OIDC, repo-scoped)
#   3. Service Account             terraform-runner
#   4. Project IAM binding         roles/owner
#   5. WIF binding                 iam.workloadIdentityUser for the repo
#
# Lives OUTSIDE terraform on purpose — the SA terraform CI impersonates
# can't be created by that same CI (chicken-and-egg). Run once per project
# from any machine with admin gcloud creds; the resulting SA persists
# across infra rebuilds (it's outside the terraform state).
#
# Idempotent across every step. Handles soft-deleted resources (within
# their 30-day undelete window) by undeleting rather than creating fresh,
# which preserves stable resource IDs / numeric names.
#
# Usage:
#   ./scripts/create-tf-runner.sh
#   # or override defaults via env:
#   PROJECT_ID=foo PROJECT_NUMBER=123 REPO=owner/repo \
#     ./scripts/create-tf-runner.sh
#
# After running, set the GitHub secret:
#   gh secret set TF_RUNNER_SA --repo "$REPO" --body "$SA_EMAIL"
# =============================================================================

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-terraform-project-883456}"
PROJECT_NUMBER="${PROJECT_NUMBER:-367483097634}"
REPO="${REPO:-aslamchandio/web-app-project}"

POOL_ID="github-pool"
PROVIDER_ID="github-provider"
SA_ID="terraform-runner"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
ROLE="roles/owner"

# Helper: does a workload identity pool exist (ACTIVE or DELETED)?
# Echoes the state, or empty string if it really doesn't exist.
pool_state() {
  gcloud iam workload-identity-pools describe "$POOL_ID" \
    --project="$PROJECT_ID" --location=global \
    --format='value(state)' 2>/dev/null || true
}

provider_state() {
  gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --project="$PROJECT_ID" --location=global \
    --workload-identity-pool="$POOL_ID" \
    --format='value(state)' 2>/dev/null || true
}

sa_exists()      { gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; }
sa_softdeleted_uid() {
  gcloud iam service-accounts list \
    --project="$PROJECT_ID" --show-deleted \
    --filter="email:${SA_EMAIL} AND -enabled" \
    --format="value(uniqueId)" 2>/dev/null | head -1
}

echo "===== Bootstrap terraform-runner identity stack ====="
echo "Project:  $PROJECT_ID  (number $PROJECT_NUMBER)"
echo "Repo:     $REPO"
echo "Pool:     $POOL_ID"
echo "Provider: $PROVIDER_ID"
echo "SA:       $SA_EMAIL"
echo "Role:     $ROLE"
echo ""

# ---- 1. Workload Identity Pool ----
echo "[1/5] Workload Identity Pool '$POOL_ID'..."
case "$(pool_state)" in
  ACTIVE)
    echo "  already ACTIVE"
    ;;
  DELETED)
    echo "  soft-deleted, undeleting..."
    gcloud iam workload-identity-pools undelete "$POOL_ID" \
      --project="$PROJECT_ID" --location=global
    ;;
  "")
    echo "  creating..."
    gcloud iam workload-identity-pools create "$POOL_ID" \
      --project="$PROJECT_ID" --location=global \
      --display-name="GitHub Actions" \
      --description="OIDC identities from GitHub Actions for CI"
    ;;
esac

# ---- 2. WIF Provider (OIDC, attribute-condition-pinned to this repo) ----
echo "[2/5] Workload Identity Provider '$PROVIDER_ID'..."
case "$(provider_state)" in
  ACTIVE)
    echo "  already ACTIVE"
    ;;
  DELETED)
    echo "  soft-deleted, undeleting..."
    gcloud iam workload-identity-pools providers undelete "$PROVIDER_ID" \
      --project="$PROJECT_ID" --location=global \
      --workload-identity-pool="$POOL_ID"
    ;;
  "")
    echo "  creating (attribute_condition pins to '$REPO')..."
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
      --project="$PROJECT_ID" --location=global \
      --workload-identity-pool="$POOL_ID" \
      --display-name="GitHub Actions Provider" \
      --issuer-uri="https://token.actions.githubusercontent.com" \
      --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.actor=assertion.actor" \
      --attribute-condition="assertion.repository == '${REPO}'"
    ;;
esac

# ---- 3. Service Account (create / undelete / skip) ----
echo "[3/5] Service Account '$SA_EMAIL'..."
if sa_exists; then
  echo "  already exists"
else
  DELETED_UID=$(sa_softdeleted_uid)
  if [[ -n "$DELETED_UID" ]]; then
    echo "  soft-deleted (uid=$DELETED_UID), undeleting..."
    gcloud iam service-accounts undelete "$DELETED_UID" --project="$PROJECT_ID"
  else
    echo "  creating..."
    gcloud iam service-accounts create "$SA_ID" \
      --project="$PROJECT_ID" \
      --display-name="Terraform CI runner (managed by gcloud, not terraform)" \
      --description="Impersonated by .github/workflows/terraform-*.yml via WIF"
  fi
fi

# ---- 4. Project IAM ----
echo "[4/5] Grant ${ROLE} at project scope..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="$ROLE" \
  --condition=None \
  --quiet >/dev/null
echo "  granted"

# ---- 5. WIF binding ----
echo "[5/5] WIF binding: principalSet (repo-scoped) -> ${SA_ID}..."
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${REPO}" \
  --quiet >/dev/null
echo "  bound"

echo ""
echo "===== Done ====="
echo "Set the GitHub secret so the workflows can impersonate the SA:"
echo "  gh secret set TF_RUNNER_SA --repo '$REPO' --body '$SA_EMAIL'"
echo ""
echo "And (if not already set):"
echo "  gh secret set GCP_WIF_PROVIDER --repo '$REPO' \\"
echo "    --body 'projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}'"
