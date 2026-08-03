#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA:?STOCK_MYSQL_REPLAY_BATCH_SCHEMA is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"
: "${STOCK_V4_REPLAY_CONTRACT_ID:?STOCK_V4_REPLAY_CONTRACT_ID is required}"
: "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY:?STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_CHECKPOINT_COMPLETION:-}" != "YES" ]]; then
  printf 'FAIL checkpoint completion requires STOCK_V4_REPLAY_ALLOW_CHECKPOINT_COMPLETION=YES\n' >&2
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
if [[ ! "${STOCK_V4_REPLAY_CONTRACT_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL STOCK_V4_REPLAY_CONTRACT_ID must be a positive integer\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  printf 'FAIL counterparty user key contains unsupported characters\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
CHECKPOINT_PORT="${STOCK_V4_REPLAY_CHECKPOINT_BATCH_PORT:-30492}"
EOD_PORT="${STOCK_V4_REPLAY_EOD_BATCH_PORT:-30491}"
START_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_BATCH_START_TIMEOUT_SECONDS:-120}"
PHASE_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_PHASE_TIMEOUT_SECONDS:-300}"
CLOCK_STOP_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_CLOCK_STOP_TIMEOUT_SECONDS:-30}"
MAX_TRADING_DAYS="${STOCK_V4_REPLAY_MAX_CHECKPOINT_DAYS:-25}"
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

for port in "${CHECKPOINT_PORT}" "${EOD_PORT}"; do
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
    printf 'FAIL replay batch port must be between 1024 and 65535: %s\n' \
      "${port}" >&2
    exit 1
  fi
done
if [[ "${CHECKPOINT_PORT}" == "${EOD_PORT}" ]]; then
  printf 'FAIL checkpoint and EOD batch ports must be different\n' >&2
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
if [[ ! "${MAX_TRADING_DAYS}" =~ ^[1-9][0-9]*$ ]] \
    || (( MAX_TRADING_DAYS > 100 )); then
  printf 'FAIL checkpoint day guard must be between 1 and 100\n' >&2
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
    printf 'FAIL checkpoint completion requires stopped aligned REGULAR state response=%s\n' \
      "${response}" >&2
    exit 1
  fi
  printf '%s' "${response}" | "${JQ_BIN}" -r '.data.activeBusinessDate'
}

wait_for_regular_clock_stop() {
  local expected_business_date="$1"
  local started_at
  local response

  started_at="$(date +%s)"
  while true; do
    response="$(clock_response)"
    require_success_json 'checkpoint clock stop' "${response}"
    if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
        --arg expectedBusinessDate "${expected_business_date}" \
        '.data.marketSession == "REGULAR"
         and .data.activeBusinessDate == $expectedBusinessDate
         and .data.simulationDate == $expectedBusinessDate
         and .data.preparingBusinessDate == null
         and .data.postClosePhase == null
         and .data.postCloseStatus == null' >/dev/null; then
      printf 'FAIL checkpoint batch stop changed the aligned REGULAR state response=%s\n' \
        "${response}" >&2
      exit 1
    fi
    if printf '%s' "${response}" | "${JQ_BIN}" -e \
        '.data.running == false' >/dev/null; then
      printf '%s' "${response}" | "${JQ_BIN}" -r '.data.activeBusinessDate'
      return 0
    fi
    if (( "$(date +%s)" - started_at >= CLOCK_STOP_TIMEOUT_SECONDS )); then
      printf 'FAIL checkpoint simulation clock did not stop after batch shutdown response=%s\n' \
        "${response}" >&2
      exit 1
    fi
    sleep 1
  done
}

lifecycle_row() {
  mysql_query "
    SELECT contract.symbol,
           contract.status,
           contract.policy_version,
           COALESCE(current_policy.status, 'MISSING'),
           (
             SELECT COUNT(*)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version scheduled
              WHERE scheduled.policy_scope = 'UNDERWRITING_CONTRACT'
                AND scheduled.scope_key = contract.contract_code
                AND scheduled.status = 'SCHEDULED'
           ) AS scheduled_count
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version current_policy
        ON current_policy.policy_scope = 'UNDERWRITING_CONTRACT'
       AND current_policy.scope_key = contract.contract_code
       AND current_policy.version_no = contract.policy_version
     WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
  "
}

is_terminal_checkpoint_lifecycle() {
  local contract_status="$1"
  local policy_status="$2"
  local scheduled_count="$3"

  [[ ("${contract_status}" == "ALLOCATED" \
        || "${contract_status}" == "COMPLETED") \
      && "${policy_status}" == "RETIRED" \
      && "${scheduled_count}" == "0" ]]
}

batch_pid=""
batch_port=""
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
    if (( "$(date +%s)" - started_at >= 30 )); then
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
  if [[ "${mode}" == "checkpoint-trading" ]]; then
    STOCK_V4_REPLAY_BATCH_PORT="${port}" \
    STOCK_V4_REPLAY_ALLOW_CHECKPOINT_TRADING=YES \
      bash "${SCRIPT_DIR}/run-stock-v4-replay-batch.sh" \
        --checkpoint-trading >"${batch_log}" 2>&1 &
  else
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
        "http://127.0.0.1:${port}/actuator/health" \
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

