#!/usr/bin/env bash
# Apply the Kubernetes manifests with image placeholders substituted.
#
# Usage:  scripts/deploy.sh <PROJECT_ID> [REGION] [TAG]
#
# Assumes:
#   - terraform apply has run (so k8s/generated-config.yaml exists)
#   - kubectl is configured against the GKE cluster
#   - scripts/build-and-push.sh has pushed images for TAG
#
set -euo pipefail

PROJECT_ID="${1:?usage: deploy.sh <PROJECT_ID> [REGION] [TAG]}"
REGION="${2:-us-central1}"
TAG="${3:-latest}"
REPO="${ARTIFACT_REPO:-ecom-microservices}"

REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K8S="${ROOT}/k8s"

if [ ! -f "${K8S}/generated-config.yaml" ]; then
  echo "ERROR: ${K8S}/generated-config.yaml is missing. Run terraform apply first." >&2
  exit 1
fi

# Render image placeholders -> real Artifact Registry URLs into a temp dir.
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

for f in "${K8S}"/*.yaml; do
  out="${TMP}/$(basename "$f")"
  sed \
    -e "s#IMAGE_CATALOG#${REGISTRY}/catalog-service:${TAG}#g" \
    -e "s#IMAGE_CART#${REGISTRY}/cart-service:${TAG}#g" \
    -e "s#IMAGE_CHECKOUT#${REGISTRY}/checkout-service:${TAG}#g" \
    -e "s#IMAGE_ORDER#${REGISTRY}/order-service:${TAG}#g" \
    -e "s#IMAGE_UI#${REGISTRY}/ui-service:${TAG}#g" \
    "$f" > "$out"
done

echo "▶ Applying namespace"
kubectl apply -f "${TMP}/00-namespace.yaml"

echo "▶ Applying ComputeClass (must exist before workloads can be scheduled)"
kubectl apply -f "${TMP}/05-compute-class.yaml"

echo "▶ Applying config (ConfigMaps + ServiceAccount + SecretProviderClass)"
kubectl apply -f "${TMP}/generated-config.yaml"

# Remove legacy plaintext-password Secrets if they exist from a previous deploy.
# The synced K8s Secret `ecom-db-password` is now populated by the CSI driver
# from GCP Secret Manager — no static secrets in the cluster anymore.
echo "▶ Cleaning up legacy plaintext Secrets (if present)"
kubectl -n ecom delete secret ecom-db ecom-redis --ignore-not-found

echo "▶ Applying workloads + Gateway"
# Apply in filename order (10-, 20-, ... 70-) so dependencies are satisfied
# (e.g. ui-service Deployment before its HTTPRoute parent ref and HPA target).
for f in $(ls "${TMP}"/[1-9][0-9]-*.yaml | sort); do
  kubectl apply -f "$f"
done

echo
echo "✔ Deployed. Watch rollout with:"
echo "    kubectl -n ecom get pods -w"
echo "Once the Gateway has an address:"
echo "    kubectl -n ecom get gateway ecom-gateway"
