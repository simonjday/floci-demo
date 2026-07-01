# LocalStack — EKS Demo Scenario (Local Kubernetes Cluster)

> Supplement to `localstack-demo-guide.md` and `localstack-demo-additional-scenarios.md`.  
> **Tier requirement:** EKS is available from the **Ultimate** tier and above — confirmed via
> LocalStack's service availability table. It is **not** included in Hobby or Base.  
> **Last verified:** June 2026

---

## What LocalStack EKS Actually Does

LocalStack's EKS implementation spins up an embedded **k3d** (k3s-in-Docker) Kubernetes cluster, either by auto-provisioning one in your local Docker engine or by attaching to an existing cluster you already have access to (referenced via `$HOME/.kube/config`). This is a genuinely functional Kubernetes API server — `kubectl get nodes`, `kubectl apply`, and standard cluster operations work against it, not just CRUD-level mock responses.

Source: https://docs.localstack.cloud/aws/services/eks/

---

## Getting Ultimate Trial Access

EKS is gated behind the **Ultimate** tier — neither Hobby nor Base include it. If you don't already have an Ultimate subscription, LocalStack offers a free trial.

1. Go to https://www.localstack.cloud/pricing
2. Find the **Ultimate** plan (listed as "For teams building complex applications") and click **Start Free Trial**
3. This routes to `app.localstack.cloud/sign-up` — create your account
4. **No credit card is required to start** — confirmed directly on the pricing page (Ultimate's annual billing is explicitly listed as "credit card optional")
5. The trial runs for **45 days**, per LocalStack's own pricing announcement
6. Once signed up, retrieve your `LOCALSTACK_AUTH_TOKEN` from the Auth Token page in the LocalStack Web Application
7. Export it and start LocalStack as usual — your Ultimate entitlements (110+ services, including EKS) activate automatically based on the token, with no separate configuration needed:

```bash
export LOCALSTACK_AUTH_TOKEN="<your-trial-token>"
localstack start -d

# Confirm EKS is now available
curl -s http://localhost:4566/_localstack/health | jq '.services.eks'
```

What Ultimate includes beyond Base, relevant to this demo: 110+ emulated services, EKS, advanced IAM policy testing, the live AWS resource replicator, and a larger Cloud Pod storage allowance (3 GB vs Base's 300 MB per workspace).

> **Note:** the Hobby tier's free-forever offering is restricted to non-commercial use. The Ultimate trial does not carry that restriction, since it previews a paid commercial tier — but once the 45-day trial ends, continuing to use Ultimate features requires converting to a paid subscription.

Sources:
- https://www.localstack.cloud/pricing
- https://blog.localstack.cloud/2026-upcoming-pricing-changes/ (45-day trial confirmation)
- https://docs.localstack.cloud/aws/getting-started/auth-token/

---

## Prerequisites

```bash
# kubectl is required to interact with the cluster
brew install kubectl

# Confirm your LocalStack tier includes EKS (Ultimate or above)
curl -s http://localhost:4566/_localstack/health | jq '.services.eks'
```

If you're on Hobby or Base tier, `create-cluster` will fail with an error similar to:

```
An error occurred (InternalFailure) when calling the CreateCluster operation:
API for service 'eks' not yet implemented or pro feature
```

This has been a long-documented behaviour in LocalStack's GitHub issue tracker — confirm your tier before troubleshooting further.

Source: https://github.com/localstack/localstack/issues/11412

---

## Step 1 — Important: Check for a Pre-Existing `~/.kube/config`

If a `~/.kube/config` already exists on your machine and you're on a LocalStack CLI version before 3.7, it gets mounted automatically into the container — and LocalStack will assume you want to use a cluster referenced in that file, which has its own requirements. If you hit a `"status": "FAILED"` result with `Unable to start EKS cluster` in the logs, this is the most common cause.

```bash
# Back up your existing kube config before testing, just in case
cp ~/.kube/config ~/.kube/config.backup 2>/dev/null || true
```

Source: https://docs.localstack.cloud/aws/services/eks/

---

## Step 2 — Create the Cluster

```bash
awslocal eks create-cluster \
  --name demo-cluster \
  --role-arn "arn:aws:iam::000000000000:role/eks-role" \
  --resources-vpc-config "{}"
```

Cluster creation takes a few moments while LocalStack provisions the k3d components underneath. **Do not attempt to access the cluster until status is `ACTIVE`.**

```bash
awslocal eks wait cluster-active --name demo-cluster
```

---

## Step 3 — Verify the Backing Docker Containers

This is the real proof point — confirm k3d/k3s containers actually exist, not just an API response:

```bash
docker ps | grep k3d
```

Expected output resembles:

```
b335f7f0  rancher/k3d-proxy:5.0.1-rc.1   ...  k3d-demo-cluster-serverlb
f05770ec  rancher/k3s:v1.21.5-k3s2        ...  (server node)
```

> **Note:** the Traefik ingress controller and the default k3d load balancer are **no longer started automatically** as of a recent LocalStack release. If you need them, set the relevant configuration variable documented at https://docs.localstack.cloud/aws/services/eks/.

---

## Step 4 — Configure `kubectl`

```bash
awslocal eks update-kubeconfig --name demo-cluster

kubectl config use-context arn:aws:eks:us-east-1:000000000000:cluster/demo-cluster

kubectl cluster-info
kubectl get nodes
```

You should see the k3d control-plane node listed, in a `Ready` state — but **tainted**, meaning workloads can't yet be scheduled on it. This is by design: the server node alone is not a worker node.

---

## Step 5 — Add a Worker Node (Managed Node Group)

Without this step, the cluster exists but cannot run anything.

```bash
awslocal eks create-nodegroup \
  --cluster-name demo-cluster \
  --nodegroup-name demo-nodegroup \
  --subnets subnet-00000001 \
  --node-role arn:aws:iam::000000000000:role/eks-node-role \
  --scaling-config minSize=1,maxSize=1,desiredSize=1

awslocal eks wait nodegroup-active \
  --cluster-name demo-cluster \
  --nodegroup-name demo-nodegroup
```

When you create a managed node group, LocalStack automatically provisions a Docker container, joins it to the cluster, and provisions a mocked EC2 instance behind it.

```bash
kubectl get nodes
# You should now see two nodes: the (tainted) control plane and an untainted worker
```

Source: https://docs.localstack.cloud/aws/services/eks/

---

## Step 6 — Deploy a Workload

```bash
kubectl create deployment hello-world --image=nginx:alpine
kubectl expose deployment hello-world --port=80 --type=ClusterIP

kubectl get pods -o wide
kubectl get svc hello-world
```

If this schedules and reaches `Running` status, you have a functioning local Kubernetes deployment — backed by a real k3s API server, not a stub.

---

## Step 7 — Using ECR Images Inside the Cluster

LocalStack's emulated ECR (from earlier in your evaluation) can be referenced directly from workloads running inside the EKS cluster.

```bash
# Tag and push an image to LocalStack's ECR (from your earlier ECR testing)
awslocal ecr create-repository --repository-name demo/app

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
      000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4510

docker tag nginx:alpine \
  000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4510/demo/app:v1
docker push \
  000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4510/demo/app:v1

# Reference it in a deployment manifest pointing at that ECR URI
kubectl create deployment demo-app \
  --image=000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4510/demo/app:v1
```

> If image pulls inside the cluster fail to resolve the registry hostname, check the `LOCALSTACK_HOST` configuration variable — it controls how resource URIs (including ECR) are returned, and may need adjusting depending on your network setup.

Source: https://docs.localstack.cloud/aws/services/eks/

---

## Alternative: `eksctl` Support (Experimental)

LocalStack also supports creating clusters via `eksctl` rather than raw `awslocal eks` calls. As of the verified documentation, **this integration is explicitly marked experimental** — expect rough edges.

```bash
brew install eksctl
eksctl create cluster --name demo-cluster-eksctl
eksctl get nodes --cluster demo-cluster-eksctl
```

Source: https://docs.localstack.cloud/aws/integrations/containers/eksctl/ ("The support for eksctl is currently experimental and may not work in all cases.")

---

## Provisioning via Terraform (`tflocal`)

For a fuller, IaC-driven evaluation, a community walkthrough (LocalStack Pro v4.10.1, AWS provider ~>5.0) demonstrates provisioning a complete VPC + IAM role + EKS cluster stack via Terraform, then connecting with `kubectl` via `aws eks update-kubeconfig`. The resulting `kubectl get nodes` shows the k3d control-plane node in a `Ready` state.

This is a heavier setup (10 resources: VPC, subnets, security groups, IAM role/policy, EKS cluster) but is the more realistic test of how your actual Terraform EKS modules would behave locally.

Source: https://medium.com/@piolojustincabigao/building-a-fully-local-eks-environment-for-kubernetes-development-df6191754585

---

## Known Issues to Expect

| Symptom | Cause | Source |
|---|---|---|
| `API for service 'eks' not yet implemented or pro feature` | Not on Ultimate tier | github.com/localstack/localstack/issues/11412 |
| `"status": "FAILED"`, `Unable to start EKS cluster` in logs | Pre-existing `~/.kube/config` being auto-mounted (CLI < 3.7) | docs.localstack.cloud/aws/services/eks/ |
| `kubectl get po` fails with `EOF` against port 4511 | Port range conflict or stale kube-config from a previous cluster | discuss.localstack.cloud/t/how-to-operator-kubernetes-cluster-in-localstack-eks |
| `the server has asked for the client to provide credentials` | Missing `update-kubeconfig` + context switch step | discuss.localstack.cloud/t/how-to-operator-kubernetes-cluster-in-localstack-eks |
| `endpoint` field doesn't match expected container address when using an existing cluster | Known discrepancy reported against LocalStack support, not yet resolved at time of writing | discuss.localstack.cloud/t/eks-configure-using-an-existing-k8s-installation |

---

## Two Other Worth-Noting EKS-Adjacent Capabilities

1. **Self-managed EC2 nodes joining an emulated EKS cluster** (introduced 2026.05.0) — EC2 instances launched with a `NodeConfig` in user data on AmazonLinux2023 can join a matching EKS cluster, enabling early Karpenter-style autoscaling testing. Marked early-stage by LocalStack themselves; Karpenter version coverage not fully validated.
   Source: https://blog.localstack.cloud/localstack-for-aws-release-2026-05-0/

2. **LocalStack Kubernetes Executor (separate from EKS)** — this is a different feature: rather than emulating EKS, you run LocalStack *itself* inside a real Kubernetes cluster, and configure `CONTAINER_RUNTIME=kubernetes` so that LocalStack provisions its backing resources (Lambda, RDS, etc.) as pods rather than Docker containers. Useful if your team already standardises on Kubernetes for local dev infrastructure, but conceptually distinct from "emulating EKS."
   Source: https://blog.localstack.cloud/running-localstack-on-kubernetes-for-local-aws-development-testing/

---

## Summary: Is It Worth Including in the Demo / Article?

Yes — with caveats clearly stated. The k3d-backed cluster is genuinely functional (real `kubectl`, real scheduling, real pods), which is a strong differentiator over a pure API mock. But:

- It requires the **Ultimate** (paid) tier — worth stating explicitly in any comparison, since this directly contrasts with Floci's free EKS support via real k3s
- Setup has more documented rough edges than the core services (S3, SQS, DynamoDB) — expect at least one of the "Known Issues" above on a first attempt
- The `eksctl` path is explicitly experimental per LocalStack's own docs

This makes it a good candidate for a "advanced/Ultimate-tier" section of your write-up rather than the core walkthrough, since it requires both a paid subscription and slightly more troubleshooting patience than the rest of the demo.

---

## Verified References

| Topic | Source |
|---|---|
| Ultimate trial signup, pricing, "credit card optional" | https://www.localstack.cloud/pricing |
| 45-day trial duration confirmation | https://blog.localstack.cloud/2026-upcoming-pricing-changes/ |
| Auth Token retrieval | https://docs.localstack.cloud/aws/getting-started/auth-token/ |
| EKS service overview, k3d architecture, node groups, ECR usage | https://docs.localstack.cloud/aws/services/eks/ |
| eksctl support (experimental) | https://docs.localstack.cloud/aws/integrations/containers/eksctl/ |
| EKS requires Pro/Ultimate tier (GitHub issue) | https://github.com/localstack/localstack/issues/11412 |
| kube-config / context troubleshooting | https://discuss.localstack.cloud/t/how-to-operator-kubernetes-cluster-in-localstack-eks/919.html |
| Existing-cluster endpoint discrepancy | https://discuss.localstack.cloud/t/eks-configure-using-an-existing-k8s-installation/1084 |
| Full Terraform + EKS + kubectl walkthrough | https://medium.com/@piolojustincabigao/building-a-fully-local-eks-environment-for-kubernetes-development-df6191754585 |
| Self-managed EC2 nodes joining EKS (2026.05.0) | https://blog.localstack.cloud/localstack-for-aws-release-2026-05-0/ |
| LocalStack Kubernetes Executor (running LocalStack on K8s) | https://blog.localstack.cloud/running-localstack-on-kubernetes-for-local-aws-development-testing/ |
| EKS tier availability (Ultimate+) | https://docs.localstack.cloud/aws/licensing/ |
