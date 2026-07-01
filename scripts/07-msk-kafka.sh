#!/usr/bin/env bash
# 07-msk-kafka.sh — MSK (Managed Streaming for Kafka) via real Redpanda container
#
# Source: https://floci.io/floci/services/msk/
#
# Floci starts a real redpandadata/redpanda container.
# The Kafka broker is wire-compatible with standard Kafka clients.
# Optional: install kcat (kafkacat) for produce/consume:
#   brew install kcat

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCOUNT_ID=000000000000
REGION=${AWS_DEFAULT_REGION}
CLUSTER_NAME=demo-kafka
TOPIC=orders

echo ""
echo "═══════════════════════════════════════"
echo "  MSK — Kafka via Redpanda (real Docker)"
echo "═══════════════════════════════════════"

# Check if cluster already exists
EXISTING=$(aws kafka list-clusters \
  --query "ClusterInfoList[?ClusterName=='${CLUSTER_NAME}'].ClusterArn" \
  --output text 2>/dev/null)

if [ -z "${EXISTING}" ]; then
  echo "  Creating MSK cluster (starts Redpanda container)..."
  aws kafka create-cluster \
    --cluster-name "${CLUSTER_NAME}" \
    --kafka-version "3.5.1" \
    --number-of-broker-nodes 1 \
    --broker-node-group-info '{
      "InstanceType":   "kafka.m5.large",
      "ClientSubnets":  ["subnet-00000001"],
      "StorageInfo":    {"EbsStorageInfo": {"VolumeSize": 20}}
    }' > /dev/null
  echo "  Waiting for cluster to become ACTIVE..."
  sleep 5
else
  echo "  Cluster already exists: ${EXISTING}"
fi

CLUSTER_ARN=$(aws kafka list-clusters \
  --query "ClusterInfoList[?ClusterName=='${CLUSTER_NAME}'].ClusterArn" \
  --output text)

echo "✓ Cluster ARN: ${CLUSTER_ARN}"

echo ""
echo "  Cluster details:"
aws kafka describe-cluster \
  --cluster-arn "${CLUSTER_ARN}" \
  --query 'ClusterInfo.{name:ClusterName,state:State,kafka:CurrentBrokerSoftwareInfo.KafkaVersion,brokers:NumberOfBrokerNodes}' \
  --output table

echo ""
echo "  Bootstrap brokers:"
BROKERS=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "${CLUSTER_ARN}" \
  --query 'BootstrapBrokerString' --output text)
echo "  ${BROKERS}"

echo ""
echo "  MSK cluster list:"
aws kafka list-clusters \
  --query 'ClusterInfoList[*].{name:ClusterName,state:State,arn:ClusterArn}' \
  --output table

if command -v kcat &> /dev/null; then
  echo ""
  echo "  kcat detected — producing and consuming test messages..."

  echo '{"orderId":"kafka-001","amount":42.00}' \
    | kcat -b "${BROKERS}" -t "${TOPIC}" -P

  echo '{"orderId":"kafka-002","amount":15.00}' \
    | kcat -b "${BROKERS}" -t "${TOPIC}" -P

  echo "  Messages in topic '${TOPIC}':"
  kcat -b "${BROKERS}" -t "${TOPIC}" -C -e -q

  echo "✓ Produce and consume via kcat"
else
  echo ""
  echo "  kcat not installed — skipping produce/consume test"
  echo "  Install with: brew install kcat"
  echo ""
  echo "  Manual produce:"
  echo "    echo '{\"orderId\":\"001\"}' | kcat -b ${BROKERS} -t ${TOPIC} -P"
  echo ""
  echo "  Manual consume:"
  echo "    kcat -b ${BROKERS} -t ${TOPIC} -C -e"
fi

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  MSK / Kafka demo complete"
echo "═══════════════════════════════════════"
