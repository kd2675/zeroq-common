#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA:?STOCK_MYSQL_REPLAY_BATCH_SCHEMA is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"
: "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID:?STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_COMPLETION:-}" != "YES" ]]; then
  printf 'FAIL role-redistribution completion requires STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_COMPLETION=YES\n' >&2
  exit 1
fi
TARGET_ENVIRONMENT="${STOCK_V4_TARGET_ENVIRONMENT:-replay}"
OPERATING_BATCH_ALLOW=""
OPERATING_DAY_ALLOW=""
if [[ "${TARGET_ENVIRONMENT}" == "operating" ]]; then
  if [[ "${STOCK_V4_OPERATING_ALLOW_ROLE_REDISTRIBUTION_COMPLETION:-}" != "YES" ]]; then
    printf 'FAIL operating role-redistribution completion requires STOCK_V4_OPERATING_ALLOW_ROLE_REDISTRIBUTION_COMPLETION=YES\n' >&2
    exit 1
  fi
  if [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" != "STOCK_SERVICE" \
      || "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" != "STOCK_BATCH_METADATA" ]]; then
    printf 'FAIL operating role-redistribution completion requires exact STOCK_SERVICE and STOCK_BATCH_METADATA schemas\n' >&2
    exit 1
  fi
  OPERATING_BATCH_ALLOW="YES"
  OPERATING_DAY_ALLOW="YES"
elif [[ "${TARGET_ENVIRONMENT}" == "replay" ]]; then
  if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
      || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
    printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
    exit 1
  fi
  if [[ ! "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$ ]]; then
    printf 'FAIL batch replay schema must match STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+\n' >&2
    exit 1
  fi
else
  printf 'FAIL STOCK_V4_TARGET_ENVIRONMENT must be replay or operating\n' >&2
  exit 1
fi
if [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" == "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" ]]; then
  printf 'FAIL business and batch replay schemas must be different\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL role-redistribution plan id must be a positive integer\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
PLAN_ID="${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID}"
ROLE_PORT="${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_BATCH_PORT:-30492}"
EOD_PORT="${STOCK_V4_REPLAY_EOD_BATCH_PORT:-30491}"
START_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_BATCH_START_TIMEOUT_SECONDS:-120}"
PHASE_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_PHASE_TIMEOUT_SECONDS:-600}"
CLOCK_STOP_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_CLOCK_STOP_TIMEOUT_SECONDS:-30}"
MAX_TRADING_DAYS_OVERRIDE="${STOCK_V4_REPLAY_MAX_ROLE_REDISTRIBUTION_DAYS:-}"
BULK_COMPLETION="${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_BULK_COMPLETION:-false}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"
JQ_BIN="$(command -v jq || true)"
CHECK_ONLY=false

for argument in "$@"; do
  case "${argument}" in
    --check-only)
      CHECK_ONLY=true
      ;;
    *)
      printf 'FAIL unsupported argument: %s\n' "${argument}" >&2
      exit 1
      ;;
  esac
done

for port in "${ROLE_PORT}" "${EOD_PORT}"; do
  if [[ ! "${port}" =~ ^[0-9]+$ ]] \
      || (( port < 1024 || port > 65535 )); then
    printf 'FAIL replay batch port must be between 1024 and 65535: %s\n' \
      "${port}" >&2
    exit 1
  fi
done
if [[ "${ROLE_PORT}" == "${EOD_PORT}" ]]; then
  printf 'FAIL role-redistribution and EOD batch ports must be different\n' >&2
  exit 1
