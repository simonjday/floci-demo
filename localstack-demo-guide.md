# LocalStack — End-to-End Demo Flow for M3 MacBook Pro

> **Purpose:** Evaluate LocalStack for AWS on Apple Silicon, covering account setup, core services, IaC via Terraform, and a realistic event-driven pipeline.  
> **Target hardware:** MacBook Pro M3 (arm64), Docker Desktop  
> **Time to complete:** ~30–40 minutes including image pulls  
> **Last verified:** June 2026

---

## Important Context Before You Start

As of **March 23, 2026**, LocalStack consolidated `localstack/localstack` and `localstack/localstack-pro` into a single Docker image. Both tags now contain the same image, and an account plus `LOCALSTACK_AUTH_TOKEN` is **required to start the container** — there is no longer a no-account community image.

A free **Hobby** tier exists for non-commercial use and gives equivalent functionality to the old community edition, but it still requires registering an account and obtaining a token.

By default, **LocalStack does not persist data across container restarts** — it is ephemeral. Persistence is available via the `PERSISTENCE` flag or LocalStack's Cloud Pods feature (see Step 8).

Sources:
- https://blog.localstack.cloud/the-road-ahead-for-localstack/
- https://blog.localstack.cloud/localstack-for-aws-release-2026-03-0/
- https://docs.localstack.cloud/aws/getting-started/auth-token/
- https://docs.localstack.cloud/aws/developer-tools/snapshots/persistence/

---

## Step 1 — Get a LocalStack Account and Auth Token

1. Go to https://app.localstack.cloud and create a free account (Hobby tier for non-commercial evaluation, or start a Base/Ultimate trial for commercial evaluation).
2. Navigate to the Auth Token page in the LocalStack Web Application to retrieve your personal Auth Token.
3. Export it in your shell:

```bash
export LOCALSTACK_AUTH_TOKEN="<your-token-here>"
```

Add this to your `.zshrc` if you'll be running LocalStack regularly:

```bash
echo 'export LOCALSTACK_AUTH_TOKEN="<your-token-here>"' >> ~/.zshrc
source ~/.zshrc
```

> **Note:** There is a temporary bypass flag, `LOCALSTACK_ACKNOWLEDGE_ACCOUNT_REQUIREMENT=1`, that LocalStack introduced to give teams more migration time — but this was only valid until **April 6, 2026** and should not be relied on now.

Source: https://blog.localstack.cloud/localstack-for-aws-release-2026-03-0/

---

## Step 2 — Prerequisites

```bash
# Verify Docker Desktop is running on arm64
docker info | grep -E "Architecture|Server Version"

# Verify AWS CLI v2 is installed
aws --version

# Install the LocalStack CLI (recommended — validates your config and avoids
# common docker-compose pitfalls around container naming, networking, and volumes)
brew install localstack/tap/localstack-cli

# Install pipx — modern macOS Python installs are "externally managed" (PEP 668),
# so a bare `pip install` will fail with externally-managed-environment.
# pipx installs CLI tools in isolated environments without that restriction.
brew install pipx
pipx ensurepath
source ~/.zshrc   # or restart your terminal

# Install awslocal — a thin wrapper around the AWS CLI that automatically
# points at the LocalStack endpoint (no --endpoint-url needed on every call)
pipx install awscli-local

# Install tflocal — a Terraform wrapper that auto-configures provider
# endpoints to point at LocalStack
pipx install terraform-local

# Verify
localstack --version
awslocal --version
tflocal -version
```

> **Troubleshooting:** If `pip install awscli-local` fails with `error: externally-managed-environment`, use `pipx` as above. This is a standard protection in recent Python/Homebrew installs on macOS, not a problem with the package itself. The `terraform-local` project's own README recommends `pipx` for exactly this reason.

Sources:
- https://docs.localstack.cloud/aws/getting-started/installation/
- https://github.com/localstack/terraform-local (pipx recommended in installation section)

---

## Step 3 — Project Structure

```bash
mkdir localstack-demo && cd localstack-demo
mkdir -p lambda terraform
```

---

## Step 4 — `docker-compose.yml`

