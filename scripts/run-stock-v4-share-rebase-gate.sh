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
: "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID:?STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID is required}"
: "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION:?STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION is required}"
: "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT:?STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT is required}"
: "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES:?STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES is required}"
: "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES:?STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES is required}"
: "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION:?STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_SHARE_REBASE_GATE:-}" != "YES" ]]; then
  printf 'FAIL share-rebase gate requires STOCK_V4_REPLAY_ALLOW_SHARE_REBASE_GATE=YES\n' >&2
  exit 1
fi
if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$ ]]; then
  printf 'FAIL batch replay schema must match STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" == "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" ]]; then
  printf 'FAIL business and batch replay schemas must be different\n' >&2
  exit 1
fi

for numeric_value in \
  "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}" \
  "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
  "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
  "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION}"; do
  if [[ ! "${numeric_value}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL share-rebase numeric contract values must be positive integers: %s\n' \
      "${numeric_value}" >&2
    exit 1
  fi
done
if (( STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES
      > STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES )); then
  printf 'FAIL expected tradable shares cannot exceed issued shares\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
BATCH_PORT="${STOCK_V4_REPLAY_SHARE_REBASE_BATCH_PORT:-30491}"
START_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_BATCH_START_TIMEOUT_SECONDS:-120}"
PHASE_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_PHASE_TIMEOUT_SECONDS:-600}"
RETRY_GUARD_SECONDS="${STOCK_V4_REPLAY_SHARE_REBASE_RETRY_GUARD_SECONDS:-120}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"
JQ_BIN="$(command -v jq || true)"
CHECK_ONLY=false
RESUME_PREOPEN=false

for argument in "$@"; do
  case "${argument}" in
    --check-only)
      CHECK_ONLY=true
      ;;
    --resume-preopen)
      RESUME_PREOPEN=true
      ;;
    *)
      printf 'FAIL unsupported argument: %s\n' "${argument}" >&2
      exit 1
      ;;
  esac
done

if [[ ! "${BATCH_PORT}" =~ ^[0-9]+$ ]] \
    || (( BATCH_PORT < 1024 || BATCH_PORT > 65535 )); then
  printf 'FAIL share-rebase batch port must be between 1024 and 65535\n' >&2
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
if [[ ! "${RETRY_GUARD_SECONDS}" =~ ^[1-9][0-9]*$ ]] \
    || (( RETRY_GUARD_SECONDS < 120 || RETRY_GUARD_SECONDS > 900 )); then
  printf 'FAIL share-rebase retry guard must be between 120 and 900 seconds\n' >&2
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
  "--default-character-set=utf8mb4"
  "--batch"
  "--raw"
  "--skip-column-names"
)

mysql_query() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" --execute="$1"
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

plan_row() {
  mysql_query "
    SELECT CONCAT_WS(
             '|',
             plan.contract_version,
             plan.rebase_stage,
             plan.status,
             plan.source_state_version,
             COALESCE(plan.effective_business_date, ''),
             CAST(plan.target_numeric_value AS UNSIGNED),
             plan.target_numeric_unit,
             COALESCE(DATE_FORMAT(plan.applied_at, '%Y-%m-%dT%H:%i:%s'), '')
           )
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan plan
     WHERE plan.plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
  "
}

require_plan_contract() {
  local allowed_status="$1"
  local row
  local contract_version
  local stage
  local status
  local source_state_version
  local effective_business_date
  local target_value
  local target_unit
  local applied_at

  row="$(plan_row)"
  if [[ -z "${row}" ]]; then
    printf 'FAIL share-rebase plan was not found: %s\n' \
      "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}" >&2
    exit 1
  fi
  IFS='|' read -r contract_version stage status source_state_version \
    effective_business_date target_value target_unit applied_at <<< "${row}"
  if [[ "${contract_version}" != "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
      || "${stage}" != "SHARE_STRUCTURE" \
      || "${target_value}" != "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}" \
      || "${target_unit}" != "SHARES" ]]; then
    printf 'FAIL share-rebase plan numeric contract drifted row=%s\n' "${row}" >&2
    exit 1
  fi
  if [[ "${status}" != "${allowed_status}" ]]; then
    printf 'FAIL share-rebase plan status expected=%s actual=%s\n' \
      "${allowed_status}" "${status}" >&2
    exit 1
  fi
  if [[ ! "${source_state_version}" =~ ^[0-9]+$ ]]; then
    printf 'FAIL share-rebase source state version is invalid: %s\n' \
      "${source_state_version}" >&2
    exit 1
  fi
  if [[ "${allowed_status}" == "SCHEDULED" && -z "${effective_business_date}" ]]; then
    printf 'FAIL scheduled share-rebase effective date is missing\n' >&2
    exit 1
  fi
  if [[ "${allowed_status}" == "APPLIED" && -z "${applied_at}" ]]; then
    printf 'FAIL applied share-rebase timestamp is missing\n' >&2
    exit 1
  fi
  printf '%s\n' "${effective_business_date}"
}

