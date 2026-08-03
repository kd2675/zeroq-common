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
: "${STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID:?STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_COMPLETION:-}" != "YES" ]]; then
  printf 'FAIL liquidity-distribution completion requires STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_COMPLETION=YES\n' >&2
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
if [[ ! "${STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL liquidity-distribution plan id must be a positive integer\n' >&2
  exit 1
fi
if [[ -n "${STOCK_V4_REPLAY_DISTRIBUTION_SOURCE_USER_KEY:-}" \
    && ! "${STOCK_V4_REPLAY_DISTRIBUTION_SOURCE_USER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  printf 'FAIL distribution source user key contains unsupported characters\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
PLAN_ID="${STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID}"
DISTRIBUTION_PORT="${STOCK_V4_REPLAY_DISTRIBUTION_BATCH_PORT:-30492}"
EOD_PORT="${STOCK_V4_REPLAY_EOD_BATCH_PORT:-30491}"
START_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_BATCH_START_TIMEOUT_SECONDS:-120}"
PHASE_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_PHASE_TIMEOUT_SECONDS:-600}"
CLOCK_STOP_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_CLOCK_STOP_TIMEOUT_SECONDS:-30}"
MAX_TRADING_DAYS_OVERRIDE="${STOCK_V4_REPLAY_MAX_DISTRIBUTION_DAYS:-}"
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

for port in "${DISTRIBUTION_PORT}" "${EOD_PORT}"; do
  if [[ ! "${port}" =~ ^[0-9]+$ ]] \
      || (( port < 1024 || port > 65535 )); then
    printf 'FAIL replay batch port must be between 1024 and 65535: %s\n' \
      "${port}" >&2
    exit 1
  fi
done
if [[ "${DISTRIBUTION_PORT}" == "${EOD_PORT}" ]]; then
  printf 'FAIL distribution and EOD batch ports must be different\n' >&2
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
if [[ -n "${MAX_TRADING_DAYS_OVERRIDE}" ]]; then
  if [[ ! "${MAX_TRADING_DAYS_OVERRIDE}" =~ ^[1-9][0-9]*$ ]] \
      || (( MAX_TRADING_DAYS_OVERRIDE > 100 )); then
    printf 'FAIL distribution trading-day override must be between 1 and 100\n' >&2
    exit 1
  fi
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
    printf 'FAIL distribution completion requires stopped aligned REGULAR state response=%s\n' \
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
    require_success_json 'distribution clock stop' "${response}"
    if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
        --arg expectedBusinessDate "${expected_business_date}" \
        '.data.marketSession == "REGULAR"
         and .data.activeBusinessDate == $expectedBusinessDate
         and .data.simulationDate == $expectedBusinessDate
         and .data.preparingBusinessDate == null
         and .data.postClosePhase == null
         and .data.postCloseStatus == null' >/dev/null; then
      printf 'FAIL distribution batch stop changed the aligned REGULAR state response=%s\n' \
        "${response}" >&2
      exit 1
    fi
    if printf '%s' "${response}" | "${JQ_BIN}" -e \
        '.data.running == false' >/dev/null; then
      printf '%s' "${response}" | "${JQ_BIN}" -r \
        '.data.activeBusinessDate'
      return 0
    fi
    if (( "$(date +%s)" - started_at >= CLOCK_STOP_TIMEOUT_SECONDS )); then
      printf 'FAIL distribution simulation clock did not stop after batch shutdown response=%s\n' \
        "${response}" >&2
      exit 1
    fi
    sleep 1
  done
}