LocalStack's official Docker Compose reference requires the container name, the `LOCALSTACK_AUTH_TOKEN` environment variable, the external service port range, and a Docker socket mount for services that depend on Docker (e.g. Lambda).

```yaml
# docker-compose.yml
version: "3.8"

services:
  localstack:
    container_name: "${LOCALSTACK_DOCKER_NAME:-localstack-main}"
    image: localstack/localstack-pro     # localstack/localstack now resolves to the same image
    platform: linux/arm64                # explicit for M3 — LocalStack publishes a multi-arch manifest
    ports:
      - "127.0.0.1:4566:4566"            # LocalStack Gateway — all services
      - "127.0.0.1:4510-4559:4510-4559"  # external service port range (RDS, OpenSearch, etc.)
    environment:
      # Auth — required since the March 2026 image consolidation
      - LOCALSTACK_AUTH_TOKEN=${LOCALSTACK_AUTH_TOKEN}
      - DEBUG=${DEBUG:-0}
      # Persistence (off by default — set PERSISTENCE=1 to retain state across restarts)
      - PERSISTENCE=${PERSISTENCE:-0}
    volumes:
      - "${LOCALSTACK_VOLUME_DIR:-./volume}:/var/lib/localstack"
      - "/var/run/docker.sock:/var/run/docker.sock"
```

Source: https://hub.docker.com/r/localstack/localstack (official docker-compose.yml reference)

---

## Step 5 — Start LocalStack

**Option A — via LocalStack CLI (recommended; validates config and warns on misconfiguration):**

```bash
localstack start -d
localstack status
```

Expected output includes the runtime status, Docker image tag, and container IP.

**Option B — via Docker Compose:**

```bash
docker compose up -d
docker compose logs -f localstack
```

Wait for the health check to pass:

```bash
curl -s http://localhost:4566/_localstack/health | jq .
```

Source: https://docs.localstack.cloud/aws/getting-started/quickstart/

---

## Step 6 — Configure Shell Environment

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
```

From here you can use either `aws --endpoint-url=http://localhost:4566 <command>` or, more conveniently, `awslocal <command>` (which has the endpoint pre-configured).

---

## Step 7 — Core Services Smoke Test

### S3

```bash
awslocal s3 mb s3://localstack-demo-bucket
echo '{"event":"demo","ts":"2026-06-30"}' | awslocal s3 cp - s3://localstack-demo-bucket/events/001.json
awslocal s3 ls s3://localstack-demo-bucket/events/
awslocal s3 cp s3://localstack-demo-bucket/events/001.json -
```

### SQS (Standard + DLQ)

```bash
awslocal sqs create-queue --queue-name orders-dlq

DLQ_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/orders-dlq \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

awslocal sqs create-queue --queue-name orders \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}"

awslocal sqs send-message \
  --queue-url http://localhost:4566/000000000000/orders \
  --message-body '{"orderId":"abc-123","amount":42.00}'

awslocal sqs receive-message \
  --queue-url http://localhost:4566/000000000000/orders \
  --query 'Messages[0].Body'
```

### DynamoDB

```bash
awslocal dynamodb create-table \
  --table-name orders \
  --attribute-definitions AttributeName=orderId,AttributeType=S \
  --key-schema AttributeName=orderId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

awslocal dynamodb put-item --table-name orders \
  --item '{"orderId":{"S":"abc-123"},"status":{"S":"PLACED"},"amount":{"N":"42.00"}}'

awslocal dynamodb get-item --table-name orders \
  --key '{"orderId":{"S":"abc-123"}}'
```

### Secrets Manager + SSM

```bash
awslocal ssm put-parameter --name /demo/db/host --value "localhost" --type String
awslocal ssm get-parameter --name /demo/db/host

awslocal secretsmanager create-secret \
  --name demo/app/credentials \
  --secret-string '{"apiKey":"test-key"}'

awslocal secretsmanager get-secret-value --secret-id demo/app/credentials
```

Source for all service commands: https://docs.localstack.cloud/aws/services/

---

## Step 8 — Lambda (Real Container Execution)

