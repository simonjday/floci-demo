#!/usr/bin/env bash
# 10-terraform.sh — Terraform provider override against Floci
#
# Source: https://floci.io/floci/getting-started/
#
# Requires: terraform >= 1.10
#   brew install terraform
#
# Floci passes all 14 Terraform compatibility tests in the upstream test suite.
# This script provisions real Terraform-managed resources against local Floci.

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

TF_DIR="$(dirname "$0")/../terraform"

if ! command -v terraform &> /dev/null; then
  echo "terraform not found — install with: brew install terraform"
  exit 1
fi

echo ""
echo "═══════════════════════════════════════"
echo "  Terraform — IaC against Floci"
echo "═══════════════════════════════════════"

cd "${TF_DIR}"

echo ""
echo "  terraform init..."
terraform init -upgrade -no-color 2>&1 | tail -5

echo ""
echo "  terraform plan..."
terraform plan -no-color 2>&1 | tail -20

echo ""
echo "  terraform apply..."
terraform apply -auto-approve -no-color 2>&1 | tail -20

echo "✓ Terraform apply complete"

echo ""
echo "  Verifying resources in Floci via AWS CLI..."

echo ""
echo "  S3 buckets:"
aws s3 ls | grep tf-demo

echo ""
echo "  SQS queues:"
aws sqs list-queues --query 'QueueUrls' | grep tf-demo

echo ""
echo "  DynamoDB tables:"
aws dynamodb list-tables --query 'TableNames' | grep tf-demo

echo ""
echo "  Terraform state:"
terraform state list

echo ""
echo "  terraform destroy..."
terraform destroy -auto-approve -no-color 2>&1 | tail -10

echo ""
echo "  Resources removed from Floci:"
aws dynamodb list-tables --query 'TableNames'

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  Terraform demo complete"
echo "═══════════════════════════════════════"