fi
if [[ ! "${START_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] \
    || (( START_TIMEOUT_SECONDS > 600 )); then
  printf 'FAIL batch start timeout must be between 1 and 600 seconds\n' >&2
  exit 1
fi
if [[ ! "${PHASE_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] \
    || (( PHASE_TIMEOUT_SECONDS > 1800 )); then
  printf 'FAIL phase timeout must be between 1 and 1800 seconds\n' >&2
  exit 1
fi
if [[ ! "${CLOCK_STOP_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] \
    || (( CLOCK_STOP_TIMEOUT_SECONDS > 120 )); then
  printf 'FAIL clock stop timeout must be between 1 and 120 seconds\n' >&2
  exit 1
fi
if [[ -n "${MAX_TRADING_DAYS_OVERRIDE}" ]] \
    && { [[ ! "${MAX_TRADING_DAYS_OVERRIDE}" =~ ^[1-9][0-9]*$ ]] \
      || (( MAX_TRADING_DAYS_OVERRIDE > 100 )); }; then
  printf 'FAIL role-redistribution trading-day override must be between 1 and 100\n' >&2
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
if [[ -z "${MYSQL_BIN}" || ! -x "${MYSQL_BIN}" ]]; then
  printf 'FAIL mysql client was not found; set STOCK_MYSQL_BIN\n' >&2
  exit 1
fi
if [[ -z "${JQ_BIN}" || ! -x "${JQ_BIN}" ]]; then
  printf 'FAIL jq was not found\n' >&2
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
  "--raw"
  "--skip-column-names"
)

mysql_query() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" --execute="$1"
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local query="$3"
  local actual
  actual="$(mysql_query "${query}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL %s expected=%s actual=%s\n' \
      "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf 'PASS %s = %s\n' "${label}" "${actual}"
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
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
      '.success == true' >/dev/null; then
    printf 'FAIL %s response=%s\n' "${label}" "${response}" >&2
    exit 1
  fi
}

require_regular_stopped_clock() {
  local response
  response="$(clock_response)"
  require_success_json 'regular clock preflight' "${response}"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
      '.data.marketSession == "REGULAR"
       and .data.running == false
       and .data.activeBusinessDate == .data.simulationDate
       and .data.preparingBusinessDate == null
       and .data.postClosePhase == null
       and .data.postCloseStatus == null' >/dev/null; then
    printf 'FAIL role-redistribution completion requires stopped aligned REGULAR state response=%s\n' \
      "${response}" >&2
    exit 1
  fi
  printf '%s' "${response}" | "${JQ_BIN}" -r '.data.activeBusinessDate'
}

plan_row() {
  mysql_query "
    SELECT redistribution.status,
           redistribution.contract_version,
           redistribution.role_capacity_plan_id,
           redistribution.target_transfer_quantity,
           redistribution.effective_business_date,
           COALESCE(redistribution.open_slot, 0),
           redistribution.state_reason,
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
             WHERE source.plan_id = redistribution.plan_id),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan recipient
             WHERE recipient.plan_id = redistribution.plan_id),
           (SELECT COUNT(*)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
             WHERE allocation.plan_id = redistribution.plan_id),
           (SELECT COALESCE(SUM(execution.quantity), 0)
              FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
              JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                ON execution.order_id = order_link.order_id
               AND execution.side = 'BUY'
               AND execution.source = 'INTERNAL_ORDER_BOOK'
             WHERE order_link.plan_id = redistribution.plan_id
               AND order_link.side = 'BUY')
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
     WHERE redistribution.plan_id = ${PLAN_ID}
  "
}

load_plan() {
  local row
  row="$(plan_row)"
  if [[ -z "${row}" ]]; then
    printf 'FAIL role-redistribution plan was not found: %s\n' \
      "${PLAN_ID}" >&2
    exit 1
  fi
  IFS=$'\t' read -r plan_status contract_version role_capacity_plan_id \
    target_quantity effective_business_date open_slot state_reason \
    source_count recipient_count allocation_count filled_quantity <<< "${row}"
}

require_immutable_plan() {
  if [[ "${contract_version}" != "${initial_contract_version}" \
      || "${role_capacity_plan_id}" != "${initial_role_capacity_plan_id}" \
      || "${target_quantity}" != "${initial_target_quantity}" \
      || "${effective_business_date}" != "${initial_effective_business_date}" \
      || "${source_count}" != "${initial_source_count}" \
      || "${recipient_count}" != "${initial_recipient_count}" \
      || "${allocation_count}" != "${initial_allocation_count}" ]]; then
    printf 'FAIL role-redistribution numeric contract drifted\n' >&2
    exit 1
  fi
}

derive_required_days() {
  local business_date="$1"
  mysql_query "
    SELECT CAST(COALESCE(MAX(
             CASE
               WHEN symbol_state.remaining_quantity <= 0 THEN 0
               WHEN symbol_state.current_day_capacity > 0 THEN
                 1 + CEIL(GREATEST(
                   symbol_state.remaining_quantity
                     - symbol_state.current_day_capacity,
                   0
                 ) / symbol_state.target_daily_volume)
               ELSE
                 1 + CEIL(
                   symbol_state.remaining_quantity
                     / symbol_state.target_daily_volume
                 )
             END
           ), 0) AS UNSIGNED)
      FROM (
        SELECT source.symbol,
               target.target_daily_volume,
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
               ), 0) AS remaining_quantity,
               GREATEST(target.target_daily_volume - COALESCE((
                 SELECT SUM(execution.quantity)
                   FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                  WHERE execution.symbol = source.symbol
                    AND execution.side = 'BUY'
                    AND execution.source = 'INTERNAL_ORDER_BOOK'
                    AND execution.executed_at >= '${business_date} 00:00:00'
                    AND execution.executed_at < DATE_ADD(
                      '${business_date} 00:00:00', INTERVAL 1 DAY
                    )
               ), 0), 0) AS current_day_capacity
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
            ON redistribution.plan_id = source.plan_id
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
            ON target.contract_version = redistribution.contract_version
           AND target.symbol = source.symbol
         WHERE source.plan_id = ${PLAN_ID}
      ) symbol_state
  "
}

