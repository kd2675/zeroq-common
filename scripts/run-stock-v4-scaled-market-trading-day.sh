#!/usr/bin/env bash

set -euo pipefail

if [[ "${STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_DAY:-}" != "YES" ]]; then
  printf 'FAIL scaled-market day requires STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_DAY=YES\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA:?STOCK_MYSQL_REPLAY_BATCH_SCHEMA is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
TARGET_ENVIRONMENT="${STOCK_V4_TARGET_ENVIRONMENT:-replay}"
OPERATING_BATCH_ALLOW=""
BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30493}"
BATCH_PORT="${STOCK_V4_REPLAY_BATCH_PORT:-30491}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
POLL_SECONDS="${STOCK_V4_REPLAY_TRADING_POLL_SECONDS:-5}"
TIMEOUT_SECONDS="${STOCK_V4_REPLAY_TRADING_TIMEOUT_SECONDS:-4500}"
EXPECTED_DAY_SECONDS="${STOCK_V4_REPLAY_EXPECTED_REAL_SECONDS_PER_DAY:-7200}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"
JQ_BIN="$(command -v jq || true)"
CHECK_ONLY=false
RESUME_DAY=false

if [[ "${1:-}" == "--check-only" ]]; then
  CHECK_ONLY=true
elif [[ "${1:-}" == "--resume" ]]; then
  RESUME_DAY=true
