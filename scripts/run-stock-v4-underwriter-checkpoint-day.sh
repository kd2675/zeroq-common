#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"
: "${STOCK_V4_REPLAY_BATCH_URL:?STOCK_V4_REPLAY_BATCH_URL is required}"
: "${STOCK_V4_REPLAY_CONTRACT_ID:?STOCK_V4_REPLAY_CONTRACT_ID is required}"
: "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY:?STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_CHECKPOINT_DAY:-}" != "YES" ]]; then
  printf 'FAIL checkpoint day requires STOCK_V4_REPLAY_ALLOW_CHECKPOINT_DAY=YES\n' >&2
  exit 1
fi

if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
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
BATCH_URL="${STOCK_V4_REPLAY_BATCH_URL%/}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"
JQ_BIN="$(command -v jq || true)"
MAX_TRANCHES="${STOCK_V4_REPLAY_MAX_TRANCHES:-100}"

if [[ -z "${MYSQL_BIN}" || ! -x "${MYSQL_BIN}" ]]; then
  printf 'FAIL mysql client was not found; set STOCK_MYSQL_BIN\n' >&2
  exit 1
fi
if [[ -z "${JQ_BIN}" || ! -x "${JQ_BIN}" ]]; then
  printf 'FAIL jq was not found\n' >&2
  exit 1
fi
if [[ ! "${MAX_TRANCHES}" =~ ^[1-9][0-9]*$ ]] || (( MAX_TRANCHES > 100 )); then
  printf 'FAIL STOCK_V4_REPLAY_MAX_TRANCHES must be between 1 and 100\n' >&2
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

require_success_json() {
  local label="$1"
  local response="$2"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e '.success == true' >/dev/null; then
    printf 'FAIL %s response=%s\n' "${label}" "${response}" >&2
    exit 1
  fi
}

lock_name="${STOCK_MYSQL_REPLAY_SCHEMA}_${STOCK_V4_REPLAY_CONTRACT_ID}"
lock_dir="/tmp/stock-v4-underwriter-checkpoint-${lock_name}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another checkpoint-day runner already owns %s\n' "${lock_dir}" >&2
  exit 1
fi

