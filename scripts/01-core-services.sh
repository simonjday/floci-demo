#!/usr/bin/env bash
# 01-core-services.sh — S3, SQS (Standard + FIFO + DLQ), DynamoDB (with GSI),
#                        SSM Parameter Store, Secrets Manager
#
# Sources: https://floci.io/floci/services/s3/
#          https://floci.io/floci/services/sqs/
#          https://floci.io/floci/services/dynamodb/
#          https://floci.io/floci/services/ssm/
#          https://floci.io/floci/services/secrets-manager/

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCOUNT_ID=000000000000
REGION=${AWS_DEFAULT_REGION}

echo ""
echo "═══════════════════════════════════════"
echo "  S3"
echo "═══════════════════════════════════════"

aws s3 mb s3://floci-demo-bucket 2>/dev/null || echo "  (bucket already exists)"
echo "hello from floci" | aws s3 cp - s3://floci-demo-bucket/hello.txt
echo '{"event":"order.placed","orderId":"abc-123"}' \
  | aws s3 cp - s3://floci-demo-bucket/events/001.json

aws s3 ls s3://floci-demo-bucket/ --recursive
aws s3 cp s3://floci-demo-bucket/hello.txt -

echo "✓ S3 — bucket created, object uploaded and retrieved"

echo ""
echo "═══════════════════════════════════════"
echo "  SQS — Standard queue with DLQ"
echo "═══════════════════════════════════════"

# Create DLQ first
aws sqs create-queue --queue-name orders-dlq 2>/dev/null || echo "  (queue already exists)"

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/orders-dlq" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

# Create main queue with redrive policy
aws sqs create-queue \
  --queue-name orders \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" \
  2>/dev/null || echo "  (queue already exists)"

# Send a message
aws sqs send-message \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/orders" \
  --message-body '{"orderId":"abc-123","amount":42.00,"status":"PLACED"}'

# Receive it
MSG=$(aws sqs receive-message \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/orders" \
  --query 'Messages[0].Body' --output text)
echo "Received: ${MSG}"

# Batch send
aws sqs send-message-batch \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/orders" \
  --entries '[
    {"Id":"1","MessageBody":"{\"orderId\":\"def-456\",\"amount\":15.00}"},
    {"Id":"2","MessageBody":"{\"orderId\":\"ghi-789\",\"amount\":99.99}"}
  ]'

echo "✓ SQS — standard queue with DLQ, send/receive, batch send"

echo ""
echo "═══════════════════════════════════════"
echo "  SQS — FIFO queue"
echo "═══════════════════════════════════════"

aws sqs create-queue \
  --queue-name payments.fifo \
  --attributes FifoQueue=true,ContentBasedDeduplication=true \
  2>/dev/null || echo "  (queue already exists)"

aws sqs send-message \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/payments.fifo" \
  --message-body '{"paymentId":"pay-001","amount":42.00}' \
  --message-group-id "customer-1"

aws sqs send-message \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/payments.fifo" \
  --message-body '{"paymentId":"pay-002","amount":15.00}' \
  --message-group-id "customer-2"

echo "✓ SQS — FIFO queue with message groups"

echo ""
echo "═══════════════════════════════════════"
echo "  DynamoDB — Table with GSI"
echo "═══════════════════════════════════════"

aws dynamodb create-table \
  --table-name orders \
  --attribute-definitions \
    AttributeName=orderId,AttributeType=S \
    AttributeName=customerId,AttributeType=S \
    AttributeName=createdAt,AttributeType=S \
  --key-schema AttributeName=orderId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[
    {
      "IndexName": "customer-index",
      "KeySchema": [
        {"AttributeName":"customerId","KeyType":"HASH"},
        {"AttributeName":"createdAt","KeyType":"RANGE"}
      ],
      "Projection":{"ProjectionType":"ALL"}
    }
  ]' 2>/dev/null || echo "  (table already exists)"