assert_plan_totals() {
  assert_equals \
    "share-rebase symbol count" \
    "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
    "
  assert_equals \
    "share-rebase target issued shares" \
    "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}" \
    "
    SELECT CAST(SUM(target_issued_shares) AS UNSIGNED)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
    "
  assert_equals \
    "share-rebase target tradable shares" \
    "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES}" \
    "
    SELECT CAST(SUM(target_tradable_shares) AS UNSIGNED)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
    "
  assert_equals \
    "share-rebase target market capitalization" \
    "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION}" \
    "
    SELECT CAST(SUM(target_market_capitalization) AS UNSIGNED)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
    "
  assert_equals \
    "share-rebase per-symbol contract target mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan symbol_plan
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target symbol_target
        ON symbol_target.contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND symbol_target.symbol = symbol_plan.symbol
     WHERE symbol_plan.plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
       AND (
         symbol_target.symbol IS NULL
         OR symbol_plan.target_issued_shares
              <> symbol_target.target_issued_shares
         OR symbol_plan.target_tradable_shares
              <> symbol_target.target_tradable_shares
         OR symbol_plan.target_reference_price
              <> symbol_target.target_reference_price
         OR symbol_plan.target_market_capitalization
              <> symbol_target.target_market_capitalization
       )
    "
  assert_equals \
    "share-rebase mature symbol targets" \
    "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target
     WHERE contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND lifecycle_status = 'MATURE'
       AND distributed_tradable_share_rate = 1.00000000
    "
}

require_stopped_regular_clock() {
  local response
  response="$(clock_response)"
  require_success_json 'share-rebase initial clock' "${response}"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
      '.data.marketSession == "REGULAR"
       and .data.running == false
       and .data.activeBusinessDate == .data.simulationDate
       and .data.preparingBusinessDate == null
       and .data.postClosePhase == null
       and .data.postCloseStatus == null' >/dev/null; then
    printf 'FAIL share-rebase requires stopped aligned REGULAR state response=%s\n' \
      "${response}" >&2
    exit 1
  fi
  printf '%s' "${response}"
}

require_stopped_reports_clock() {
  local response
  response="$(clock_response)"
  require_success_json 'share-rebase reports clock' "${response}"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
      '.data.marketSession == "PRE_OPEN"
       and .data.running == false
       and .data.activeBusinessDate != .data.simulationDate
       and .data.preparingBusinessDate == .data.simulationDate
       and .data.postClosePhase == "REPORTS_AGGREGATED"
       and .data.postCloseStatus == "PENDING"
       and (.data.availableJumpActions
            | index("NEXT_PREOPEN_TRANSFORM_START") != null)' >/dev/null; then
    printf 'FAIL share-rebase resume requires stopped PRE_OPEN/REPORTS_AGGREGATED state response=%s\n' \
      "${response}" >&2
    exit 1
  fi
  printf '%s' "${response}"
}

assert_quiescent_ledgers() {
  assert_equals \
    "open orders" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order
     WHERE status IN ('PENDING', 'OPEN', 'PARTIALLY_FILLED')
    "
  assert_equals \
    "reserved holding quantity" \
    "0" \
    "
    SELECT COALESCE(SUM(reserved_quantity), 0)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding
    "
  assert_equals \
    "reserved order cash" \
    "0.00" \
    "
    SELECT COALESCE(SUM(reserved_cash), 0.00)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order
     WHERE status IN ('PENDING', 'OPEN', 'PARTIALLY_FILLED')
    "
  assert_equals \
    "active automatic participant intents" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_participant_order_intent
     WHERE status = 'ACTIVE'
    "
  assert_equals \
    "open liquidity distribution plans" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_liquidity_distribution_plan
     WHERE status IN ('DRAFT', 'SCHEDULED', 'ACTIVE')
    "
}

