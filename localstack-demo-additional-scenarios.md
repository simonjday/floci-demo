# LocalStack — Additional Demo Scenarios

> Supplement to `localstack-demo-guide.md`. These scenarios go beyond the core
> service smoke tests and exercise LocalStack's higher-fidelity Docker-backed
> emulation — EC2, RDS, API Gateway, and IAM.  
> **Last verified:** June 2026

---

## Scenario A — EC2 (Real Docker-Backed Instances)

LocalStack's Docker VM manager backs each EC2 instance with a real Docker container — you can actually SSH into it. This is the default VM manager and requires the Docker socket mounted (already configured in `docker-compose.yml`, Step 4 of the main guide).

### A1 — Prepare a "mock AMI"

LocalStack treats specially-tagged Docker images as AMIs. AWS provides no API to download real AMIs, so you build a local image and tag it using LocalStack's naming convention.

```bash
docker pull ubuntu:focal
docker tag ubuntu:focal localstack-ec2/ubuntu-focal-docker-ami:ami-00a001
```

### A2 — Create a security group rule

```bash
SG_ID=$(awslocal ec2 describe-security-groups \
  --query 'SecurityGroups[0].GroupId' --output text)

awslocal ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 8000 \
  --cidr 0.0.0.0/0
```

### A3 — Generate an SSH key pair and launch the instance

```bash
awslocal ec2 create-key-pair --key-name my-key \
  --query 'KeyMaterial' --output text > my-key.pem
chmod 400 my-key.pem

cat > user_script.sh << 'EOF'
#!/bin/bash
apt-get update -y
apt-get install -y python3
cd /tmp && python3 -m http.server 8000 &
EOF

awslocal ec2 run-instances \
  --image-id ami-00a001 \
  --instance-type t3.micro \
  --key-name my-key \
  --security-group-ids "$SG_ID" \
  --user-data file://user_script.sh
```

### A4 — Confirm the backing Docker container

```bash
docker ps | grep localstack-ec2
```

You should see a container named `localstack-ec2.<InstanceId>` — confirming this is a real container, not a stub response.

### A5 — SSH into the instance

Find the mapped SSH port from the LocalStack logs (`localstack logs` or `docker compose logs -f localstack`) — it will report something like `Instance i-xxxx will be accessible via SSH at: 127.0.0.1:<port>`.

```bash
ssh -i my-key.pem -p <port> root@127.0.0.1
```

### Known limitations (verified from LocalStack docs)

- Only the default security group is currently supported
- AWS does not provide an API to download real AMIs — you must build your own via `docker tag`, or use Packer with the Docker builder against the Amazon Linux Docker base image
- The Docker VM manager does not fully support persistence — resource records persist, but the instances/AMIs themselves (Docker containers/images) do not survive a restart
- All standard container limitations apply (root access restrictions, networking constraints)

Source: https://docs.localstack.cloud/aws/services/ec2/

---

## Scenario B — RDS with a Real PostgreSQL Engine

When you create an RDS instance with the `postgres` or `aurora-postgresql` engine, LocalStack dynamically installs and runs the actual PostgreSQL version inside Docker — not a stub.

```bash
awslocal rds create-db-instance \
  --db-instance-identifier demo-postgres \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version "17" \
  --master-username admin \
  --master-user-password password123 \
  --allocated-storage 20

awslocal rds wait db-instance-available \
  --db-instance-identifier demo-postgres

awslocal rds describe-db-instances \
  --db-instance-identifier demo-postgres \
  --query 'DBInstances[0].Endpoint'
```

Connect with `psql` using the endpoint and port reported above:

```bash
PGPASSWORD=password123 psql -h localhost -p <port> -U admin -d test
```

### Notes verified from LocalStack docs

