"""
order_processor/handler.py

Lambda function triggered by SQS.
Receives order records, logs them, and writes to DynamoDB.

Deployed by: scripts/02-eventbridge-pipeline.sh
Runtime:     python3.12 (real Docker container via Floci)
"""

import json
import os
import boto3
from datetime import datetime, timezone

# When running inside Floci's Lambda container, AWS_ENDPOINT_URL
# is passed as an environment variable so the SDK points back at Floci.
endpoint_url = os.environ.get("AWS_ENDPOINT_URL", "http://host.docker.internal:4566")
table_name   = os.environ.get("TABLE_NAME", "processed-orders")
region       = os.environ.get("AWS_DEFAULT_REGION", "eu-west-1")

dynamodb = boto3.resource(
    "dynamodb",
    endpoint_url=endpoint_url,
    region_name=region,
    aws_access_key_id="test",
    aws_secret_access_key="test",
)
table = dynamodb.Table(table_name)


def lambda_handler(event, context):
    records = event.get("Records", [])
    print(f"[order-processor] received {len(records)} record(s)")

    processed = []
    for record in records:
        try:
            body = json.loads(record["body"])
            order_id    = body.get("orderId", "unknown")
            amount      = body.get("amount", 0)
            customer_id = body.get("customerId", "unknown")

            print(f"  processing order={order_id} customer={customer_id} amount={amount}")

            # Write to DynamoDB
            table.put_item(
                Item={
                    "orderId":     order_id,
                    "customerId":  customer_id,
                    "amount":      str(amount),
                    "status":      "PROCESSED",
                    "processedAt": datetime.now(timezone.utc).isoformat(),
                    "source":      "eventbridge-pipeline",
                }
            )

            processed.append(order_id)

        except (json.JSONDecodeError, KeyError) as e:
            print(f"  ERROR parsing record: {e}")

    print(f"[order-processor] done. processed={processed}")
    return {
        "statusCode": 200,
        "processed":  len(processed),
        "orderIds":   processed,
    }