verify_applied_ledger() {
  assert_equals \
    "applied per-symbol instrument share mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan symbol_plan
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
        ON instrument.symbol = symbol_plan.symbol
     WHERE symbol_plan.plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
       AND (
         instrument.symbol IS NULL
         OR instrument.issued_shares <> symbol_plan.target_issued_shares
         OR instrument.tradable_shares <> symbol_plan.target_tradable_shares
       )
    "
  assert_equals \
    "applied instrument issued shares" \
    "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}" \
    "
    SELECT CAST(SUM(instrument.issued_shares) AS UNSIGNED)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan symbol_plan
        ON symbol_plan.plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
       AND symbol_plan.symbol = instrument.symbol
    "
  assert_equals \
    "applied instrument tradable shares" \
    "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES}" \
    "
    SELECT CAST(SUM(instrument.tradable_shares) AS UNSIGNED)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan symbol_plan
        ON symbol_plan.plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
       AND symbol_plan.symbol = instrument.symbol
    "
  assert_equals \
    "applied holding-plan mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_holding_plan holding_plan
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
        ON holding.account_id = holding_plan.account_id
       AND holding.symbol = holding_plan.symbol
     WHERE holding_plan.plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
       AND (
         COALESCE(holding.quantity, 0) <> holding_plan.target_quantity
         OR COALESCE(holding.reserved_quantity, 0) <> 0
       )
    "
  assert_equals \
    "applied per-symbol holding reconciliation failures" \
    "0" \
    "
    SELECT COUNT(*)
      FROM (
        SELECT symbol_plan.symbol
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan symbol_plan
          LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
            ON holding.symbol = symbol_plan.symbol
         WHERE symbol_plan.plan_id = ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}
         GROUP BY symbol_plan.symbol, symbol_plan.target_issued_shares
        HAVING COALESCE(SUM(holding.quantity), 0) <> symbol_plan.target_issued_shares
      ) mismatch
    "
}

batch_pid=""
batch_log=""

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
    if (( "$(date +%s)" - started_at >= 30 )); then
      printf 'FAIL replay batch did not stop: port=%s log=%s\n' \
        "${BATCH_PORT}" "${batch_log}" >&2
      exit 1
    fi
    sleep 1
  done
  printf 'PASS replay batch stopped port=%s log=%s\n' \
    "${BATCH_PORT}" "${batch_log}"
  batch_pid=""
}

start_batch() {
  if curl -fsS --max-time 1 \
      "http://127.0.0.1:${BATCH_PORT}/actuator/health" >/dev/null 2>&1; then
    printf 'FAIL replay batch port is already active: %s\n' "${BATCH_PORT}" >&2
    exit 1
  fi
  batch_log="/tmp/stock-v4-share-rebase-${BATCH_PORT}-$$.log"
  STOCK_V4_REPLAY_BATCH_PORT="${BATCH_PORT}" \
  STOCK_V4_REPLAY_ALLOW_EOD_TRANSITION=YES \
  STOCK_BATCH_POST_CLOSE_RETRY_BASE_SECONDS="${RETRY_GUARD_SECONDS}" \
    bash "${SCRIPT_DIR}/run-stock-v4-replay-batch.sh" \
      --eod-transition >"${batch_log}" 2>&1 &
  batch_pid=$!

  local started_at
  started_at="$(date +%s)"
  while true; do
    if curl -fsS --max-time 2 \
      "http://127.0.0.1:${BATCH_PORT}/actuator/health" 2>/dev/null \
        | "${JQ_BIN}" -e '.status == "UP"' >/dev/null 2>&1; then
      printf 'PASS replay batch started mode=eod-transition port=%s pid=%s log=%s\n' \
        "${BATCH_PORT}" "${batch_pid}" "${batch_log}"
      return 0
    fi
    if ! kill -0 "${batch_pid}" 2>/dev/null; then
      printf 'FAIL replay batch exited before health UP: log=%s\n' \
        "${batch_log}" >&2
      tail -n 80 "${batch_log}" >&2 || true
      exit 1
    fi
    if (( "$(date +%s)" - started_at >= START_TIMEOUT_SECONDS )); then
      printf 'FAIL replay batch health timed out: log=%s\n' \
        "${batch_log}" >&2
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

wait_for_share_gate() {
  local effective_business_date="$1"
  local started_at
  local response
  local status
  started_at="$(date +%s)"
  while true; do
    response="$(clock_response)"
    require_success_json 'share-rebase gate clock' "${response}"
    status="$(plan_row | cut -d'|' -f3)"
    if [[ "${status}" == "APPLIED" ]] \
        && printf '%s' "${response}" | "${JQ_BIN}" -e \
          --arg effectiveBusinessDate "${effective_business_date}" \
          '.data.marketSession == "PRE_OPEN"
           and .data.simulationDate == $effectiveBusinessDate
           and .data.preparingBusinessDate == $effectiveBusinessDate
           and .data.postClosePhase == "REPORTS_AGGREGATED"
           and .data.postCloseStatus == "DEFERRED"' >/dev/null; then
      printf 'PASS share-rebase applied and coordinator stopped at bounded-progress gate\n'
      return 0
    fi
    if [[ "${status}" == "FAILED" ]] \
        || printf '%s' "${response}" | "${JQ_BIN}" -e \
          '.data.postCloseStatus == "FAILED"' >/dev/null; then
      printf 'FAIL share-rebase or post-close cycle entered FAILED state response=%s plan=%s\n' \
        "${response}" "$(plan_row)" >&2
      exit 1
    fi
    if (( "$(date +%s)" - started_at >= PHASE_TIMEOUT_SECONDS )); then
      printf 'FAIL share-rebase bounded-progress gate timed out response=%s plan=%s\n' \
        "${response}" "$(plan_row)" >&2
      exit 1
    fi
    sleep 1
  done
}

lock_dir="/tmp/stock-v4-share-rebase-gate-${STOCK_MYSQL_REPLAY_SCHEMA}-${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another share-rebase runner owns %s\n' "${lock_dir}" >&2
  exit 1
fi
cleanup() {
  local exit_code=$?
  stop_batch || true
  rmdir "${lock_dir}" 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT

if [[ "${RESUME_PREOPEN}" == "true" ]]; then
  initial_clock="$(require_stopped_reports_clock)"
  gate_mode='resume-preopen'
else
  initial_clock="$(require_stopped_regular_clock)"
  gate_mode='close-and-advance'
fi
active_business_date="$(
  printf '%s' "${initial_clock}" | "${JQ_BIN}" -r '.data.activeBusinessDate'
)"
effective_business_date="$(require_plan_contract 'SCHEDULED')"
if [[ "${RESUME_PREOPEN}" == "true" ]]; then
  expected_effective_business_date="$(
    printf '%s' "${initial_clock}" \
      | "${JQ_BIN}" -r '.data.preparingBusinessDate'
  )"
