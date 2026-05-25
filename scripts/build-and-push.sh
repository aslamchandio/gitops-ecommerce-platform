#!/usr/bin/env bash
# Build all service images and push them to Artifact Registry.
#
# Usage:  scripts/build-and-push.sh <PROJECT_ID> [REGION] [TAG]
#
set -euo pipefail

PROJECT_ID="${1:?usage: build-and-push.sh <PROJECT_ID> [REGION] [TAG]}"
REGION="${2:-us-central1}"
TAG="${3:-$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d-%H%M%S)}"
REPO="${ARTIFACT_REPO:-ecom-microservices}"

REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}"

echo "▶ Authenticating docker to ${REGION}-docker.pkg.dev"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

SERVICES=(catalog-service cart-service checkout-service order-service ui-service)

for svc in "${SERVICES[@]}"; do
  image="${REGISTRY}/${svc}:${TAG}"
  echo "▶ Building ${svc} → ${image}"
  docker build -t "${image}" "./services/${svc}"
  echo "▶ Pushing  ${svc}"
  docker push "${image}"
  # Also tag :latest so deploy scripts can fall back to it.
  docker tag "${image}" "${REGISTRY}/${svc}:latest"
  docker push "${REGISTRY}/${svc}:latest"
done

echo
echo "✔ All images pushed with tag: ${TAG}"
echo "  Export TAG=${TAG} before running deploy.sh"
