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
: "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION:?STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION is required}"
: "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID:?STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID is required}"
: "${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID:?STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID is required}"
: "${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID:?STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID is required}"
: "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT:?STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT is required}"
: "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES:?STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES is required}"
: "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES:?STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES is required}"
: "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION:?STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION is required}"
: "${STOCK_V4_REPLAY_EXPECTED_DAILY_VOLUME:?STOCK_V4_REPLAY_EXPECTED_DAILY_VOLUME is required}"
: "${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_LOWER:?STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_LOWER is required}"
: "${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_UPPER:?STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_UPPER is required}"
: "${STOCK_V4_REPLAY_EXPECTED_AUTO_MARKET_MAX_ORDER_TOTAL:?STOCK_V4_REPLAY_EXPECTED_AUTO_MARKET_MAX_ORDER_TOTAL is required}"
: "${STOCK_V4_REPLAY_EXPECTED_ENGINE_PARTICIPANTS:?STOCK_V4_REPLAY_EXPECTED_ENGINE_PARTICIPANTS is required}"
: "${STOCK_V4_REPLAY_EXPECTED_REPRESENTED_PARTICIPANTS:?STOCK_V4_REPLAY_EXPECTED_REPRESENTED_PARTICIPANTS is required}"
: "${STOCK_V4_REPLAY_EXPECTED_POPULATION_WEIGHT:?STOCK_V4_REPLAY_EXPECTED_POPULATION_WEIGHT is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_CONTRACT_ACTIVATION_GATE:-}" != "YES" ]]; then
  printf 'FAIL contract-activation gate requires STOCK_V4_REPLAY_ALLOW_CONTRACT_ACTIVATION_GATE=YES\n' >&2
  exit 1
fi
TARGET_ENVIRONMENT="${STOCK_V4_TARGET_ENVIRONMENT:-replay}"
OPERATING_BATCH_ALLOW=""
if [[ "${TARGET_ENVIRONMENT}" == "operating" ]]; then
  if [[ "${STOCK_V4_OPERATING_ALLOW_CONTRACT_ACTIVATION_GATE:-}" != "YES" ]]; then
    printf 'FAIL operating contract-activation gate requires STOCK_V4_OPERATING_ALLOW_CONTRACT_ACTIVATION_GATE=YES\n' >&2
    exit 1
  fi
  if [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" != "STOCK_SERVICE" \
      || "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}" != "STOCK_BATCH_METADATA" ]]; then
    printf 'FAIL operating contract-activation gate requires exact STOCK_SERVICE and STOCK_BATCH_METADATA schemas\n' >&2
    exit 1
  fi
  OPERATING_BATCH_ALLOW="YES"
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

