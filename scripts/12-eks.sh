#!/usr/bin/env bash
# 12-eks.sh — EKS via real k3s cluster
#
# Sources: https://floci.io/aws/
#          https://floci.io/floci/services/  (EKS real mode spins up a
#          real k3s container per Services Overview)
#
# Caveat (read before running): as of this writing, Floci's EKS "real
# mode" has a confirmed, open upstream bug — github.com/floci-io/floci
# issue #1118. aws eks create-cluster succeeds and a real k3s container
# comes up, but:
#   1. describe-cluster returns a Docker-network-only endpoint
#      (https://floci-eks-<name>:6443), not host-reachable.
#   2. Even hitting the k3s API directly on its host-published port
#      (range 6500-6599) returns 401 — the AWS-shaped API never surfaces
#      usable client credentials, only the CA cert.
# This script works around both by extracting the real admin kubeconfig
# from inside the k3s container via `docker exec` and rewriting its
# server address to the host-published port — the same workaround
# documented in that issue. This is a community workaround for a known
# bug, not officially supported Floci behavior; if a future Floci release
# ships `floci eks kubeconfig <name>` or similar, prefer that instead.

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

echo ""
echo "═══════════════════════════════════════"
echo "  EKS — real k3s cluster"
echo "═══════════════════════════════════════"
echo "  Known upstream issue: floci-io/floci#1118 — see header comment"
echo "  in this script. Working around it via docker exec, not the API."

EKS_CLUSTER=demo-eks

EXISTING_EKS=$(aws eks list-clusters \
  --query "clusters[?@=='${EKS_CLUSTER}']" --output text 2>/dev/null)

if [ -z "${EXISTING_EKS}" ]; then
  echo "  Creating EKS cluster (starts a real k3s container)..."
  aws eks create-cluster \
    --name "${EKS_CLUSTER}" \
    --role-arn "arn:aws:iam::000000000000:role/eks-role" \
    --resources-vpc-config subnetIds=subnet-00000001 > /dev/null
  echo "  Waiting for cluster to become ACTIVE..."
  aws eks wait cluster-active --name "${EKS_CLUSTER}"
else
  echo "  Cluster already exists: ${EKS_CLUSTER}"
fi

echo "✓ EKS cluster ACTIVE"

echo ""
echo "  Cluster details (API-reported endpoint — not host-reachable, see caveat above):"
aws eks describe-cluster \
  --name "${EKS_CLUSTER}" \
  --query 'cluster.{name:name,status:status,endpoint:endpoint,version:version}' \
  --output table

# Find the real k3s container by image rather than assuming a fixed name.
EKS_CONTAINER=$(docker ps --filter "ancestor=rancher/k3s:latest" --format "{{.Names}}" | head -1)

if [ -z "${EKS_CONTAINER}" ]; then
  echo ""
  echo "  Could not find a running rancher/k3s container — skipping"
  echo "  kubeconfig extraction. Check 'docker ps' manually."
else
  echo ""
  echo "  Found k3s container '${EKS_CONTAINER}'"

  EKS_HOSTPORT=$(docker port "${EKS_CONTAINER}" 6443 | head -1 | sed -E 's/.*:([0-9]+)$/\1/')

  if [ -z "${EKS_HOSTPORT}" ]; then
    echo "  Could not determine host port for the k3s API server — skipping."
  else
    echo "  k3s API server published at localhost:${EKS_HOSTPORT}"

    KUBECONFIG_FILE="/tmp/floci-eks-${EKS_CLUSTER}-kubeconfig.yaml"
    docker exec "${EKS_CONTAINER}" cat /etc/rancher/k3s/k3s.yaml > "${KUBECONFIG_FILE}"
    sed -i.bak -E "s#https://127.0.0.1:6443#https://127.0.0.1:${EKS_HOSTPORT}#" "${KUBECONFIG_FILE}"
    rm -f "${KUBECONFIG_FILE}.bak"

    echo "  Extracted working kubeconfig to: ${KUBECONFIG_FILE}"

    if command -v kubectl &> /dev/null; then
      echo ""
      echo "  Verifying cluster access..."
      KUBECONFIG="${KUBECONFIG_FILE}" kubectl get nodes

      echo ""
      echo "  Deploying nginx..."
      KUBECONFIG="${KUBECONFIG_FILE}" kubectl run nginx --image=nginx:alpine --port=80 > /dev/null
      echo "  Waiting for pod to be Ready..."
      KUBECONFIG="${KUBECONFIG_FILE}" kubectl wait --for=condition=Ready pod/nginx --timeout=60s || true

      echo ""
      echo "  Pods and services:"
      KUBECONFIG="${KUBECONFIG_FILE}" kubectl get pods,svc

      echo "✓ kubectl working against real k3s cluster"
    else
      echo "  kubectl not installed — skipping cluster verification"
      echo "  Install with: brew install kubectl"
      echo ""
      echo "  Manual verification:"
      echo "    KUBECONFIG=${KUBECONFIG_FILE} kubectl get nodes"
    fi
  fi
fi

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  EKS demo complete"
echo "═══════════════════════════════════════"
echo ""
echo "  Cluster is left running for inspection. Manual cleanup, if you want it:"
echo "    aws eks delete-cluster --name ${EKS_CLUSTER}"
