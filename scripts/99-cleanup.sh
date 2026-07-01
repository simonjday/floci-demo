#!/usr/bin/env bash
# 99-cleanup.sh — Full reset of Floci state
#
# Because compose.yaml runs FLOCI_STORAGE_MODE=hybrid, everything the demo
# scripts create (buckets, queues, tables, secrets, the Lambda function, the
# RDS/MSK/ECR containers, etc.) persists across `docker compose restart` and
# survives between separate runs of scripts/01-*.sh through scripts/10-*.sh.
# That's the point of Step 11 (09-persistence.sh), but it also means running
# the numbered scripts repeatedly accumulates state — most are now idempotent
# (see 01-core-services.sh), but the cleanest fix for "start over" is simply
# to wipe the container and its persisted data.
#
# Usage: bash scripts/99-cleanup.sh

set -euo pipefail

cd "$(dirname "$0")/.."

echo "This will stop Floci and permanently delete all persisted demo state"
echo "(./data — S3 objects, DynamoDB tables, SQS queues, secrets, RDS/MSK/ECR"
echo "container data, everything created by scripts/01-*.sh through 10-*.sh)."
read -r -p "Continue? [y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborted — nothing changed."
  exit 0
fi

echo ""
echo "Stopping and removing the Floci container..."
docker compose down

echo "Removing persisted state (./data)..."
rm -rf ./data

echo "Removing any leftover Terraform state from script 10, if present..."
rm -rf ./terraform/.terraform ./terraform/.terraform.lock.hcl ./terraform/terraform.tfstate*

echo ""
echo "✓ Clean. Bring Floci back up with:"
echo "    docker compose up -d"
echo "    source scripts/00-setup.sh"