for numeric_value in \
  "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
  "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}" \
  "${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}" \
  "${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}" \
  "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
  "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION}" \
  "${STOCK_V4_REPLAY_EXPECTED_DAILY_VOLUME}" \
  "${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_LOWER}" \
  "${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_UPPER}" \
  "${STOCK_V4_REPLAY_EXPECTED_AUTO_MARKET_MAX_ORDER_TOTAL}" \
  "${STOCK_V4_REPLAY_EXPECTED_ENGINE_PARTICIPANTS}" \
  "${STOCK_V4_REPLAY_EXPECTED_REPRESENTED_PARTICIPANTS}" \
  "${STOCK_V4_REPLAY_EXPECTED_POPULATION_WEIGHT}"; do
  if [[ ! "${numeric_value}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL contract-activation numeric values must be positive integers: %s\n' \
      "${numeric_value}" >&2
    exit 1
  fi
done
if (( STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES
      > STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES )); then
  printf 'FAIL expected tradable shares cannot exceed issued shares\n' >&2
  exit 1
fi
if (( STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_LOWER
      > STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_UPPER )); then
  printf 'FAIL expected turnover lower bound cannot exceed upper bound\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
BATCH_PORT="${STOCK_V4_REPLAY_ACTIVATION_BATCH_PORT:-30491}"
START_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_BATCH_START_TIMEOUT_SECONDS:-120}"
PHASE_TIMEOUT_SECONDS="${STOCK_V4_REPLAY_PHASE_TIMEOUT_SECONDS:-900}"
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

if [[ ! "${BATCH_PORT}" =~ ^[0-9]+$ ]] \
    || (( BATCH_PORT < 1024 || BATCH_PORT > 65535 )); then
  printf 'FAIL activation batch port must be between 1024 and 65535\n' >&2
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

assert_quiescent_ledgers() {
  assert_equals \
    "open orders" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order
     WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
    "
  assert_equals \
    "reserved holding quantity" \
    "0" \
    "
    SELECT COALESCE(SUM(reserved_quantity), 0)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding
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

assert_population_contract() {
  assert_equals \
    "population contract" \
    "${STOCK_V4_REPLAY_EXPECTED_ENGINE_PARTICIPANTS}|${STOCK_V4_REPLAY_EXPECTED_REPRESENTED_PARTICIPANTS}|${STOCK_V4_REPLAY_EXPECTED_POPULATION_WEIGHT}" \
    "
    SELECT CONCAT(
             engine_participant_count, '|',
             represented_participant_count, '|',
             CAST(population_weight AS UNSIGNED)
           )
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_participant_population_contract
     WHERE contract_version =
           ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
    "
  assert_equals \
    "active engine participants" \
    "${STOCK_V4_REPLAY_EXPECTED_ENGINE_PARTICIPANTS}" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_participant
     WHERE enabled = true
       AND withdrawn_at IS NULL
    "
}

assert_scheduled_contract() {
  assert_equals \
    "scheduled scaled-market contract" \
    "SCHEDULED|${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}|${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}|${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}|${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}|${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}|${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION}|${STOCK_V4_REPLAY_EXPECTED_DAILY_VOLUME}|${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_LOWER}|${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_UPPER}" \
    "
    SELECT CONCAT_WS(
             '|',
             status,
             share_rebase_plan_id,
             price_capital_rebase_plan_id,
             role_capacity_plan_id,
             target_mature_symbol_count,
             target_issued_shares,
             CAST(target_market_capitalization AS UNSIGNED),
             target_daily_volume,
             CAST(target_daily_turnover_lower AS UNSIGNED),
             CAST(target_daily_turnover_upper AS UNSIGNED)
           )
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract
     WHERE contract_version =
           ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
    "
  assert_equals \
    "scheduled rebase plan state mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan
     WHERE plan_id IN (
       ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID},
       ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID},
       ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
     )
       AND (
         (rebase_stage = 'SHARE_STRUCTURE'
           AND status <> 'APPLIED')
         OR (
           rebase_stage IN ('PRICE_CAPITAL', 'MARKET_ROLE_CAPACITY')
           AND status NOT IN ('SCHEDULED', 'APPLIED')
         )
       )
    "
  assert_equals \
    "rebase and contract effective-date mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan plan
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract contract
        ON contract.contract_version = plan.contract_version
     WHERE plan.plan_id IN (
       ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID},
       ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID},
       ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
     )
       AND (
         plan.contract_version <>
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
         OR plan.effective_business_date IS NULL
         OR plan.status NOT IN ('SCHEDULED', 'APPLIED')
         OR (
           plan.status = 'SCHEDULED'
           AND plan.effective_business_date <>
               contract.effective_business_date
         )
         OR (
           plan.status = 'APPLIED'
           AND plan.effective_business_date >
               contract.effective_business_date
         )
       )
    "
}