elif [[ $# -gt 0 ]]; then
  printf 'FAIL unsupported argument: %s\n' "$1" >&2
  exit 1
fi

if [[ "${TARGET_ENVIRONMENT}" == "operating" ]]; then
  if [[ "${STOCK_V4_OPERATING_ALLOW_SCALED_MARKET_DAY:-}" != "YES" ]]; then
    printf 'FAIL operating scaled-market day requires STOCK_V4_OPERATING_ALLOW_SCALED_MARKET_DAY=YES\n' >&2
    exit 1
  fi
  if [[ "${REPLAY_SCHEMA}" != "STOCK_SERVICE" \
      || "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" != "STOCK_BATCH_METADATA" ]]; then
    printf 'FAIL operating scaled-market day requires exact STOCK_SERVICE and STOCK_BATCH_METADATA schemas\n' >&2
    exit 1
  fi
  OPERATING_BATCH_ALLOW="YES"
elif [[ "${TARGET_ENVIRONMENT}" == "replay" ]]; then
  if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
      || [[ "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
    printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
    exit 1
  fi
  if [[ ! "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$ ]]; then
    printf 'FAIL replay batch schema must match STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+\n' >&2
    exit 1
  fi
else
  printf 'FAIL STOCK_V4_TARGET_ENVIRONMENT must be replay or operating\n' >&2
  exit 1
fi
if [[ "${REPLAY_SCHEMA}" == "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" ]]; then
  printf 'FAIL business and batch metadata schemas must be different\n' >&2
  exit 1
fi
if [[ ! "${BATCH_PORT}" =~ ^[0-9]+$ ]] \
    || (( BATCH_PORT < 1024 || BATCH_PORT > 65535 )); then
  printf 'FAIL STOCK_V4_REPLAY_BATCH_PORT must be between 1024 and 65535\n' >&2
  exit 1
fi
if [[ ! "${POLL_SECONDS}" =~ ^[1-9][0-9]*$ || "${POLL_SECONDS}" -gt 30 ]]; then
  printf 'FAIL STOCK_V4_REPLAY_TRADING_POLL_SECONDS must be between 1 and 30\n' >&2
  exit 1
fi
if [[ ! "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ \
    || "${TIMEOUT_SECONDS}" -lt 60 || "${TIMEOUT_SECONDS}" -gt 10800 ]]; then
  printf 'FAIL STOCK_V4_REPLAY_TRADING_TIMEOUT_SECONDS must be between 60 and 10800\n' >&2
  exit 1
fi
if [[ ! "${EXPECTED_DAY_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL STOCK_V4_REPLAY_EXPECTED_REAL_SECONDS_PER_DAY must be positive\n' >&2
  exit 1
fi
if [[ -z "${JQ_BIN}" || ! -x "${JQ_BIN}" ]]; then
  printf 'FAIL jq was not found\n' >&2
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
  "--connect-timeout=10"
  "--ssl-mode=DISABLED"
  "--default-character-set=utf8mb4"
  "--batch"
  "--skip-column-names"
)

mysql_query() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" \
    "${REPLAY_SCHEMA}" --execute="$1"
}

clock_response() {
  curl -sS \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    "${BACK_URL}/api/stock/v1/markets/simulation-clock"
}

require_success_json() {
  local label="$1"
  local response="$2"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e '.success == true' >/dev/null; then
    printf 'FAIL %s response=%s\n' "${label}" "${response}" >&2
    exit 1
  fi
}

batch_pid=""
batch_log=""
lock_dir="/tmp/stock-v4-scaled-market-day-${REPLAY_SCHEMA}.lock"

assert_batch_log_clean() {
  if [[ -z "${batch_log}" || ! -f "${batch_log}" ]]; then
    return 0
  fi
  if rg -q 'Stock batch execution failed:|Order-book execution worker run failed:|Order-book ready-symbol reconciliation worker failed:|Order-book execution worker gate refresh failed:| ERROR ' "${batch_log}"; then
    printf 'FAIL scaled-market batch log contains a failed job or ERROR: log=%s\n' \
      "${batch_log}" >&2
    tail -n 100 "${batch_log}" >&2 || true
    return 1
  fi
}

assert_intraday_flow_invariants() {
  local invariant_result
  invariant_result="$(mysql_query "
    WITH day_execution AS (
      SELECT execution.symbol,
             SUM(CASE WHEN execution.side = 'BUY'
                 THEN execution.quantity ELSE 0 END) AS buy_quantity,
             SUM(CASE WHEN execution.side = 'SELL'
                 THEN execution.quantity ELSE 0 END) AS sell_quantity
        FROM stock_execution execution
        JOIN stock_order matched_order
          ON matched_order.id = execution.order_id
       WHERE execution.source = 'INTERNAL_ORDER_BOOK'
         AND execution.executed_at >= '${trading_date} 00:00:00'
         AND execution.executed_at < DATE_ADD('${trading_date} 00:00:00', INTERVAL 1 DAY)
         AND COALESCE(matched_order.origin_type, '') <> 'MARKET_RECONSTRUCTION'
         AND NOT EXISTS (
           SELECT 1
             FROM stock_scaled_market_role_redistribution_order_link transfer_link
            WHERE transfer_link.order_id = matched_order.id
         )
       GROUP BY execution.symbol
    ),
    controlled_open AS (
      SELECT open_order.symbol,
             SUM(CASE WHEN open_order.side = 'BUY'
                 THEN open_order.quantity - open_order.filled_quantity ELSE 0 END)
                 AS buy_quantity,
             SUM(CASE WHEN open_order.side = 'SELL'
                 THEN open_order.quantity - open_order.filled_quantity ELSE 0 END)
                 AS sell_quantity
        FROM stock_order open_order
       WHERE open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
         AND open_order.market_type = 'ORDER_BOOK'
         AND COALESCE(open_order.origin_type, '') <> 'MARKET_RECONSTRUCTION'
         AND NOT EXISTS (
           SELECT 1
             FROM stock_scaled_market_role_redistribution_order_link transfer_link
            WHERE transfer_link.order_id = open_order.id
         )
       GROUP BY open_order.symbol
    )
    SELECT CONCAT(
             SUM(CASE
                   WHEN COALESCE(day_execution.buy_quantity, 0)
                          + COALESCE(controlled_open.buy_quantity, 0)
                          > target.target_daily_volume
                     OR COALESCE(day_execution.sell_quantity, 0)
                          + COALESCE(controlled_open.sell_quantity, 0)
                          > target.target_daily_volume
                   THEN 1 ELSE 0 END),
             '|',
             COALESCE(SUM(
               day_execution.buy_quantity - day_execution.sell_quantity
             ), 0),
             '|',
             (SELECT COUNT(*)
                FROM stock_order
               WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
                 AND (
                   quantity <= filled_quantity
                   OR (side = 'BUY' AND reserved_cash <= 0)
                   OR (side = 'SELL' AND reserved_cash <> 0)
                 ))
           )
      FROM stock_scaled_market_symbol_target target
      JOIN stock_scaled_market_contract contract
        ON contract.contract_version = target.contract_version
       AND contract.status = 'ACTIVE'
      LEFT JOIN day_execution
        ON day_execution.symbol = target.symbol
      LEFT JOIN controlled_open
        ON controlled_open.symbol = target.symbol
     WHERE target.lifecycle_status IN ('MATURE', 'STRESS')
  ")"
  if [[ "${invariant_result}" != "0|0|0" ]]; then
    printf 'FAIL scaled-market intraday invariants expected=0|0|0 actual=%s\n' \
      "${invariant_result}" >&2
    return 1
  fi
  printf 'PASS scaled-market intraday invariants targetBreaches|sideImbalance|invalidReservations=%s\n' \
    "${invariant_result}"
}

stop_batch() {
  if [[ -z "${batch_pid}" ]]; then
    return 0
  fi
  if kill -0 "${batch_pid}" 2>/dev/null; then
    kill "${batch_pid}" 2>/dev/null || true
    wait "${batch_pid}" 2>/dev/null || true
  fi
  local started_at
  started_at="$(date +%s)"
  while curl -fsS --max-time 1 \
      "http://127.0.0.1:${BATCH_PORT}/actuator/health" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started_at >= 60 )); then
      printf 'FAIL replay batch did not stop: port=%s log=%s\n' \
        "${BATCH_PORT}" "${batch_log}" >&2
      return 1
    fi
    sleep 1
  done
  printf 'PASS scaled-market trading batch stopped port=%s log=%s\n' \
    "${BATCH_PORT}" "${batch_log}"
  batch_pid=""
}

cleanup() {
  stop_batch || true
  rmdir "${lock_dir}" 2>/dev/null || true
}

if curl -fsS --max-time 1 \
    "http://127.0.0.1:${BATCH_PORT}/actuator/health" >/dev/null 2>&1; then
  printf 'FAIL replay batch port is already active: %s\n' "${BATCH_PORT}" >&2
  exit 1
fi

initial_clock="$(clock_response)"
require_success_json 'scaled-market opening clock' "${initial_clock}"
if [[ "${RESUME_DAY}" == "true" ]]; then
  if [[ "${STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_RESUME:-}" != "YES" ]]; then
    printf 'FAIL scaled-market day resume requires STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_RESUME=YES\n' >&2
    exit 1
  fi
  if ! printf '%s' "${initial_clock}" | "${JQ_BIN}" -e \
      --argjson expectedDaySeconds "${EXPECTED_DAY_SECONDS}" \
      '.data.marketSession == "REGULAR"
        and .data.running == false
        and .data.marketOpenReady == true
        and .data.activeBusinessDate == .data.simulationDate
        and (.data.simulationDateTime[11:19] >= "06:00:00")
        and (.data.simulationDateTime[11:19] < "18:00:00")
        and .data.realSecondsPerSimulationDay == $expectedDaySeconds' >/dev/null; then
    printf 'FAIL scaled-market resume requires stopped aligned REGULAR state before 18:00 response=%s\n' \
      "${initial_clock}" >&2
    exit 1
  fi
else
  if ! printf '%s' "${initial_clock}" | "${JQ_BIN}" -e \
      --argjson expectedDaySeconds "${EXPECTED_DAY_SECONDS}" \
      '.data.marketSession == "REGULAR"
        and .data.running == false
        and .data.marketOpenReady == true
        and .data.activeBusinessDate == .data.simulationDate
        and (.data.simulationDateTime | endswith("T06:00:00"))
        and .data.realSecondsPerSimulationDay == $expectedDaySeconds' >/dev/null; then
    printf 'FAIL scaled-market day requires stopped 06:00 REGULAR state at the unchanged clock speed response=%s\n' \
      "${initial_clock}" >&2
    exit 1
  fi
fi

trading_date="$(printf '%s' "${initial_clock}" | "${JQ_BIN}" -r '.data.simulationDate')"
if [[ "${RESUME_DAY}" == "true" ]]; then
  baseline_order_id="$(mysql_query "SELECT COALESCE(MAX(id), 0) FROM stock_order WHERE created_at < '${trading_date} 00:00:00'")"
  baseline_execution_id="$(mysql_query "SELECT COALESCE(MAX(id), 0) FROM stock_execution WHERE executed_at < '${trading_date} 00:00:00'")"
  baseline_intent_id="$(mysql_query "SELECT COALESCE(MAX(id), 0) FROM stock_auto_participant_order_intent WHERE simulation_trade_date < '${trading_date}'")"
else
  baseline_order_id="$(mysql_query 'SELECT COALESCE(MAX(id), 0) FROM stock_order')"
  baseline_execution_id="$(mysql_query 'SELECT COALESCE(MAX(id), 0) FROM stock_execution')"
  baseline_intent_id="$(mysql_query 'SELECT COALESCE(MAX(id), 0) FROM stock_auto_participant_order_intent')"
fi

printf 'PASS scaled-market day preflight date=%s orderId=%s executionId=%s intentId=%s speed=%s\n' \
  "${trading_date}" "${baseline_order_id}" "${baseline_execution_id}" \
  "${baseline_intent_id}" "${EXPECTED_DAY_SECONDS}"

batch_mode_argument="--scaled-market-trading"
if [[ "${RESUME_DAY}" == "true" ]]; then
  batch_mode_argument="--resume-scaled-market-trading"
fi
STOCK_V4_OPERATING_ALLOW_BATCH="${OPERATING_BATCH_ALLOW}" \
STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_TRADING=YES \
  bash "${SCRIPT_DIR}/run-stock-v4-replay-batch.sh" \
    --check-only "${batch_mode_argument}"

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS scaled-market day check-only completed without changing the clock or ledgers\n'
  exit 0
fi

if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another scaled-market day runner owns %s\n' "${lock_dir}" >&2
  exit 1
fi
trap cleanup EXIT INT TERM

batch_log="/tmp/stock-v4-scaled-market-day-${BATCH_PORT}-$$.log"
STOCK_V4_REPLAY_BATCH_PORT="${BATCH_PORT}" \
STOCK_V4_OPERATING_ALLOW_BATCH="${OPERATING_BATCH_ALLOW}" \
STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_TRADING=YES \
  bash "${SCRIPT_DIR}/run-stock-v4-replay-batch.sh" \
    "${batch_mode_argument}" >"${batch_log}" 2>&1 &
batch_pid=$!

started_at="$(date +%s)"
while true; do
  if curl -fsS --max-time 2 \
      "http://127.0.0.1:${BATCH_PORT}/actuator/health" \
      | "${JQ_BIN}" -e '.status == "UP"' >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${batch_pid}" 2>/dev/null; then
    printf 'FAIL replay batch exited before health UP: log=%s\n' "${batch_log}" >&2
    tail -n 100 "${batch_log}" >&2 || true
    exit 1
  fi
  assert_batch_log_clean
  if (( "$(date +%s)" - started_at >= 180 )); then
    printf 'FAIL replay batch health timed out: log=%s\n' "${batch_log}" >&2
    tail -n 100 "${batch_log}" >&2 || true
    exit 1
  fi
  sleep 2
done
printf 'PASS scaled-market trading batch started port=%s pid=%s log=%s\n' \
  "${BATCH_PORT}" "${batch_pid}" "${batch_log}"

last_reported_hour=""
while true; do
  response="$(clock_response)"
  require_success_json 'scaled-market running clock' "${response}"
  simulation_date_time="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.simulationDateTime')"
  simulation_date="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.simulationDate')"
  market_session="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.marketSession')"
  running="$(printf '%s' "${response}" | "${JQ_BIN}" -r '.data.running')"

  if [[ "${simulation_date}" != "${trading_date}" ]]; then
    printf 'FAIL trading date advanced unexpectedly expected=%s actual=%s\n' \
      "${trading_date}" "${simulation_date}" >&2
    exit 1
  fi
  if [[ "${market_session}" == "AFTER_CLOSE" ]]; then
    printf 'PASS scaled-market regular session reached close simulationDateTime=%s\n' \
      "${simulation_date_time}"
    break
  fi
  if [[ "${market_session}" != "REGULAR" || "${running}" != "true" ]]; then
    printf 'FAIL scaled-market clock left running REGULAR state response=%s\n' \
      "${response}" >&2
    exit 1
  fi
  if ! kill -0 "${batch_pid}" 2>/dev/null; then
    printf 'FAIL replay batch exited during trading: log=%s\n' "${batch_log}" >&2
    tail -n 100 "${batch_log}" >&2 || true
    exit 1
  fi
  assert_batch_log_clean

  simulation_hour="${simulation_date_time:11:2}"
  if [[ "${simulation_hour}" != "${last_reported_hour}" ]]; then
    assert_intraday_flow_invariants
    printf 'INFO scaled-market trading progress simulationDateTime=%s\n' \
      "${simulation_date_time}"
    last_reported_hour="${simulation_hour}"
  fi
  if (( "$(date +%s)" - started_at >= TIMEOUT_SECONDS )); then
    printf 'FAIL scaled-market trading timed out after %ss response=%s\n' \
      "${TIMEOUT_SECONDS}" "${response}" >&2
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done

assert_batch_log_clean
assert_intraday_flow_invariants
stop_batch
printf 'PASS scaled-market batch log has no failed jobs or ERROR entries\n'

shutdown_started_at="$(date +%s)"
while true; do
  closed_clock="$(clock_response)"
  require_success_json 'scaled-market stopped close clock' "${closed_clock}"
  if printf '%s' "${closed_clock}" | "${JQ_BIN}" -e \
      --arg tradingDate "${trading_date}" \
      '.data.marketSession == "AFTER_CLOSE"
        and .data.running == false
        and .data.simulationDate == $tradingDate
        and .data.activeBusinessDate == $tradingDate' >/dev/null; then
    break
  fi
  if (( "$(date +%s)" - shutdown_started_at >= 60 )); then
    printf 'FAIL scaled-market batch shutdown did not preserve stopped close state response=%s\n' \
      "${closed_clock}" >&2
    exit 1
  fi
  sleep 1
done
printf 'PASS scaled-market stopped close state simulationDateTime=%s\n' \
  "$(printf '%s' "${closed_clock}" | "${JQ_BIN}" -r '.data.simulationDateTime')"

order_result="$(mysql_query "
  SELECT CONCAT(
           COUNT(*), '|',
           COALESCE(SUM(quantity), 0), '|',
           SUM(CASE WHEN status = 'FILLED' THEN 1 ELSE 0 END), '|',
           SUM(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END)
         )
    FROM stock_order
   WHERE id > ${baseline_order_id}
")"
execution_result="$(mysql_query "
  SELECT CONCAT(
           COUNT(*), '|',
           COALESCE(SUM(CASE WHEN side = 'BUY' THEN quantity ELSE 0 END), 0), '|',
           COALESCE(SUM(CASE WHEN side = 'BUY' THEN gross_amount ELSE 0 END), 0)
         )
    FROM stock_execution
   WHERE id > ${baseline_execution_id}
")"
intent_result="$(mysql_query "
  SELECT CONCAT(
           COUNT(*), '|',
           SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END), '|',
           SUM(CASE WHEN status = 'ACTIVE' THEN 1 ELSE 0 END)
         )
    FROM stock_auto_participant_order_intent
   WHERE id > ${baseline_intent_id}
")"

printf 'PASS scaled-market raw day result orders=count|quantity|filled|cancelled=%s\n' \
  "${order_result}"
printf 'PASS scaled-market raw day result executions=rows|buyQuantity|buyTurnover=%s\n' \
  "${execution_result}"
printf 'PASS scaled-market raw day result intents=count|completed|active=%s\n' \
  "${intent_result}"
printf 'PASS scaled-market regular day stopped for EOD date=%s log=%s\n' \
  "${trading_date}" "${batch_log}"

trap - EXIT INT TERM
rmdir "${lock_dir}" 2>/dev/null || true