else
  expected_effective_business_date="$(mysql_query "
    SELECT DATE_FORMAT(
             DATE_ADD('${active_business_date}', INTERVAL 1 DAY),
             '%Y-%m-%d'
           )
  ")"
fi
if [[ "${effective_business_date}" != "${expected_effective_business_date}" ]]; then
  printf 'FAIL share-rebase effective date must be the next simulation date: active=%s effective=%s\n' \
    "${active_business_date}" "${effective_business_date}" >&2
  exit 1
fi
assert_plan_totals
assert_quiescent_ledgers

printf 'PASS share-rebase gate preflight mode=%s date=%s effective=%s plan=%s contract=%s\n' \
  "${gate_mode}" \
  "${active_business_date}" "${effective_business_date}" \
  "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}" \
  "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}"

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS share-rebase gate check-only finished without mutation\n'
  exit 0
fi

start_batch
if [[ "${RESUME_PREOPEN}" != "true" ]]; then
  close_response="$(curl -sS -X PATCH \
    -H 'Content-Type: application/json' \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    --data '{"action":"TODAY_MARKET_CLOSE"}' \
    "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
  require_success_json 'share-rebase market close' "${close_response}"
  wait_for_portfolio_settlement

  STOCK_V4_REPLAY_ALLOW_EOD_ADVANCE=YES \
  STOCK_V4_REPLAY_EOD_TIMEOUT_SECONDS="${PHASE_TIMEOUT_SECONDS}" \
    bash "${SCRIPT_DIR}/run-stock-v4-eod-to-next-open.sh" --stop-after-reports
fi

transform_response="$(curl -sS -X PATCH \
  -H 'Content-Type: application/json' \
  -H "X-User-Key: ${ADMIN_USER_KEY}" \
  -H 'X-User-Role: ADMIN' \
  --data '{"action":"NEXT_PREOPEN_TRANSFORM_START"}' \
  "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
require_success_json 'share-rebase pre-open transform start' "${transform_response}"
wait_for_share_gate "${effective_business_date}"
stop_batch

require_plan_contract 'APPLIED' >/dev/null
verify_applied_ledger
assert_quiescent_ledgers

final_clock="$(clock_response)"
require_success_json 'share-rebase final clock' "${final_clock}"
if ! printf '%s' "${final_clock}" | "${JQ_BIN}" -e \
    --arg effectiveBusinessDate "${effective_business_date}" \
    '.data.marketSession == "PRE_OPEN"
     and .data.running == false
     and .data.simulationDate == $effectiveBusinessDate
     and .data.preparingBusinessDate == $effectiveBusinessDate
     and .data.postClosePhase == "REPORTS_AGGREGATED"
     and .data.postCloseStatus == "DEFERRED"' >/dev/null; then
  printf 'FAIL share-rebase final gate drifted response=%s\n' \
    "${final_clock}" >&2
  exit 1
fi

printf 'PASS share-rebase gate complete plan=%s issued=%s tradable=%s symbols=%s effective=%s\n' \
  "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}" \
  "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
  "${effective_business_date}"