batch_pid=""
batch_port=""
batch_log=""
current_day_log=""

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
      "http://127.0.0.1:${batch_port}/actuator/health" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started_at >= 30 )); then
      printf 'FAIL replay batch did not stop: port=%s log=%s\n' \
        "${batch_port}" "${batch_log}" >&2
      exit 1
    fi
    sleep 1
  done
  started_at="$(date +%s)"
  while true; do
    local stopped_clock
    stopped_clock="$(clock_response)"
    require_success_json 'batch shutdown clock' "${stopped_clock}"
    if printf '%s' "${stopped_clock}" | "${JQ_BIN}" -e \
        '.data.running == false' >/dev/null; then
      break
    fi
    if (( "$(date +%s)" - started_at >= CLOCK_STOP_TIMEOUT_SECONDS )); then
      printf 'FAIL replay batch stopped but simulation clock stayed running: port=%s response=%s\n' \
        "${batch_port}" "${stopped_clock}" >&2
      exit 1
    fi
    sleep 1
  done
  printf 'PASS replay batch stopped port=%s log=%s\n' \
    "${batch_port}" "${batch_log}"
  batch_pid=""
  batch_port=""
}

start_batch() {
  local mode="$1"
  local port="$2"
  if curl -fsS --max-time 1 \
      "http://127.0.0.1:${port}/actuator/health" >/dev/null 2>&1; then
    printf 'FAIL replay batch port is already active: %s\n' "${port}" >&2
    exit 1
  fi
  batch_port="${port}"
  batch_log="/tmp/stock-v4-${mode}-${port}-$$.log"
  if [[ "${mode}" == "role-redistribution-trading" ]]; then
    STOCK_V4_OPERATING_ALLOW_BATCH="${OPERATING_BATCH_ALLOW}" \
    STOCK_V4_REPLAY_BATCH_PORT="${port}" \
    STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION=YES \
      bash "${SCRIPT_DIR}/run-stock-v4-replay-batch.sh" \
        --role-redistribution-trading >"${batch_log}" 2>&1 &
  else
    STOCK_V4_OPERATING_ALLOW_BATCH="${OPERATING_BATCH_ALLOW}" \
    STOCK_V4_REPLAY_BATCH_PORT="${port}" \
    STOCK_V4_REPLAY_ALLOW_EOD_TRANSITION=YES \
      bash "${SCRIPT_DIR}/run-stock-v4-replay-batch.sh" \
        --eod-transition >"${batch_log}" 2>&1 &
  fi
  batch_pid=$!
  local started_at
  started_at="$(date +%s)"
  while true; do
    if curl -fsS --max-time 2 \
        "http://127.0.0.1:${port}/actuator/health" 2>/dev/null \
        | "${JQ_BIN}" -e '.status == "UP"' >/dev/null 2>&1; then
      printf 'PASS replay batch started mode=%s port=%s pid=%s log=%s\n' \
        "${mode}" "${port}" "${batch_pid}" "${batch_log}"
      return 0
    fi
    if ! kill -0 "${batch_pid}" 2>/dev/null; then
      printf 'FAIL replay batch exited before health UP: mode=%s log=%s\n' \
        "${mode}" "${batch_log}" >&2
      tail -n 80 "${batch_log}" >&2 || true
      exit 1
    fi
    if (( "$(date +%s)" - started_at >= START_TIMEOUT_SECONDS )); then
      printf 'FAIL replay batch health timed out: mode=%s log=%s\n' \
        "${mode}" "${batch_log}" >&2
      tail -n 80 "${batch_log}" >&2 || true
      exit 1
    fi
    sleep 2
  done
}

