#!/usr/bin/env bash
# 05-rds-postgres.sh — RDS PostgreSQL via real Docker container
#
# Source: https://floci.io/floci/services/rds/
#
# Floci starts a real postgres:16-alpine container.
# First run pulls the image — may take a minute depending on connection speed.
# Requires psql to be installed for the connection test:
#   brew install libpq && brew link --force libpq

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCOUNT_ID=000000000000
DB_ID=demo-postgres
DB_USER=admin
DB_PASS=flocipass

echo ""
echo "═══════════════════════════════════════"
echo "  RDS PostgreSQL — real Docker backend"
echo "═══════════════════════════════════════"

# Delete if exists
aws rds delete-db-instance \
  --db-instance-identifier "${DB_ID}" \
  --skip-final-snapshot 2>/dev/null || true

echo "  Creating RDS instance (starts postgres:16-alpine container)..."

aws rds create-db-instance \
  --db-instance-identifier "${DB_ID}" \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version "16" \
  --master-username "${DB_USER}" \
  --master-user-password "${DB_PASS}" \
  --db-name appdb \
  --allocated-storage 20 \
  --publicly-accessible \
  --no-multi-az > /dev/null

echo "  Waiting for available status (real DB engine starting)..."
aws rds wait db-instance-available \
  --db-instance-identifier "${DB_ID}"

echo "✓ RDS instance available"

# Get connection details
DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "${DB_ID}" \
  --query 'DBInstances[0].Endpoint' \
  --output json)
echo ""
echo "  Endpoint: ${DB_ENDPOINT}"

DB_HOST=$(echo "${DB_ENDPOINT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Address'])")
DB_PORT=$(echo "${DB_ENDPOINT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Port'])")

echo "  Host: ${DB_HOST}"
echo "  Port: ${DB_PORT}"

echo ""
echo "  Testing connection via psql..."

if command -v psql &> /dev/null; then
  PGPASSWORD="${DB_PASS}" psql \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d appdb \
    --no-password \
    -c "
      CREATE TABLE IF NOT EXISTS orders (
        id         SERIAL PRIMARY KEY,
        order_id   VARCHAR(50) UNIQUE NOT NULL,
        customer   VARCHAR(100),
        amount     NUMERIC(10,2),
        created_at TIMESTAMPTZ DEFAULT NOW()
      );

      INSERT INTO orders (order_id, customer, amount) VALUES
        ('abc-123', 'cust-1', 42.00),
        ('def-456', 'cust-1', 15.00),
        ('ghi-789', 'cust-2', 99.99)
      ON CONFLICT DO NOTHING;

      SELECT order_id, customer, amount FROM orders ORDER BY created_at;
    "
  echo "✓ psql connected to real PostgreSQL engine"
else
  echo "  psql not found — skipping direct connection test"
  echo "  Install with: brew install libpq && brew link --force libpq"
  echo ""
  echo "  Manual connection command:"
  echo "    PGPASSWORD=${DB_PASS} psql -h ${DB_HOST} -p ${DB_PORT} -U ${DB_USER} -d appdb"
fi

echo ""
echo "  Describe instance summary:"
aws rds describe-db-instances \
  --db-instance-identifier "${DB_ID}" \
  --query 'DBInstances[0].{
    id:DBInstanceIdentifier,
    status:DBInstanceStatus,
    engine:Engine,
    engineVersion:EngineVersion,
    endpoint:Endpoint.Address,
    port:Endpoint.Port
  }' --output table

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  RDS PostgreSQL demo complete"
echo "═══════════════════════════════════════"
