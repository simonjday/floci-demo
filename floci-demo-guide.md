# Floci Demo — M3 MacBook Walkthrough

> **Target:** MacBook Pro M3 (arm64 / Apple Silicon) running macOS with Docker Desktop
> **Floci version:** 1.5.26
> **Time to complete:** ~20 minutes (excluding Docker image pulls)
> **Sources:** https://floci.io/floci/ · https://github.com/floci-io/floci

**How to use this guide:** each step explains what's happening and tells you which script to run — it does not retype the commands inline. The `scripts/*.sh` files are the source of truth; this guide is the narration. If you ever see this guide and a script disagree, the script is right (open an issue on the repo, since that means this doc has drifted).

---

## Prerequisites

```bash
# Verify Docker Desktop is running and arm64 is available
docker info | grep -E "Architecture|Server Version"

# Verify AWS CLI v2 is installed
aws --version   # aws-cli/2.x

# Optional: install the Floci CLI (wraps container lifecycle + env export)
# Homebrew tap is floci-io/homebrew-floci — installed as floci-io/floci/floci,
# NOT floci-io/tap (that tap does not exist)
brew install floci-io/floci/floci

# Alternative: install script (no Homebrew dependency)
curl -fsSL https://floci.io/install.sh | sh
```

> This guide runs Floci via `docker compose`, so the CLI above is optional — skip it if you're not using `floci start`/`floci env`.

Docker Desktop on macOS does **not** require UFW firewall rules (that only applies to native Linux). The Docker VM handles host routing automatically.

> **zsh gotcha, unrelated to Floci:** interactive zsh doesn't treat `#` as a comment by default. It doesn't matter for this guide since you'll be running `bash scripts/*.sh` rather than pasting commands into your prompt — but if you ever do paste snippets from this doc directly into zsh, comment lines will error (`command not found: #`, or `unknown file attribute: i` from parentheses inside a comment being read as a glob qualifier). Fix once if you want: `echo "setopt interactivecomments" >> ~/.zshrc && source ~/.zshrc`.

---

## Repository layout the scripts expect

```
floci-demo/
├── compose.yaml
├── scripts/
│   ├── 00-setup.sh              # sourced by every other script
│   ├── 01-core-services.sh
│   ├── 02-eventbridge-pipeline.sh
│   ├── 03-step-functions.sh
│   ├── 04-multi-account.sh
│   ├── 05-rds-postgres.sh
│   ├── 06-ecr.sh
│   ├── 07-msk-kafka.sh
│   ├── 08-athena.sh
│   ├── 09-persistence.sh
│   ├── 10-terraform.sh
│   ├── 11-ecs.sh
│   └── 12-eks.sh
├── lambda/
│   └── order_processor/
│       └── handler.py           # required by 02-eventbridge-pipeline.sh
├── terraform/
│   └── main.tf                  # required by 10-terraform.sh
└── data/                        # gitignored, created by hybrid storage mode
```

`02-eventbridge-pipeline.sh` and `10-terraform.sh` both expect files at fixed relative paths (`../lambda/order_processor/handler.py` and `../terraform/main.tf` from the `scripts/` directory) — they don't create these for you. Steps 4 and 12 below create them.

---

## Step 1 — `compose.yaml`

```yaml
services:
  floci:
    image: floci/floci:latest          # native arm64 binary, ~90 MB
    platform: linux/arm64              # explicit for M3 — avoids Rosetta emulation
    ports:
      - "4566:4566"                    # single unified endpoint for all AWS API calls
      - "6379-6399:6379-6399"          # ElastiCache / Redis proxy ports
      - "7001-7099:7001-7099"          # RDS / PostgreSQL + MySQL proxy ports
      # ECR uses its own sidecar container bound to 5100-5199 by default —
      # do NOT add that range here, it will conflict with the sidecar (see Step 8)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # required for Lambda, RDS, MSK, ECS, EKS
      - ./data:/app/data               # persistent state survives container restarts
    environment:
      FLOCI_STORAGE_MODE: hybrid       # in-memory perf + 5s async flush to ./data
      FLOCI_HOSTNAME: floci            # ensures returned URLs resolve correctly inside compose
      FLOCI_DEFAULT_REGION: eu-west-1  # override from us-east-1 if preferred
    user: root                         # required for Docker socket access
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:4566/_localstack/health"]
      interval: 5s
      timeout: 3s
      retries: 10
```

