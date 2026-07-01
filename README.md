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
| `11-ecs.sh` | ECS | Real Docker task |
| `12-eks.sh` | EKS | Real k3s cluster |

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Docker Desktop | 4.x+ | Apple Silicon: enable VirtioFS in settings |
| AWS CLI | v2 | `brew install awscli` |
| Terraform | 1.10+ | Optional — only for script 10 |
| psql | Any | Optional — only for script 05 |
| kubectl | Any | Optional — only for script 12's EKS verification |

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

## Connecting kubectl to the EKS demo cluster

`12-eks.sh` extracts a working kubeconfig to `/tmp/floci-eks-demo-eks-kubeconfig.yaml`, already pointed at the k3s container's host-published port — no manual cert wrangling needed. Your Mac's own `kubectl` (not a containerized one) can use it directly:

```bash
export KUBECONFIG=/tmp/floci-eks-demo-eks-kubeconfig.yaml
kubectl get nodes
kubectl get pods,svc
```

That export only applies to the current shell. To make it persistent:

**Merge it into your default kubeconfig** (adds it as a context alongside your other clusters, so plain `kubectl` works without exporting anything):
```bash
KUBECONFIG=~/.kube/config:/tmp/floci-eks-demo-eks-kubeconfig.yaml \
  kubectl config view --flatten > /tmp/merged-kubeconfig.yaml
mv /tmp/merged-kubeconfig.yaml ~/.kube/config
kubectl config get-contexts   # confirm the floci-eks context is there
kubectl config use-context <floci-eks-context-name>
```

**Or** just keep the `export` in your shell profile if you're only using this cluster for the demo.

**Stale port caveat:** the k3s container's host port (from the `6500-6599` range) is assigned per-container. If it's ever recreated — `docker compose down/up`, `--force-recreate`, or a restart — it may come back on a *different* port, and the extracted kubeconfig will point at a stale one. If `kubectl get nodes` starts failing with a connection error (rather than `401`), that's almost certainly why — just re-run `bash scripts/12-eks.sh`, which re-extracts a fresh kubeconfig against the current port.

---

## Architecture

```
compose.yaml
└── floci/floci:latest (arm64 native binary, ~90 MB)
    ├── :4566   → all 65 AWS service endpoints
    ├── :4510-4520 → Lambda / misc direct ports
    ├── :6379-6399 → ElastiCache / Redis proxy ports
    └── :7001-7099 → RDS / PostgreSQL + MySQL proxy ports

In-process services (fast, no Docker child):
  SQS · SNS · S3 · DynamoDB · Kinesis · SSM · Secrets Manager
  IAM · STS · KMS · Cognito · EventBridge · Step Functions
  CloudWatch · API Gateway · AppSync · Route53 · ACM · ELB v2
  CloudFormation · CodeDeploy · CodePipeline · and more

Real Docker containers (high-fidelity):
  Lambda    → public.ecr.aws/lambda/<runtime>
  RDS       → postgres:16-alpine / mysql:8.0 / mariadb:11
  MSK       → redpandadata/redpanda:latest  (Docker-network-only — no host port, see Troubleshooting)
  ElastiCache → valkey/valkey:8
  Neptune   → tinkerpop/gremlin-server:3.7.3
  DocumentDB → mongo:7.0
  ECS/EC2   → user-specified images
  EKS       → rancher/k3s:latest
  OpenSearch → opensearchproject/opensearch:2
  CodeBuild → user environment image
  ECR       → registry:2  (self-publishes its own host port, e.g. 5100)

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

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `psql: connection to server at "localhost" ... Connection refused` on script 05 | `6379-6399` / `7001-7099` port ranges missing from `compose.yaml`'s `floci` service | Add both ranges (see `compose.yaml` in this repo), then `docker compose up -d --force-recreate floci` |
| `psql: server closed the connection unexpectedly` on script 05, with `docker logs floci-demo-floci-1` showing `Unexpected PostgreSQL startup protocol version: 80,877,104` | Floci's Postgres protocol handler doesn't support the GSSENCRequest preamble modern `libpq` (e.g. Homebrew's) sends by default before the real startup packet | `export PGGSSENCMODE=disable` before connecting — already set in `05-rds-postgres.sh` |
| `describe-db-instances` reports an `Address` like `172.18.0.2` | That's the backing container's internal Docker network IP, not host-reachable | Always connect via `localhost:<reported-port>`, never the `Address` field — `05-rds-postgres.sh` does this automatically |
| `kcat: ... Connection setup timed out` / `All broker connections are down` on script 07 | Floci doesn't publish a host port for the Kafka broker (confirmed via `docker ps` — no `0.0.0.0:` binding on the Redpanda container, unlike RDS/ElastiCache) | Not fixable via `localhost`. `07-msk-kafka.sh` now uses `rpk` (Redpanda's own CLI) via `docker exec` directly inside the broker container — no host client needed, and it avoids the amd64-only `kcat` Docker image running under Rosetta emulation on Apple Silicon |
| `Binder Error: No function matches ... substr(DATE, ...)` on script 08 | Real fidelity gap, not a Floci bug: Athena's Presto/Trino engine implicitly casts `DATE` for string functions like `SUBSTR`; Floci's DuckDB-backed Athena doesn't | Cast explicitly: `SUBSTR(CAST(date AS VARCHAR), 1, 7)` — valid in both engines |
| `kubectl` gets `401 Unauthorized` or can't reach the EKS cluster on script 12 | Confirmed open upstream bug in Floci — [issue #1118](https://github.com/floci-io/floci/issues/1118): the AWS-shaped API doesn't surface a host-reachable endpoint or usable client credentials for real-mode EKS clusters | Not a bug in this repo. `12-eks.sh` already works around it via `docker exec` to extract the real admin kubeconfig from the k3s container directly — no action needed unless that workaround itself fails, in which case check `docker ps` for the `rancher/k3s` container manually |
| Script hangs at a `(END)` / `less` prompt | AWS CLI v2 pipes output through a pager whenever stdout is a TTY | Press `q` to unstick it; `00-setup.sh` sets `AWS_PAGER=""` so re-sourcing it prevents recurrence |

---

## License

MIT. See [LICENSE](LICENSE).
