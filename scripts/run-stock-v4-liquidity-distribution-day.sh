#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"
: "${STOCK_V4_REPLAY_BATCH_URL:?STOCK_V4_REPLAY_BATCH_URL is required}"
: "${STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID:?STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_DAY:-}" != "YES" ]]; then
  printf 'FAIL liquidity-distribution day requires STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_DAY=YES\n' >&2
  exit 1
fi
TARGET_ENVIRONMENT="${STOCK_V4_TARGET_ENVIRONMENT:-replay}"
if [[ "${TARGET_ENVIRONMENT}" == "operating" ]]; then
  if [[ "${STOCK_V4_OPERATING_ALLOW_LIQUIDITY_DISTRIBUTION_DAY:-}" != "YES" ]]; then
    printf 'FAIL operating liquidity-distribution day requires STOCK_V4_OPERATING_ALLOW_LIQUIDITY_DISTRIBUTION_DAY=YES\n' >&2
    exit 1
  fi
  if [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" != "STOCK_SERVICE" ]]; then
    printf 'FAIL operating liquidity-distribution day requires exact STOCK_SERVICE schema\n' >&2
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
BATCH_URL="${STOCK_V4_REPLAY_BATCH_URL%/}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
PLAN_ID="${STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID}"
SOURCE_USER_KEY="${STOCK_V4_REPLAY_DISTRIBUTION_SOURCE_USER_KEY:-}"
MAX_TRANCHES="${STOCK_V4_REPLAY_MAX_DISTRIBUTION_TRANCHES:-20}"
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
if [[ ! "${MAX_TRANCHES}" =~ ^[1-9][0-9]*$ ]] \
    || (( MAX_TRANCHES > 100 )); then
  printf 'FAIL distribution tranche guard must be between 1 and 100\n' >&2
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
  local query="$1"
  local output
  local exit_code
  local attempt=1
  local max_attempts=3

  while true; do
    if output="$(
      env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
        "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" \
        --execute="${query}" 2>&1
    )"; then
      printf '%s' "${output}"
      return 0
    else
      exit_code=$?
    fi

    if [[ "${output}" == *"waiting for initial communication packet"* \
        && ${attempt} -lt ${max_attempts} ]]; then
      printf 'WARN transient MySQL pre-connection handshake failure; retrying attempt=%s/%s\n' \
        "$((attempt + 1))" "${max_attempts}" >&2
      attempt=$((attempt + 1))
      sleep 1
      continue
    fi

    printf '%s\n' "${output}" >&2
    return "${exit_code}"
  done
}