wait_for_portfolio_settlement() {
  local started_at
  local response
  started_at="$(date +%s)"
  while true; do
    response="$(clock_response)"
    require_success_json 'portfolio settlement clock' "${response}"
    if printf '%s' "${response}" | "${JQ_BIN}" -e \
        '.data.marketSession == "AFTER_CLOSE"
         and .data.running == false
         and .data.postCloseProcessingCompleted == true
         and .data.postClosePhase == "PORTFOLIO_SETTLED"' >/dev/null; then
      return 0
    fi
    if printf '%s' "${response}" | "${JQ_BIN}" -e \
        '.data.postCloseStatus == "FAILED"' >/dev/null; then
      printf 'FAIL portfolio settlement entered FAILED state response=%s\n' \
        "${response}" >&2
      exit 1
    fi
    if (( "$(date +%s)" - started_at >= PHASE_TIMEOUT_SECONDS )); then
      printf 'FAIL portfolio settlement timed out response=%s\n' \
        "${response}" >&2
      exit 1
    fi
    sleep 2
  done
}

close_and_advance_to_next_open() {
  local closing_date
  local close_response
  closing_date="$(require_regular_stopped_clock)"
  start_batch 'eod-transition' "${EOD_PORT}"
  close_response="$(curl -sS -X PATCH \
    -H 'Content-Type: application/json' \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    --data '{"action":"TODAY_MARKET_CLOSE"}' \
    "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
  require_success_json 'today market close' "${close_response}"
  wait_for_portfolio_settlement
  STOCK_V4_REPLAY_ALLOW_EOD_ADVANCE=YES \
  STOCK_V4_REPLAY_BACK_URL="${BACK_URL}" \
  STOCK_V4_REPLAY_EOD_TIMEOUT_SECONDS="${PHASE_TIMEOUT_SECONDS}" \
    bash "${SCRIPT_DIR}/run-stock-v4-eod-to-next-open.sh"
  stop_batch
  local opened_date
  opened_date="$(require_regular_stopped_clock)"
  if [[ "${opened_date}" == "${closing_date}" ]]; then
    printf 'FAIL EOD transition did not advance the business date: %s\n' \
      "${closing_date}" >&2
    exit 1
  fi
  printf 'PASS business date advanced closed=%s opened=%s\n' \
    "${closing_date}" "${opened_date}"
}

lock_dir="/tmp/stock-v4-role-redistribution-completion-${STOCK_MYSQL_REPLAY_SCHEMA}-${PLAN_ID}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another role-redistribution completion runner owns %s\n' \
    "${lock_dir}" >&2
  exit 1