assert_plan_shapes() {
  assert_equals \
    "price-capital target symbol count" \
    "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
    "
  assert_equals \
    "price-capital target market capitalization" \
    "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION}" \
    "
    SELECT CAST(SUM(target_market_capitalization) AS UNSIGNED)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
    "
  assert_equals \
    "price-capital per-symbol contract target mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_symbol_plan symbol_plan
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target symbol_target
        ON symbol_target.contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND symbol_target.symbol = symbol_plan.symbol
     WHERE symbol_plan.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
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
    "role-capacity header contract" \
    "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}|${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}|4|32" \
    "
    SELECT CONCAT_WS(
             '|',
             target_auto_market_config_count,
             target_liquidity_mandate_count,
             target_institution_portfolio_count,
             target_institution_mandate_count
           )
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_capacity_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
    "
  assert_equals \
    "role-capacity automatic-market plan count" \
    "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_auto_market_capacity_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
    "
  assert_equals \
    "role-capacity automatic-market target maximum total" \
    "${STOCK_V4_REPLAY_EXPECTED_AUTO_MARKET_MAX_ORDER_TOTAL}" \
    "
    SELECT SUM(target_max_order_quantity)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_auto_market_capacity_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
    "
  assert_equals \
    "role-capacity automatic-market ratio or symbol mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_auto_market_capacity_plan planned
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        ON target.contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND target.symbol = planned.symbol
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract contract
        ON contract.contract_version = target.contract_version
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_daily_snapshot baseline
        ON baseline.close_run_id = contract.baseline_close_run_id
       AND baseline.symbol = target.symbol
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
       AND (
         target.symbol IS NULL
         OR planned.source_enabled = false
         OR planned.source_max_order_quantity <= 0
         OR planned.source_order_ttl_seconds <= 0
         OR planned.source_tradable_shares <= 0
         OR planned.source_tradable_shares <>
              COALESCE(
                target.pre_rebase_tradable_shares,
                baseline.tradable_shares
              )
         OR planned.target_tradable_shares
              <> target.target_tradable_shares
         OR planned.target_daily_volume
              <> target.target_daily_volume
         OR planned.target_max_order_quantity <>
              LEAST(
                planned.target_tradable_shares,
                CEILING(planned.target_daily_volume * 0.120000)
              )
       )
    "
  assert_equals \
    "role-capacity LP plan count" \
    "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_lp_capacity_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
    "
  assert_equals \
    "role-capacity institution portfolio count" \
    "4" \
    "
    SELECT COUNT(DISTINCT portfolio_id)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_institution_capacity_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
    "
  assert_equals \
    "role-capacity institution mandate count" \
    "32" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_institution_capacity_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
    "
  assert_equals \
    "role-capacity target daily volume" \
    "${STOCK_V4_REPLAY_EXPECTED_DAILY_VOLUME}" \
    "
    SELECT SUM(target_reference_daily_volume)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_lp_capacity_plan
     WHERE plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
    "
  assert_equals \
    "role-capacity LP per-symbol target mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_lp_capacity_plan planned
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        ON target.contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND target.symbol = planned.symbol
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract contract
        ON contract.contract_version = target.contract_version
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_daily_snapshot baseline
        ON baseline.close_run_id = contract.baseline_close_run_id
       AND baseline.symbol = target.symbol
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
       AND (
         target.symbol IS NULL
         OR planned.target_reference_daily_volume
              <> target.target_daily_volume
         OR planned.source_tradable_shares <>
              COALESCE(
                target.pre_rebase_tradable_shares,
                baseline.tradable_shares
              )
         OR planned.target_tradable_shares
              <> target.target_tradable_shares
         OR planned.target_target_inventory_quantity <>
              CEILING(
                CAST(
                  planned.source_target_inventory_quantity
                  AS DECIMAL(30, 0)
                )
                * planned.target_tradable_shares
                / planned.source_tradable_shares
              )
         OR planned.target_target_inventory_quantity
              + planned.target_inventory_band_quantity
              > planned.target_tradable_shares
         OR planned.source_account_nav <= 0
         OR planned.target_account_nav <= 0
         OR planned.daily_loss_nav_rate <= 0
         OR planned.daily_loss_nav_rate > 0.1000000000
       )
    "
}