plan_row() {
  local business_date="$1"
  if [[ ! "${business_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf 'FAIL plan-row business date is invalid: %s\n' \
      "${business_date}" >&2
    exit 1
  fi
  mysql_query "
    SELECT plan.symbol, plan.status, plan.contract_version,
           plan.target_quantity, plan.daily_quantity_limit,
           plan.max_order_quantity, plan.submitted_quantity,
           plan.filled_quantity,
           COALESCE((
             SELECT SUM(execution.quantity)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin origin
               JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                 ON execution.order_id = origin.order_id
                AND execution.side = 'BUY'
                AND execution.source = 'INTERNAL_ORDER_BOOK'
              WHERE origin.role_transfer_plan_id = plan.plan_id
                AND execution.executed_at >= '${business_date} 00:00:00'
                AND execution.executed_at <
                    DATE_ADD('${business_date} 00:00:00', INTERVAL 1 DAY)
           ), 0),
           plan.effective_business_date,
           COALESCE(plan.open_slot, 0), plan.state_reason
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_liquidity_distribution_plan plan
     WHERE plan.plan_id = ${PLAN_ID}
  "
}

is_completed_plan() {
  local status="$1"
  local target="$2"
  local submitted="$3"
  local filled="$4"
  local open_slot="$5"

  [[ "${status}" == "COMPLETED" \
      && "${target}" == "${submitted}" \
      && "${target}" == "${filled}" \
      && "${open_slot}" == "0" ]]
}

require_immutable_plan_contract() {
  local symbol="$1"
  local contract_version="$2"
  local target="$3"
  local daily_limit="$4"
  local max_order="$5"
  local effective="$6"

  if [[ "${symbol}" != "${initial_symbol}" \
      || "${contract_version}" != "${initial_contract_version}" \
      || "${target}" != "${initial_target}" \
      || "${daily_limit}" != "${initial_daily_limit}" \
      || "${max_order}" != "${initial_max_order}" \
      || "${effective}" != "${initial_effective}" ]]; then
    printf 'FAIL liquidity-distribution numeric contract drifted: symbol=%s/%s contractVersion=%s/%s target=%s/%s dailyLimit=%s/%s maxOrder=%s/%s effective=%s/%s\n' \
      "${initial_symbol}" "${symbol}" \
      "${initial_contract_version}" "${contract_version}" \
      "${initial_target}" "${target}" \
      "${initial_daily_limit}" "${daily_limit}" \
      "${initial_max_order}" "${max_order}" \
      "${initial_effective}" "${effective}" >&2
    exit 1
  fi
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
  if [[ "${mode}" == "liquidity-distribution-trading" ]]; then
    STOCK_V4_REPLAY_BATCH_PORT="${port}" \
    STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION=YES \
      bash "${SCRIPT_DIR}/run-stock-v4-replay-batch.sh" \
        --liquidity-distribution-trading >"${batch_log}" 2>&1 &
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

lock_dir="/tmp/stock-v4-liquidity-distribution-completion-${STOCK_MYSQL_REPLAY_SCHEMA}-${PLAN_ID}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another liquidity-distribution completion runner owns %s\n' \
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
initial_plan="$(plan_row "${initial_date}")"
if [[ -z "${initial_plan}" ]]; then
  printf 'FAIL liquidity-distribution plan was not found: %s\n' \
    "${PLAN_ID}" >&2
  exit 1
fi
IFS=$'\t' read -r initial_symbol initial_status initial_contract_version \
  initial_target initial_daily_limit initial_max_order initial_submitted \
  initial_filled initial_daily_filled initial_effective initial_open_slot \
  initial_reason <<< "${initial_plan}"
if [[ ! "${initial_symbol}" =~ ^[A-Z0-9._-]{1,20}$ ]]; then
  printf 'FAIL liquidity-distribution symbol is not canonical: %s\n' \
    "${initial_symbol}" >&2
  exit 1
fi
for numeric_value in \
  "${initial_contract_version}" "${initial_target}" \
  "${initial_daily_limit}" "${initial_max_order}" \
  "${initial_submitted}" "${initial_filled}" \
  "${initial_daily_filled}"; do
  if [[ ! "${numeric_value}" =~ ^[0-9]+$ ]]; then
    printf 'FAIL liquidity-distribution plan contains a non-numeric contract value: %s\n' \
      "${numeric_value}" >&2
    exit 1
  fi
done
if (( initial_contract_version <= 0 \
      || initial_target <= 0 \
      || initial_daily_limit <= 0 \
      || initial_max_order <= 0 \
      || initial_max_order > initial_daily_limit \
      || initial_filled > initial_target \
      || initial_submitted < initial_filled \
      || initial_daily_filled > initial_daily_limit )); then
  printf 'FAIL liquidity-distribution plan numeric contract is invalid\n' >&2
  exit 1
fi
if ! is_completed_plan \
    "${initial_status}" "${initial_target}" "${initial_submitted}" \
    "${initial_filled}" "${initial_open_slot}"; then
  if [[ "${initial_status}" != "SCHEDULED" \
      && "${initial_status}" != "ACTIVE" ]]; then
    printf 'FAIL unsupported liquidity-distribution status: %s\n' \
      "${initial_status}" >&2
    exit 1
  fi
  if [[ "${initial_open_slot}" != "1" ]]; then
    printf 'FAIL liquidity-distribution plan does not own the global open slot: effective=%s current=%s openSlot=%s\n' \
      "${initial_effective}" "${initial_date}" \
      "${initial_open_slot}" >&2
    exit 1
  fi
fi

remaining_quantity=$((initial_target - initial_filled))
current_day_capacity=$((initial_daily_limit - initial_daily_filled))
if (( remaining_quantity == 0 )); then
  required_trading_days=0
elif (( current_day_capacity > 0 )); then
  remaining_after_current=$((remaining_quantity - current_day_capacity))
  if (( remaining_after_current <= 0 )); then
    required_trading_days=1
  else
    required_trading_days=$((
      1 + (remaining_after_current + initial_daily_limit - 1)
        / initial_daily_limit
    ))
  fi
else
  required_trading_days=$((
    1 + (remaining_quantity + initial_daily_limit - 1)
      / initial_daily_limit
  ))
fi
if (( required_trading_days > 100 )); then
  printf 'FAIL derived distribution trading-day guard exceeds 100: %s\n' \
    "${required_trading_days}" >&2
  exit 1
fi
if [[ -n "${MAX_TRADING_DAYS_OVERRIDE}" ]]; then
  if (( MAX_TRADING_DAYS_OVERRIDE < required_trading_days )); then
    printf 'FAIL distribution trading-day override is below the derived minimum: override=%s derived=%s\n' \
      "${MAX_TRADING_DAYS_OVERRIDE}" "${required_trading_days}" >&2
    exit 1
  fi
  MAX_TRADING_DAYS="${MAX_TRADING_DAYS_OVERRIDE}"
else
  MAX_TRADING_DAYS="${required_trading_days}"
fi

printf 'PASS liquidity-distribution completion preflight date=%s plan=%s symbol=%s status=%s filled=%s/%s dailyFilled=%s/%s derivedTradingDays=%s guard=%s state=%s\n' \
  "${initial_date}" "${PLAN_ID}" "${initial_symbol}" \
  "${initial_status}" "${initial_filled}" "${initial_target}" \
  "${initial_daily_filled}" "${initial_daily_limit}" \
  "${required_trading_days}" "${MAX_TRADING_DAYS}" "${initial_reason}"

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS liquidity-distribution completion check-only finished without mutation\n'
  exit 0
fi

trading_days=0
while true; do
  trade_date="$(require_regular_stopped_clock)"
  current_plan="$(plan_row "${trade_date}")"
  IFS=$'\t' read -r symbol status contract_version target daily_limit \
    max_order submitted filled daily_filled effective open_slot reason \
    <<< "${current_plan}"
  require_immutable_plan_contract \
    "${symbol}" "${contract_version}" "${target}" "${daily_limit}" \
    "${max_order}" "${effective}"
  if is_completed_plan \
      "${status}" "${target}" "${submitted}" "${filled}" "${open_slot}"; then
    printf 'PASS liquidity-distribution reached terminal state plan=%s symbol=%s filled=%s/%s tradingDays=%s\n' \
      "${PLAN_ID}" "${symbol}" "${filled}" "${target}" \
      "${trading_days}"
    break
  fi
  if [[ "${status}" != "SCHEDULED" && "${status}" != "ACTIVE" ]]; then
    printf 'FAIL unsupported distribution lifecycle status=%s state=%s\n' \
      "${status}" "${reason}" >&2
    exit 1
  fi
  if (( trading_days >= MAX_TRADING_DAYS )); then
    printf 'FAIL liquidity-distribution exceeded trading-day guard: max=%s\n' \
      "${MAX_TRADING_DAYS}" >&2
    exit 1
  fi

  if [[ "${effective}" > "${trade_date}" ]]; then
    if [[ "${status}" != "SCHEDULED" ]]; then
      printf 'FAIL only a scheduled distribution may advance to a future effective opening: status=%s effective=%s current=%s\n' \
        "${status}" "${effective}" "${trade_date}" >&2
      exit 1
    fi
    printf 'INFO advancing scheduled liquidity distribution to its effective opening current=%s effective=%s\n' \
      "${trade_date}" "${effective}"
    close_and_advance_to_next_open
    opened_date="$(require_regular_stopped_clock)"
    if [[ "${opened_date}" != "${effective}" ]]; then
      printf 'FAIL one controlled EOD transition did not reach the scheduled effective opening: expected=%s actual=%s\n' \
        "${effective}" "${opened_date}" >&2
      exit 1
    fi
    continue
  fi
  start_batch 'liquidity-distribution-trading' "${DISTRIBUTION_PORT}"
  current_day_log="$(
    mktemp "/tmp/stock-v4-liquidity-distribution-day-${PLAN_ID}-${trade_date}.XXXXXX"
  )"
  set +e
  STOCK_V4_REPLAY_BATCH_URL="http://127.0.0.1:${DISTRIBUTION_PORT}" \
  STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_DAY=YES \
    bash "${SCRIPT_DIR}/run-stock-v4-liquidity-distribution-day.sh" \
      2>&1 | tee "${current_day_log}"
  day_exit_code="${PIPESTATUS[0]}"
  set -e
  if [[ "${day_exit_code}" != "0" ]] \
      || ! grep -F \
        "LIQUIDITY_DISTRIBUTION_DAY_OK plan=${PLAN_ID} date=${trade_date}" \
        "${current_day_log}" >/dev/null; then
    printf 'FAIL liquidity-distribution day did not emit its verified completion sentinel: date=%s exit=%s log=%s\n' \
      "${trade_date}" "${day_exit_code}" "${current_day_log}" >&2
    exit 1
  fi
  rm -f "${current_day_log}"
  current_day_log=""
  stop_batch
  stopped_trade_date="$(wait_for_regular_clock_stop "${trade_date}")"
  if [[ "${stopped_trade_date}" != "${trade_date}" ]]; then
    printf 'FAIL distribution batch stop changed the business date: expected=%s actual=%s\n' \
      "${trade_date}" "${stopped_trade_date}" >&2
    exit 1
  fi
  trading_days=$((trading_days + 1))
  printf 'PASS controlled liquidity-distribution trading day=%s count=%s\n' \
    "${trade_date}" "${trading_days}"

  completed_plan="$(plan_row "${trade_date}")"
  IFS=$'\t' read -r completed_symbol completed_status \
    completed_contract_version completed_target completed_daily_limit \
    completed_max_order completed_submitted completed_filled \
    completed_daily_filled completed_effective completed_open_slot \
    completed_reason <<< "${completed_plan}"
  require_immutable_plan_contract \
    "${completed_symbol}" "${completed_contract_version}" \
    "${completed_target}" "${completed_daily_limit}" \
    "${completed_max_order}" "${completed_effective}"
  if is_completed_plan \
      "${completed_status}" "${completed_target}" \
      "${completed_submitted}" "${completed_filled}" \
      "${completed_open_slot}"; then
    printf 'PASS liquidity-distribution reached terminal state plan=%s symbol=%s filled=%s/%s tradingDays=%s\n' \
      "${PLAN_ID}" "${completed_symbol}" "${completed_filled}" \
      "${completed_target}" "${trading_days}"
    break
  fi
  if [[ "${completed_status}" != "ACTIVE" ]]; then
    printf 'FAIL distribution day ended in unsupported status=%s state=%s\n' \
      "${completed_status}" "${completed_reason}" >&2
    exit 1
  fi
  close_and_advance_to_next_open
done

final_date="$(require_regular_stopped_clock)"
final_plan="$(plan_row "${final_date}")"
IFS=$'\t' read -r final_symbol final_status final_contract_version \
  final_target final_daily_limit final_max_order final_submitted \
  final_filled final_daily_filled final_effective final_open_slot \
  final_reason <<< "${final_plan}"
require_immutable_plan_contract \
  "${final_symbol}" "${final_contract_version}" "${final_target}" \
  "${final_daily_limit}" "${final_max_order}" "${final_effective}"
if ! is_completed_plan \
    "${final_status}" "${final_target}" "${final_submitted}" \
    "${final_filled}" "${final_open_slot}"; then
  printf 'FAIL final liquidity-distribution plan does not reconcile\n' >&2
  exit 1
fi

printf 'PASS single numeric liquidity-distribution lever fully completed finalDate=%s plan=%s symbol=%s filled=%s tradingDays=%s state=%s\n' \
  "${final_date}" "${PLAN_ID}" "${final_symbol}" "${final_filled}" \
  "${trading_days}" "${final_reason}"