fi
cleanup() {
  local exit_code=$?
  stop_batch || true
  if [[ -n "${current_day_log}" ]]; then
    rm -f "${current_day_log}"
  fi
  rmdir "${lock_dir}" 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT

initial_date="$(require_regular_stopped_clock)"
load_plan
initial_contract_version="${contract_version}"
initial_role_capacity_plan_id="${role_capacity_plan_id}"
initial_target_quantity="${target_quantity}"
initial_effective_business_date="${effective_business_date}"
initial_source_count="${source_count}"
initial_recipient_count="${recipient_count}"
initial_allocation_count="${allocation_count}"
if [[ "${plan_status}" != "ACTIVE" && "${plan_status}" != "COMPLETED" ]]; then
  printf 'FAIL role-redistribution completion requires ACTIVE or COMPLETED plan: %s\n' \
    "${plan_status}" >&2
  exit 1
fi
if [[ "${BULK_COMPLETION}" == "true" \
    && "${plan_status}" == "ACTIVE" ]]; then
  derived_trading_days=1
else
  derived_trading_days="$(derive_required_days "${initial_date}")"
fi
if [[ ! "${derived_trading_days}" =~ ^[0-9]+$ ]] \
    || (( derived_trading_days > 100 )); then
  printf 'FAIL derived role-redistribution trading-day guard is invalid: %s\n' \
    "${derived_trading_days}" >&2
  exit 1
fi
if [[ "${plan_status}" == "ACTIVE" && "${derived_trading_days}" == "0" ]]; then
  derived_trading_days=1
fi
if [[ -n "${MAX_TRADING_DAYS_OVERRIDE}" ]]; then
  if (( MAX_TRADING_DAYS_OVERRIDE < derived_trading_days )); then
    printf 'FAIL role-redistribution override is below derived minimum: override=%s derived=%s\n' \
      "${MAX_TRADING_DAYS_OVERRIDE}" "${derived_trading_days}" >&2
    exit 1
  fi
  MAX_TRADING_DAYS="${MAX_TRADING_DAYS_OVERRIDE}"
else
  MAX_TRADING_DAYS="${derived_trading_days}"
fi
printf 'PASS role-redistribution completion preflight date=%s plan=%s mode=%s status=%s filled=%s/%s symbols=%s recipients=%s allocations=%s derivedTradingDays=%s guard=%s state=%s\n' \
  "${initial_date}" "${PLAN_ID}" "${BULK_COMPLETION}" \
  "${plan_status}" \
  "${filled_quantity}" "${target_quantity}" "${source_count}" \
  "${recipient_count}" "${allocation_count}" \
  "${derived_trading_days}" "${MAX_TRADING_DAYS}" "${state_reason}"

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS role-redistribution completion check-only finished without mutation\n'
  exit 0
fi

trading_days=0
while [[ "${plan_status}" != "COMPLETED" ]]; do
  trade_date="$(require_regular_stopped_clock)"
  load_plan
  require_immutable_plan
  if [[ "${plan_status}" == "COMPLETED" ]]; then
    break
  fi
  if (( trading_days >= MAX_TRADING_DAYS )); then
    printf 'FAIL role-redistribution exceeded trading-day guard: max=%s\n' \
      "${MAX_TRADING_DAYS}" >&2
    exit 1
  fi
  if [[ "${effective_business_date}" > "${trade_date}" ]]; then
    close_and_advance_to_next_open
    continue
  fi

  start_batch 'role-redistribution-trading' "${ROLE_PORT}"
  current_day_log="$(mktemp "/tmp/stock-v4-role-redistribution-day-${PLAN_ID}-${trade_date}.XXXXXX")"
  set +e
  STOCK_V4_REPLAY_BATCH_URL="http://127.0.0.1:${ROLE_PORT}" \
  STOCK_V4_REPLAY_BACK_URL="${BACK_URL}" \
  STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_DAY=YES \
  STOCK_V4_OPERATING_ALLOW_ROLE_REDISTRIBUTION_DAY="${OPERATING_DAY_ALLOW}" \
    bash "${SCRIPT_DIR}/run-stock-v4-role-redistribution-day.sh" \
      2>&1 | tee "${current_day_log}"
  day_exit_code="${PIPESTATUS[0]}"
  set -e
  if [[ "${day_exit_code}" != "0" ]] \
      || ! rg -F \
        "ROLE_REDISTRIBUTION_DAY_OK plan=${PLAN_ID} date=${trade_date}" \
        "${current_day_log}" >/dev/null; then
    printf 'FAIL role-redistribution day did not emit its verified completion sentinel: date=%s exit=%s log=%s\n' \
      "${trade_date}" "${day_exit_code}" "${current_day_log}" >&2
    exit 1
  fi
  rm -f "${current_day_log}"
  current_day_log=""
  stop_batch
  stopped_date="$(require_regular_stopped_clock)"
  if [[ "${stopped_date}" != "${trade_date}" ]]; then
    printf 'FAIL role-redistribution batch stop changed the business date: expected=%s actual=%s\n' \
      "${trade_date}" "${stopped_date}" >&2
    exit 1
  fi
  trading_days=$((trading_days + 1))
  load_plan
  require_immutable_plan
  printf 'PASS controlled role-redistribution trading day=%s count=%s filled=%s/%s status=%s\n' \
    "${trade_date}" "${trading_days}" "${filled_quantity}" \
    "${target_quantity}" "${plan_status}"
  if [[ "${plan_status}" != "COMPLETED" ]]; then
    close_and_advance_to_next_open
  fi
done

assert_equals \
  "completed role-redistribution terminal contract" \
  "COMPLETED|0|DISTRIBUTION_COMPLETED" \
  "
  SELECT CONCAT(status, '|', COALESCE(open_slot, 0), '|', state_reason)
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan
   WHERE plan_id = ${PLAN_ID}
  "
assert_equals \
  "completed role-redistribution quantity and cost reconciliation" \
  "1" \
  "
  SELECT (
    redistribution.target_transfer_quantity = (
      SELECT COALESCE(SUM(execution.quantity), 0)
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
          ON execution.order_id = order_link.order_id
         AND execution.side = 'BUY'
         AND execution.source = 'INTERNAL_ORDER_BOOK'
       WHERE order_link.plan_id = redistribution.plan_id
         AND order_link.side = 'BUY'
    )
    AND redistribution.target_transfer_quantity = (
      SELECT COALESCE(SUM(execution.quantity), 0)
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
          ON execution.order_id = order_link.order_id
         AND execution.side = 'SELL'
         AND execution.source = 'INTERNAL_ORDER_BOOK'
       WHERE order_link.plan_id = redistribution.plan_id
         AND order_link.side = 'SELL'
    )
    AND NOT EXISTS (
      SELECT 1
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
          ON execution.order_id = order_link.order_id
       WHERE order_link.plan_id = redistribution.plan_id
         AND (execution.fee_amount <> 0 OR execution.tax_amount <> 0)
    )
  )
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
   WHERE redistribution.plan_id = ${PLAN_ID}
  "
expected_holding_matrix="${initial_recipient_count}|${initial_source_count}|$((
  initial_recipient_count * initial_source_count
))"
assert_equals \
  "post-redistribution recipient holding matrix cardinality" \
  "${expected_holding_matrix}" \
  "
  SELECT CONCAT(
           (
             SELECT COUNT(*)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan
              WHERE plan_id = ${PLAN_ID}
           ), '|',
           (
             SELECT COUNT(*)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan
              WHERE plan_id = ${PLAN_ID}
           ), '|',
           COUNT(*)
         )
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_holding_plan
   WHERE plan_id = ${PLAN_ID}
  "
