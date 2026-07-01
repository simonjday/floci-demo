#!/usr/bin/env bash
# 07-msk-kafka.sh — MSK (Managed Streaming for Kafka) via real Redpanda container
#
# Source: https://floci.io/floci/services/msk/
#
# Floci starts a real redpandadata/redpanda container. Unlike RDS and
# ElastiCache, Floci does not publish a host port for the Kafka broker
# (confirmed via `docker ps` — the container shows `9092/tcp` with no
# `0.0.0.0:` host binding, and this range isn't in Floci's documented
# compose.yaml either). So neither a host-installed kcat nor a client
# on your Mac can reach it directly, regardless of what describe-cluster
# or get-bootstrap-brokers reports. This script instead uses `rpk`,
# Redpanda's own CLI already present inside the broker container, via
# `docker exec` — no external client install or image pull required,
# and it runs natively on arm64 (Redpanda ships true multi-arch images,
# unlike e.g. kcat's amd64-only Docker Hub image).

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
echo "  Bootstrap brokers (from API, informational only):"
BROKERS=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "${CLUSTER_ARN}" \
  --query 'BootstrapBrokerString' --output text)
echo "  ${BROKERS}"
echo "  ^ This is the Redpanda container's internal Docker network IP."
echo "  Unlike RDS/ElastiCache, Floci does not publish a host port for Kafka,"
echo "  so it's unreachable from localhost — see 'docker ps', the container"
echo "  shows '9092/tcp' with no '0.0.0.0:' prefix. Connect via the Docker"
echo "  network instead, using the container name as the bootstrap host."

echo ""
echo "  MSK cluster list:"
aws kafka list-clusters \
  --query 'ClusterInfoList[*].{name:ClusterName,state:State,arn:ClusterArn}' \
  --output table

# Discover the actual Redpanda container and the Docker network Floci
# attached it to, rather than assuming a fixed name — Floci's container
# naming for sidecars isn't documented, so match by image instead.
KAFKA_CONTAINER=$(docker ps --filter "ancestor=redpandadata/redpanda:latest" --format "{{.Names}}" | head -1)

if [ -z "${KAFKA_CONTAINER}" ]; then
  echo ""
  echo "  Could not find a running redpandadata/redpanda container —"
  echo "  skipping produce/consume test. Check 'docker ps' manually."
else
  echo ""
  echo "  Found broker container '${KAFKA_CONTAINER}'"
  echo "  Producing and consuming test messages via rpk, exec'd inside the broker container..."

  # rpk is Redpanda's own CLI, already present in the container and running
  # natively (Redpanda ships true arm64 images) — this avoids pulling an
  # external client image like kcat, which is amd64-only on Docker Hub and
  # runs under Rosetta emulation on Apple Silicon otherwise.
  printf '{"orderId":"kafka-001","amount":42.00}\n{"orderId":"kafka-002","amount":15.00}\n' \
    | docker exec -i "${KAFKA_CONTAINER}" rpk topic produce "${TOPIC}"

  echo "  Messages in topic '${TOPIC}':"
  docker exec "${KAFKA_CONTAINER}" rpk topic consume "${TOPIC}" -n 2 -o start

  echo "✓ Produce and consume via rpk (native arm64, no external image)"
  echo ""
  echo "  Manual equivalent, if you want to run it yourself:"
  echo "    docker exec -it ${KAFKA_CONTAINER} rpk topic consume ${TOPIC} -o start"
fi

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  MSK / Kafka demo complete"
echo "═══════════════════════════════════════"
