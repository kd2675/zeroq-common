#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"
: "${STOCK_V4_REPLAY_BATCH_URL:?STOCK_V4_REPLAY_BATCH_URL is required}"
: "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID:?STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_DAY:-}" != "YES" ]]; then
  printf 'FAIL role-redistribution day requires STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_DAY=YES\n' >&2
  exit 1
fi
TARGET_ENVIRONMENT="${STOCK_V4_TARGET_ENVIRONMENT:-replay}"
if [[ "${TARGET_ENVIRONMENT}" == "operating" ]]; then
  if [[ "${STOCK_V4_OPERATING_ALLOW_ROLE_REDISTRIBUTION_DAY:-}" != "YES" ]]; then
    printf 'FAIL operating role-redistribution day requires STOCK_V4_OPERATING_ALLOW_ROLE_REDISTRIBUTION_DAY=YES\n' >&2
    exit 1
  fi
  if [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" != "STOCK_SERVICE" ]]; then
    printf 'FAIL operating role-redistribution day requires exact STOCK_SERVICE schema\n' >&2
    exit 1
  fi
elif [[ "${TARGET_ENVIRONMENT}" == "replay" ]]; then
  if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
      || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
    printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
    exit 1
  fi
else
  printf 'FAIL STOCK_V4_TARGET_ENVIRONMENT must be replay or operating\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL role-redistribution plan id must be a positive integer\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
BATCH_URL="${STOCK_V4_REPLAY_BATCH_URL%/}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
PLAN_ID="${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID}"
MAX_PAIRS="${STOCK_V4_REPLAY_MAX_ROLE_REDISTRIBUTION_PAIRS:-10000}"
BULK_COMPLETION="${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_BULK_COMPLETION:-false}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"
JQ_BIN="$(command -v jq || true)"

if [[ -z "${MYSQL_BIN}" || ! -x "${MYSQL_BIN}" ]]; then
  printf 'FAIL mysql client was not found; set STOCK_MYSQL_BIN\n' >&2
  exit 1
fi
if [[ -z "${JQ_BIN}" || ! -x "${JQ_BIN}" ]]; then
  printf 'FAIL jq was not found\n' >&2
  exit 1
fi
if [[ ! "${MAX_PAIRS}" =~ ^[1-9][0-9]*$ ]] \
    || (( MAX_PAIRS > 100000 )); then
  printf 'FAIL role-redistribution pair guard must be between 1 and 100000\n' >&2
  exit 1
fi
if [[ "${BULK_COMPLETION}" != "true" \
    && "${BULK_COMPLETION}" != "false" ]]; then
  printf 'FAIL role-redistribution bulk completion must be true or false\n' >&2
  exit 1
fi
if [[ "${BULK_COMPLETION}" == "true" \
    && "${STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_BULK_COMPLETION:-}" != "YES" ]]; then
  printf 'FAIL bulk role redistribution requires STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_BULK_COMPLETION=YES\n' >&2
  exit 1
fi
if [[ "${TARGET_ENVIRONMENT}" == "operating" \
    && "${BULK_COMPLETION}" == "true" ]]; then
  printf 'FAIL operating role redistribution forbids bulk completion\n' >&2
  exit 1
fi

if [[ "${BULK_COMPLETION}" == "true" ]]; then
  bulk_completion_sql="TRUE"
else
  bulk_completion_sql="FALSE"
fi

MYSQL_CONNECTION_ARGS=(
  "--host=${STOCK_MYSQL_HOST}"
  "--port=${STOCK_MYSQL_PORT}"
  "--user=${STOCK_MYSQL_USER}"
  "--connect-timeout=10"
  "--ssl-mode=DISABLED"
  "--default-character-set=utf8mb4"
  "--batch"
  "--raw"
  "--skip-column-names"
)

mysql_query() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" --execute="$1"
}

require_success_json() {
  local label="$1"
  local response="$2"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
      '.success == true' >/dev/null; then
    printf 'FAIL %s response=%s\n' "${label}" "${response}" >&2
    exit 1
  fi
}