active_buy_order_id=""
cleanup() {
  local exit_code=$?
  if [[ -n "${active_buy_order_id}" ]]; then
    curl -sS -X DELETE \
      -H "X-User-Key: ${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" \
      -H 'X-User-Role: USER' \
      "${BACK_URL}/api/stock/v1/orders/${active_buy_order_id}" >/dev/null || true
  fi
  rmdir "${lock_dir}" 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT

health_response="$(curl -sS "${BATCH_URL}/actuator/health")"
if [[ "$(printf '%s' "${health_response}" | "${JQ_BIN}" -r '.status // ""')" != "UP" ]]; then
  printf 'FAIL replay batch health is not UP response=%s\n' "${health_response}" >&2
  exit 1
fi

clock_response="$(curl -sS \
  -H "X-User-Key: ${ADMIN_USER_KEY}" \
  -H 'X-User-Role: ADMIN' \
  "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
require_success_json 'simulation clock' "${clock_response}"

trade_date="$(printf '%s' "${clock_response}" | "${JQ_BIN}" -r '.data.simulationDate')"
simulation_date_time="$(printf '%s' "${clock_response}" | "${JQ_BIN}" -r '.data.simulationDateTime')"
active_business_date="$(printf '%s' "${clock_response}" | "${JQ_BIN}" -r '.data.activeBusinessDate')"
market_session="$(printf '%s' "${clock_response}" | "${JQ_BIN}" -r '.data.marketSession')"
clock_running="$(printf '%s' "${clock_response}" | "${JQ_BIN}" -r '.data.running')"

if [[ "${market_session}" != "REGULAR" \
    || "${clock_running}" != "true" \
    || "${active_business_date}" != "${trade_date}" ]]; then
  printf 'FAIL checkpoint day requires running REGULAR session with aligned business date: simulationDateTime=%s active=%s session=%s running=%s\n' \
    "${simulation_date_time}" "${active_business_date}" "${market_session}" "${clock_running}" >&2
  exit 1
fi

contract_row="$(mysql_query "
  SELECT contract.symbol,
         contract.status,
         contract.policy_version,
         policy.status,
         JSON_UNQUOTE(JSON_EXTRACT(policy.config_json, '$.requiredCheckpointQuantity')),
         JSON_UNQUOTE(JSON_EXTRACT(policy.config_json, '$.dailySubmissionQuantityLimit')),
         JSON_UNQUOTE(JSON_EXTRACT(policy.config_json, '$.singleOrderQuantityLimit'))
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
      ON policy.policy_scope = 'UNDERWRITING_CONTRACT'
     AND policy.scope_key = contract.contract_code
     AND policy.version_no = contract.policy_version
   WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
")"
if [[ -z "${contract_row}" ]]; then
  printf 'FAIL underwriting contract or current policy was not found\n' >&2
  exit 1
fi

IFS=$'\t' read -r symbol contract_status policy_version policy_status \
  required_checkpoint_quantity daily_submission_limit single_order_limit \
  <<< "${contract_row}"
if [[ ! "${symbol}" =~ ^[A-Z0-9._-]+$ ]]; then
  printf 'FAIL contract symbol is not safe for replay verification: %s\n' "${symbol}" >&2
  exit 1
fi
if [[ "${contract_status}" != "STABILIZING" || "${policy_status}" != "ACTIVE" ]]; then
  printf 'FAIL checkpoint policy must be STABILIZING/ACTIVE: contract=%s policy=%s version=%s\n' \
    "${contract_status}" "${policy_status}" "${policy_version}" >&2
  exit 1
fi

printf 'PASS checkpoint day preflight date=%s symbol=%s contract=%s policyVersion=%s required=%s dailyLimit=%s singleLimit=%s\n' \
  "${trade_date}" "${symbol}" "${STOCK_V4_REPLAY_CONTRACT_ID}" \
  "${policy_version}" "${required_checkpoint_quantity}" \
  "${daily_submission_limit}" "${single_order_limit}"

tranche_count=0
filled_this_run=0
while (( tranche_count < MAX_TRANCHES )); do
  job_response="$(curl -sS -X POST \
    -H "X-Internal-Token: ${STOCK_BATCH_INTERNAL_TOKEN}" \
    "${BATCH_URL}/internal/stock-batch/v1/jobs/issue-underwriter-market/run")"
  require_success_json 'issue-underwriter job' "${job_response}"

  lifecycle_row="$(mysql_query "
    SELECT status, policy_version
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract
     WHERE id = ${STOCK_V4_REPLAY_CONTRACT_ID}
  ")"
  IFS=$'\t' read -r current_contract_status current_policy_version \
    <<< "${lifecycle_row}"
  if [[ "${current_contract_status}" == "ALLOCATED" \
      || "${current_contract_status}" == "COMPLETED" ]]; then
    break
  fi
  if [[ "${current_contract_status}" != "STABILIZING" \
      || "${current_policy_version}" != "${policy_version}" ]]; then
    printf 'FAIL checkpoint lifecycle changed unexpectedly: status=%s version=%s\n' \
      "${current_contract_status}" "${current_policy_version}" >&2
    exit 1
  fi

  open_sell_row="$(mysql_query "
    SELECT COUNT(*),
           COALESCE(MIN(open_order.id), 0),
           COALESCE(MIN(open_order.limit_price + instrument.tick_size), 0),
           COALESCE(SUM(open_order.quantity - open_order.filled_quantity), 0)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_order
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin strategy_origin
        ON strategy_origin.order_id = open_order.id
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
        ON instrument.symbol = open_order.symbol
     WHERE strategy_origin.underwriting_contract_id = ${STOCK_V4_REPLAY_CONTRACT_ID}
       AND strategy_origin.origin_type = 'ISSUE_UNDERWRITER'
       AND open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
       AND open_order.quantity > open_order.filled_quantity
  ")"
  IFS=$'\t' read -r open_sell_count sell_order_id buy_limit_price sell_remaining_quantity \
    <<< "${open_sell_row}"

  if [[ "${open_sell_count}" == "0" ]]; then
    daily_gate="$(mysql_query "
      SELECT CONCAT(state_status, ':', gate_reason)
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_daily_supply_state
       WHERE simulation_trade_date = '${trade_date}'
         AND underwriting_contract_id = ${STOCK_V4_REPLAY_CONTRACT_ID}
    ")"
    if [[ "${daily_gate}" == 'GATED:DAILY_SUBMISSION_LIMIT_REACHED' \
        || "${daily_gate}" == 'COMPLETED:FILLED_TARGET_REACHED' ]]; then
      break
    fi
    printf 'FAIL underwriter job produced no open sell and no terminal daily gate: gate=%s\n' \
      "${daily_gate:-MISSING}" >&2
    exit 1
  fi
  if [[ "${open_sell_count}" != "1" || "${sell_remaining_quantity}" -le 0 ]]; then
    printf 'FAIL expected exactly one positive open contract sell: count=%s quantity=%s\n' \
      "${open_sell_count}" "${sell_remaining_quantity}" >&2
    exit 1
  fi
  open_symbol_order_count="$(mysql_query "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order
     WHERE symbol = '${symbol}'
       AND status IN ('PENDING', 'PARTIALLY_FILLED')
       AND quantity > filled_quantity
  ")"
  if [[ "${open_symbol_order_count}" != "1" ]]; then
    printf 'FAIL controlled replay requires the contract sell to be the only open symbol order: open=%s\n' \
      "${open_symbol_order_count}" >&2
    exit 1
  fi

  cash_capacity_row="$(mysql_query "
    SELECT account.cash_balance,
           account.cash_balance - COALESCE((
             SELECT SUM(open_buy.reserved_cash)
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_buy
              WHERE open_buy.account_id = account.id
                AND open_buy.side = 'BUY'
                AND open_buy.status IN ('PENDING', 'PARTIALLY_FILLED')
           ), 0) AS available_cash,
           ${buy_limit_price} * ${sell_remaining_quantity}
             AS required_cash,
           GREATEST(
             ${buy_limit_price} * ${sell_remaining_quantity}
               - (
                 account.cash_balance - COALESCE((
                   SELECT SUM(open_buy.reserved_cash)
                     FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_buy
                    WHERE open_buy.account_id = account.id
                      AND open_buy.side = 'BUY'
                      AND open_buy.status IN (
                        'PENDING', 'PARTIALLY_FILLED'
                      )
                 ), 0)
               ),
             0
           ) AS cash_shortfall
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
     WHERE account.user_key = '${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}'
       AND account.status = 'ACTIVE'
  ")"
  if [[ -z "${cash_capacity_row}" ]]; then
    printf 'FAIL active counterparty account was not found: %s\n' \
      "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" >&2
    exit 1
  fi
  IFS=$'\t' read -r cash_balance available_cash required_cash cash_shortfall \
    <<< "${cash_capacity_row}"
  if [[ "${cash_shortfall}" != "0.00" && "${cash_shortfall}" != "0" ]]; then
    printf 'FAIL counterparty cash capacity is insufficient: balance=%s available=%s required=%s shortfall=%s\n' \
      "${cash_balance}" "${available_cash}" "${required_cash}" \
      "${cash_shortfall}" >&2
    exit 1
  fi

  client_order_id="replay-cp-${STOCK_V4_REPLAY_CONTRACT_ID}-${trade_date//-/}-${sell_order_id}"
  buy_payload="$("${JQ_BIN}" -cn \
    --arg symbol "${symbol}" \
    --arg clientOrderId "${client_order_id}" \
    --argjson limitPrice "${buy_limit_price}" \
    --argjson quantity "${sell_remaining_quantity}" \
    '{symbol: $symbol, marketType: "ORDER_BOOK", side: "BUY", orderType: "LIMIT", limitPrice: $limitPrice, quantity: $quantity, clientOrderId: $clientOrderId}')"
  buy_response="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-User-Key: ${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" \
    -H 'X-User-Role: USER' \
    --data "${buy_payload}" \
    "${BACK_URL}/api/stock/v1/orders")"
  require_success_json 'counterparty buy order' "${buy_response}"
  active_buy_order_id="$(printf '%s' "${buy_response}" | "${JQ_BIN}" -r '.data.id')"

  execution_response="$(curl -sS -X POST \
    -H "X-Internal-Token: ${STOCK_BATCH_INTERNAL_TOKEN}" \
    "${BATCH_URL}/internal/stock-batch/v1/jobs/order-book-execution/run")"
  require_success_json 'order-book execution job' "${execution_response}"

  fill_row="$(mysql_query "
    SELECT sell_order.status,
           sell_order.filled_quantity,
           buy_order.status,
           buy_order.filled_quantity
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order sell_order
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order buy_order
        ON buy_order.id = ${active_buy_order_id}
     WHERE sell_order.id = ${sell_order_id}
  ")"
  IFS=$'\t' read -r sell_status sell_filled_quantity buy_status buy_filled_quantity \
    <<< "${fill_row}"
  if [[ "${sell_status}" != "FILLED" \
      || "${buy_status}" != "FILLED" \
      || "${sell_filled_quantity}" != "${sell_remaining_quantity}" \
      || "${buy_filled_quantity}" != "${sell_remaining_quantity}" ]]; then
    printf 'FAIL exact checkpoint fill mismatch: sell=%s/%s buy=%s/%s expected=%s\n' \
      "${sell_status}" "${sell_filled_quantity}" \
      "${buy_status}" "${buy_filled_quantity}" \
      "${sell_remaining_quantity}" >&2
    exit 1
  fi

  active_buy_order_id=""
  tranche_count=$((tranche_count + 1))
  filled_this_run=$((filled_this_run + sell_remaining_quantity))
  printf 'PASS tranche=%s sellOrder=%s quantity=%s buyPrice=%s\n' \
    "${tranche_count}" "${sell_order_id}" \
    "${sell_remaining_quantity}" "${buy_limit_price}"