assert_equals \
  "post-redistribution recipient holding matrix mismatches" \
  "0" \
  "
  SELECT COUNT(*)
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_holding_plan snapshot
    LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
      ON allocation.plan_id = snapshot.plan_id
     AND allocation.target_account_id = snapshot.account_id
     AND allocation.symbol = snapshot.symbol
    LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      ON holding.account_id = snapshot.account_id
     AND holding.symbol = snapshot.symbol
   WHERE snapshot.plan_id = ${PLAN_ID}
     AND (
       COALESCE(holding.quantity, 0)
         <> snapshot.source_quantity
            + COALESCE(allocation.target_quantity, 0)
       OR COALESCE(holding.reserved_quantity, 0) <> 0
     )
  "
assert_equals \
  "post-redistribution unsupported recipient holdings" \
  "0" \
  "
  SELECT COUNT(*)
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan recipient
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      ON holding.account_id = recipient.account_id
    LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_holding_plan snapshot
      ON snapshot.plan_id = recipient.plan_id
     AND snapshot.account_id = holding.account_id
     AND snapshot.symbol = holding.symbol
   WHERE recipient.plan_id = ${PLAN_ID}
     AND snapshot.account_id IS NULL
     AND (
       holding.quantity <> 0
       OR holding.reserved_quantity <> 0
     )
  "