run_batch_job() {
  local label="$1"
  local path="$2"
  local response
  response="$(curl -sS -X POST \
    -H "X-Internal-Token: ${STOCK_BATCH_INTERNAL_TOKEN}" \
    "${BATCH_URL}${path}")"
  require_success_json "${label}" "${response}"
}

legacy_plan_state_row() {
  local trade_date="$1"
  mysql_query "
    SELECT redistribution.status,
           redistribution.contract_version,
           redistribution.role_capacity_plan_id,
           redistribution.target_transfer_quantity,
           redistribution.target_transfer_amount,
           redistribution.effective_business_date,
           COALESCE(redistribution.open_slot, 0),
           redistribution.state_reason,
           contract.status,
           role_rebase.status,
           (SELECT COALESCE(SUM(allocation.target_quantity), 0)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
             WHERE allocation.plan_id = redistribution.plan_id),
           (SELECT COALESCE(SUM(execution.quantity), 0)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
              JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                ON execution.order_id = order_link.order_id
               AND execution.side = 'BUY'
               AND execution.source = 'INTERNAL_ORDER_BOOK'
             WHERE order_link.plan_id = redistribution.plan_id
               AND order_link.side = 'BUY'),
           (SELECT COALESCE(SUM(execution.quantity), 0)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
              JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                ON execution.order_id = order_link.order_id
               AND execution.side = 'SELL'
               AND execution.source = 'INTERNAL_ORDER_BOOK'
             WHERE order_link.plan_id = redistribution.plan_id
               AND order_link.side = 'SELL'),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link
             WHERE plan_id = redistribution.plan_id),
           (SELECT COUNT(DISTINCT pair_id)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link
             WHERE plan_id = redistribution.plan_id),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
              JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_order
                ON open_order.id = order_link.order_id
               AND open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
               AND open_order.quantity > open_order.filled_quantity
             WHERE order_link.plan_id = redistribution.plan_id),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
              JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order linked_order
                ON linked_order.id = order_link.order_id
             WHERE order_link.plan_id = redistribution.plan_id
               AND (
                 linked_order.origin_type <> 'MARKET_RECONSTRUCTION'
                 OR linked_order.account_id <> order_link.order_account_id
                 OR linked_order.symbol <> order_link.symbol
                 OR linked_order.side <> order_link.side
                 OR linked_order.quantity <> order_link.submitted_quantity
                 OR linked_order.limit_price <> order_link.reference_price
               )),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
              JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                ON execution.order_id = order_link.order_id
             WHERE order_link.plan_id = redistribution.plan_id
               AND (
                 execution.source <> 'INTERNAL_ORDER_BOOK'
                 OR execution.side <> order_link.side
                 OR execution.price <> order_link.reference_price
                 OR execution.fee_amount <> 0
                 OR execution.tax_amount <> 0
               )),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order affected_order
             WHERE affected_order.created_at >= redistribution.activated_at
               AND affected_order.account_id IN (
                 SELECT source_lp_account_id
                   FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan
                  WHERE plan_id = redistribution.plan_id
                 UNION
                 SELECT account_id
                   FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan
                  WHERE plan_id = redistribution.plan_id
               )
               AND NOT EXISTS (
                 SELECT 1
                   FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
                  WHERE order_link.plan_id = redistribution.plan_id
                    AND order_link.order_id = affected_order.id
               )),
           (SELECT COALESCE(SUM(holding.reserved_quantity), 0)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
             WHERE holding.account_id IN (
               SELECT source_lp_account_id
                 FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan
                WHERE plan_id = redistribution.plan_id
               UNION
               SELECT account_id
                 FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan
                WHERE plan_id = redistribution.plan_id
             )),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
             WHERE allocation.plan_id = redistribution.plan_id
               AND allocation.target_quantity > (
                 SELECT COALESCE(SUM(execution.quantity), 0)
                   FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
                   JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                     ON execution.order_id = order_link.order_id
                    AND execution.side = 'BUY'
                    AND execution.source = 'INTERNAL_ORDER_BOOK'
                  WHERE order_link.plan_id = allocation.plan_id
                    AND order_link.symbol = allocation.symbol
                    AND order_link.target_account_id = allocation.target_account_id
                    AND order_link.side = 'BUY'
               )),
           COALESCE((
             SELECT MIN(allocation.symbol)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
               JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
                 ON target.contract_version = redistribution.contract_version
                AND target.symbol = allocation.symbol
              WHERE allocation.plan_id = redistribution.plan_id
                AND allocation.target_quantity > (
                  SELECT COALESCE(SUM(execution.quantity), 0)
                    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
                    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                      ON execution.order_id = order_link.order_id
                     AND execution.side = 'BUY'
                     AND execution.source = 'INTERNAL_ORDER_BOOK'
                   WHERE order_link.plan_id = allocation.plan_id
                     AND order_link.symbol = allocation.symbol
                     AND order_link.target_account_id = allocation.target_account_id
                     AND order_link.side = 'BUY'
                )
                AND target.target_daily_volume > (
                  SELECT COALESCE(SUM(execution.quantity), 0)
                    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                   WHERE execution.symbol = allocation.symbol
                     AND execution.side = 'BUY'
                     AND execution.source = 'INTERNAL_ORDER_BOOK'
                     AND execution.executed_at >= '${trade_date} 00:00:00'
                     AND execution.executed_at < DATE_ADD(
                       '${trade_date} 00:00:00', INTERVAL 1 DAY
                     )
                )
           ), '__NONE__'),
           (SELECT COALESCE(SUM(LEAST(
                     source.target_transfer_quantity - COALESCE((
                       SELECT SUM(execution.quantity)
                         FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
                         JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                           ON execution.order_id = order_link.order_id
                          AND execution.side = 'BUY'
                          AND execution.source = 'INTERNAL_ORDER_BOOK'
                        WHERE order_link.plan_id = source.plan_id
                          AND order_link.symbol = source.symbol
                          AND order_link.side = 'BUY'
                     ), 0),
                     GREATEST(target.target_daily_volume - COALESCE((
                       SELECT SUM(execution.quantity)
                         FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                        WHERE execution.symbol = source.symbol
                          AND execution.side = 'BUY'
                          AND execution.source = 'INTERNAL_ORDER_BOOK'
                          AND execution.executed_at >= '${trade_date} 00:00:00'
                          AND execution.executed_at < DATE_ADD(
                            '${trade_date} 00:00:00', INTERVAL 1 DAY
                          )
                     ), 0), 0)
                   )), 0)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
              JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
                ON target.contract_version = redistribution.contract_version
               AND target.symbol = source.symbol
             WHERE source.plan_id = redistribution.plan_id)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract contract
        ON contract.contract_version = redistribution.contract_version
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan role_rebase
        ON role_rebase.plan_id = redistribution.role_capacity_plan_id
       AND role_rebase.rebase_stage = 'MARKET_ROLE_CAPACITY'
     WHERE redistribution.plan_id = ${PLAN_ID}
  "
}

