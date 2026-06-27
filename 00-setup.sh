#!/usr/bin/env bash
# 00-setup.sh — Configure shell environment for Floci
# Usage: source scripts/00-setup.sh
#
# Sources: https://floci.io/floci/getting-started/quick-start/
#          https://floci.io/floci/getting-started/aws-setup/

set -euo pipefail

export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=eu-west-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test

# Convenience alias — drop --endpoint-url from every command
# AWS CLI v2.x picks up AWS_ENDPOINT_URL automatically, so this
# is just a belt-and-suspenders reminder for scripts that set it explicitly.

echo "✓ AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL}"
echo "✓ AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"
echo "✓ AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
echo ""
echo "Waiting for Floci to be healthy..."

until curl -sf "${AWS_ENDPOINT_URL}/_localstack/health" > /dev/null 2>&1; do
  printf "."
  sleep 1
done

echo ""
echo "✓ Floci is ready at ${AWS_ENDPOINT_URL}"
