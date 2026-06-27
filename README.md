# floci-demo

> Runnable demo scripts for [Floci](https://floci.io/floci/) — the free, MIT-licensed, open-source local AWS emulator.  
> Covers 12 AWS service patterns on a single `docker compose up`.

[![Floci](https://img.shields.io/badge/floci-1.5.26-blue)](https://github.com/floci-io/floci/releases/tag/1.5.26)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![CI](https://github.com/YOUR_GITHUB_USERNAME/floci-demo/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_GITHUB_USERNAME/floci-demo/actions/workflows/ci.yml)

---

## What This Repo Demonstrates

| Script | Services | Pattern |
|---|---|---|
| `01-core-services.sh` | S3, SQS, DynamoDB, SSM, Secrets Manager | CRUD smoke tests |
| `02-eventbridge-pipeline.sh` | EventBridge, SQS, Lambda, DynamoDB | Event-driven order pipeline |
| `03-step-functions.sh` | Step Functions | ASL state machine execution |
| `04-multi-account.sh` | SQS | Per-account resource isolation |
| `05-rds-postgres.sh` | RDS (PostgreSQL 16) | Real Docker DB, IAM auth |
| `06-ecr.sh` | ECR | OCI push/pull with real registry |
| `07-msk-kafka.sh` | MSK (Redpanda) | Kafka-compatible broker |
| `08-athena.sh` | Athena, Glue, S3 | Real SQL via DuckDB sidecar |
| `09-persistence.sh` | All stateful services | State survival across restarts |
| `10-terraform.sh` | S3, SQS, DynamoDB | IaC provider override |

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Docker Desktop | 4.x+ | Apple Silicon: enable VirtioFS in settings |
| AWS CLI | v2 | `brew install awscli` |
| Terraform | 1.10+ | Optional — only for script 10 |
| psql | Any | Optional — only for script 05 |

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/simonjday/floci-demo.git
cd floci-demo

# 2. Start Floci
docker compose up -d

# 3. Configure AWS CLI (no real credentials needed)
source scripts/00-setup.sh

# 4. Run any demo script
bash scripts/01-core-services.sh
bash scripts/02-eventbridge-pipeline.sh
# ... etc

# 5. Tear down
docker compose down
```

---

## Architecture

```
compose.yaml
└── floci/floci:latest (arm64 native binary, ~90 MB)
    ├── :4566   → all 65 AWS service endpoints
    └── :4510-4520 → RDS / ElastiCache / MSK direct ports

In-process services (fast, no Docker child):
  SQS · SNS · S3 · DynamoDB · Kinesis · SSM · Secrets Manager
  IAM · STS · KMS · Cognito · EventBridge · Step Functions
  CloudWatch · API Gateway · AppSync · Route53 · ACM · ELB v2
  CloudFormation · CodeDeploy · CodePipeline · and more

Real Docker containers (high-fidelity):
  Lambda    → public.ecr.aws/lambda/<runtime>
  RDS       → postgres:16-alpine / mysql:8.0 / mariadb:11
  MSK       → redpandadata/redpanda:latest
  ElastiCache → valkey/valkey:8
  Neptune   → tinkerpop/gremlin-server:3.7.3
  DocumentDB → mongo:7.0
  ECS/EC2   → user-specified images
  EKS       → rancher/k3s:latest
  OpenSearch → opensearchproject/opensearch:2
  CodeBuild → user environment image
  ECR       → registry:2

Sidecar:
  Athena + CUR → floci-duck (DuckDB) for real SQL execution
```

---

## Storage Mode

This repo uses `hybrid` mode by default — in-memory performance with state flushed to `./data` every 5 seconds.

```
./data/   ← gitignored, persisted state across container restarts
```

To change mode, edit `FLOCI_STORAGE_MODE` in `compose.yaml`:

| Mode | Description | Use case |
|---|---|---|
| `memory` | RAM only, lost on stop | CI / ephemeral tests |
| `hybrid` | In-memory + async 5s flush | Local dev (default here) |
| `persistent` | Immediate disk flush | Durability-first dev |
| `wal` | Write-ahead log | Maximum durability |

---

## CI

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs the core services and EventBridge pipeline scripts against Floci on every push. It uses the `memory` storage mode for speed and cleans up automatically.

---

## References

- Floci documentation: https://floci.io/floci/
- Floci GitHub: https://github.com/floci-io/floci
- Floci Docker Hub: https://hub.docker.com/r/floci/floci


---

## License

MIT. See [LICENSE](LICENSE).