# Put items
aws dynamodb put-item --table-name orders \
  --item '{
    "orderId":    {"S":"abc-123"},
    "customerId": {"S":"cust-1"},
    "createdAt":  {"S":"2026-06-27T10:00:00Z"},
    "status":     {"S":"PLACED"},
    "amount":     {"N":"42.00"}
  }'

aws dynamodb put-item --table-name orders \
  --item '{
    "orderId":    {"S":"def-456"},
    "customerId": {"S":"cust-1"},
    "createdAt":  {"S":"2026-06-27T11:00:00Z"},
    "status":     {"S":"SHIPPED"},
    "amount":     {"N":"15.00"}
  }'

aws dynamodb put-item --table-name orders \
  --item '{
    "orderId":    {"S":"ghi-789"},
    "customerId": {"S":"cust-2"},
    "createdAt":  {"S":"2026-06-27T12:00:00Z"},
    "status":     {"S":"PLACED"},
    "amount":     {"N":"99.99"}
  }'

# GetItem
aws dynamodb get-item \
  --table-name orders \
  --key '{"orderId":{"S":"abc-123"}}' \
  --query 'Item.{order:orderId.S, status:status.S, amount:amount.N}'

# Query via GSI
echo "Customer cust-1 orders (via GSI):"
aws dynamodb query \
  --table-name orders \
  --index-name customer-index \
  --key-condition-expression "customerId = :cid" \
  --expression-attribute-values '{":cid":{"S":"cust-1"}}' \
  --query 'Items[*].{order:orderId.S, status:status.S, createdAt:createdAt.S}'

# Conditional update — expected to no-op on re-runs once status is already PROCESSING
aws dynamodb update-item \
  --table-name orders \
  --key '{"orderId":{"S":"abc-123"}}' \
  --update-expression "SET #s = :new_status" \
  --condition-expression "#s = :old_status" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":new_status":{"S":"PROCESSING"},":old_status":{"S":"PLACED"}}' \
  2>/dev/null || echo "  (already PROCESSING from a prior run — condition check correctly skipped it)"

echo "✓ DynamoDB — table, GSI, GetItem, Query, conditional Update"

echo ""
echo "═══════════════════════════════════════"
echo "  SSM Parameter Store"
echo "═══════════════════════════════════════"

aws ssm put-parameter --name /demo/db/host     --value "localhost" --type String     --overwrite
aws ssm put-parameter --name /demo/db/port     --value "5432"      --type String     --overwrite
aws ssm put-parameter --name /demo/db/name     --value "appdb"     --type String     --overwrite
aws ssm put-parameter --name /demo/db/password --value "s3cr3t"    --type SecureString --overwrite

aws ssm get-parameters-by-path \
  --path /demo/db \
  --with-decryption \
  --query 'Parameters[*].{Name:Name,Value:Value}'

echo "✓ SSM — String and SecureString parameters with path hierarchy"

echo ""
echo "═══════════════════════════════════════"
echo "  Secrets Manager"
echo "═══════════════════════════════════════"

aws secretsmanager create-secret \
  --name demo/app/credentials \
  --secret-string '{"apiKey":"sk-floci-test-key","endpoint":"http://api.internal","timeout":30}' \
  2>/dev/null || echo "  (secret already exists)"

aws secretsmanager get-secret-value \
  --secret-id demo/app/credentials \
  --query SecretString --output text | python3 -m json.tool

# Rotate (creates new version)
aws secretsmanager put-secret-value \
  --secret-id demo/app/credentials \
  --secret-string '{"apiKey":"sk-floci-rotated-key","endpoint":"http://api.internal","timeout":30}'

aws secretsmanager list-secret-version-ids \
  --secret-id demo/app/credentials \
  --query 'Versions[*].{VersionId:VersionId,Stages:VersionStages}'

echo "✓ Secrets Manager — create, retrieve, rotate secret"
echo ""
echo "═══════════════════════════════════════"
echo "  ✅  Core services demo complete"
echo "═══════════════════════════════════════"
