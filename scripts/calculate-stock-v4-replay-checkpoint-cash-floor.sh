#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_REPLAY_CONTRACT_ID:?STOCK_V4_REPLAY_CONTRACT_ID is required}"

if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_CONTRACT_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL STOCK_V4_REPLAY_CONTRACT_ID must be a positive integer\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
CHECKPOINT_PORT="${STOCK_V4_REPLAY_CHECKPOINT_BATCH_PORT:-30492}"
EOD_PORT="${STOCK_V4_REPLAY_EOD_BATCH_PORT:-30491}"
DAILY_SUBMISSION_RATE="${STOCK_V4_REPLAY_UNDERWRITER_DAILY_SUBMISSION_RATE:-0.100000}"
SINGLE_ORDER_RATE="${STOCK_V4_REPLAY_UNDERWRITER_SINGLE_ORDER_RATE:-0.020000}"
CONFIGURED_DAILY_ORDER_LIMIT="${STOCK_V4_REPLAY_UNDERWRITER_DAILY_ORDER_LIMIT:-20}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"
JQ_BIN="$(command -v jq || true)"

if [[ ! "${BACK_URL}" =~ ^http://127[.]0[.]0[.]1:[0-9]+$ ]]; then
  printf 'FAIL replay back URL must use an explicit 127.0.0.1 HTTP port\n' >&2
  exit 1
fi
if [[ ! "${ADMIN_USER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  printf 'FAIL replay admin user key contains unsupported characters\n' >&2
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
for port in "${CHECKPOINT_PORT}" "${EOD_PORT}"; do
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
    printf 'FAIL replay batch port must be between 1024 and 65535: %s\n' \
      "${port}" >&2
    exit 1
  fi
  if curl -fsS --max-time 1 \
      "http://127.0.0.1:${port}/actuator/health" >/dev/null 2>&1; then
    printf 'FAIL checkpoint cash-floor calculation requires replay batch port %s to be stopped\n' \
      "${port}" >&2
    exit 1
  fi
done

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

require_positive_integer() {
  local label="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL %s must be a positive integer: %s\n' \
      "${label}" "${value}" >&2
    exit 1
  fi
}

money_to_won() {
  local label="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+([.]00)?$ ]]; then
    printf 'FAIL %s must be a whole-won amount: %s\n' \
      "${label}" "${value}" >&2
    exit 1
  fi
  printf '%s' "${value%%.*}"
}

rate_to_millionths() {
  local label="$1"
  local value="$2"
  local whole
  local fractional
  if [[ ! "${value}" =~ ^(0|1)([.][0-9]{1,6})?$ ]]; then
    printf 'FAIL %s must be between 0.000001 and 1.000000: %s\n' \
      "${label}" "${value}" >&2
    exit 1
  fi
  whole="${value%%.*}"
  if [[ "${value}" == *.* ]]; then
    fractional="${value#*.}"
  else
    fractional=""
  fi
  while (( ${#fractional} < 6 )); do
    fractional="${fractional}0"
  done
  local millionths=$((10#${whole} * 1000000 + 10#${fractional:-0}))
  if (( millionths < 1 || millionths > 1000000 )); then
    printf 'FAIL %s must be between 0.000001 and 1.000000: %s\n' \
      "${label}" "${value}" >&2
    exit 1
  fi
  printf '%s' "${millionths}"
}

scaled_quantity() {
  local base="$1"
  local rate_millionths="$2"
  local scaled=$((base * rate_millionths / 1000000))
  if (( scaled < 1 )); then
    scaled=1
  fi
  printf '%s' "${scaled}"
}

tick_size_for() {
  local market="$1"
  local price="$2"
  case "${market}" in
    ETF|ETN|ELW)
      printf '5'
      ;;
    *)
      if (( price < 2000 )); then
        printf '1'
      elif (( price < 5000 )); then
        printf '5'
      elif (( price < 20000 )); then
        printf '10'
      elif (( price < 50000 )); then
        printf '50'
      elif (( price < 200000 )); then
        printf '100'
      elif (( price < 500000 )); then
        printf '500'
      else
        printf '1000'
      fi
      ;;
  esac
}

ceiling_valid_quote_price() {
  local market="$1"
  local candidate="$2"
  local attempt
  local tick
  if (( candidate < 1 )); then
    candidate=1
  fi
  for attempt in 1 2 3; do
    tick="$(tick_size_for "${market}" "${candidate}")"
    candidate=$(((candidate + tick - 1) / tick * tick))
    if (( candidate % $(tick_size_for "${market}" "${candidate}") == 0 )); then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  printf 'FAIL failed to align quote price market=%s candidate=%s\n' \
    "${market}" "${candidate}" >&2
  exit 1
}

next_valid_quote_price() {
  local market="$1"
  local current_price="$2"
  local current_tick
  current_tick="$(tick_size_for "${market}" "${current_price}")"
  if (( current_price % current_tick != 0 )); then
    printf 'FAIL current price is not a valid Korean quote: market=%s price=%s tick=%s\n' \
      "${market}" "${current_price}" "${current_tick}" >&2
    exit 1
  fi
  ceiling_valid_quote_price "${market}" $((current_price + 1))
}

clock_response="$(curl -sS \
  -H "X-User-Key: ${ADMIN_USER_KEY}" \
  -H 'X-User-Role: ADMIN' \
  "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
if ! printf '%s' "${clock_response}" | "${JQ_BIN}" -e \
    '.success == true
     and .data.running == false
     and (
       (
         .data.marketSession == "REGULAR"
         and .data.activeBusinessDate == .data.simulationDate
         and .data.preparingBusinessDate == null
         and .data.postClosePhase == null
         and .data.postCloseStatus == null
       )
       or
       (
         .data.marketSession == "PRE_OPEN"
         and .data.preparingBusinessDate == .data.simulationDate
         and .data.activeBusinessDate != .data.simulationDate
       )
       or
       (
         .data.marketSession == "AFTER_CLOSE"
         and .data.activeBusinessDate == .data.simulationDate
         and .data.preparingBusinessDate == null
         and .data.postClosePhase == "PORTFOLIO_SETTLED"
         and .data.postCloseStatus == "PENDING"
       )
     )' >/dev/null; then
  printf 'FAIL checkpoint cash-floor calculation requires a stopped stable REGULAR, PRE_OPEN, or PORTFOLIO_SETTLED state response=%s\n' \
    "${clock_response}" >&2
  exit 1
fi
clock_session="$(printf '%s' "${clock_response}" \
  | "${JQ_BIN}" -r '.data.marketSession')"
simulation_date="$(printf '%s' "${clock_response}" \
  | "${JQ_BIN}" -r '.data.simulationDate')"

contract_row="$(mysql_query "
  SELECT contract.contract_code,
         contract.symbol,
         contract.status,
         contract.policy_version,
         contract.stabilization_quantity_limit,
         contract.issue_price,
         instrument.market,
         instrument.tick_size,
         instrument.tradable_shares,
         price.current_price,
         price.previous_close,
         instrument.price_limit_rate,
         holding.quantity,
         holding.reserved_quantity,
         COALESCE((
           SELECT SUM(execution.quantity)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin strategy_origin
             JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
               ON execution.order_id = strategy_origin.order_id
            WHERE strategy_origin.origin_type = 'ISSUE_UNDERWRITER'
              AND strategy_origin.underwriting_contract_id = contract.id
         ), 0) AS lifetime_filled_quantity,
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_order
            WHERE open_order.symbol = contract.symbol
              AND open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
              AND open_order.quantity > open_order.filled_quantity
         ) AS open_symbol_order_count,
         COALESCE((
           SELECT SUM(symbol_holding.reserved_quantity)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding symbol_holding
            WHERE symbol_holding.symbol = contract.symbol
         ), 0) AS symbol_reserved_quantity
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      ON instrument.symbol = contract.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_price price
      ON price.symbol = contract.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      ON holding.account_id = contract.account_id
     AND holding.symbol = contract.symbol
   WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
")"
if [[ -z "${contract_row}" ]]; then
  printf 'FAIL underwriting contract, instrument, price, or holding was not found\n' >&2
  exit 1
fi

IFS=$'\t' read -r contract_code symbol contract_status contract_policy_version \
  stabilization_quantity_limit issue_price_decimal market stored_tick_decimal \
  tradable_shares current_price_decimal previous_close_decimal \
  price_limit_rate_decimal underwriter_holding underwriter_reserved \
  lifetime_filled_quantity open_symbol_order_count symbol_reserved_quantity \
  <<< "${contract_row}"

if [[ ! "${contract_code}" =~ ^[A-Za-z0-9._:-]+$ \
    || ! "${symbol}" =~ ^[A-Z0-9._-]+$ \
    || ! "${market}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'FAIL contract identity contains unsupported characters\n' >&2
  exit 1
fi
for numeric_pair in \
  "contract policy version:${contract_policy_version}" \
  "tradable shares:${tradable_shares}" \
  "underwriter holding:${underwriter_holding}"; do
  require_positive_integer "${numeric_pair%%:*}" "${numeric_pair#*:}"
done
for non_negative_pair in \
  "stabilization quantity limit:${stabilization_quantity_limit}" \
  "underwriter reserved:${underwriter_reserved}" \
  "lifetime filled quantity:${lifetime_filled_quantity}" \
  "open symbol order count:${open_symbol_order_count}" \
  "symbol reserved quantity:${symbol_reserved_quantity}"; do
  if [[ ! "${non_negative_pair#*:}" =~ ^[0-9]+$ ]]; then
    printf 'FAIL %s must be a non-negative integer: %s\n' \
      "${non_negative_pair%%:*}" "${non_negative_pair#*:}" >&2
    exit 1
  fi
done
if [[ "${underwriter_reserved}" != "0" \
    || "${open_symbol_order_count}" != "0" \
    || "${symbol_reserved_quantity}" != "0" ]]; then
  printf 'FAIL cash-floor calculation requires zero open symbol orders and reservations: underwriterReserved=%s openOrders=%s symbolReserved=%s\n' \
    "${underwriter_reserved}" "${open_symbol_order_count}" \
    "${symbol_reserved_quantity}" >&2
  exit 1
fi

policy_row="$(mysql_query "
  SELECT policy.status,
         policy.version_no,
         DATE_FORMAT(policy.effective_business_date, '%Y-%m-%d'),
         JSON_UNQUOTE(JSON_EXTRACT(policy.config_json, '$.preset')),
         JSON_UNQUOTE(JSON_EXTRACT(
           policy.config_json,
           '$.targetDistributedTradableShareRate'
         )),
         JSON_UNQUOTE(JSON_EXTRACT(
           policy.config_json,
           '$.requiredCheckpointQuantity'
         )),
         JSON_UNQUOTE(JSON_EXTRACT(
           policy.config_json,
           '$.capacityReferenceDailyVolume'
         )),
         JSON_UNQUOTE(JSON_EXTRACT(policy.config_json, '$.durationDays')),
         JSON_UNQUOTE(JSON_EXTRACT(
           policy.config_json,
           '$.dailySubmissionQuantityLimit'
         )),
         JSON_UNQUOTE(JSON_EXTRACT(
           policy.config_json,
           '$.singleOrderQuantityLimit'
         )),
         JSON_UNQUOTE(JSON_EXTRACT(policy.config_json, '$.dailyOrderLimit')),
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version candidate
            WHERE candidate.policy_scope = 'UNDERWRITING_CONTRACT'
              AND candidate.scope_key = contract.contract_code
              AND (
                (
                  contract.status = 'STABILIZING'
                  AND candidate.status = 'ACTIVE'
                  AND candidate.version_no = contract.policy_version
                )
                OR
                (
                  contract.status = 'ALLOCATED'
                  AND candidate.status = 'SCHEDULED'
                  AND candidate.version_no = contract.policy_version + 1
                )
              )
         ) AS selected_policy_count
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
      ON policy.policy_scope = 'UNDERWRITING_CONTRACT'
     AND policy.scope_key = contract.contract_code
     AND (
       (
         contract.status = 'STABILIZING'
         AND policy.status = 'ACTIVE'
         AND policy.version_no = contract.policy_version
       )
       OR
       (
         contract.status = 'ALLOCATED'
         AND policy.status = 'SCHEDULED'
         AND policy.version_no = contract.policy_version + 1
       )
     )
   WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
")"
if [[ -z "${policy_row}" ]]; then
  printf 'FAIL exactly one current ACTIVE or next SCHEDULED checkpoint policy is required\n' >&2
  exit 1
fi

IFS=$'\t' read -r policy_status policy_version effective_business_date preset \
  target_rate required_checkpoint_quantity capacity_reference_daily_volume \
  duration_days config_daily_submission_limit config_single_order_limit \
  config_daily_order_limit selected_policy_count <<< "${policy_row}"

if [[ "${selected_policy_count}" != "1" \
    || "${preset}" != "DISTRIBUTED_TRADABLE_SHARE_CHECKPOINT_V1" ]]; then
  printf 'FAIL selected checkpoint policy is ambiguous or not the exact distribution preset: count=%s preset=%s\n' \
    "${selected_policy_count}" "${preset}" >&2
  exit 1
fi
require_positive_integer "policy version" "${policy_version}"
require_positive_integer "required checkpoint quantity" \
  "${required_checkpoint_quantity}"
require_positive_integer "capacity reference daily volume" \
  "${capacity_reference_daily_volume}"
require_positive_integer "duration days" "${duration_days}"

if [[ "${policy_status}" == "ACTIVE" ]]; then
  if [[ "${contract_status}" != "STABILIZING" \
      || "${policy_version}" != "${contract_policy_version}" ]]; then
    printf 'FAIL ACTIVE policy does not match the STABILIZING contract\n' >&2
    exit 1
  fi
  require_positive_integer "daily submission quantity limit" \
    "${config_daily_submission_limit}"
  require_positive_integer "single order quantity limit" \
    "${config_single_order_limit}"
  require_positive_integer "daily order limit" \
    "${config_daily_order_limit}"
  daily_submission_limit="${config_daily_submission_limit}"
  single_order_limit="${config_single_order_limit}"
  daily_order_limit="${config_daily_order_limit}"
  if (( stabilization_quantity_limit <= lifetime_filled_quantity )); then
    printf 'FAIL ACTIVE checkpoint has no positive remaining quantity: limit=%s filled=%s\n' \
      "${stabilization_quantity_limit}" "${lifetime_filled_quantity}" >&2
    exit 1
  fi
  remaining_quantity=$((stabilization_quantity_limit - lifetime_filled_quantity))
elif [[ "${policy_status}" == "SCHEDULED" ]]; then
  if [[ "${contract_status}" != "ALLOCATED" ]] \
      || (( policy_version != contract_policy_version + 1 )); then
    printf 'FAIL SCHEDULED policy is not the next version of the ALLOCATED contract\n' >&2
    exit 1
  fi
  daily_rate_millionths="$(rate_to_millionths \
    "daily submission rate" "${DAILY_SUBMISSION_RATE}")"
  single_rate_millionths="$(rate_to_millionths \
    "single order rate" "${SINGLE_ORDER_RATE}")"
  require_positive_integer "configured daily order limit" \
    "${CONFIGURED_DAILY_ORDER_LIMIT}"
  if (( CONFIGURED_DAILY_ORDER_LIMIT > 100 )); then
    printf 'FAIL configured daily order limit cannot exceed 100\n' >&2
    exit 1
  fi
  daily_submission_limit="$(scaled_quantity \
    "${capacity_reference_daily_volume}" "${daily_rate_millionths}")"
  single_order_limit="$(scaled_quantity \
    "${capacity_reference_daily_volume}" "${single_rate_millionths}")"
  daily_order_limit="${CONFIGURED_DAILY_ORDER_LIMIT}"
  remaining_quantity="${required_checkpoint_quantity}"
else
  printf 'FAIL unsupported checkpoint policy status: %s\n' \
    "${policy_status}" >&2
  exit 1
fi

if (( remaining_quantity > underwriter_holding )); then
  printf 'FAIL checkpoint quantity exceeds unreserved underwriter inventory: remaining=%s holding=%s\n' \
    "${remaining_quantity}" "${underwriter_holding}" >&2
  exit 1
fi
if (( (daily_submission_limit + single_order_limit - 1) / single_order_limit \
    > daily_order_limit )); then
  printf 'FAIL daily quantity limit requires more orders than the checkpoint-day runner permits: daily=%s single=%s orderLimit=%s\n' \
    "${daily_submission_limit}" "${single_order_limit}" \
    "${daily_order_limit}" >&2
  exit 1
fi

issue_price="$(money_to_won "issue price" "${issue_price_decimal}")"
stored_tick="$(money_to_won "stored instrument tick" "${stored_tick_decimal}")"
current_price="$(money_to_won "current price" "${current_price_decimal}")"
previous_close="$(money_to_won "previous close" "${previous_close_decimal}")"
if [[ ! "${price_limit_rate_decimal}" =~ ^[0-9]+([.][0-9]{1,2})?$ ]]; then
  printf 'FAIL price limit rate must have at most two decimal places: %s\n' \
    "${price_limit_rate_decimal}" >&2
  exit 1
fi
price_limit_whole="${price_limit_rate_decimal%%.*}"
if [[ "${price_limit_rate_decimal}" == *.* ]]; then
  price_limit_fractional="${price_limit_rate_decimal#*.}"
else
  price_limit_fractional=""
fi
while (( ${#price_limit_fractional} < 2 )); do
  price_limit_fractional="${price_limit_fractional}0"
done
price_limit_hundredths=$((10#${price_limit_whole} * 100 \
  + 10#${price_limit_fractional:-0}))
if (( price_limit_hundredths <= 0 || price_limit_hundredths >= 10000 )); then
  printf 'FAIL price limit rate must be greater than 0 and less than 100: %s\n' \
    "${price_limit_rate_decimal}" >&2
  exit 1
fi
require_positive_integer "stored instrument tick" "${stored_tick}"
require_positive_integer "current price" "${current_price}"
require_positive_integer "previous close" "${previous_close}"

remaining="${remaining_quantity}"
total_cash=0
total_orders=0
day_count=0
first_buy_price=0
last_buy_price=0
last_sell_price="${current_price}"

while (( remaining > 0 )); do
  day_count=$((day_count + 1))
  if (( day_count > duration_days )); then
    printf 'FAIL checkpoint needs more trading days than its policy duration: requiredDays>%s remaining=%s\n' \
      "${duration_days}" "${remaining}" >&2
    exit 1
  fi
  if (( remaining < daily_submission_limit )); then
    day_quantity="${remaining}"
  else
    day_quantity="${daily_submission_limit}"
  fi
  day_remaining="${day_quantity}"
  day_orders=0
  day_cash=0
  day_first_buy=0
  day_last_buy=0
  lower_numerator=$((previous_close * (10000 - price_limit_hundredths)))
  upper_numerator=$((previous_close * (10000 + price_limit_hundredths)))

  while (( day_remaining > 0 )); do
    day_orders=$((day_orders + 1))
    if (( day_orders > daily_order_limit )); then
      printf 'FAIL simulated checkpoint exceeded the daily order limit: day=%s limit=%s\n' \
        "${day_count}" "${daily_order_limit}" >&2
      exit 1
    fi
    if (( day_remaining < single_order_limit )); then
      order_quantity="${day_remaining}"
    else
      order_quantity="${single_order_limit}"
    fi

    sell_price="$(next_valid_quote_price "${market}" "${current_price}")"
    if (( sell_price < issue_price )); then
      sell_price="${issue_price}"
    fi
    sell_tick="$(tick_size_for "${market}" "${sell_price}")"
    if (( sell_price % sell_tick != 0 )); then
      printf 'FAIL simulated passive SELL is not a valid Korean quote: day=%s order=%s price=%s tick=%s\n' \
        "${day_count}" "${day_orders}" "${sell_price}" "${sell_tick}" >&2
      exit 1
    fi
    if (( sell_price * 10000 < lower_numerator \
        || sell_price * 10000 > upper_numerator )); then
      printf 'FAIL simulated passive SELL reaches the daily price clamp; explicit price-path handling is required: day=%s order=%s price=%s previousClose=%s rate=%s\n' \
        "${day_count}" "${day_orders}" "${sell_price}" "${previous_close}" \
        "${price_limit_rate_decimal}" >&2
      exit 1
    fi

    buy_price=$((sell_price + stored_tick))
    buy_tick="$(tick_size_for "${market}" "${buy_price}")"
    if (( buy_price % buy_tick != 0 )); then
      printf 'FAIL checkpoint-day BUY price would violate the dynamic Korean tick: day=%s order=%s sell=%s storedTick=%s buy=%s dynamicTick=%s\n' \
        "${day_count}" "${day_orders}" "${sell_price}" "${stored_tick}" \
        "${buy_price}" "${buy_tick}" >&2
      exit 1
    fi
    if (( buy_price * 10000 < lower_numerator \
        || buy_price * 10000 > upper_numerator )); then
      printf 'FAIL checkpoint-day BUY price would exceed the daily price band: day=%s order=%s buy=%s previousClose=%s rate=%s\n' \
        "${day_count}" "${day_orders}" "${buy_price}" "${previous_close}" \
        "${price_limit_rate_decimal}" >&2
      exit 1
    fi

    order_cash=$((order_quantity * buy_price))
    day_cash=$((day_cash + order_cash))
    total_cash=$((total_cash + order_cash))
    total_orders=$((total_orders + 1))
    if (( first_buy_price == 0 )); then
      first_buy_price="${buy_price}"
    fi
    if (( day_first_buy == 0 )); then
      day_first_buy="${buy_price}"
    fi
    day_last_buy="${buy_price}"
    last_buy_price="${buy_price}"
    last_sell_price="${sell_price}"
    current_price="${sell_price}"
    day_remaining=$((day_remaining - order_quantity))
    remaining=$((remaining - order_quantity))
  done

  printf 'PLAN checkpoint cash floor day=%s quantity=%s orders=%s firstBuy=%s lastBuy=%s grossCash=%s.00\n' \
    "${day_count}" "${day_quantity}" "${day_orders}" "${day_first_buy}" \
    "${day_last_buy}" "${day_cash}"
  previous_close="${current_price}"
done

printf 'PASS checkpoint cash floor contract=%s symbol=%s policy=%s/%s effectiveDate=%s clock=%s/%s targetRate=%s remaining=%s days=%s orders=%s dailyLimit=%s singleLimit=%s dailyOrderLimit=%s firstBuy=%s lastBuy=%s expectedEndingSell=%s requiredAvailableCash=%s.00\n' \
  "${STOCK_V4_REPLAY_CONTRACT_ID}" "${symbol}" "${policy_status}" \
  "${policy_version}" "${effective_business_date}" "${clock_session}" \
  "${simulation_date}" "${target_rate}" "${remaining_quantity}" \
  "${day_count}" "${total_orders}" "${daily_submission_limit}" \
  "${single_order_limit}" "${daily_order_limit}" "${first_buy_price}" \
  "${last_buy_price}" "${last_sell_price}" "${total_cash}"