---

## Step 2 — Start Floci and configure the shell

```bash
docker compose up -d
docker compose logs -f floci   # Ctrl-C once you see it's ready
```

Then, for every subsequent step, `source scripts/00-setup.sh` from the repo root instead of manually exporting variables — it sets `AWS_ENDPOINT_URL` / region / dummy credentials *and* blocks until Floci's health endpoint responds, so you never race the container startup:

```bash
source scripts/00-setup.sh
```

---

## Step 3 — Core services smoke test

```bash
bash scripts/01-core-services.sh
```

Covers S3 (upload/list/retrieve), SQS (standard queue with a DLQ + redrive policy, batch send, a FIFO queue with message groups), DynamoDB (table with a GSI, conditional update, GSI query), SSM Parameter Store (`String` + `SecureString` under a path hierarchy), and Secrets Manager (create, retrieve, rotate). All resource names are idempotent-safe to re-run except the DynamoDB table create, which will error on a second run if you haven't torn down first — that's expected, not a bug.

---

## Step 4 — EventBridge → SQS → Lambda → DynamoDB pipeline

This is the one step that needs a file you create yourself, since `02-eventbridge-pipeline.sh` expects `lambda/order_processor/handler.py` to already exist rather than writing it for you.

```bash
mkdir -p lambda/order_processor
```

Create `lambda/order_processor/handler.py`:

```python
import json
import os
import boto3

TABLE_NAME = os.environ.get("TABLE_NAME", "processed-orders")
ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")

dynamodb = boto3.resource("dynamodb", endpoint_url=ENDPOINT_URL)
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    records = event.get("Records", [])
    print(f"Received {len(records)} SQS records")

    processed = 0
    for record in records:
        body = json.loads(record["body"])
        order_id = body.get("orderId", "unknown")
        print(f"Processing order: {body}")

        table.put_item(Item={
            "orderId": order_id,
            "amount": str(body.get("amount", "0")),
            "customerId": body.get("customerId", "unknown"),
        })
        processed += 1

    return {"statusCode": 200, "processed": processed}
```

> This handler is my own inferred implementation, not something published by Floci — it's written to match what `02-eventbridge-pipeline.sh` sets up (a `processed-orders` DynamoDB table, `TABLE_NAME`/`AWS_ENDPOINT_URL` passed as Lambda environment variables) but isn't verified against an official example. Adjust freely; the script only cares that the zip contains a `handler.py` with a `lambda_handler` entry point.

Then run the pipeline:

```bash
bash scripts/02-eventbridge-pipeline.sh
```

This creates the `processed-orders` table, an `order-events` SQS queue, packages and deploys the Lambda (real Docker container — first invocation pulls the Python 3.12 runtime image and can take 10–30s), does a direct `invoke` smoke test, wires an SQS→Lambda event source mapping, creates a `commerce` EventBridge bus with a rule routing `OrderPlaced` events to the queue, and fires two test events end-to-end.

The direct-invoke call already has `--cli-binary-format raw-in-base64-out` set — without it, AWS CLI v2 treats the `--payload` JSON as pre-base64-encoded and the Lambda runtime fails with `Runtime.UnmarshalError`. This isn't Floci-specific; it's standard AWS CLI v2 behavior and will bite you the same way against real AWS.

---

## Step 5 — Step Functions

```bash
bash scripts/03-step-functions.sh
```

Creates an `order-workflow` state machine (Pass/Choice/Fail states modeling validate → check inventory → process payment → update inventory → notify, with a rejection branch for zero-amount orders), runs a happy-path execution and polls it to completion, runs a failure-path execution, and lists execution history.

---

## Step 6 — Multi-account isolation

```bash
bash scripts/04-multi-account.sh
```

Demonstrates Floci's account isolation: if `AWS_ACCESS_KEY_ID` is exactly 12 digits, Floci treats it as the account ID, and resources created under one 12-digit key are invisible to another — even with identical names. The script creates same-named SQS queues and DynamoDB tables under two different fake account IDs and verifies each only sees its own.

---

## Step 7 — RDS PostgreSQL (real Docker backend)

```bash
bash scripts/05-rds-postgres.sh
```

