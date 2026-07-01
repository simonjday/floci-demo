#!/usr/bin/env bash
# 04-multi-account.sh — Multi-account isolation using 12-digit AWS_ACCESS_KEY_ID
#
# Source: https://floci.io/floci/configuration/multi-account/
#
# If AWS_ACCESS_KEY_ID is exactly 12 digits, Floci uses it as the account ID.
# Resources created under one account are invisible to another.

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCT_A=111111111111
ACCT_B=222222222222

echo ""
echo "═══════════════════════════════════════"
echo "  Multi-Account Isolation"
echo "  Account A: ${ACCT_A}"
echo "  Account B: ${ACCT_B}"
echo "═══════════════════════════════════════"

# ── Account A ─────────────────────────────────────────────────────────────────
echo ""
echo "  [Account A] Creating resources..."
AWS_ACCESS_KEY_ID=${ACCT_A} aws sqs create-queue --queue-name shared-queue-name
AWS_ACCESS_KEY_ID=${ACCT_A} aws sqs create-queue --queue-name account-a-only
AWS_ACCESS_KEY_ID=${ACCT_A} aws s3 mb s3://account-a-bucket
AWS_ACCESS_KEY_ID=${ACCT_A} aws dynamodb create-table \
  --table-name shared-table-name \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST > /dev/null
AWS_ACCESS_KEY_ID=${ACCT_A} aws dynamodb put-item \
  --table-name shared-table-name \
  --item '{"id":{"S":"account-a-record"},"owner":{"S":"account-a"}}'

echo "  [Account A] Resources created"

# ── Account B ─────────────────────────────────────────────────────────────────
echo ""
echo "  [Account B] Creating resources with same names..."
AWS_ACCESS_KEY_ID=${ACCT_B} aws sqs create-queue --queue-name shared-queue-name
AWS_ACCESS_KEY_ID=${ACCT_B} aws sqs create-queue --queue-name account-b-only
AWS_ACCESS_KEY_ID=${ACCT_B} aws s3 mb s3://account-b-bucket
AWS_ACCESS_KEY_ID=${ACCT_B} aws dynamodb create-table \
  --table-name shared-table-name \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST > /dev/null
AWS_ACCESS_KEY_ID=${ACCT_B} aws dynamodb put-item \
  --table-name shared-table-name \
  --item '{"id":{"S":"account-b-record"},"owner":{"S":"account-b"}}'

echo "  [Account B] Resources created"

# ── Isolation verification ─────────────────────────────────────────────────────
echo ""
echo "  Verifying isolation..."
echo ""

echo "  [Account A] SQS queues:"
AWS_ACCESS_KEY_ID=${ACCT_A} aws sqs list-queues \
  --query 'QueueUrls' --output table

echo ""
echo "  [Account B] SQS queues:"
AWS_ACCESS_KEY_ID=${ACCT_B} aws sqs list-queues \
  --query 'QueueUrls' --output table

echo ""
echo "  [Account A] S3 buckets:"
AWS_ACCESS_KEY_ID=${ACCT_A} aws s3 ls

echo ""
echo "  [Account B] S3 buckets:"
AWS_ACCESS_KEY_ID=${ACCT_B} aws s3 ls

echo ""
echo "  [Account A] DynamoDB scan (should show account-a-record only):"
AWS_ACCESS_KEY_ID=${ACCT_A} aws dynamodb scan \
  --table-name shared-table-name \
  --query 'Items[*].{id:id.S, owner:owner.S}'

echo ""
echo "  [Account B] DynamoDB scan (should show account-b-record only):"
AWS_ACCESS_KEY_ID=${ACCT_B} aws dynamodb scan \
  --table-name shared-table-name \
  --query 'Items[*].{id:id.S, owner:owner.S}'

echo ""
echo "  Account A cannot see account-b-only queue:"
NOT_FOUND=$(AWS_ACCESS_KEY_ID=${ACCT_A} aws sqs get-queue-url \
  --queue-name account-b-only 2>&1 || true)
if echo "${NOT_FOUND}" | grep -q "NonExistentQueue\|does not exist"; then
  echo "  ✓ Confirmed — queue not visible across accounts"
else
  echo "  (Result: ${NOT_FOUND})"
fi

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  Multi-account isolation demo complete"
echo "═══════════════════════════════════════"