verify_applied_contract() {
  assert_equals \
    "active scaled-market contract" \
    "ACTIVE|${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}|${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}|${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}" \
    "
    SELECT CONCAT_WS(
             '|',
             status,
             share_rebase_plan_id,
             price_capital_rebase_plan_id,
             role_capacity_plan_id
           )
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract
     WHERE contract_version =
           ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
    "
  assert_equals \
    "applied rebase plan count" \
    "3" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan
     WHERE plan_id IN (
       ${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID},
       ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID},
       ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
     )
       AND status = 'APPLIED'
       AND applied_at IS NOT NULL
    "
  assert_equals \
    "active mature target symbol count" \
    "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target
     WHERE contract_version =
           ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND lifecycle_status = 'MATURE'
       AND activation_business_date IS NOT NULL
    "
  assert_equals \
    "applied issued and tradable shares" \
    "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}|${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES}" \
    "
    SELECT CONCAT(
             CAST(SUM(instrument.issued_shares) AS UNSIGNED),
             '|',
             CAST(SUM(instrument.tradable_shares) AS UNSIGNED)
           )
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        ON target.contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND target.symbol = instrument.symbol
    "
  assert_equals \
    "applied per-symbol economic target mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
        ON instrument.symbol = target.symbol
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_price price
        ON price.symbol = target.symbol
     WHERE target.contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND (
         instrument.symbol IS NULL
         OR price.symbol IS NULL
         OR instrument.issued_shares <> target.target_issued_shares
         OR instrument.tradable_shares <> target.target_tradable_shares
         OR instrument.initial_price <> target.target_reference_price
         OR price.current_price <> target.target_reference_price
         OR price.previous_close <> target.target_reference_price
         OR instrument.issued_shares * price.current_price
              <> target.target_market_capitalization
       )
    "
  assert_equals \
    "applied market capitalization" \
    "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION}" \
    "
    SELECT CAST(
             SUM(instrument.issued_shares * price.current_price)
             AS UNSIGNED
           )
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_price price
        ON price.symbol = instrument.symbol
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        ON target.contract_version =
             ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND target.symbol = instrument.symbol
    "
  assert_equals \
    "price-capital account cash mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_account_plan planned
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
        ON account.id = planned.account_id
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       AND NOT EXISTS (
         SELECT 1
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
           JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan recipient
             ON recipient.plan_id = redistribution.plan_id
          WHERE redistribution.contract_version =
                ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
            AND redistribution.status = 'COMPLETED'
            AND recipient.account_id = planned.account_id
       )
       AND NOT EXISTS (
         SELECT 1
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
           JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
             ON source.plan_id = redistribution.plan_id
          WHERE redistribution.contract_version =
                ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
            AND redistribution.status = 'COMPLETED'
            AND source.source_lp_account_id = planned.account_id
       )
       AND (
         account.id IS NULL
         OR account.cash_balance <> planned.target_cash_balance
       )
    "
  assert_equals \
    "price-capital account holding-value mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_account_plan planned
      LEFT JOIN (
        SELECT holding.account_id,
               SUM(holding.quantity * price.current_price)
                 AS actual_holding_market_value
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_price price
            ON price.symbol = holding.symbol
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
            ON target.contract_version =
                 ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
           AND target.symbol = holding.symbol
         GROUP BY holding.account_id
      ) actual
        ON actual.account_id = planned.account_id
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       AND NOT EXISTS (
         SELECT 1
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
           JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan recipient
             ON recipient.plan_id = redistribution.plan_id
          WHERE redistribution.contract_version =
                ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
            AND redistribution.status = 'COMPLETED'
            AND recipient.account_id = planned.account_id
       )
       AND NOT EXISTS (
         SELECT 1
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
           JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
             ON source.plan_id = redistribution.plan_id
          WHERE redistribution.contract_version =
                ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
            AND redistribution.status = 'COMPLETED'
            AND source.source_lp_account_id = planned.account_id
       )
       AND COALESCE(actual.actual_holding_market_value, 0.00)
             <> planned.target_holding_market_value
    "
  assert_equals \
    "price-capital cohort AUM mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_capital_cohort_plan cohort
      LEFT JOIN (
        SELECT planned.participant_category,
               COUNT(*) AS actual_account_count,
               SUM(account.cash_balance) AS actual_cash,
               SUM(planned.target_holding_market_value)
                 AS actual_holding_market_value
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_account_plan planned
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
            ON account.id = planned.account_id
         WHERE planned.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
         GROUP BY planned.participant_category
      ) actual
        ON actual.participant_category = cohort.participant_category
     WHERE cohort.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       AND (
         NOT EXISTS (
           SELECT 1
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
            WHERE redistribution.contract_version =
                  ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
              AND redistribution.status = 'COMPLETED'
         )
         OR cohort.participant_category NOT IN (
           'LIQUIDITY_PROVIDER',
           'INSTITUTIONAL_INVESTOR'
         )
       )
       AND (
         actual.participant_category IS NULL
         OR actual.actual_account_count <> cohort.current_account_count
         OR actual.actual_cash <> cohort.target_cash
         OR actual.actual_holding_market_value
              <> cohort.target_holding_market_value
         OR actual.actual_cash + actual.actual_holding_market_value
              <> cohort.target_aum
       )
    "
  assert_equals \
    "price-capital cash-flow audit row count" \
    "$(
      mysql_query "
      SELECT COUNT(*)
        FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_account_plan
       WHERE plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
         AND cash_delta <> 0.00
      "
    )" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account_cash_flow
     WHERE reason = 'SCALED_MARKET_REBASE'
       AND created_by =
           CONCAT(
             'SCALED_MARKET_REBASE:',
             ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
           )
       AND effective_business_date = (
         SELECT effective_business_date
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan
          WHERE plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       )
    "
  assert_equals \
    "price-capital cash-flow audit mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account_cash_flow flow
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_account_plan planned
        ON planned.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       AND planned.account_id = flow.account_id
     WHERE flow.reason = 'SCALED_MARKET_REBASE'
       AND flow.created_by =
           CONCAT(
             'SCALED_MARKET_REBASE:',
             ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
           )
       AND flow.effective_business_date = (
         SELECT effective_business_date
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan
          WHERE plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       )
       AND (
         planned.account_id IS NULL
         OR planned.cash_delta = 0.00
         OR flow.amount <> ABS(planned.cash_delta)
         OR flow.flow_type <>
            CASE
              WHEN planned.cash_delta > 0.00 THEN 'DEPOSIT'
              ELSE 'WITHDRAW'
            END
       )
    "
  assert_equals \
    "price-capital planned cash-flow account mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_account_plan planned
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       AND planned.cash_delta <> 0.00
       AND (
         SELECT COUNT(*)
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account_cash_flow flow
          WHERE flow.account_id = planned.account_id
            AND flow.reason = 'SCALED_MARKET_REBASE'
            AND flow.created_by =
                CONCAT(
                  'SCALED_MARKET_REBASE:',
                  ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
                )
            AND flow.effective_business_date = (
              SELECT effective_business_date
                FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_plan
               WHERE plan_id =
                     ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
            )
            AND flow.amount = ABS(planned.cash_delta)
            AND flow.flow_type =
                CASE
                  WHEN planned.cash_delta > 0.00 THEN 'DEPOSIT'
                  ELSE 'WITHDRAW'
                END
       ) <> 1
    "
  assert_equals \
    "price-capital holding mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_rebase_holding_plan planned
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
        ON holding.account_id = planned.account_id
       AND holding.symbol = planned.symbol
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}
       AND NOT EXISTS (
         SELECT 1
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
           JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan recipient
             ON recipient.plan_id = redistribution.plan_id
          WHERE redistribution.contract_version =
                ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
            AND redistribution.status = 'COMPLETED'
            AND recipient.account_id = planned.account_id
       )
       AND NOT EXISTS (
         SELECT 1
           FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
           JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
             ON source.plan_id = redistribution.plan_id
          WHERE redistribution.contract_version =
                ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
            AND redistribution.status = 'COMPLETED'
            AND source.source_lp_account_id = planned.account_id
       )
       AND (
         holding.account_id IS NULL
         OR holding.quantity <> planned.target_quantity
         OR holding.reserved_quantity <> 0
         OR holding.average_price <> planned.target_average_price
       )
    "
  assert_equals \
    "completed role-redistribution plan count" \
    "1" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan
     WHERE contract_version =
           ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
       AND status = 'COMPLETED'
       AND state_reason = 'DISTRIBUTION_COMPLETED'
    "
  assert_equals \
    "completed role-redistribution live ledger mismatches" \
    "0" \
    "
    SELECT COUNT(*)
      FROM (
        SELECT CONCAT('recipient:', recipient.account_id) AS mismatch_key
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan recipient
            ON recipient.plan_id = redistribution.plan_id
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
            ON account.id = recipient.account_id
         WHERE redistribution.contract_version =
               ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
           AND redistribution.status = 'COMPLETED'
           AND (
             account.cash_balance <> recipient.target_final_cash
             OR (
               SELECT COALESCE(SUM(
                        holding.quantity * price.current_price
                      ), 0)
                 FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
                 JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_price price
                   ON price.symbol = holding.symbol
                WHERE holding.account_id = recipient.account_id
             ) <> recipient.target_final_stock_market_value
             OR account.cash_balance + (
               SELECT COALESCE(SUM(
                        holding.quantity * price.current_price
                      ), 0)
                 FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
                 JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_price price
                   ON price.symbol = holding.symbol
                WHERE holding.account_id = recipient.account_id
             ) <> recipient.target_final_aum
           )
        UNION ALL
        SELECT CONCAT(
                 'recipient-holding:', snapshot.account_id, ':',
                 snapshot.symbol
               ) AS mismatch_key
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_holding_plan snapshot
            ON snapshot.plan_id = redistribution.plan_id
          LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_allocation_plan allocation
            ON allocation.plan_id = snapshot.plan_id
           AND allocation.target_account_id = snapshot.account_id
           AND allocation.symbol = snapshot.symbol
          LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
            ON holding.account_id = snapshot.account_id
           AND holding.symbol = snapshot.symbol
         WHERE redistribution.contract_version =
               ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
           AND redistribution.status = 'COMPLETED'
           AND (
             COALESCE(holding.quantity, 0) <>
               snapshot.source_quantity
               + COALESCE(allocation.target_quantity, 0)
             OR COALESCE(holding.reserved_quantity, 0) <> 0
           )
        UNION ALL
        SELECT CONCAT('lp:', source.source_lp_account_id, ':', source.symbol)
               AS mismatch_key
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan source
            ON source.plan_id = redistribution.plan_id
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
            ON account.id = source.source_lp_account_id
          JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
            ON holding.account_id = source.source_lp_account_id
           AND holding.symbol = source.symbol
         WHERE redistribution.contract_version =
               ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
           AND redistribution.status = 'COMPLETED'
           AND (
             holding.quantity <> source.target_final_quantity
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
        UNION ALL
        SELECT CONCAT('execution:', redistribution.plan_id)
               AS mismatch_key
          FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
         WHERE redistribution.contract_version =
               ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
           AND redistribution.status = 'COMPLETED'
           AND (
             redistribution.target_transfer_quantity <> (
               SELECT COALESCE(SUM(execution.quantity), 0)
                 FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
                 JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                   ON execution.order_id = order_link.order_id
                  AND execution.side = 'BUY'
                  AND execution.source = 'INTERNAL_ORDER_BOOK'
                WHERE order_link.plan_id = redistribution.plan_id
                  AND order_link.side = 'BUY'
             )
             OR redistribution.target_transfer_quantity <> (
               SELECT COALESCE(SUM(execution.quantity), 0)
                 FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
                 JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
                   ON execution.order_id = order_link.order_id
                  AND execution.side = 'SELL'
                  AND execution.source = 'INTERNAL_ORDER_BOOK'
                WHERE order_link.plan_id = redistribution.plan_id
                  AND order_link.side = 'SELL'
             )
           )
      ) mismatch
    "
  assert_equals \
    "automatic-market role-capacity mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_auto_market_capacity_plan planned
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_market_config config
        ON config.symbol = planned.symbol
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
       AND (
         config.symbol IS NULL
         OR config.enabled = false
         OR config.max_order_quantity
              <> planned.target_max_order_quantity
         OR config.order_ttl_seconds
              <> planned.source_order_ttl_seconds
       )
    "
  assert_equals \
    "LP role-capacity mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_lp_capacity_plan planned
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_liquidity_mandate mandate
        ON mandate.id = planned.mandate_id
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
       AND (
         mandate.id IS NULL
         OR mandate.policy_version <> planned.target_policy_version
         OR mandate.reference_daily_volume <>
            planned.target_reference_daily_volume
         OR mandate.max_order_quantity <> planned.target_max_order_quantity
         OR mandate.target_inventory_quantity <>
            planned.target_target_inventory_quantity
         OR mandate.inventory_band_quantity <>
            planned.target_inventory_band_quantity
         OR mandate.daily_loss_limit_amount <>
            planned.target_daily_loss_limit_amount
       )
    "
  assert_equals \
    "institution role-capacity mismatch count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_institution_capacity_plan planned
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_institution_portfolio portfolio
        ON portfolio.id = planned.portfolio_id
      LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_institution_symbol_mandate mandate
        ON mandate.portfolio_id = planned.portfolio_id
       AND mandate.symbol = planned.symbol
     WHERE planned.plan_id = ${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}
       AND (
         portfolio.id IS NULL
         OR portfolio.policy_version <> planned.target_policy_version
         OR mandate.id IS NULL
         OR mandate.enabled = false
         OR mandate.reference_daily_volume <>
            planned.target_reference_daily_volume
         OR mandate.daily_participation_rate <>
            planned.target_daily_participation_rate
       )
    "
  assert_equals \
    "live V3 policy count" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_participant_policy_revision
     WHERE behavior_model_version = 'V3'
       AND (
         status <> 'RETIRED'
         OR runtime_enabled = true
       )
    "
  assert_equals \
    "active V4 policy count" \
    "1" \
    "
    SELECT COUNT(*)
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_participant_policy_revision
     WHERE behavior_model_version = 'V4'
       AND status = 'ACTIVE'
       AND runtime_enabled = true
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
  batch_log="/tmp/stock-v4-contract-activation-${BATCH_PORT}-$$.log"
  STOCK_V4_OPERATING_ALLOW_BATCH="${OPERATING_BATCH_ALLOW}" \
  STOCK_V4_REPLAY_BATCH_PORT="${BATCH_PORT}" \
  STOCK_V4_REPLAY_ALLOW_EOD_TRANSITION=YES \
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

lock_dir="/tmp/stock-v4-contract-activation-${STOCK_MYSQL_REPLAY_SCHEMA}-${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another contract-activation runner owns %s\n' \
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

initial_clock="$(clock_response)"
require_success_json 'contract-activation initial clock' "${initial_clock}"
if ! printf '%s' "${initial_clock}" | "${JQ_BIN}" -e \
    '.data.marketSession == "PRE_OPEN"
     and .data.running == false
     and (.data.simulationDateTime | endswith("T04:30:00"))
     and .data.preparingBusinessDate == .data.simulationDate
     and .data.activeBusinessDate != .data.simulationDate
     and .data.postClosePhase == "REPORTS_AGGREGATED"
     and (.data.postCloseStatus == "PENDING"
       or .data.postCloseStatus == "DEFERRED")' >/dev/null; then
  printf 'FAIL contract activation requires a stopped prepared reports gate response=%s\n' \
    "${initial_clock}" >&2
  exit 1
fi
effective_business_date="$(
  printf '%s' "${initial_clock}" | "${JQ_BIN}" -r '.data.preparingBusinessDate'
)"

