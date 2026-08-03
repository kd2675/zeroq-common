#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DDL_FILE="${ROOT_DIR}/stock-back-service/src/main/resources/db/ddl/stock_scaled_market_liquidity_distribution_alter.sql"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_MIGRATION:-}" != "YES" ]]; then
  printf 'FAIL migration requires STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_MIGRATION=YES\n' >&2
  exit 1
fi

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"

if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_* and must not be a batch schema\n' >&2
  exit 1
fi
if [[ ! -f "${DDL_FILE}" ]]; then
  printf 'FAIL missing migration file %s\n' "${DDL_FILE}" >&2
  exit 1
fi
if [[ -z "${MYSQL_BIN}" ]]; then
  MYSQL_BIN="$(command -v mysql || true)"
fi
if [[ -z "${MYSQL_BIN}" || ! -x "${MYSQL_BIN}" ]]; then
  printf 'FAIL mysql client was not found; set STOCK_MYSQL_BIN\n' >&2
  exit 1
fi

MYSQL_CONNECTION_ARGS=(
  "--host=${STOCK_MYSQL_HOST}"
  "--port=${STOCK_MYSQL_PORT}"
  "--user=${STOCK_MYSQL_USER}"
  "--database=${REPLAY_SCHEMA}"
  "--connect-timeout=10"
  "--default-character-set=utf8mb4"
  "--batch"
  "--skip-column-names"
)

mysql_replay() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" "$@"
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local query="$3"
  local actual

  actual="$(mysql_replay --execute="${query}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL %s expected=%s actual=%s\n' \
      "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf 'PASS %s = %s\n' "${label}" "${actual}"
}

business_fingerprint() {
  mysql_replay --execute="
    SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*) FROM stock_account),
      (SELECT CAST(SUM(cash_balance) AS DECIMAL(24,2)) FROM stock_account),
      (SELECT COUNT(*) FROM stock_holding),
      (SELECT SUM(quantity) FROM stock_holding),
      (SELECT SUM(reserved_quantity) FROM stock_holding),
      (SELECT COUNT(*) FROM stock_order),
      (SELECT COUNT(*) FROM stock_execution),
      (SELECT COUNT(*) FROM stock_account_cash_flow),
      (SELECT COUNT(*) FROM stock_order_strategy_origin)
    );
  "
}

liquidity_distribution_fingerprint() {
  local table_count
  table_count="$(mysql_replay --execute="
    SELECT COUNT(*)
      FROM information_schema.tables
     WHERE table_schema = DATABASE()
       AND table_name IN (
         'stock_scaled_market_liquidity_distribution_plan',
         'stock_scaled_market_liquidity_distribution_source_order'
       );
  ")"
  if [[ "${table_count}" != "2" ]]; then
    printf 'ABSENT\n'
    return 0
  fi
  mysql_replay --execute="
    SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*)
         FROM stock_scaled_market_liquidity_distribution_plan),
      (SELECT COUNT(*)
         FROM stock_scaled_market_liquidity_distribution_source_order)
    );
  "
}

connected_schema="$(mysql_replay --execute='SELECT DATABASE()')"
if [[ "${connected_schema}" != "${REPLAY_SCHEMA}" ]]; then
  printf 'FAIL connected schema mismatch expected=%s actual=%s\n' \
    "${REPLAY_SCHEMA}" "${connected_schema}" >&2
  exit 1
fi
printf 'PASS connected isolated replay schema %s\n' "${REPLAY_SCHEMA}"
printf 'PASS operating STOCK_SERVICE is outside the migration target\n'

fingerprint_before="$(business_fingerprint)"
distribution_fingerprint_before="$(liquidity_distribution_fingerprint)"
for attempt in 1 2; do
  sed "s/STOCK_SERVICE/${REPLAY_SCHEMA}/g" "${DDL_FILE}" \
    | mysql_replay >/dev/null
  printf 'PASS liquidity-distribution migration attempt %s applied\n' \
    "${attempt}"
done
fingerprint_after="$(business_fingerprint)"
distribution_fingerprint_after="$(liquidity_distribution_fingerprint)"

if [[ "${fingerprint_after}" != "${fingerprint_before}" ]]; then
  printf 'FAIL migration changed replay business data\n' >&2
  printf 'before=%s\nafter=%s\n' \
    "${fingerprint_before}" "${fingerprint_after}" >&2
  exit 1
fi
printf 'PASS replay business data unchanged = %s\n' "${fingerprint_after}"

if [[ "${distribution_fingerprint_before}" == "ABSENT" ]]; then
  expected_distribution_fingerprint="0|0"
else
  expected_distribution_fingerprint="${distribution_fingerprint_before}"
fi
if [[ "${distribution_fingerprint_after}" != "${expected_distribution_fingerprint}" ]]; then
  printf 'FAIL migration changed liquidity-distribution audit rows\n' >&2
  printf 'before=%s\nafter=%s\n' \
    "${distribution_fingerprint_before}" \
    "${distribution_fingerprint_after}" >&2
  exit 1
fi
printf 'PASS liquidity-distribution audit rows unchanged = %s\n' \
  "${distribution_fingerprint_after}"

assert_equals \
  "role-transfer origin column" \
  "1" \
  "
  SELECT COUNT(*)
    FROM information_schema.columns
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_order_strategy_origin'
     AND column_name = 'role_transfer_plan_id'
  "
assert_equals \
  "role-transfer origin index" \
  "2" \
  "
  SELECT COUNT(*)
    FROM information_schema.statistics
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_order_strategy_origin'
     AND index_name = 'idx_stock_order_strategy_role_transfer'
  "
assert_equals \
  "liquidity-distribution tables" \
  "2" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = DATABASE()
     AND table_name IN (
       'stock_scaled_market_liquidity_distribution_plan',
       'stock_scaled_market_liquidity_distribution_source_order'
     )
  "
assert_equals \
  "liquidity-distribution open-slot column" \
  "1" \
  "
  SELECT COUNT(*)
    FROM information_schema.columns
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_scaled_market_liquidity_distribution_plan'
     AND column_name = 'open_slot'
  "
assert_equals \
  "liquidity-distribution open-slot unique index" \
  "1" \
  "
  SELECT COUNT(DISTINCT index_name)
    FROM information_schema.statistics
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_scaled_market_liquidity_distribution_plan'
     AND index_name = 'uk_stock_scaled_liquidity_distribution_open_slot'
     AND non_unique = 0
  "
assert_equals \
  "invalid liquidity-distribution open slots" \
  "0" \
  "
  SELECT COUNT(*)
    FROM stock_scaled_market_liquidity_distribution_plan
   WHERE (
     status IN ('DRAFT', 'SCHEDULED', 'ACTIVE')
     AND (open_slot IS NULL OR open_slot <> 1)
   )
      OR (
        status IN ('COMPLETED', 'FAILED')
        AND open_slot IS NOT NULL
      )
  "
assert_equals \
  "invalid role-transfer origins" \
  "0" \
  "
  SELECT COUNT(*)
    FROM stock_order_strategy_origin
   WHERE role_transfer_plan_id IS NOT NULL
     AND (
       role_transfer_plan_id <= 0
       OR origin_type <> 'LIQUIDITY_PROVIDER'
       OR liquidity_mandate_id IS NULL
     )
  "

printf 'PASS isolated liquidity-distribution migration completed idempotently\n'