plan_state_row() {
  local trade_date="$1"
  mysql_query "
    WITH plan_header AS (
      SELECT redistribution.plan_id,
             redistribution.status,
             redistribution.contract_version,
             redistribution.role_capacity_plan_id,
             redistribution.target_transfer_quantity,
             redistribution.target_transfer_amount,
             redistribution.effective_business_date,
             COALESCE(redistribution.open_slot, 0) AS open_slot,
             redistribution.state_reason,
             redistribution.activated_at,
             contract.status AS contract_status,
             role_rebase.status AS role_capacity_status
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract contract
          ON contract.contract_version = redistribution.contract_version
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan role_rebase
          ON role_rebase.plan_id = redistribution.role_capacity_plan_id
         AND role_rebase.rebase_stage = 'MARKET_ROLE_CAPACITY'
       WHERE redistribution.plan_id = ${PLAN_ID}
    ), affected_account AS (
      SELECT source_lp_account_id AS account_id
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan
       WHERE plan_id = ${PLAN_ID}
      UNION
      SELECT account_id
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan
       WHERE plan_id = ${PLAN_ID}
    ), link_count_state AS (
      SELECT COUNT(*) AS linked_order_count,
             COUNT(DISTINCT pair_id) AS linked_pair_count
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link
       WHERE plan_id = ${PLAN_ID}
    ), linked_order_state AS (
      SELECT COALESCE(SUM(CASE
                 WHEN linked_order.status IN (
                   'PENDING',
                   'PARTIALLY_FILLED'
                 )
                  AND linked_order.quantity >
                      linked_order.filled_quantity
                 THEN 1 ELSE 0 END), 0) AS open_order_count,
             COALESCE(SUM(CASE
                 WHEN linked_order.origin_type <>
                        'MARKET_RECONSTRUCTION'
                   OR linked_order.account_id <>
                        order_link.order_account_id
                   OR linked_order.symbol <> order_link.symbol
                   OR linked_order.side <> order_link.side
                   OR linked_order.quantity <>
                        order_link.submitted_quantity
                   OR linked_order.limit_price <>
                        order_link.reference_price
                 THEN 1 ELSE 0 END), 0) AS invalid_link_count
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order linked_order
          ON linked_order.id = order_link.order_id
       WHERE order_link.plan_id = ${PLAN_ID}
    ), linked_execution_state AS (
      SELECT COALESCE(SUM(CASE
                 WHEN order_link.side = 'BUY'
                  AND execution.side = 'BUY'
                  AND execution.source = 'INTERNAL_ORDER_BOOK'
                 THEN execution.quantity ELSE 0 END), 0)
               AS buy_quantity,
             COALESCE(SUM(CASE
                 WHEN order_link.side = 'SELL'
                  AND execution.side = 'SELL'
                  AND execution.source = 'INTERNAL_ORDER_BOOK'
                 THEN execution.quantity ELSE 0 END), 0)
               AS sell_quantity,
             COALESCE(SUM(CASE
                 WHEN execution.source <> 'INTERNAL_ORDER_BOOK'
                   OR execution.side <> order_link.side
                   OR execution.price <> order_link.reference_price
                   OR execution.fee_amount <> 0
                   OR execution.tax_amount <> 0
                 THEN 1 ELSE 0 END), 0)
               AS invalid_execution_count
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
          ON execution.order_id = order_link.order_id
       WHERE order_link.plan_id = ${PLAN_ID}
    ), allocation_fill AS (
      SELECT order_link.symbol,
             order_link.target_account_id,
             COALESCE(SUM(execution.quantity), 0) AS filled_quantity
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
          ON execution.order_id = order_link.order_id
         AND execution.side = 'BUY'
         AND execution.source = 'INTERNAL_ORDER_BOOK'
       WHERE order_link.plan_id = ${PLAN_ID}
         AND order_link.side = 'BUY'
       GROUP BY order_link.symbol,
                order_link.target_account_id
    ), symbol_fill AS (
      SELECT order_link.symbol,
             COALESCE(SUM(execution.quantity), 0) AS filled_quantity
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
          ON execution.order_id = order_link.order_id
         AND execution.side = 'BUY'
         AND execution.source = 'INTERNAL_ORDER_BOOK'
       WHERE order_link.plan_id = ${PLAN_ID}
         AND order_link.side = 'BUY'
       GROUP BY order_link.symbol
    ), daily_symbol_fill AS (
      SELECT execution.symbol,
             COALESCE(SUM(execution.quantity), 0) AS filled_quantity
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
       WHERE execution.side = 'BUY'
         AND execution.source = 'INTERNAL_ORDER_BOOK'
         AND execution.executed_at >= '${trade_date} 00:00:00'
         AND execution.executed_at < DATE_ADD(
           '${trade_date} 00:00:00', INTERVAL 1 DAY
         )
       GROUP BY execution.symbol
    ), allocation_state AS (
      SELECT COUNT(*) AS remaining_allocation_count,
             COALESCE(MIN(CASE
               WHEN ${bulk_completion_sql}
                 OR target.target_daily_volume >
                    COALESCE(daily_fill.filled_quantity, 0)
               THEN allocation.symbol ELSE NULL END), '__NONE__')
               AS next_symbol
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
        JOIN plan_header header
          ON header.plan_id = allocation.plan_id
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
          ON target.contract_version = header.contract_version
         AND target.symbol = allocation.symbol
        LEFT JOIN allocation_fill fill
          ON fill.symbol = allocation.symbol
         AND fill.target_account_id = allocation.target_account_id
        LEFT JOIN daily_symbol_fill daily_fill
          ON daily_fill.symbol = allocation.symbol
       WHERE allocation.target_quantity >
             COALESCE(fill.filled_quantity, 0)
    ), day_capacity_state AS (
      SELECT COALESCE(SUM(CASE
               WHEN ${bulk_completion_sql} THEN GREATEST(
                 source.target_transfer_quantity -
                   COALESCE(symbol_fill.filled_quantity, 0),
                 0
               )
               ELSE LEAST(
                 source.target_transfer_quantity -
                   COALESCE(symbol_fill.filled_quantity, 0),
                 GREATEST(
                   target.target_daily_volume -
                     COALESCE(daily_fill.filled_quantity, 0),
                   0
                 )
               )
             END), 0) AS day_fill_capacity
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
        JOIN plan_header header
          ON header.plan_id = source.plan_id
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
          ON target.contract_version = header.contract_version
         AND target.symbol = source.symbol
        LEFT JOIN symbol_fill
          ON symbol_fill.symbol = source.symbol
        LEFT JOIN daily_symbol_fill daily_fill
          ON daily_fill.symbol = source.symbol
    ), unauthorized_state AS (
      SELECT COUNT(*) AS unauthorized_order_count
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order affected_order
        JOIN affected_account
          ON affected_account.account_id = affected_order.account_id
        JOIN plan_header header
          ON affected_order.created_at >= header.activated_at
        LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
          ON order_link.plan_id = header.plan_id
         AND order_link.order_id = affected_order.id
       WHERE order_link.order_id IS NULL
    ), reserved_state AS (
      SELECT COALESCE(SUM(holding.reserved_quantity), 0)
               AS affected_reserved_quantity
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
        JOIN affected_account
          ON affected_account.account_id = holding.account_id
    )
    SELECT header.status,
           header.contract_version,
           header.role_capacity_plan_id,
           header.target_transfer_quantity,
           header.target_transfer_amount,
           header.effective_business_date,
           header.open_slot,
           header.state_reason,
           header.contract_status,
           header.role_capacity_status,
           (SELECT COALESCE(SUM(allocation.target_quantity), 0)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
             WHERE allocation.plan_id = header.plan_id),
           execution_state.buy_quantity,
           execution_state.sell_quantity,
           link_count.linked_order_count,
           link_count.linked_pair_count,
           order_state.open_order_count,
           order_state.invalid_link_count,
           execution_state.invalid_execution_count,
           unauthorized.unauthorized_order_count,
           reserved.affected_reserved_quantity,
           allocation.remaining_allocation_count,
           allocation.next_symbol,
           capacity.day_fill_capacity
      FROM plan_header header
      CROSS JOIN link_count_state link_count
      CROSS JOIN linked_order_state order_state
      CROSS JOIN linked_execution_state execution_state
      CROSS JOIN unauthorized_state unauthorized
      CROSS JOIN reserved_state reserved
      CROSS JOIN allocation_state allocation
      CROSS JOIN day_capacity_state capacity
  "
}

