#!/usr/bin/env bash
# 09-persistence.sh — Verify state survival across container restarts (hybrid mode)
#
# Source: https://floci.io/floci/configuration/storage/
#
# hybrid mode: in-memory perf + async flush to ./data every 5 seconds.
# State is restored on restart from the flush files.
# Run compose.yaml with FLOCI_STORAGE_MODE=hybrid (the default in this repo).

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

echo ""
echo "═══════════════════════════════════════"
echo "  Persistence — hybrid storage mode"
echo "═══════════════════════════════════════"

echo ""
echo "  Phase 1: Write state"

aws s3 mb s3://persistence-test-bucket 2>/dev/null || true
echo "persist-test-content-$(date +%s)" \
  | aws s3 cp - s3://persistence-test-bucket/marker.txt

aws dynamodb create-table \
  --table-name persist-check \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST 2>/dev/null || true

aws dynamodb put-item \
  --table-name persist-check \
  --item "{\"id\":{\"S\":\"restart-marker\"},\"value\":{\"S\":\"survives-restart\"},\"ts\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"

aws sqs create-queue --queue-name persist-queue 2>/dev/null || true
aws sqs send-message \
  --queue-url "${AWS_ENDPOINT_URL}/000000000000/persist-queue" \
  --message-body '{"marker":"pre-restart"}'

aws ssm put-parameter \
  --name /persist/test/marker \
  --value "written-at-$(date +%s)" \
  --type String \
  --overwrite

echo "✓ State written to S3, DynamoDB, SQS, SSM"

echo ""
echo "  Waiting 6s for hybrid flush to disk (flush interval = 5s)..."
sleep 6

echo "  Data directory contents:"
ls -la "$(dirname "$0")/../data/" 2>/dev/null || echo "  (data dir empty or not found — check volume mount)"

echo ""
echo "  Phase 2: Restart Floci container..."
docker compose restart floci

echo "  Waiting for Floci to be healthy..."
until curl -sf "${AWS_ENDPOINT_URL}/_localstack/health" > /dev/null 2>&1; do
  printf "."
  sleep 1
done
echo ""
echo "✓ Floci back online"

echo ""
echo "  Phase 3: Verify state survived restart"

echo ""
echo "  S3 marker object:"
aws s3 cp s3://persistence-test-bucket/marker.txt - && echo ""

echo ""
echo "  DynamoDB marker record:"
aws dynamodb get-item \
  --table-name persist-check \
  --key '{"id":{"S":"restart-marker"}}' \
  --query 'Item.{id:id.S, value:value.S, ts:ts.S}'

echo ""
echo "  SQS queue still exists:"
aws sqs get-queue-attributes \
  --queue-url "${AWS_ENDPOINT_URL}/000000000000/persist-queue" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes'

echo ""
echo "  SSM parameter survived:"
aws ssm get-parameter \
  --name /persist/test/marker \
  --query 'Parameter.{Name:Name,Value:Value}'

echo ""
echo "  S3 buckets after restart:"
aws s3 ls

echo ""
echo "  DynamoDB tables after restart:"
aws dynamodb list-tables --query 'TableNames'

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Storage modes reference:"
echo "  memory     — fastest, no durability, ideal for CI"
echo "  hybrid     — in-memory + 5s async flush (this demo)"
echo "  persistent — immediate flush on every write"
echo "  wal        — write-ahead log, highest durability"
echo ""
echo "  Set FLOCI_STORAGE_MODE in compose.yaml to change mode"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  ✅  Persistence demo complete"
echo "═══════════════════════════════════════"