LocalStack runs Lambda functions in real Docker containers — this requires the Docker socket mounted in Step 4.

```bash
mkdir -p lambda
cat > lambda/handler.py << 'EOF'
import json

def lambda_handler(event, context):
    print(f"Received {len(event.get('Records', []))} records")
    for record in event.get('Records', []):
        body = json.loads(record['body'])
        print(f"Processing: {body}")
    return {"statusCode": 200, "processed": len(event.get('Records', []))}
EOF

cd lambda
zip handler.zip handler.py
cd ..

awslocal lambda create-function \
  --function-name order-processor \
  --runtime python3.12 \
  --handler handler.lambda_handler \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --zip-file fileb://lambda/handler.zip \
  --timeout 30

awslocal lambda invoke \
  --function-name order-processor \
  --payload '{"Records":[{"body":"{\"orderId\":\"abc-123\"}"}]}' \
  /tmp/lambda-out.json
cat /tmp/lambda-out.json
```

### Wire SQS → Lambda

```bash
QUEUE_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/orders \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

awslocal lambda create-event-source-mapping \
  --function-name order-processor \
  --event-source-arn "$QUEUE_ARN" \
  --batch-size 5 \
  --enabled
```

Source: https://docs.localstack.cloud/aws/services/lambda/

---

## Step 9 — EventBridge → SQS

```bash
awslocal events create-event-bus --name commerce

awslocal events put-rule \
  --name route-orders-to-queue \
  --event-bus-name commerce \
  --event-pattern '{"source":["com.demo.orders"],"detail-type":["OrderPlaced"]}' \
  --state ENABLED

awslocal events put-targets \
  --rule route-orders-to-queue \
  --event-bus-name commerce \
  --targets "[{\"Id\":\"sqs-target\",\"Arn\":\"$QUEUE_ARN\"}]"

awslocal events put-events \
  --entries '[{
    "EventBusName": "commerce",
    "Source": "com.demo.orders",
    "DetailType": "OrderPlaced",
    "Detail": "{\"orderId\":\"xyz-789\",\"amount\":99.99}"
  }]'

# Confirm message arrived
awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/orders \
  --attribute-names ApproximateNumberOfMessages
```

Source: https://docs.localstack.cloud/aws/services/events/

---

## Step 10 — Step Functions

```bash
cat > /tmp/order-workflow.json << 'EOF'
{
  "Comment": "Order processing workflow",
  "StartAt": "ValidateOrder",
  "States": {
    "ValidateOrder": {
      "Type": "Pass",
      "Result": {"status": "valid"},
      "ResultPath": "$.validation",
      "Next": "NotifyCustomer"
    },
    "NotifyCustomer": {
      "Type": "Pass",
      "End": true
    }
  }
}
EOF

awslocal stepfunctions create-state-machine \
  --name order-workflow \
  --definition file:///tmp/order-workflow.json \
  --role-arn arn:aws:iam::000000000000:role/sfn-role

EXEC_ARN=$(awslocal stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:000000000000:stateMachine:order-workflow \
  --input '{"orderId":"abc-123"}' \
  --query executionArn --output text)

awslocal stepfunctions describe-execution \
  --execution-arn "$EXEC_ARN" \
  --query '{status:status, output:output}'
```

Source: https://docs.localstack.cloud/aws/services/stepfunctions/

---

## Step 11 — Terraform via `tflocal`

`tflocal` automatically configures the AWS provider's service endpoints to point at LocalStack — no manual endpoint block needed.

```bash
cat > terraform/main.tf << 'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "demo" {
  bucket = "tf-localstack-demo-bucket"
}

resource "aws_sqs_queue" "demo" {
  name = "tf-localstack-demo-queue"
}

resource "aws_dynamodb_table" "demo" {
  name         = "tf-localstack-demo-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
EOF

cd terraform
tflocal init
tflocal apply -auto-approve

# Verify
awslocal s3 ls | grep tf-localstack
awslocal sqs list-queues | grep tf-localstack
awslocal dynamodb list-tables | grep tf-localstack

cd ..
```