require_success_json() {
  local label="$1"
  local response="$2"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e '.success == true' >/dev/null; then
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

plan_state_row() {
  local trade_date="$1"
  mysql_query "
    SELECT plan.symbol,
           plan.status,
           plan.target_quantity,
           plan.daily_quantity_limit,
           plan.max_order_quantity,
           plan.source_account_id,
           plan.target_account_id,
           plan.funding_source_account_id,
           plan.source_opening_quantity,
           plan.target_opening_quantity,
           plan.submitted_quantity,
           plan.filled_quantity,
           plan.state_reason,
           plan.effective_business_date,
           plan.open_slot,
           COALESCE(source_account.user_key, '__NULL__'),
           source_account.status,
           source_account.participant_category,
           source_holding.quantity,
           source_holding.reserved_quantity,
           target_holding.quantity,
           target_holding.reserved_quantity,
           price.current_price,
           COALESCE((
             SELECT SUM(execution.quantity)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin origin
               JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                 ON execution.order_id = origin.order_id
                AND execution.side = 'BUY'
                AND execution.source = 'INTERNAL_ORDER_BOOK'
              WHERE origin.role_transfer_plan_id = plan.plan_id
           ), 0) AS actual_total_filled,
           COALESCE((
             SELECT SUM(execution.quantity)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin origin
               JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                 ON execution.order_id = origin.order_id
                AND execution.side = 'BUY'
                AND execution.source = 'INTERNAL_ORDER_BOOK'
                AND execution.executed_at >= '${trade_date} 00:00:00'
                AND execution.executed_at < DATE_ADD(
                  '${trade_date} 00:00:00',
                  INTERVAL 1 DAY
                )
              WHERE origin.role_transfer_plan_id = plan.plan_id
           ), 0) AS actual_daily_filled,
           (
             SELECT COUNT(*)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_order
              WHERE open_order.symbol = plan.symbol
                AND open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
                AND open_order.quantity > open_order.filled_quantity
           ) AS open_symbol_orders,
           (
             SELECT COUNT(*)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_source
              WHERE open_source.account_id = plan.source_account_id
                AND open_source.symbol = plan.symbol
                AND open_source.side = 'SELL'
                AND open_source.market_type = 'ORDER_BOOK'
                AND open_source.order_type = 'LIMIT'
                AND open_source.status IN ('PENDING', 'PARTIALLY_FILLED')
                AND open_source.quantity > open_source.filled_quantity
           ) AS open_source_orders,
           (
             SELECT COUNT(*)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin origin
               JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_target
                 ON open_target.id = origin.order_id
              WHERE origin.role_transfer_plan_id = plan.plan_id
                AND open_target.status IN ('PENDING', 'PARTIALLY_FILLED')
                AND open_target.quantity > open_target.filled_quantity
           ) AS open_target_orders
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_liquidity_distribution_plan plan
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account source_account
        ON source_account.id = plan.source_account_id
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding source_holding
        ON source_holding.account_id = plan.source_account_id
       AND source_holding.symbol = plan.symbol
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding target_holding
        ON target_holding.account_id = plan.target_account_id
       AND target_holding.symbol = plan.symbol
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_price price
        ON price.symbol = plan.symbol
     WHERE plan.plan_id = ${PLAN_ID}
  "
}

load_plan_state() {
  local trade_date="$1"
  local row
  row="$(plan_state_row "${trade_date}")"
  if [[ -z "${row}" ]]; then
    printf 'FAIL liquidity-distribution plan state was not found: %s\n' \
      "${PLAN_ID}" >&2
    exit 1
  fi
  IFS=$'\t' read -r symbol plan_status target_quantity daily_limit \
    single_limit source_account_id target_account_id funding_account_id \
    source_opening_quantity target_opening_quantity submitted_quantity \
    recorded_filled_quantity state_reason effective_business_date open_slot \
    source_user_key source_account_status source_category source_quantity \
    source_reserved_quantity target_holding_quantity target_reserved_quantity \
    current_price actual_total_filled actual_daily_filled open_symbol_orders \
    open_source_orders open_target_orders <<< "${row}"
}

assert_isolated_open_orders() {
  if (( open_symbol_orders != open_source_orders + open_target_orders )); then
    printf 'FAIL unrelated open order entered the distribution symbol book: symbol=%s all=%s source=%s target=%s\n' \
      "${symbol}" "${open_symbol_orders}" "${open_source_orders}" \
      "${open_target_orders}" >&2
    exit 1
  fi
  if (( open_source_orders > 1 || open_target_orders > 1 )); then
    printf 'FAIL distribution plan has multiple open source or target orders: source=%s target=%s\n' \
      "${open_source_orders}" "${open_target_orders}" >&2
    exit 1
  fi
}

lock_dir="/tmp/stock-v4-liquidity-distribution-day-${STOCK_MYSQL_REPLAY_SCHEMA}-${PLAN_ID}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another liquidity-distribution day runner owns %s\n' \
    "${lock_dir}" >&2
  exit 1
fi

active_source_order_id=""
source_category=""
cleanup() {
  local exit_code=$?
  if [[ -n "${active_source_order_id}" \
      && "${source_category}" == "MANUAL_PARTICIPANT" \
      && -n "${SOURCE_USER_KEY}" ]]; then
    linked_count="$(mysql_query "
      SELECT COUNT(*)
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_liquidity_distribution_source_order
       WHERE source_order_id = ${active_source_order_id}
    " 2>/dev/null || printf '1')"
    if [[ "${linked_count}" == "0" ]]; then
      curl -sS -X DELETE \
        -H "X-User-Key: ${SOURCE_USER_KEY}" \
        -H 'X-User-Role: USER' \
        "${BACK_URL}/api/stock/v1/orders/${active_source_order_id}" \
        >/dev/null || true
    fi
  fi
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
  printf 'FAIL liquidity-distribution day requires running aligned REGULAR state response=%s\n' \
    "${clock_response}" >&2
  exit 1
fi

load_plan_state "${trade_date}"
if [[ "${source_user_key}" == "__NULL__" ]]; then
  source_user_key=""
fi
if [[ ! "${symbol}" =~ ^[A-Z0-9._-]{1,20}$ ]]; then
  printf 'FAIL distribution symbol is not canonical: %s\n' "${symbol}" >&2
  exit 1
fi
if [[ "${source_account_status}" != "ACTIVE" \
    || ( "${source_category}" != "MANUAL_PARTICIPANT" \
      && "${source_category}" != "ISSUE_UNDERWRITER" ) ]]; then
  printf 'FAIL source account identity or role mismatch: account=%s user=%s status=%s category=%s\n' \
    "${source_account_id}" "${source_user_key}" \
    "${source_account_status}" "${source_category}" >&2
  exit 1
fi
if [[ "${source_category}" == "MANUAL_PARTICIPANT" \
    && ( -z "${SOURCE_USER_KEY}" \
      || "${source_user_key}" != "${SOURCE_USER_KEY}" ) ]]; then
  printf 'FAIL manual distribution source requires its exact user key: account=%s expected=%s actual=%s\n' \
    "${source_account_id}" "${source_user_key}" "${SOURCE_USER_KEY}" >&2
  exit 1
fi
if [[ "${source_category}" == "ISSUE_UNDERWRITER" \
    && ( -n "${source_user_key}" || -n "${SOURCE_USER_KEY}" ) ]]; then
  printf 'FAIL issue-underwriter source must remain a non-login system account: account=%s dbUser=%s suppliedUser=%s\n' \
    "${source_account_id}" "${source_user_key:-NONE}" \
    "${SOURCE_USER_KEY:-NONE}" >&2
  exit 1
fi
underwriting_contract_id=""
underwriting_policy_version=""
if [[ "${source_category}" == "MANUAL_PARTICIPANT" ]]; then
  competing_underwriter_count="$(mysql_query "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract
     WHERE symbol = '${symbol}'
       AND status = 'STABILIZING'
  ")"
  if [[ "${competing_underwriter_count}" != "0" ]]; then
    printf 'FAIL manual distribution cannot overlap an active underwriting checkpoint: symbol=%s contracts=%s\n' \
      "${symbol}" "${competing_underwriter_count}" >&2
    exit 1
  fi
else
  underwriter_row="$(mysql_query "
    SELECT contract.id,
           contract.status,
           contract.policy_version,
           policy.status,
           policy.effective_business_date,
           contract.stabilization_quantity_limit,
           COALESCE((
             SELECT SUM(execution.quantity)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin origin
               JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                 ON execution.order_id = origin.order_id
                AND execution.side = 'SELL'
                AND execution.source = 'INTERNAL_ORDER_BOOK'
              WHERE origin.origin_type = 'ISSUE_UNDERWRITER'
                AND origin.underwriting_contract_id = contract.id
           ), 0)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
        ON policy.policy_scope = 'UNDERWRITING_CONTRACT'
       AND policy.scope_key = contract.contract_code
       AND policy.version_no = contract.policy_version
     WHERE contract.symbol = '${symbol}'
       AND contract.account_id = ${source_account_id}
       AND contract.status = 'STABILIZING'
       AND policy.status = 'ACTIVE'
  ")"
  if [[ -z "${underwriter_row}" \
      || "$(printf '%s\n' "${underwriter_row}" | wc -l | tr -d ' ')" != "1" ]]; then
    printf 'FAIL issue-underwriter distribution requires exactly one owned active checkpoint: account=%s symbol=%s\n' \
      "${source_account_id}" "${symbol}" >&2
    exit 1
  fi
  IFS=$'\t' read -r underwriting_contract_id underwriting_contract_status \
    underwriting_policy_version underwriting_policy_status \
    underwriting_effective_date underwriting_quantity_limit \
    underwriting_filled_quantity <<< "${underwriter_row}"
  underwriting_remaining_quantity=$(( \
    underwriting_quantity_limit - underwriting_filled_quantity \
  ))
  if [[ "${underwriting_contract_status}" != "STABILIZING" \
      || "${underwriting_policy_status}" != "ACTIVE" \
      || "${underwriting_effective_date}" != "${effective_business_date}" \
      || "${underwriting_remaining_quantity}" \
        != "$((target_quantity - actual_total_filled))" ]]; then
    printf 'FAIL issue-underwriter checkpoint does not reconcile with the distribution plan: contract=%s policy=%s effective=%s/%s remaining=%s/%s\n' \
      "${underwriting_contract_status}" "${underwriting_policy_status}" \
      "${underwriting_effective_date}" "${effective_business_date}" \
      "${underwriting_remaining_quantity}" \
      "$((target_quantity - actual_total_filled))" >&2
    exit 1
  fi
fi
if [[ "${plan_status}" != "SCHEDULED" && "${plan_status}" != "ACTIVE" ]]; then
  printf 'FAIL distribution day requires SCHEDULED or ACTIVE plan: status=%s\n' \
    "${plan_status}" >&2
  exit 1
fi
if [[ "${effective_business_date}" > "${trade_date}" || "${open_slot}" != "1" ]]; then
  printf 'FAIL distribution plan is not due at this opening: effective=%s tradeDate=%s openSlot=%s\n' \
    "${effective_business_date}" "${trade_date}" "${open_slot}" >&2
  exit 1
fi
assert_isolated_open_orders
run_batch_job \
  'liquidity-distribution initial reconciliation job' \
  '/internal/stock-batch/v1/jobs/scaled-market-liquidity-distribution/run'
load_plan_state "${trade_date}"
assert_isolated_open_orders
if [[ "${recorded_filled_quantity}" != "${actual_total_filled}" \
    || "${submitted_quantity}" -lt "${actual_total_filled}" \
    || ( "${submitted_quantity}" != "${actual_total_filled}" \
      && "${open_target_orders}" == "0" ) ]]; then
  printf 'FAIL distribution plan starts with invalid progress: submitted=%s recorded=%s actual=%s openTarget=%s\n' \
    "${submitted_quantity}" "${recorded_filled_quantity}" \
    "${actual_total_filled}" "${open_target_orders}" >&2
  exit 1
fi

initial_total_filled="${actual_total_filled}"
initial_remaining=$((target_quantity - initial_total_filled))
initial_daily_filled="${actual_daily_filled}"
initial_daily_remaining=$((daily_limit - initial_daily_filled))
expected_daily_fill="${initial_remaining}"
if (( expected_daily_fill > initial_daily_remaining )); then
  expected_daily_fill="${initial_daily_remaining}"
fi
printf 'PASS liquidity-distribution day preflight date=%s plan=%s symbol=%s remaining=%s dailyLimit=%s singleLimit=%s price=%s\n' \
  "${trade_date}" "${PLAN_ID}" "${symbol}" "${initial_remaining}" \
  "${daily_limit}" "${single_limit}" "${current_price}"

tranche_count=0
while (( tranche_count < MAX_TRANCHES )); do
  load_plan_state "${trade_date}"
  assert_isolated_open_orders
  if [[ "${plan_status}" == "COMPLETED" ]]; then
    break
  fi

  remaining_quantity=$((target_quantity - actual_total_filled))
  remaining_daily_quantity=$((daily_limit - actual_daily_filled))
  if (( remaining_quantity == 0 || remaining_daily_quantity == 0 )); then
    run_batch_job \
      'liquidity-distribution reconciliation job' \
      '/internal/stock-batch/v1/jobs/scaled-market-liquidity-distribution/run'
    break
  fi

  run_batch_job \
    'liquidity-distribution target-order job' \
    '/internal/stock-batch/v1/jobs/scaled-market-liquidity-distribution/run'
  run_batch_job \
    'liquidity-distribution execution job' \
    '/internal/stock-batch/v1/jobs/order-book-execution/run'
  run_batch_job \
    'liquidity-distribution post-execution reconciliation job' \
    '/internal/stock-batch/v1/jobs/scaled-market-liquidity-distribution/run'

  load_plan_state "${trade_date}"
  assert_isolated_open_orders
  if (( open_symbol_orders != 0 )); then
    printf 'FAIL distribution tranche did not clear the isolated order book: all=%s source=%s target=%s\n' \
      "${open_symbol_orders}" "${open_source_orders}" \
      "${open_target_orders}" >&2
    exit 1
  fi
  active_source_order_id=""

  if [[ "${plan_status}" == "COMPLETED" ]]; then
    break
  fi
  remaining_quantity=$((target_quantity - actual_total_filled))
  remaining_daily_quantity=$((daily_limit - actual_daily_filled))
  if (( remaining_quantity == 0 || remaining_daily_quantity == 0 )); then
    break
  fi

  order_quantity="${remaining_quantity}"
  if (( order_quantity > remaining_daily_quantity )); then
    order_quantity="${remaining_daily_quantity}"
  fi
  if (( order_quantity > single_limit )); then
    order_quantity="${single_limit}"
  fi
  if (( order_quantity <= 0 )); then
    printf 'FAIL bounded source quantity is not positive\n' >&2
    exit 1
  fi
  if (( source_quantity - source_reserved_quantity < order_quantity )); then
    printf 'FAIL source inventory is insufficient for bounded tranche: available=%s required=%s\n' \
      "$((source_quantity - source_reserved_quantity))" \
      "${order_quantity}" >&2
    exit 1
  fi

  if [[ "${source_category}" == "MANUAL_PARTICIPANT" ]]; then
    client_order_id="replay-lpd-${PLAN_ID}-${trade_date//-/}-${actual_total_filled}"
    sell_payload="$("${JQ_BIN}" -cn \
      --arg symbol "${symbol}" \
      --arg clientOrderId "${client_order_id}" \
      --argjson limitPrice "${current_price}" \
      --argjson quantity "${order_quantity}" \
      '{symbol: $symbol, marketType: "ORDER_BOOK", side: "SELL", orderType: "LIMIT", limitPrice: $limitPrice, quantity: $quantity, clientOrderId: $clientOrderId}')"
    sell_response="$(curl -sS -X POST \
      -H 'Content-Type: application/json' \
      -H "X-User-Key: ${SOURCE_USER_KEY}" \
      -H 'X-User-Role: USER' \
      --data "${sell_payload}" \
      "${BACK_URL}/api/stock/v1/orders")"
    require_success_json 'distribution source sell order' "${sell_response}"
    active_source_order_id="$(
      printf '%s' "${sell_response}" | "${JQ_BIN}" -r '.data.id'
    )"
    source_order_price="${current_price}"
  else
    run_batch_job \
      'issue-underwriter distribution source-order job' \
      '/internal/stock-batch/v1/jobs/issue-underwriter-market/run'
    source_order_row="$(mysql_query "
      SELECT COUNT(*),
             COALESCE(MIN(open_order.id), 0),
             COALESCE(MIN(open_order.limit_price), 0),
             COALESCE(SUM(
               open_order.quantity - open_order.filled_quantity
             ), 0),
             COALESCE(MIN(origin.policy_version), 0)
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_order
        JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin origin
          ON origin.order_id = open_order.id
       WHERE open_order.account_id = ${source_account_id}
         AND open_order.symbol = '${symbol}'
         AND open_order.side = 'SELL'
         AND open_order.market_type = 'ORDER_BOOK'
         AND open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
         AND open_order.quantity > open_order.filled_quantity
         AND origin.origin_type = 'ISSUE_UNDERWRITER'
         AND origin.underwriting_contract_id =
             ${underwriting_contract_id}
    ")"
    IFS=$'\t' read -r source_order_count active_source_order_id \
      source_order_price source_order_quantity source_order_policy_version \
      <<< "${source_order_row}"
    if [[ "${source_order_count}" != "1" \
        || "${source_order_quantity}" != "${order_quantity}" \
        || "${source_order_policy_version}" \
          != "${underwriting_policy_version}" ]]; then
      printf 'FAIL issue-underwriter source order does not match the bounded distribution tranche: count=%s quantity=%s/%s policy=%s/%s\n' \
        "${source_order_count}" "${source_order_quantity}" \
        "${order_quantity}" "${source_order_policy_version}" \
        "${underwriting_policy_version}" >&2
      exit 1
    fi
  fi
  if [[ ! "${active_source_order_id}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL source sell response did not contain a positive order id\n' >&2
    exit 1
  fi
  tranche_count=$((tranche_count + 1))
  printf 'PASS source tranche queued date=%s tranche=%s order=%s quantity=%s price=%s\n' \
    "${trade_date}" "${tranche_count}" "${active_source_order_id}" \
    "${order_quantity}" "${source_order_price}"
done

if (( tranche_count >= MAX_TRANCHES )); then
  printf 'FAIL liquidity-distribution day exceeded tranche guard: max=%s\n' \
    "${MAX_TRANCHES}" >&2
  exit 1
fi

load_plan_state "${trade_date}"
assert_isolated_open_orders
if [[ "${source_category}" == "ISSUE_UNDERWRITER" \
    && "${plan_status}" == "COMPLETED" ]]; then
  run_batch_job \
    'issue-underwriter checkpoint completion job' \
    '/internal/stock-batch/v1/jobs/issue-underwriter-market/run'
  underwriter_terminal_row="$(mysql_query "
    SELECT contract.status,
           (
             SELECT COUNT(*)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
              WHERE policy.policy_scope = 'UNDERWRITING_CONTRACT'
                AND policy.scope_key = contract.contract_code
                AND policy.version_no = contract.policy_version
                AND policy.status = 'ACTIVE'
           ),
           daily_state.state_status,
           daily_state.gate_reason
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_daily_supply_state daily_state
        ON daily_state.underwriting_contract_id = contract.id
       AND daily_state.simulation_trade_date = '${trade_date}'
     WHERE contract.id = ${underwriting_contract_id}
  ")"
  IFS=$'\t' read -r underwriting_terminal_status active_policy_count \
    underwriting_daily_status underwriting_gate_reason \
    <<< "${underwriter_terminal_row}"
  if [[ ( "${underwriting_terminal_status}" != "ALLOCATED" \
        && "${underwriting_terminal_status}" != "COMPLETED" ) \
      || "${active_policy_count}" != "0" \
      || "${underwriting_daily_status}" != "COMPLETED" \
      || "${underwriting_gate_reason}" != "FILLED_TARGET_REACHED" ]]; then
    printf 'FAIL issue-underwriter checkpoint did not reach a clean terminal boundary: contract=%s activePolicy=%s daily=%s gate=%s\n' \
      "${underwriting_terminal_status}" "${active_policy_count}" \
      "${underwriting_daily_status}" "${underwriting_gate_reason}" >&2
    exit 1
  fi
  printf 'PASS issue-underwriter checkpoint retired after direct LP distribution contract=%s policy=%s terminal=%s\n' \
    "${underwriting_contract_id}" "${underwriting_policy_version}" \
    "${underwriting_terminal_status}"
fi
if (( open_symbol_orders != 0 \
      || source_reserved_quantity != 0 \
      || target_reserved_quantity != 0 )); then
  printf 'FAIL distribution day left open orders or reservations: open=%s sourceReserved=%s targetReserved=%s\n' \
    "${open_symbol_orders}" "${source_reserved_quantity}" \
    "${target_reserved_quantity}" >&2
  exit 1
fi
if [[ "${recorded_filled_quantity}" != "${actual_total_filled}" \
    || "${submitted_quantity}" != "${actual_total_filled}" ]]; then
  printf 'FAIL final distribution progress is not reconciled: submitted=%s recorded=%s actual=%s\n' \
    "${submitted_quantity}" "${recorded_filled_quantity}" \
    "${actual_total_filled}" >&2
  exit 1
fi
filled_this_run=$((actual_total_filled - initial_total_filled))
if (( filled_this_run != expected_daily_fill )); then
  printf 'FAIL distribution day fill differs from the exact bounded target: expected=%s actual=%s\n' \
    "${expected_daily_fill}" "${filled_this_run}" >&2
  exit 1
fi
expected_source_quantity=$((source_opening_quantity - actual_total_filled))
expected_target_quantity=$((target_opening_quantity + actual_total_filled))
if (( source_quantity != expected_source_quantity \
      || target_holding_quantity != expected_target_quantity )); then
  printf 'FAIL distribution holdings do not reconcile: source=%s/%s target=%s/%s\n' \
    "${source_quantity}" "${expected_source_quantity}" \
    "${target_holding_quantity}" "${expected_target_quantity}" >&2
  exit 1
fi
if [[ "${plan_status}" != "ACTIVE" && "${plan_status}" != "COMPLETED" ]]; then
  printf 'FAIL unsupported distribution plan status after trading: %s\n' \
    "${plan_status}" >&2
  exit 1
fi

printf 'PASS liquidity-distribution day complete date=%s plan=%s symbol=%s filledThisRun=%s totalFilled=%s remaining=%s status=%s state=%s openOrders=0 reserved=0\n' \
  "${trade_date}" "${PLAN_ID}" "${symbol}" "${filled_this_run}" \
  "${actual_total_filled}" "$((target_quantity - actual_total_filled))" \
  "${plan_status}" "${state_reason}"
printf 'LIQUIDITY_DISTRIBUTION_DAY_OK plan=%s date=%s filled=%s\n' \
  "${PLAN_ID}" "${trade_date}" "${filled_this_run}"
