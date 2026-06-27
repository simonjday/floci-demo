#!/usr/bin/env bash
# 02-eventbridge-pipeline.sh — EventBridge → SQS → Lambda (real Docker) → DynamoDB
#
# Sources: https://floci.io/floci/services/eventbridge/
#          https://floci.io/floci/services/lambda/
#          https://floci.io/floci/services/dynamodb/
#
# NOTE: Lambda invokes a real Docker container on first call.
#       First run may take 10-30s while the runtime image is pulled.

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCOUNT_ID=000000000000
REGION=${AWS_DEFAULT_REGION}
LAMBDA_DIR="$(dirname "$0")/../lambda/order_processor"

echo ""
echo "═══════════════════════════════════════"
echo "  DynamoDB — processed orders table"
echo "═══════════════════════════════════════"

aws dynamodb create-table \
  --table-name processed-orders \
  --attribute-definitions AttributeName=orderId,AttributeType=S \
  --key-schema AttributeName=orderId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST 2>/dev/null || echo "  (table already exists)"

echo "✓ processed-orders table ready"

echo ""
echo "═══════════════════════════════════════"
echo "  SQS — order processing queue"
echo "═══════════════════════════════════════"

aws sqs create-queue --queue-name order-events 2>/dev/null || echo "  (queue already exists)"

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/order-events" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

echo "✓ order-events queue: ${QUEUE_ARN}"

echo ""
echo "═══════════════════════════════════════"
echo "  Lambda — build and deploy"
echo "═══════════════════════════════════════"

# Package the Lambda function
cd "${LAMBDA_DIR}"
zip -q -j /tmp/order-processor.zip handler.py
cd - > /dev/null

# Create or update function
if aws lambda get-function --function-name order-processor > /dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name order-processor \
    --zip-file fileb:///tmp/order-processor.zip > /dev/null
  echo "  (function updated)"
else
  aws lambda create-function \
    --function-name order-processor \
    --runtime python3.12 \
    --handler handler.lambda_handler \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/lambda-role" \
    --zip-file fileb:///tmp/order-processor.zip \
    --timeout 30 \
    --environment "Variables={TABLE_NAME=processed-orders,AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL}}" \
    > /dev/null
  echo "  function created"
fi

# Wait for active state
aws lambda wait function-active --function-name order-processor
echo "✓ order-processor Lambda deployed"

echo ""
echo "═══════════════════════════════════════"
echo "  Lambda direct invocation test"
echo "═══════════════════════════════════════"

# First invocation pulls the runtime image — may take a moment
echo "  Invoking Lambda (first call may pull runtime image)..."
aws lambda invoke \
  --function-name order-processor \
  --payload '{"Records":[{"body":"{\"orderId\":\"direct-001\",\"amount\":42.00,\"customerId\":\"cust-1\"}"}]}' \
  /tmp/lambda-out.json > /dev/null
cat /tmp/lambda-out.json
echo ""

echo "✓ Lambda invoked successfully via real Docker runtime"

echo ""
echo "═══════════════════════════════════════"
echo "  SQS → Lambda event source mapping"
echo "═══════════════════════════════════════"

# Check if mapping already exists
MAPPING_UUID=$(aws lambda list-event-source-mappings \
  --function-name order-processor \
  --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null || echo "None")

if [ "${MAPPING_UUID}" = "None" ] || [ -z "${MAPPING_UUID}" ]; then
  aws lambda create-event-source-mapping \
    --function-name order-processor \
    --event-source-arn "${QUEUE_ARN}" \
    --batch-size 5 \
    --enabled > /dev/null
  echo "  event source mapping created"
else
  echo "  (mapping already exists: ${MAPPING_UUID})"
fi

echo "✓ SQS → Lambda event source mapping active"

echo ""
echo "═══════════════════════════════════════"
echo "  EventBridge — custom bus and rule"
echo "═══════════════════════════════════════"

aws events create-event-bus --name commerce 2>/dev/null || echo "  (bus already exists)"

aws events put-rule \
  --name route-orders-to-queue \
  --event-bus-name commerce \
  --event-pattern '{
    "source":      ["com.demo.orders"],
    "detail-type": ["OrderPlaced"]
  }' \
  --state ENABLED > /dev/null

aws events put-targets \
  --rule route-orders-to-queue \
  --event-bus-name commerce \
  --targets "[{\"Id\":\"sqs-target\",\"Arn\":\"${QUEUE_ARN}\"}]" > /dev/null

echo "✓ EventBridge bus 'commerce' with rule → SQS target"

echo ""
echo "═══════════════════════════════════════"
echo "  Fire test events"
echo "═══════════════════════════════════════"

aws events put-events \
  --entries '[
    {
      "EventBusName": "commerce",
      "Source":       "com.demo.orders",
      "DetailType":   "OrderPlaced",
      "Detail":       "{\"orderId\":\"ev-001\",\"amount\":99.99,\"customerId\":\"cust-2\"}"
    },
    {
      "EventBusName": "commerce",
      "Source":       "com.demo.orders",
      "DetailType":   "OrderPlaced",
      "Detail":       "{\"orderId\":\"ev-002\",\"amount\":14.50,\"customerId\":\"cust-3\"}"
    }
  ]'

echo "✓ 2 OrderPlaced events fired → EventBridge → SQS → Lambda"
echo ""
echo "  Checking SQS queue depth (Lambda processes async)..."
sleep 3
aws sqs get-queue-attributes \
  --queue-url "${AWS_ENDPOINT_URL}/${ACCOUNT_ID}/order-events" \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
  --query 'Attributes'

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  EventBridge pipeline demo complete"
echo "═══════════════════════════════════════"
