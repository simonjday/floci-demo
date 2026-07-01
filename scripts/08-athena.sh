#!/usr/bin/env bash
# 08-athena.sh — Athena real SQL via DuckDB sidecar + Glue Data Catalog + S3
#
# Sources: https://floci.io/floci/services/athena/
#          https://floci.io/floci/services/glue/
#
# Floci uses a DuckDB sidecar (floci-duck) for real SQL execution over local S3.
# Results are written to an S3 output location, identical to real AWS Athena.

set -euo pipefail

source "$(dirname "$0")/00-setup.sh"

ACCOUNT_ID=000000000000
DATA_BUCKET=floci-athena-data
RESULTS_BUCKET=floci-athena-results
DB_NAME=demo_analytics
TABLE_NAME=sales

echo ""
echo "═══════════════════════════════════════"
echo "  Athena — real SQL via DuckDB sidecar"
echo "═══════════════════════════════════════"

echo ""
echo "  Creating S3 buckets..."
aws s3 mb "s3://${DATA_BUCKET}"    2>/dev/null || true
aws s3 mb "s3://${RESULTS_BUCKET}" 2>/dev/null || true

echo ""
echo "  Uploading CSV data to S3..."

cat > /tmp/sales.csv << 'EOF'
date,region,product,quantity,unit_price,revenue
2026-01-01,EU,widget-a,100,12.00,1200.00
2026-01-01,EU,widget-b,80,10.00,800.00
2026-01-15,US,widget-a,120,12.00,1440.00
2026-02-01,EU,widget-a,125,12.00,1500.00
2026-02-01,EU,widget-c,30,10.00,300.00
2026-02-15,US,widget-b,90,10.00,900.00
2026-03-01,EU,widget-a,150,12.00,1800.00
2026-03-01,US,widget-c,60,10.00,600.00
2026-03-15,APAC,widget-a,200,11.50,2300.00
2026-03-15,APAC,widget-b,150,9.50,1425.00
EOF

aws s3 cp /tmp/sales.csv "s3://${DATA_BUCKET}/sales/sales.csv"
echo "✓ Data uploaded to s3://${DATA_BUCKET}/sales/"

echo ""
echo "  Creating Glue Data Catalog..."

aws glue create-database \
  --database-input "{\"Name\":\"${DB_NAME}\"}" 2>/dev/null || true

aws glue create-table \
  --database-name "${DB_NAME}" \
  --table-input "{
    \"Name\": \"${TABLE_NAME}\",
    \"Description\": \"Sales data for Athena demo\",
    \"StorageDescriptor\": {
      \"Columns\": [
        {\"Name\":\"date\",       \"Type\":\"string\"},
        {\"Name\":\"region\",     \"Type\":\"string\"},
        {\"Name\":\"product\",    \"Type\":\"string\"},
        {\"Name\":\"quantity\",   \"Type\":\"int\"},
        {\"Name\":\"unit_price\", \"Type\":\"double\"},
        {\"Name\":\"revenue\",    \"Type\":\"double\"}
      ],
      \"Location\": \"s3://${DATA_BUCKET}/sales/\",
      \"InputFormat\":  \"org.apache.hadoop.mapred.TextInputFormat\",
      \"OutputFormat\": \"org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat\",
      \"SerdeInfo\": {
        \"SerializationLibrary\": \"org.apache.hadoop.hive.serde2.OpenCSVSerde\",
        \"Parameters\": {\"skip.header.line.count\": \"1\"}
      }
    },
    \"TableType\": \"EXTERNAL_TABLE\"
  }" 2>/dev/null || true

echo "✓ Glue database '${DB_NAME}' and table '${TABLE_NAME}' created"

# ── Helper function ────────────────────────────────────────────────────────────
run_query() {
  local label=$1
  local sql=$2

  echo ""
  echo "  Query: ${label}"
  echo "  SQL:   ${sql}"

  QUERY_ID=$(aws athena start-query-execution \
    --query-string "${sql}" \
    --query-execution-context "Database=${DB_NAME}" \
    --result-configuration "OutputLocation=s3://${RESULTS_BUCKET}/" \
    --query 'QueryExecutionId' --output text)

  # Poll for completion
  for i in {1..20}; do
    STATE=$(aws athena get-query-execution \
      --query-execution-id "${QUERY_ID}" \
      --query 'QueryExecution.Status.State' --output text)
    [ "${STATE}" = "SUCCEEDED" ] && break
    [ "${STATE}" = "FAILED" ]    && {
      REASON=$(aws athena get-query-execution \
        --query-execution-id "${QUERY_ID}" \
        --query 'QueryExecution.Status.StateChangeReason' --output text)
      echo "  FAILED: ${REASON}"
      return 1
    }
    sleep 1
  done

  echo "  Results:"
  aws athena get-query-results \
    --query-execution-id "${QUERY_ID}" \
    --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
    --output table
}

echo ""
echo "═══════════════════════════════════════"
echo "  Running Athena queries (DuckDB executes against S3)"
echo "═══════════════════════════════════════"

run_query \
  "Revenue by product" \
  "SELECT product, SUM(revenue) as total_revenue, SUM(quantity) as total_units FROM ${TABLE_NAME} GROUP BY product ORDER BY total_revenue DESC"

run_query \
  "Revenue by region" \
  "SELECT region, SUM(revenue) as total_revenue FROM ${TABLE_NAME} GROUP BY region ORDER BY total_revenue DESC"

run_query \
  "Monthly trend" \
  "SELECT SUBSTR(date,1,7) as month, SUM(revenue) as monthly_revenue FROM ${TABLE_NAME} GROUP BY SUBSTR(date,1,7) ORDER BY month"

run_query \
  "Top product per region" \
  "SELECT region, product, SUM(revenue) as revenue FROM ${TABLE_NAME} GROUP BY region, product ORDER BY region, revenue DESC"

echo ""
echo "  Query execution history:"
aws athena list-query-executions \
  --query 'QueryExecutionIds' --output json

echo ""
echo "  Results files in S3:"
aws s3 ls "s3://${RESULTS_BUCKET}/"

echo ""
echo "═══════════════════════════════════════"
echo "  ✅  Athena demo complete"
echo "═══════════════════════════════════════"
