#!/usr/bin/env bash
# 11-ecs.sh — ECS via real Docker task
#
# Source: https://floci.io/aws/

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

echo ""
echo "═══════════════════════════════════════"
echo "  ECS — real Docker task"
echo "═══════════════════════════════════════"

ECS_CLUSTER=demo-ecs
TASK_FAMILY=web-task

EXISTING_CLUSTER=$(aws ecs list-clusters \
  --query "clusterArns[?contains(@, '${ECS_CLUSTER}')]" --output text 2>/dev/null)

if [ -z "${EXISTING_CLUSTER}" ]; then
  echo "  Creating ECS cluster..."
  aws ecs create-cluster --cluster-name "${ECS_CLUSTER}" > /dev/null
else
  echo "  Cluster already exists: ${EXISTING_CLUSTER}"
fi

echo "  Registering task definition (nginx:alpine, bridge mode, host port 8081)..."
aws ecs register-task-definition \
  --family "${TASK_FAMILY}" \
  --network-mode bridge \
  --container-definitions '[{
    "name": "web",
    "image": "nginx:alpine",
    "portMappings": [{"containerPort": 80, "hostPort": 8081}],
    "memory": 128,
    "cpu": 64
  }]' > /dev/null

echo "  Running task (Floci launches a real nginx:alpine container)..."
TASK_ARN=$(aws ecs run-task \
  --cluster "${ECS_CLUSTER}" \
  --task-definition "${TASK_FAMILY}" \
  --count 1 \
  --query 'tasks[0].taskArn' --output text)

echo "✓ Task started: ${TASK_ARN}"

echo "  Waiting for task to reach RUNNING..."
for i in $(seq 1 15); do
  STATUS=$(aws ecs describe-tasks \
    --cluster "${ECS_CLUSTER}" \
    --tasks "${TASK_ARN}" \
    --query 'tasks[0].lastStatus' --output text)
  if [ "${STATUS}" = "RUNNING" ]; then
    break
  fi
  sleep 1
done
echo "  Task status: ${STATUS}"

echo ""
echo "  Verifying the real container serves traffic on localhost:8081..."
sleep 1
if curl -sf http://localhost:8081 > /dev/null; then
  echo "✓ nginx responding on http://localhost:8081"
else
  echo "  nginx not responding yet — task container may still be starting."
  echo "  Check manually: curl http://localhost:8081"
fi

echo ""
echo "  Tasks in cluster:"
aws ecs list-tasks --cluster "${ECS_CLUSTER}" --output table

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  ECS demo complete"
echo "═══════════════════════════════════════"
echo ""
echo "  Task is left running for inspection. Manual cleanup, if you want it:"
echo "    aws ecs stop-task --cluster ${ECS_CLUSTER} --task ${TASK_ARN}"
echo "    aws ecs delete-cluster --cluster ${ECS_CLUSTER}"
