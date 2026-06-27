#!/usr/bin/env bash
# 03-step-functions.sh — Step Functions state machine (ASL execution)
#
# Source: https://floci.io/floci/services/step-functions/

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCOUNT_ID=000000000000
REGION=${AWS_DEFAULT_REGION}
SM_NAME=order-workflow

echo ""
echo "═══════════════════════════════════════"
echo "  Step Functions — order workflow"
echo "═══════════════════════════════════════"

# Delete existing state machine if present
SM_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${SM_NAME}"
aws stepfunctions delete-state-machine --state-machine-arn "${SM_ARN}" 2>/dev/null || true
sleep 1

# Create the state machine
aws stepfunctions create-state-machine \
  --name "${SM_NAME}" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/sfn-role" \
  --definition '{
    "Comment": "Order processing workflow",
    "StartAt": "ValidateOrder",
    "States": {
      "ValidateOrder": {
        "Type":       "Pass",
        "Comment":    "Validate the incoming order payload",
        "Result":     {"valid": true, "validatedBy": "rules-engine-v2"},
        "ResultPath": "$.validation",
        "Next":       "CheckInventory"
      },
      "CheckInventory": {
        "Type":       "Choice",
        "Choices": [
          {
            "Variable":            "$.amount",
            "NumericGreaterThan":  0,
            "Next":                "ProcessPayment"
          }
        ],
        "Default": "RejectOrder"
      },
      "ProcessPayment": {
        "Type":       "Pass",
        "Result":     {"transactionId": "txn-001", "gateway": "stripe-local"},
        "ResultPath": "$.payment",
        "Next":       "UpdateInventory"
      },
      "UpdateInventory": {
        "Type":       "Pass",
        "Result":     {"updated": true, "warehouseId": "WH-EU-1"},
        "ResultPath": "$.inventory",
        "Next":       "NotifyCustomer"
      },
      "NotifyCustomer": {
        "Type":    "Pass",
        "Result":  {"channel": "email", "sent": true},
        "ResultPath": "$.notification",
        "End":     true
      },
      "RejectOrder": {
        "Type":  "Fail",
        "Error": "InvalidOrder",
        "Cause": "Order amount must be greater than zero"
      }
    }
  }' > /dev/null

echo "✓ State machine '${SM_NAME}' created"

echo ""
echo "  Starting execution: happy path"
EXEC_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn "${SM_ARN}" \
  --name "exec-$(date +%s)" \
  --input '{"orderId":"abc-123","amount":42.00,"customerId":"cust-1"}' \
  --query executionArn --output text)

echo "  Execution ARN: ${EXEC_ARN}"

# Poll for completion
for i in {1..10}; do
  STATUS=$(aws stepfunctions describe-execution \
    --execution-arn "${EXEC_ARN}" \
    --query 'status' --output text)
  if [ "${STATUS}" = "SUCCEEDED" ] || [ "${STATUS}" = "FAILED" ]; then
    break
  fi
  sleep 1
done

echo "  Status: ${STATUS}"
aws stepfunctions describe-execution \
  --execution-arn "${EXEC_ARN}" \
  --query 'output' --output text | python3 -m json.tool

echo ""
echo "  Execution history (last 5 events):"
aws stepfunctions get-execution-history \
  --execution-arn "${EXEC_ARN}" \
  --query 'events[-5:].{type:type,timestamp:timestamp}' \
  --output table

echo ""
echo "  Starting execution: failure path (amount = 0)"
FAIL_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn "${SM_ARN}" \
  --name "exec-fail-$(date +%s)" \
  --input '{"orderId":"bad-001","amount":0,"customerId":"cust-x"}' \
  --query executionArn --output text)

sleep 2
aws stepfunctions describe-execution \
  --execution-arn "${FAIL_ARN}" \
  --query '{status:status, cause:cause}'

echo ""
echo "  Listing all executions:"
aws stepfunctions list-executions \
  --state-machine-arn "${SM_ARN}" \
  --query 'executions[*].{name:name,status:status}' \
  --output table

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  Step Functions demo complete"
echo "═══════════════════════════════════════"
