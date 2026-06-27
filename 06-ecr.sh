#!/usr/bin/env bash
# 06-ecr.sh — ECR with real OCI registry (registry:2 container)
#
# Source: https://floci.io/floci/services/ecr/
#
# Floci starts a real registry:2 OCI container.
# localhost loopback URIs are trusted insecure by Docker Desktop — no daemon config needed.

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCOUNT_ID=000000000000
REGION=${AWS_DEFAULT_REGION}
REPO_NAME=demo/app
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.localhost:5000"

echo ""
echo "═══════════════════════════════════════"
echo "  ECR — real OCI registry backend"
echo "═══════════════════════════════════════"

# Create repository (lazy-starts the OCI registry container)
aws ecr create-repository \
  --repository-name "${REPO_NAME}" 2>/dev/null || echo "  (repo already exists)"

echo "✓ Repository created: ${REPO_NAME}"
echo "  Registry URI: ${REGISTRY}/${REPO_NAME}"

# Authenticate Docker against Floci's emulated ECR
echo ""
echo "  Authenticating Docker..."
aws ecr get-login-password \
  | docker login \
      --username AWS \
      --password-stdin \
      "${REGISTRY}"

echo "✓ Docker authenticated"

# Pull a small base image if not already present
echo ""
echo "  Pulling base image (alpine:3.19)..."
docker pull alpine:3.19 --quiet

# Tag and push
IMAGE_TAG="${REGISTRY}/${REPO_NAME}:v1"
echo ""
echo "  Tagging as ${IMAGE_TAG}..."
docker tag alpine:3.19 "${IMAGE_TAG}"

echo "  Pushing to Floci ECR..."
docker push "${IMAGE_TAG}"

echo "✓ Image pushed"

# List images via AWS CLI
echo ""
echo "  Images in repository:"
aws ecr list-images \
  --repository-name "${REPO_NAME}" \
  --query 'imageIds[*].{tag:imageTag,digest:imageDigest}' \
  --output table

# Push a second tag
echo ""
echo "  Pushing v2 tag..."
docker tag alpine:3.19 "${REGISTRY}/${REPO_NAME}:v2"
docker push "${REGISTRY}/${REPO_NAME}:v2"

aws ecr list-images \
  --repository-name "${REPO_NAME}" \
  --query 'imageIds[*].imageTag' \
  --output json

# Pull back (clean local tag first)
echo ""
echo "  Removing local tags and pulling back from Floci ECR..."
docker rmi "${IMAGE_TAG}" "${REGISTRY}/${REPO_NAME}:v2" 2>/dev/null || true
docker pull "${IMAGE_TAG}"
echo "✓ Image pulled back successfully"

# Image detail
echo ""
echo "  Image detail:"
aws ecr describe-images \
  --repository-name "${REPO_NAME}" \
  --query 'imageDetails[*].{tag:imageTags[0],size:imageSizeInBytes,pushed:imagePushedAt}' \
  --output table

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  ECR demo complete"
echo "═══════════════════════════════════════"