Sources:
- https://docs.localstack.cloud/aws/integrations/infrastructure-as-code/terraform/
- https://github.com/localstack/terraform-local

---

## Step 12 — Persistence (Optional)

By default, LocalStack is **ephemeral** — state is lost when the container stops. To retain state across restarts:

```bash
# Stop current instance
localstack stop   # or: docker compose down

# Restart with persistence enabled
PERSISTENCE=1 localstack start -d
# or
PERSISTENCE=1 docker compose up -d
```

State is written to the volume mounted at `/var/lib/localstack` (configured in Step 4 as `./volume`).

For team-shared state snapshots, LocalStack offers **Cloud Pods** (available from Base tier upward) — export and import full environment state via the LocalStack Web Application or CLI. This is a paid-tier feature, distinct from the free `PERSISTENCE` flag.

Sources:
- https://docs.localstack.cloud/aws/developer-tools/snapshots/persistence/
- https://docs.localstack.cloud/aws/developer-tools/snapshots/cloud-pods/

---

## Step 13 — Teardown

```bash
# Via CLI
localstack stop

# Via Docker Compose
docker compose down

# Remove persisted volume data if PERSISTENCE was used
rm -rf ./volume
```

---

## Troubleshooting on macOS / M3

| Symptom | Cause | Fix |
|---|---|---|
| Container fails to start, license/auth warning | Missing or invalid `LOCALSTACK_AUTH_TOKEN` | Re-check Step 1; confirm the env var is exported in the shell running `docker compose` |
| Wrong architecture pulled | Docker not resolving arm64 manifest | Add `platform: linux/arm64` explicitly in compose; LocalStack publishes multi-arch manifests since v0.13 |
| Lambda invocation hangs | Docker socket not mounted | Confirm `/var/run/docker.sock:/var/run/docker.sock` volume is present |
| Container name resolution fails between containers | Using `network_mode: bridge` | Remove `network_mode: bridge` if other containers need to resolve LocalStack by name |
| State lost after restart | Persistence not enabled | Set `PERSISTENCE=1` per Step 12 |
| `pip install awscli-local` fails | `externally-managed-environment` (PEP 668) on modern macOS/Homebrew Python | Use `pipx install awscli-local` instead — see Step 2 |
| `tflocal: command not found` | pipx binaries not on PATH | Run `pipx ensurepath` and restart your shell |

Sources:
- https://docs.localstack.cloud/aws/capabilities/config/arm64-support/
- https://docs.localstack.cloud/aws/getting-started/installation/
- https://github.com/localstack/terraform-local

---

## Verified References

| Topic | Source |
|---|---|
| Account/auth token requirement (March 2026 change) | https://blog.localstack.cloud/the-road-ahead-for-localstack/ |
| 2026.03.0 release details, image consolidation | https://blog.localstack.cloud/localstack-for-aws-release-2026-03-0/ |
| Pricing tiers (Hobby/Base/Ultimate/Enterprise) | https://blog.localstack.cloud/2026-upcoming-pricing-changes/ |
| Auth token setup | https://docs.localstack.cloud/aws/getting-started/auth-token/ |
| Installation (CLI, Docker, Docker Compose) | https://docs.localstack.cloud/aws/getting-started/installation/ |
| Official docker-compose.yml reference | https://hub.docker.com/r/localstack/localstack |
| Quickstart guide | https://docs.localstack.cloud/aws/getting-started/quickstart/ |
| ARM64 / Apple Silicon support | https://docs.localstack.cloud/aws/capabilities/config/arm64-support/ |
| Persistence | https://docs.localstack.cloud/aws/developer-tools/snapshots/persistence/ |
| Cloud Pods | https://docs.localstack.cloud/aws/developer-tools/snapshots/cloud-pods/ |
| Terraform integration (tflocal) | https://docs.localstack.cloud/aws/integrations/infrastructure-as-code/terraform/ |
| terraform-local (tflocal) source | https://github.com/localstack/terraform-local |
| Service documentation index | https://docs.localstack.cloud/aws/services/ |
| Service availability by plan/tier | https://docs.localstack.cloud/aws/licensing/ |