assert_scheduled_contract
assert_plan_shapes
assert_population_contract
assert_quiescent_ledgers

printf 'PASS contract-activation preflight effective=%s contract=%s share=%s price=%s role=%s\n' \
  "${effective_business_date}" \
  "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
  "${STOCK_V4_REPLAY_SHARE_REBASE_PLAN_ID}" \
  "${STOCK_V4_REPLAY_PRICE_CAPITAL_PLAN_ID}" \
  "${STOCK_V4_REPLAY_ROLE_CAPACITY_PLAN_ID}"

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS contract-activation gate check-only finished without mutation\n'
  exit 0
fi

start_batch
STOCK_V4_REPLAY_ALLOW_EOD_ADVANCE=YES \
STOCK_V4_REPLAY_EOD_TIMEOUT_SECONDS="${PHASE_TIMEOUT_SECONDS}" \
  bash "${SCRIPT_DIR}/run-stock-v4-eod-to-next-open.sh"
stop_batch

final_clock="$(clock_response)"
require_success_json 'contract-activation final clock' "${final_clock}"
if ! printf '%s' "${final_clock}" | "${JQ_BIN}" -e \
    --arg effectiveBusinessDate "${effective_business_date}" \
    '.data.marketSession == "REGULAR"
     and .data.running == false
     and .data.activeBusinessDate == $effectiveBusinessDate
     and .data.simulationDate == $effectiveBusinessDate
     and .data.preparingBusinessDate == null
     and .data.postClosePhase == null
     and .data.postCloseStatus == null
     and .data.marketOpenReady == true' >/dev/null; then
  printf 'FAIL contract activation did not reach the stopped effective opening response=%s\n' \
    "${final_clock}" >&2
  exit 1
fi

verify_applied_contract
assert_population_contract
assert_quiescent_ledgers

printf 'PASS scaled-market contract activation complete contract=%s effective=%s symbols=%s issued=%s tradable=%s marketCap=%s dailyVolume=%s turnover=%s..%s\n' \
  "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
  "${effective_business_date}" \
  "${STOCK_V4_REPLAY_EXPECTED_SYMBOL_COUNT}" \
  "${STOCK_V4_REPLAY_EXPECTED_ISSUED_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_TRADABLE_SHARES}" \
  "${STOCK_V4_REPLAY_EXPECTED_MARKET_CAPITALIZATION}" \
  "${STOCK_V4_REPLAY_EXPECTED_DAILY_VOLUME}" \
  "${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_LOWER}" \
  "${STOCK_V4_REPLAY_EXPECTED_DAILY_TURNOVER_UPPER}"
