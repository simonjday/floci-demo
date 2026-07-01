#!/usr/bin/env bash
# 00-setup.sh — Configure shell environment for Floci
# Usage: source scripts/00-setup.sh
#
# Sources: https://floci.io/floci/getting-started/quick-start/
#          https://floci.io/floci/getting-started/aws-setup/

# This file is designed to be *sourced*, not executed. `source` runs its
# commands directly in the calling shell — the shebang above only applies
# when the file is executed as its own process, not when sourced. That
# means `set -euo pipefail` here would leak strict mode into your entire
# interactive session once sourcing finishes: nounset (-u) in particular
# breaks tools that reference intentionally-unset variables, e.g. VS
# Code's shell integration prompt hook throwing "RPROMPT: parameter not
# set". Only turn strict mode on when this file is run as its own script
# (e.g. some other tooling calls `bash scripts/00-setup.sh` directly)
# rather than sourced into an interactive or calling shell.
if ! (return 0 2>/dev/null); then
  set -euo pipefail
fi

export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=eu-west-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test

# AWS CLI v2 pipes all output through a pager (less on macOS/Linux) whenever
# stdout is a TTY — which it is here, since these scripts are meant to be
# run directly in your terminal, not redirected. Without this, any command
# whose output fills the screen (get-item, list-tables, describe-*, etc.)
# will hang the script at a `less` prompt until you press `q`. This is
# standard AWS CLI v2 behavior, not Floci-specific — see
# https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-pagination.html
export AWS_PAGER=""

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