Starts a real `postgres:16-alpine` container, waits for `available` status, then reads the port back from `describe-db-instances` rather than assuming a fixed one — correct, since the port comes from the `7001-7099` range mapped in `compose.yaml` and isn't predictable in advance. **It does not connect using the `Address` field from that same response** — Floci's reported `Address` is the container's internal Docker network IP (e.g. `172.18.0.x`), which isn't reachable from the host on Docker Desktop. The script connects to `localhost` on the reported port instead, which works because `compose.yaml`'s port range maps straight through. It also sets `PGGSSENCMODE=disable` before connecting — modern `libpq` (including Homebrew's) defaults to probing GSSAPI encryption support before the real startup packet, and Floci's Postgres protocol handler doesn't recognize that preamble; without disabling it, `psql` fails with `server closed the connection unexpectedly` even once the port itself is reachable. If `psql` is installed (`brew install libpq && brew link --force libpq`), it connects and runs a real `CREATE TABLE` / `INSERT` / `SELECT` against the actual Postgres engine.

---

## Step 8 — ECR push/pull (real OCI registry)

```bash
bash scripts/06-ecr.sh
```

Floci backs ECR with a real `registry:2` container on its own sidecar port (default `5100`, range `5100-5199` — this is why Step 1's `compose.yaml` explicitly avoids remapping that range). The script creates a repository, authenticates Docker against the emulated registry, pushes and pulls `alpine:3.19` under two tags, and lists/describes images via the AWS CLI to confirm the control-plane and the real registry agree.

---

## Step 9 — MSK (Kafka via Redpanda)

```bash
bash scripts/07-msk-kafka.sh
```

Starts a real `redpandadata/redpanda` container behind the MSK API. The script calls `aws kafka get-bootstrap-brokers`, but the returned address is informational only — it's the broker container's internal Docker network IP, and unlike RDS/ElastiCache, Floci does not publish any host port for Kafka at all (confirmed via `docker ps`: the container shows `9092/tcp` with no `0.0.0.0:` binding, and no such range appears in Floci's own documented `compose.yaml` reference either). A host-installed `kcat` therefore cannot reach the broker under any host/port combination. Instead, the script finds the running `redpandadata/redpanda` container by image, and uses `rpk` — Redpanda's own CLI, already present inside that container — via `docker exec` to produce and consume test messages. This also sidesteps `kcat`'s Docker Hub image being amd64-only, which would otherwise run under Rosetta emulation on an M3.

---

## Step 10 — Athena over S3 (real SQL via DuckDB)

```bash
bash scripts/08-athena.sh
```

Uploads a small sales CSV to S3, registers it as a Glue table, then runs four real Athena queries (revenue by product, revenue by region, monthly trend, top product per region) — actually executed by Floci's DuckDB sidecar against the S3 data, not mocked. Polls each query to completion and prints results as tables. The monthly trend query casts its `DATE` column to `VARCHAR` explicitly before calling `SUBSTR` — real Athena's Presto/Trino engine implicitly casts `DATE` for string functions, DuckDB does not, so the uncast version fails with a `Binder Error`. This is a genuine SQL-dialect fidelity gap between Floci's DuckDB-backed Athena and real Athena, not a bug in this repo — worth knowing if you write your own Athena queries against Floci.

---

## Step 11 — Persistence across restarts

```bash
bash scripts/09-persistence.sh
```

Writes state to S3, DynamoDB, SQS, and SSM, waits 6 seconds (hybrid mode's async flush interval is 5s), restarts the Floci container with `docker compose restart floci`, waits for the health check to pass again, then re-reads everything to confirm it survived. Also prints a quick reference for the four storage modes (`memory`, `hybrid`, `persistent`, `wal`) — set via `FLOCI_STORAGE_MODE` in `compose.yaml`.

---

## Step 12 — Terraform IaC smoke test

Like Step 4, this needs a file `10-terraform.sh` expects but doesn't create.

```bash
mkdir -p terraform
```

Create `terraform/main.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  endpoints {
    s3       = "http://localhost:4566"
    sqs      = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
  }
}

resource "aws_s3_bucket" "demo" {
  bucket = "tf-demo-bucket"
}

resource "aws_sqs_queue" "demo" {
  name = "tf-demo-queue"
}

resource "aws_dynamodb_table" "demo" {
  name         = "tf-demo-table"
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "id"
    type = "S"
  }

  hash_key = "id"
}
```

Resource names must contain `tf-demo` — the script verifies success with `grep tf-demo` against `aws s3 ls`, `aws sqs list-queues`, and `aws dynamodb list-tables`.

```bash
bash scripts/10-terraform.sh
```

Runs `terraform init` → `plan` → `apply`, verifies all three resources exist via the AWS CLI, lists Terraform state, then `terraform destroy`s and confirms removal. Requires `terraform >= 1.10` (`brew install terraform`). Note: I could not find a documented, specific count of "Terraform compatibility tests" that Floci passes — if you see that claim elsewhere (including in an earlier version of this repo's scripts), treat it as unverified and check floci.io for current compatibility claims.

---

## Step 13 — ECS (real Docker task)

```bash
bash scripts/11-ecs.sh
```

Registers a task definition for `nginx:alpine` in `bridge` network mode with `containerPort: 80` mapped to `hostPort: 8081`, creates a cluster, then `run-task`s it — Floci launches an actual Docker container for the task, not a mock. The script polls `describe-tasks` until `lastStatus` reaches `RUNNING`, then curls `http://localhost:8081` to confirm the real nginx container is serving traffic. The task and cluster are left running afterward; the script prints manual `stop-task`/`delete-cluster` commands if you want to clean up.

---

## Step 14 — EKS (real k3s cluster)

```bash
bash scripts/12-eks.sh
```

Creates a real k3s cluster via `create-cluster` and waits for `ACTIVE` status — a genuine `rancher/k3s` container comes up, not a mock control plane.

**Known limitation, not a bug in this repo:** as of this writing, Floci's EKS "real mode" has a confirmed, open upstream issue — [floci-io/floci#1118](https://github.com/floci-io/floci/issues/1118). `describe-cluster` returns a Docker-network-only endpoint that isn't host-reachable, and even hitting the k3s API server directly on its host-published port (`6500-6599` range) returns `401 Unauthorized` — the AWS-shaped API never surfaces usable client credentials, only the CA certificate. `12-eks.sh` works around both problems using the same approach documented in that issue: it finds the running `rancher/k3s` container by image, reads its host-published port via `docker port`, then uses `docker exec` to pull the real admin kubeconfig straight out of `/etc/rancher/k3s/k3s.yaml` inside the container and rewrites its `server:` address to the host-reachable port. This is a community workaround for a known bug, not officially supported Floci behavior — if a future release ships something like `floci eks kubeconfig <name>`, prefer that instead.

If `kubectl` is installed (`brew install kubectl`), the script verifies the workaround with `kubectl get nodes`, deploys an `nginx:alpine` pod, waits for it to become `Ready`, and prints `kubectl get pods,svc`.

### Connecting your own kubectl to the cluster

The script extracts a working kubeconfig to `/tmp/floci-eks-demo-eks-kubeconfig.yaml`. Your Mac's own `kubectl` (not a containerized one) can use it directly, no manual cert handling needed:

```bash
export KUBECONFIG=/tmp/floci-eks-demo-eks-kubeconfig.yaml
kubectl get nodes
kubectl get pods,svc
```

That `export` only applies to the current shell. To persist it, merge it into your default kubeconfig as an additional context:

```bash
KUBECONFIG=~/.kube/config:/tmp/floci-eks-demo-eks-kubeconfig.yaml \
  kubectl config view --flatten > /tmp/merged-kubeconfig.yaml
mv /tmp/merged-kubeconfig.yaml ~/.kube/config
kubectl config get-contexts   # confirm the floci-eks context is there
kubectl config use-context <floci-eks-context-name>
```

Or simply keep the `export` in your shell profile if this cluster is only for demo purposes.

**Stale port caveat:** the k3s container's host port is assigned per-container from the `6500-6599` range. If the container is ever recreated (`docker compose down/up`, `--force-recreate`, or a restart), it can come back on a *different* port, and the previously extracted kubeconfig will point at a stale one. A connection error (as opposed to a `401`) from `kubectl get nodes` is the signal — re-run `bash scripts/12-eks.sh` to re-extract a fresh kubeconfig against the current port.

The cluster is left running afterward; the script prints a manual `delete-cluster` command if you want to clean up.

---

## Teardown

For a full reset (stops Floci, wipes `./data`, clears any leftover Terraform state):

```bash
bash scripts/99-cleanup.sh
```

Or manually:

```bash
docker compose down

# To also wipe persisted state
rm -rf ./data
```

**Note on re-running individual scripts without a full reset:** because `compose.yaml` runs `FLOCI_STORAGE_MODE=hybrid`, state persists across runs, not just across restarts. `01-core-services.sh` and the other numbered scripts guard their `create-*` calls with `2>/dev/null || echo "(already exists)"` so re-running them is safe — but a couple of things are *intentionally* not idempotent (the conditional DynamoDB update in Step 3 only fires once; re-running Step 3 after that will correctly report the condition check as already satisfied rather than erroring).

---

## Troubleshooting on macOS / M3

| Symptom | Cause | Fix |
|---|---|---|
| Image not found / wrong arch | arm64 not specified | Add `platform: linux/arm64` to compose |
| Lambda timeout | Docker socket not mounted | Add `-v /var/run/docker.sock:/var/run/docker.sock` and `user: root` |
| RDS/ElastiCache port unreachable | Port ranges not mapped | Add `"6379-6399:6379-6399"` (ElastiCache) and `"7001-7099:7001-7099"` (RDS) to ports |
| `Runtime.UnmarshalError` on Lambda invoke | AWS CLI v2 payload encoding | Add `--cli-binary-format raw-in-base64-out` to the invoke command |
| ECR push auth failure | Registry container not up yet | Wait ~5s after `create-repository` |
| `curl: connection refused` | Container still starting | Wait for healthcheck to pass, or `source scripts/00-setup.sh` which blocks on it automatically |
| `02-eventbridge-pipeline.sh` fails to zip | `lambda/order_processor/handler.py` missing | Create it per Step 4 above — the script doesn't generate it |
| `10-terraform.sh` fails at `cd "${TF_DIR}"` | `terraform/main.tf` missing | Create it per Step 12 above — the script doesn't generate it |
| Script hangs at a `(END)` / `less` prompt | AWS CLI v2 pipes output through a pager whenever stdout is a TTY | Press `q` to unstick it now; `00-setup.sh` sets `AWS_PAGER=""` so this shouldn't recur once you re-source it |
| `psql` connection refused / hangs against RDS | `describe-db-instances` reports the container's internal Docker IP (`172.18.0.x`), not a host-reachable address | Connect via `localhost` on the reported port instead — `05-rds-postgres.sh` already does this |
| `psql: server closed the connection unexpectedly` against RDS, with broker/proxy logs showing `Unexpected PostgreSQL startup protocol version: 80,877,104` | Floci's Postgres protocol handler doesn't support the GSSENCRequest preamble modern `libpq` sends by default | `export PGGSSENCMODE=disable` before connecting — `05-rds-postgres.sh` already does this |
| `kcat: ... Connection setup timed out` / `All broker connections are down` against MSK | Floci doesn't publish a host port for the Kafka broker at all (confirmed via `docker ps` — no `0.0.0.0:` binding, unlike RDS/ElastiCache) | Not fixable via `localhost`. `07-msk-kafka.sh` uses `rpk` via `docker exec` directly inside the broker container instead |
| `Binder Error: No function matches ... substr(DATE, ...)` from Athena | Real fidelity gap: Athena's Presto/Trino engine implicitly casts `DATE` for string functions; Floci's DuckDB-backed Athena doesn't | Cast explicitly: `SUBSTR(CAST(date AS VARCHAR), 1, 7)` — `08-athena.sh` already does this |
| `kubectl` gets `401 Unauthorized` or can't reach the EKS cluster | Confirmed open upstream bug — [floci-io/floci#1118](https://github.com/floci-io/floci/issues/1118): the AWS-shaped API doesn't surface a host-reachable endpoint or usable client credentials for real-mode EKS clusters | Not a bug in this repo. `12-eks.sh` works around it via `docker exec` to extract the real admin kubeconfig directly from the k3s container |

---

## References

- Floci documentation: https://floci.io/floci/
- Floci quick start: https://floci.io/floci/getting-started/quick-start/
- Floci GitHub: https://github.com/floci-io/floci
- Floci services: https://floci.io/floci/services/
- Floci storage modes: https://floci.io/floci/configuration/storage/
- Floci multi-account: https://floci.io/floci/configuration/multi-account/
- Floci EKS real-mode kubeconfig/auth issue (workaround used in Step 14): https://github.com/floci-io/floci/issues/1118