- Supported PostgreSQL major versions: 13–17 (versions below 13 are no longer available since LocalStack moved to a Debian sid base image)
- Minor version selection is not available — the latest minor of the chosen major is installed
- Default master username/password if unspecified: both default to `test` (the username `postgres` is reserved and cannot be used)
- MySQL engine: a real MySQL server launches in its own Docker container
- MariaDB engine: installed as an OS package within the LocalStack container (no version selection, no snapshot support)
- MSSQL engine: real server in a fresh container; default password `Test123!`; no snapshot support
- RDS Data API is also supported for serverless-style query execution

### Caveat — port persistence

LocalStack reserves the external port range (4510–4559 by default) at container startup. If you restart with `PERSISTENCE=1` and recreate services in a different order than originally deployed, restored resources may end up pointing at the wrong port. Restore services in the same order they were originally created where possible.

Sources:
- https://docs.localstack.cloud/aws/services/rds/
- https://discuss.localstack.cloud/t/port-settings-ignored-for-rds-instances/61

---

## Scenario C — API Gateway REST API → Lambda

```bash
# Create the REST API
API_ID=$(awslocal apigateway create-rest-api \
  --name demo-api \
  --query 'id' --output text)

ROOT_ID=$(awslocal apigateway get-resources \
  --rest-api-id "$API_ID" \
  --query 'items[0].id' --output text)

# Create a /orders resource
RESOURCE_ID=$(awslocal apigateway create-resource \
  --rest-api-id "$API_ID" \
  --parent-id "$ROOT_ID" \
  --path-part orders \
  --query 'id' --output text)

# GET method
awslocal apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method GET \
  --authorization-type NONE

# Integrate with the Lambda created in the main guide (Step 8)
LAMBDA_ARN=$(awslocal lambda get-function \
  --function-name order-processor \
  --query 'Configuration.FunctionArn' --output text)

awslocal apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

# Deploy
awslocal apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name dev

# Invoke
curl "http://localhost:4566/restapis/${API_ID}/dev/_user_request_/orders"
```

Source: https://docs.localstack.cloud/aws/services/apigateway/

---

## Scenario D — IAM Policy Testing

As of the 2026.03.0 release, LocalStack's IAM and STS implementation was migrated from the Moto library to LocalStack's own core library — improving fidelity for policy evaluation testing.

```bash
# Create a role
awslocal iam create-role \
  --role-name demo-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach a restrictive inline policy
awslocal iam put-role-policy \
  --role-name demo-role \
  --policy-name s3-read-only \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::localstack-demo-bucket", "arn:aws:s3:::localstack-demo-bucket/*"]
    }]
  }'

# Verify
awslocal iam get-role-policy \
  --role-name demo-role \
  --policy-name s3-read-only
```

For deeper IAM policy debugging, LocalStack's paid tiers offer **Explainable IAM** and **IAM Policy Enforcement** — these go beyond basic CRUD and actually evaluate whether a given action would be allowed or denied, which is useful for testing least-privilege policies before deploying to real AWS.

Sources:
- https://blog.localstack.cloud/localstack-for-aws-release-2026-05-0/ (IAM/STS migration to native library)
- https://docs.localstack.cloud/aws/developer-tools/security-testing/explainable-iam/
- https://docs.localstack.cloud/aws/developer-tools/security-testing/iam-policy-enforcement/

---

## Scenario E — EC2 Fleet (Real Infrastructure, not Mocked)

As of the 2026.03.0 release, `CreateFleet`/`DeleteFleets` trigger real Docker containers rather than returning mock responses.

```bash
cat > /tmp/launch-template-data.json << 'EOF'
{
  "ImageId": "ami-00a001",
  "InstanceType": "t3.micro"
}
EOF

awslocal ec2 create-launch-template \
  --launch-template-name demo-template \
  --launch-template-data file:///tmp/launch-template-data.json

awslocal ec2 create-fleet \
  --launch-template-configs '[{
    "LaunchTemplateSpecification": {
      "LaunchTemplateName": "demo-template",
      "Version": "$Latest"
    }
  }]' \
  --target-capacity-specification '{
    "TotalTargetCapacity": 2,
    "DefaultTargetCapacityType": "on-demand"
  }' \
  --type instant

# Confirm real containers were spawned
docker ps | grep localstack-ec2
```