lock_name="${STOCK_MYSQL_REPLAY_SCHEMA}_${STOCK_V4_REPLAY_CONTRACT_ID}"
lock_dir="/tmp/stock-v4-underwriter-completion-${lock_name}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another checkpoint-completion runner owns %s\n' \
    "${lock_dir}" >&2
  exit 1
fi
cleanup() {
  local exit_code=$?
  stop_batch || true
  rmdir "${lock_dir}" 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT

initial_date="$(require_regular_stopped_clock)"
initial_lifecycle="$(lifecycle_row)"
if [[ -z "${initial_lifecycle}" ]]; then
  printf 'FAIL underwriting contract was not found\n' >&2
  exit 1
fi
IFS=$'\t' read -r initial_symbol initial_contract_status \
  initial_policy_version initial_policy_status initial_scheduled_count \
  <<< "${initial_lifecycle}"
printf 'PASS checkpoint-completion preflight date=%s symbol=%s contract=%s policy=%s/%s scheduled=%s\n' \
  "${initial_date}" "${initial_symbol}" "${initial_contract_status}" \
  "${initial_policy_version}" "${initial_policy_status}" \
  "${initial_scheduled_count}"

if ! is_terminal_checkpoint_lifecycle \
    "${initial_contract_status}" \
    "${initial_policy_status}" \
    "${initial_scheduled_count}"; then
  bash "${SCRIPT_DIR}/check-stock-v4-replay-role-capacity.sh"
fi

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS checkpoint-completion check-only finished without mutation\n'
  exit 0
fi

trading_days=0
while true; do
  current_lifecycle="$(lifecycle_row)"
  IFS=$'\t' read -r symbol contract_status policy_version policy_status \
    scheduled_count <<< "${current_lifecycle}"

  if is_terminal_checkpoint_lifecycle \
      "${contract_status}" "${policy_status}" "${scheduled_count}"; then
    printf 'PASS checkpoint completion reached terminal lifecycle symbol=%s contract=%s policy=%s/%s tradingDays=%s\n' \
      "${symbol}" "${contract_status}" "${policy_version}" \
      "${policy_status}" \
      "${trading_days}"
    break
  fi
  if [[ "${contract_status}" == "ALLOCATED" \
      && "${scheduled_count}" == "1" ]]; then
    printf 'INFO advancing scheduled checkpoint to its effective opening\n'
    close_and_advance_to_next_open
    continue
  fi
  if [[ "${contract_status}" != "STABILIZING" \
      || "${policy_status}" != "ACTIVE" \
      || "${scheduled_count}" != "0" ]]; then
    printf 'FAIL unsupported checkpoint lifecycle contract=%s policy=%s/%s scheduled=%s\n' \
      "${contract_status}" "${policy_version}" "${policy_status}" \
      "${scheduled_count}" >&2
    exit 1
  fi
  if (( trading_days >= MAX_TRADING_DAYS )); then
    printf 'FAIL checkpoint exceeded trading-day guard: max=%s\n' \
      "${MAX_TRADING_DAYS}" >&2
    exit 1
  fi

  trade_date="$(require_regular_stopped_clock)"
  start_batch 'checkpoint-trading' "${CHECKPOINT_PORT}"
  STOCK_V4_REPLAY_BATCH_URL="http://127.0.0.1:${CHECKPOINT_PORT}" \
  STOCK_V4_REPLAY_ALLOW_CHECKPOINT_DAY=YES \
    bash "${SCRIPT_DIR}/run-stock-v4-underwriter-checkpoint-day.sh"
  stop_batch
  stopped_trade_date="$(wait_for_regular_clock_stop "${trade_date}")"
  if [[ "${stopped_trade_date}" != "${trade_date}" ]]; then
    printf 'FAIL checkpoint batch stop changed the business date: expected=%s actual=%s\n' \
      "${trade_date}" "${stopped_trade_date}" >&2
    exit 1
  fi
  printf 'PASS checkpoint simulation clock stopped date=%s\n' \
    "${stopped_trade_date}"
  trading_days=$((trading_days + 1))
  printf 'PASS controlled checkpoint trading day=%s count=%s\n' \
    "${trade_date}" "${trading_days}"

  completed_lifecycle="$(lifecycle_row)"
  IFS=$'\t' read -r completed_symbol completed_contract_status \
    completed_policy_version completed_policy_status completed_scheduled_count \
    <<< "${completed_lifecycle}"
  if is_terminal_checkpoint_lifecycle \
      "${completed_contract_status}" "${completed_policy_status}" \
      "${completed_scheduled_count}"; then
    printf 'PASS checkpoint completion reached terminal lifecycle symbol=%s contract=%s policy=%s/%s tradingDays=%s\n' \
      "${completed_symbol}" "${completed_contract_status}" \
      "${completed_policy_version}" \
      "${completed_policy_status}" "${trading_days}"
    break
  fi
  if [[ "${completed_contract_status}" != "STABILIZING" \
      || "${completed_policy_status}" != "ACTIVE" ]]; then
    printf 'FAIL checkpoint day ended in unsupported lifecycle contract=%s policy=%s/%s\n' \
      "${completed_contract_status}" "${completed_policy_version}" \
      "${completed_policy_status}" >&2
    exit 1
  fi
  close_and_advance_to_next_open
done

final_date="$(require_regular_stopped_clock)"
printf 'PASS single numeric checkpoint fully completed finalDate=%s symbol=%s tradingDays=%s\n' \
  "${final_date}" "${initial_symbol}" "${trading_days}"
exit 0