done

if (( tranche_count >= MAX_TRANCHES )); then
  printf 'FAIL checkpoint day exceeded the configured tranche guard: max=%s\n' \
    "${MAX_TRANCHES}" >&2
  exit 1
fi

result_row="$(mysql_query "
  SELECT contract.status,
         policy.status,
         holding.quantity,
         holding.reserved_quantity,
         COALESCE(daily_state.state_status, 'MISSING'),
         COALESCE(daily_state.gate_reason, 'MISSING'),
         COALESCE(daily_state.submitted_quantity, 0),
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_order
            WHERE open_order.symbol = contract.symbol
              AND open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
              AND open_order.quantity > open_order.filled_quantity
         )
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
      ON policy.policy_scope = 'UNDERWRITING_CONTRACT'
     AND policy.scope_key = contract.contract_code
     AND policy.version_no = contract.policy_version
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      ON holding.account_id = contract.account_id
     AND holding.symbol = contract.symbol
    LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_daily_supply_state daily_state
      ON daily_state.underwriting_contract_id = contract.id
     AND daily_state.simulation_trade_date = '${trade_date}'
   WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
")"
IFS=$'\t' read -r final_contract_status final_policy_status holding_quantity \
  reserved_quantity daily_status daily_gate submitted_quantity open_symbol_orders \
  <<< "${result_row}"