assert_equals \
  "post-redistribution LP inventory and cash mismatches" \
  "0" \
  "
  SELECT COUNT(*)
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
      ON account.id = source.source_lp_account_id
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      ON holding.account_id = source.source_lp_account_id
     AND holding.symbol = source.symbol
   WHERE source.plan_id = ${PLAN_ID}
     AND (
       account.status <> 'ACTIVE'
       OR account.participant_category <> 'LIQUIDITY_PROVIDER'
       OR holding.quantity <> source.target_final_quantity
       OR holding.reserved_quantity <> 0
       OR account.cash_balance <> source.source_target_cash + (
         SELECT COALESCE(SUM(execution.gross_amount), 0)
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
           JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
             ON execution.order_id = order_link.order_id
            AND execution.side = 'SELL'
            AND execution.source = 'INTERNAL_ORDER_BOOK'
          WHERE order_link.plan_id = source.plan_id
            AND order_link.symbol = source.symbol
            AND order_link.side = 'SELL'
       )
     )
  "
assert_equals \
  "post-redistribution recipient identity and cash mismatches" \
  "0" \
  "
  SELECT COUNT(*)
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan recipient
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
      ON account.id = recipient.account_id
   WHERE recipient.plan_id = ${PLAN_ID}
     AND (
       account.status <> 'ACTIVE'
       OR account.participant_category
            <> recipient.participant_category
       OR recipient.participant_category NOT IN (
         'AUTO_PARTICIPANT',
         'INSTITUTIONAL_INVESTOR'
       )
       OR account.cash_balance <> recipient.target_final_cash
       OR account.cash_balance < recipient.target_cash_buffer
     )
  "
assert_equals \
  "post-redistribution exact existing and new symbol targets" \
  "DEMO001|18945251|18945251|198600.00|3762526848600.00;DEMO002|189550602|189550602|23350.00|4426006556700.00;DEMO003|18954126|18954126|518000.00|9818237268000.00;DEMO004|189541726|94770863|20050.00|3800311606300.00;DEMO005|56862505|28431253|94600.00|5379192973000.00;DEMO006|23692711|11846356|258000.00|6112719438000.00;DEMO007|7581667|3790834|755000.00|5724158585000.00;DEMO008|72161227|36080613|77200.00|5570846724400.00" \
  "
  SELECT GROUP_CONCAT(
           CONCAT(
             target.symbol, '|',
             instrument.issued_shares, '|',
             instrument.tradable_shares, '|',
             CAST(target.target_reference_price AS DECIMAL(19,2)), '|',
             CAST(target.target_market_capitalization AS DECIMAL(24,2))
           )
           ORDER BY target.symbol SEPARATOR ';'
         )
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      ON instrument.symbol = target.symbol
   WHERE target.contract_version = ${initial_contract_version}
     AND target.lifecycle_status = 'MATURE'
     AND instrument.issued_shares = target.target_issued_shares
     AND instrument.tradable_shares = target.target_tradable_shares
  "
assert_equals \
  "post-redistribution target instrument and market-cap contract" \
  "8|577289815|402369898|44594000000000.00" \
  "
  SELECT CONCAT(
           COUNT(*), '|',
           SUM(instrument.issued_shares), '|',
           SUM(instrument.tradable_shares), '|',
           CAST(SUM(
             instrument.issued_shares * target.target_reference_price
           ) AS DECIMAL(24,2))
         )
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      ON instrument.symbol = target.symbol
   WHERE target.contract_version = ${initial_contract_version}
     AND target.lifecycle_status = 'MATURE'
     AND instrument.issued_shares = target.target_issued_shares
     AND instrument.tradable_shares = target.target_tradable_shares
  "
assert_equals \
  "post-redistribution per-symbol holding and issued-share mismatches" \
  "0" \
  "
  SELECT COUNT(*)
    FROM (
      SELECT target.symbol
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
          ON holding.symbol = target.symbol
       WHERE target.contract_version = ${initial_contract_version}
       GROUP BY target.symbol, target.target_issued_shares
      HAVING COALESCE(SUM(holding.quantity), 0) <> target.target_issued_shares
         OR COALESCE(SUM(holding.reserved_quantity), 0) <> 0
    ) mismatch
  "

final_date="$(require_regular_stopped_clock)"
load_plan
require_immutable_plan
printf 'PASS single role-inventory redistribution lever fully completed finalDate=%s plan=%s filled=%s tradingDays=%s state=%s\n' \
  "${final_date}" "${PLAN_ID}" "${filled_quantity}" \
  "${trading_days}" "${state_reason}"