load_plan_state() {
  local trade_date="$1"
  local row
  row="$(plan_state_row "${trade_date}")"
  if [[ -z "${row}" ]]; then
    printf 'FAIL role-redistribution plan state was not found: %s\n' \
      "${PLAN_ID}" >&2
    exit 1
  fi
  IFS=$'\t' read -r plan_status contract_version role_capacity_plan_id \
    target_quantity target_amount effective_business_date open_slot \
    state_reason contract_status role_capacity_status allocation_quantity \
    buy_quantity sell_quantity linked_order_count linked_pair_count \
    open_order_count invalid_link_count invalid_execution_count \
    unauthorized_order_count affected_reserved_quantity \
    remaining_allocation_count next_symbol day_fill_capacity <<< "${row}"
}

require_reconciled_state() {
  if [[ "${contract_status}" != "DRAFT" \
      || "${role_capacity_status}" != "APPLIED" ]]; then
    printf 'FAIL role-redistribution structural gate changed: contract=%s capacity=%s\n' \
      "${contract_status}" "${role_capacity_status}" >&2
    exit 1
  fi
  if (( allocation_quantity != target_quantity \
      || buy_quantity != sell_quantity \
      || buy_quantity > target_quantity \
      || linked_order_count != linked_pair_count * 2 \
      || ( open_order_count != 0 && open_order_count != 2 ) \
      || invalid_link_count != 0 \
      || invalid_execution_count != 0 \
      || unauthorized_order_count != 0 )); then
    printf 'FAIL role-redistribution ledger mismatch target=%s allocation=%s buy=%s sell=%s links=%s pairs=%s open=%s invalidLink=%s invalidExecution=%s unauthorized=%s\n' \
      "${target_quantity}" "${allocation_quantity}" \
      "${buy_quantity}" "${sell_quantity}" \
      "${linked_order_count}" "${linked_pair_count}" \
      "${open_order_count}" "${invalid_link_count}" \
      "${invalid_execution_count}" "${unauthorized_order_count}" >&2
    exit 1
  fi
}