if [[ "${reserved_quantity}" != "0" || "${open_symbol_orders}" != "0" ]]; then
  printf 'FAIL checkpoint day left reservations or open symbol orders: reserved=%s open=%s\n' \
    "${reserved_quantity}" "${open_symbol_orders}" >&2
  exit 1
fi
if [[ "${final_contract_status}" == "STABILIZING" \
    && "${daily_status}:${daily_gate}" != 'GATED:DAILY_SUBMISSION_LIMIT_REACHED' ]]; then
  printf 'FAIL active checkpoint day did not reach its daily limit: status=%s gate=%s\n' \
    "${daily_status}" "${daily_gate}" >&2
  exit 1
fi
if [[ "${final_contract_status}" != "STABILIZING" \
    && "${final_contract_status}" != "ALLOCATED" \
    && "${final_contract_status}" != "COMPLETED" ]]; then
  printf 'FAIL unsupported final contract status=%s\n' "${final_contract_status}" >&2
  exit 1
fi

printf 'PASS checkpoint day complete date=%s symbol=%s filledThisRun=%s submittedToday=%s contract=%s policy=%s holding=%s daily=%s:%s openOrders=0 reserved=0\n' \
  "${trade_date}" "${symbol}" "${filled_this_run}" "${submitted_quantity}" \
  "${final_contract_status}" "${final_policy_status}" "${holding_quantity}" \
  "${daily_status}" "${daily_gate}"
