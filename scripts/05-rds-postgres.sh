#!/usr/bin/env bash
# 05-rds-postgres.sh — RDS PostgreSQL, real Docker backend
#
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

# The Address field is the Postgres container's internal Docker network IP —
# not reachable from the host. Floci publishes the real connection point on
# localhost via the port range mapped in compose.yaml (7001-7099), so always
# connect through localhost on the reported port, never the Address field.
REPORTED_ADDRESS=$(echo "${DB_ENDPOINT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Address'])")
DB_HOST=localhost
DB_PORT=$(echo "${DB_ENDPOINT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Port'])")

echo "  Host (from API, informational only): ${REPORTED_ADDRESS}"
echo "  Host (actually connecting via):       ${DB_HOST}"
echo "  Port: ${DB_PORT}"

# "available" from the AWS-shaped API reflects container health, not
# necessarily that Floci's internal proxy has finished wiring the
# localhost:<port> -> container route yet. Poll the actual TCP port before
# handing off to psql, rather than trusting the API status alone — this
# avoids a race where the connection is accepted then immediately dropped
# ("server closed the connection unexpectedly").
echo ""
echo "  Waiting for proxy port to accept connections..."

# Floci's Postgres protocol handler doesn't support the GSSENCRequest
# preamble that libpq sends by default (gssencmode=prefer) before the real
# startup packet — it logs "Unexpected PostgreSQL startup protocol version:
# 80,877,104" and drops the connection instead of declining and continuing,
# the way real Postgres does. Disable GSS negotiation client-side so both
# the readiness probe and the real connection send a plain startup packet.
export PGGSSENCMODE=disable

PROXY_READY=0
for i in $(seq 1 15); do
  if command -v pg_isready &> /dev/null; then
    if pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -t 2 &> /dev/null; then
      PROXY_READY=1
      break
    fi
  else
    # Fallback with no extra dependency: raw TCP probe via bash's /dev/tcp
    if (exec 3<>"/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; then
      exec 3<&- 3>&-
      PROXY_READY=1
      break
    fi
  fi
  sleep 1
done

if [[ "${PROXY_READY}" -eq 1 ]]; then
  echo "✓ Proxy port responding (took ${i}s after 'available' status)"
else
  echo "  Proxy port still not responding after 15s — connection attempt below will likely fail."
  echo "  If it does, this points to a real Floci issue rather than a simple startup race:"
  echo "    docker logs floci-demo-floci-1 --tail 50"
fi

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
  --query 'DBInstances[0].{Id:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Endpoint:Endpoint}' \
  --output table