lock_dir="/tmp/stock-v4-role-redistribution-day-${STOCK_MYSQL_REPLAY_SCHEMA}-${PLAN_ID}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another role-redistribution day runner owns %s\n' \
    "${lock_dir}" >&2
  exit 1
fi
cleanup() {
  local exit_code=$?
  rmdir "${lock_dir}" 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT

health_response="$(curl -sS "${BATCH_URL}/actuator/health")"
if [[ "$(printf '%s' "${health_response}" | "${JQ_BIN}" -r '.status // ""')" != "UP" ]]; then
  printf 'FAIL replay batch health is not UP response=%s\n' \
    "${health_response}" >&2
  exit 1
fi

clock_response="$(curl -sS \
  -H "X-User-Key: ${ADMIN_USER_KEY}" \
  -H 'X-User-Role: ADMIN' \
  "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
require_success_json 'simulation clock' "${clock_response}"
trade_date="$(printf '%s' "${clock_response}" | "${JQ_BIN}" -r \
  '.data.simulationDate')"
if ! printf '%s' "${clock_response}" | "${JQ_BIN}" -e \
    '.data.marketSession == "REGULAR"
     and .data.running == true
     and .data.activeBusinessDate == .data.simulationDate
     and .data.preparingBusinessDate == null
     and .data.postClosePhase == null
     and .data.postCloseStatus == null' >/dev/null; then
  printf 'FAIL role-redistribution day requires running aligned REGULAR state response=%s\n' \
    "${clock_response}" >&2
  exit 1
fi

load_plan_state "${trade_date}"
require_reconciled_state
if [[ "${plan_status}" != "ACTIVE" && "${plan_status}" != "COMPLETED" ]]; then
  printf 'FAIL role-redistribution day requires ACTIVE or COMPLETED plan: %s\n' \
    "${plan_status}" >&2
  exit 1
fi
if [[ "${plan_status}" == "ACTIVE" \
    && ( "${effective_business_date}" > "${trade_date}" \
      || "${open_slot}" != "1" ) ]]; then
  printf 'FAIL role-redistribution plan is not due at this opening: effective=%s tradeDate=%s openSlot=%s\n' \
    "${effective_business_date}" "${trade_date}" "${open_slot}" >&2
  exit 1
fi

initial_buy_quantity="${buy_quantity}"
initial_day_fill_capacity="${day_fill_capacity}"
initial_pair_count="${linked_pair_count}"
printf 'PASS role-redistribution day preflight date=%s plan=%s mode=%s target=%s filled=%s capacity=%s remainingAllocations=%s nextSymbol=%s\n' \
  "${trade_date}" "${PLAN_ID}" "${BULK_COMPLETION}" \
  "${target_quantity}" \
  "${buy_quantity}" "${initial_day_fill_capacity}" \
  "${remaining_allocation_count}" "${next_symbol}"

processed_pairs=0
while [[ "${plan_status}" != "COMPLETED" ]]; do
  if (( processed_pairs >= MAX_PAIRS )); then
    printf 'FAIL role-redistribution day exceeded pair guard: max=%s\n' \
      "${MAX_PAIRS}" >&2
    exit 1
  fi

  if (( open_order_count == 0 )); then
    if [[ "${next_symbol}" == "__NONE__" ]]; then
      break
    fi
    expected_symbol="${next_symbol}"
    run_batch_job \
      'role-redistribution paired-order job' \
      '/internal/stock-batch/v1/jobs/scaled-market-role-redistribution/run'
    load_plan_state "${trade_date}"
    require_reconciled_state
    if [[ "${plan_status}" == "COMPLETED" ]]; then
      break
    fi
    if (( open_order_count != 2 )); then
      printf 'FAIL role-redistribution did not create exactly one pair: expectedSymbol=%s open=%s state=%s\n' \
        "${expected_symbol}" "${open_order_count}" "${state_reason}" >&2
      exit 1
    fi
  fi

  run_batch_job \
    'role-redistribution execution job' \
    '/internal/stock-batch/v1/jobs/order-book-execution/run'
  load_plan_state "${trade_date}"
  require_reconciled_state
  if (( open_order_count != 0 || affected_reserved_quantity != 0 )); then
    printf 'FAIL role-redistribution pair left open orders or reservations: open=%s reserved=%s\n' \
      "${open_order_count}" "${affected_reserved_quantity}" >&2
    exit 1
  fi
  processed_pairs=$((processed_pairs + 1))
done

if [[ "${plan_status}" == "ACTIVE" && "${next_symbol}" == "__NONE__" ]]; then
  run_batch_job \
    'role-redistribution terminal-or-limit reconciliation job' \
    '/internal/stock-batch/v1/jobs/scaled-market-role-redistribution/run'
  load_plan_state "${trade_date}"
  require_reconciled_state
fi

filled_this_run=$((buy_quantity - initial_buy_quantity))
created_pairs=$((linked_pair_count - initial_pair_count))
if (( filled_this_run != initial_day_fill_capacity )); then
  printf 'FAIL role-redistribution day fill differs from exact bounded capacity: expected=%s actual=%s\n' \
    "${initial_day_fill_capacity}" "${filled_this_run}" >&2
  exit 1
fi
if (( open_order_count != 0 || affected_reserved_quantity != 0 )); then
  printf 'FAIL role-redistribution day left open orders or reservations: open=%s reserved=%s\n' \
    "${open_order_count}" "${affected_reserved_quantity}" >&2
  exit 1
fi
if [[ "${plan_status}" == "COMPLETED" ]]; then
  if (( buy_quantity != target_quantity \
      || remaining_allocation_count != 0 \
      || open_slot != 0 )); then
    printf 'FAIL completed role redistribution does not reconcile target=%s buy=%s remaining=%s openSlot=%s\n' \
      "${target_quantity}" "${buy_quantity}" \
      "${remaining_allocation_count}" "${open_slot}" >&2
    exit 1
  fi
elif [[ "${plan_status}" != "ACTIVE" || "${next_symbol}" != "__NONE__" ]]; then
  printf 'FAIL role-redistribution day ended before completion or daily exhaustion: status=%s next=%s state=%s\n' \
    "${plan_status}" "${next_symbol}" "${state_reason}" >&2
  exit 1
fi

printf 'PASS role-redistribution day complete date=%s plan=%s filledThisRun=%s totalFilled=%s/%s pairs=%s createdPairs=%s status=%s state=%s openOrders=0 reserved=0\n' \
  "${trade_date}" "${PLAN_ID}" "${filled_this_run}" \
  "${buy_quantity}" "${target_quantity}" "${processed_pairs}" \
  "${created_pairs}" "${plan_status}" "${state_reason}"
printf 'ROLE_REDISTRIBUTION_DAY_OK plan=%s date=%s filled=%s\n' \
  "${PLAN_ID}" "${trade_date}" "${filled_this_run}"