Both On-Demand and Spot fleet types are supported, including mixed fleets. `DeleteFleets` with `TerminateInstances=true` properly stops and removes the underlying containers with no orphaned resources.

Source: https://blog.localstack.cloud/localstack-for-aws-release-2026-03-0/

---

## Scenario F — Self-Managed EC2 Nodes Joining an Emulated EKS Cluster

This is a newer capability (2026.05.0 release) worth evaluating if your work touches Kubernetes node provisioning patterns like Karpenter. EC2 instances launched with a `NodeConfig` in their user data on the AmazonLinux2023 AMI family can join a matching emulated EKS cluster as worker nodes.

Supported `NodeConfig` fields: `clusterDNS`, `maxPods`, `evictionHard`, `registerWithTaints`, `nodeLabels`.

This is an early-stage feature — Karpenter coverage has not been validated across all Karpenter versions, and Bottlerocket AMIs are not yet in scope. Worth a brief evaluation pass rather than a deep dive, given its maturity level.

Source: https://blog.localstack.cloud/localstack-for-aws-release-2026-05-0/

---

## Summary: What These Scenarios Demonstrate

| Scenario | What it proves | Fidelity level |
|---|---|---|
| EC2 instance + SSH | Real Docker container backing, not a stub | High — genuinely SSH-able |
| EC2 Fleet | Real infrastructure spawned, not mocked | High — confirmed via `docker ps` |
| RDS PostgreSQL | Real dynamically-installed PostgreSQL engine | High — real `psql` connection |
| API Gateway → Lambda | Full request routing through a real proxy integration | High |
| IAM policy | Native (non-Moto) policy storage and evaluation since 2026.03.0 | Medium-High |
| EC2 nodes joining EKS | Early-stage Karpenter-style node provisioning | Early / experimental |

These are good candidates to include in a Medium write-up specifically because they go beyond "does the API respond" and into "does the underlying behaviour match real AWS closely enough to trust for testing."

---

## Verified References

| Topic | Source |
|---|---|
| EC2 Docker VM manager, AMI tagging convention, SSH access | https://docs.localstack.cloud/aws/services/ec2/ |
| EC2 instance walkthrough (community vs Pro mock/Docker distinction) | https://hashnode.localstack.cloud/running-an-ec2-instance-locally-using-localstack-and-aws-cli |
| RDS real PostgreSQL/MySQL/MariaDB/MSSQL engines, version support | https://docs.localstack.cloud/aws/services/rds/ |
| RDS port allocation limitation | https://discuss.localstack.cloud/t/port-settings-ignored-for-rds-instances/61 |
| RDS with CDK initialization tutorial | https://docs.localstack.cloud/aws/tutorials/rds-database-initialization/ |
| API Gateway service docs | https://docs.localstack.cloud/aws/services/apigateway/ |
| IAM/STS native library migration (2026.03.0) | https://blog.localstack.cloud/localstack-for-aws-release-2026-03-0/ |
| Explainable IAM | https://docs.localstack.cloud/aws/developer-tools/security-testing/explainable-iam/ |
| IAM Policy Enforcement | https://docs.localstack.cloud/aws/developer-tools/security-testing/iam-policy-enforcement/ |
| EC2 Fleet real infrastructure (2026.03.0) | https://blog.localstack.cloud/localstack-for-aws-release-2026-03-0/ |
| Self-managed EC2 nodes joining EKS (2026.05.0) | https://blog.localstack.cloud/localstack-for-aws-release-2026-05-0/ |
| Persistence internals and known limitations | https://docs.localstack.cloud/aws/capabilities/state-management/persistence/ |
