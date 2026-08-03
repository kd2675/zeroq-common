#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"
: "${STOCK_V4_OPERATING_CONTRACT_ID:?STOCK_V4_OPERATING_CONTRACT_ID is required}"
: "${STOCK_V4_OPERATING_SYMBOL:?STOCK_V4_OPERATING_SYMBOL is required}"
: "${STOCK_V4_OPERATING_SOURCE_ACCOUNT_ID:?STOCK_V4_OPERATING_SOURCE_ACCOUNT_ID is required}"
: "${STOCK_V4_OPERATING_TARGET_MANDATE_ID:?STOCK_V4_OPERATING_TARGET_MANDATE_ID is required}"
: "${STOCK_V4_OPERATING_FUNDING_ACCOUNT_ID:?STOCK_V4_OPERATING_FUNDING_ACCOUNT_ID is required}"

if [[ "${STOCK_V4_OPERATING_ALLOW_UNDERWRITER_LIFECYCLE:-}" != "YES" ]]; then
  printf 'FAIL operating underwriter lifecycle requires STOCK_V4_OPERATING_ALLOW_UNDERWRITER_LIFECYCLE=YES\n' >&2
  exit 1
fi

OPERATING_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA:-STOCK_SERVICE}"
OPERATING_BATCH_SCHEMA="${STOCK_MYSQL_REPLAY_BATCH_SCHEMA:-STOCK_BATCH_METADATA}"
BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:20480}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-operating-admin}"
CONTRACT_VERSION="${STOCK_V4_OPERATING_SCALED_CONTRACT_VERSION:-1}"
CONTRACT_ID="${STOCK_V4_OPERATING_CONTRACT_ID}"
SYMBOL="${STOCK_V4_OPERATING_SYMBOL}"
SOURCE_ACCOUNT_ID="${STOCK_V4_OPERATING_SOURCE_ACCOUNT_ID}"
TARGET_MANDATE_ID="${STOCK_V4_OPERATING_TARGET_MANDATE_ID}"
FUNDING_ACCOUNT_ID="${STOCK_V4_OPERATING_FUNDING_ACCOUNT_ID}"
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

if [[ "${OPERATING_SCHEMA}" != "STOCK_SERVICE" \
    || "${OPERATING_BATCH_SCHEMA}" != "STOCK_BATCH_METADATA" ]]; then
  printf 'FAIL operating lifecycle requires exact STOCK_SERVICE and STOCK_BATCH_METADATA schemas\n' >&2
  exit 1
fi
if [[ ! "${CONTRACT_VERSION}" =~ ^[1-9][0-9]*$ \
    || ! "${CONTRACT_ID}" =~ ^[1-9][0-9]*$ \
    || ! "${SOURCE_ACCOUNT_ID}" =~ ^[1-9][0-9]*$ \
    || ! "${TARGET_MANDATE_ID}" =~ ^[1-9][0-9]*$ \
    || ! "${FUNDING_ACCOUNT_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL operating lifecycle identifiers must be positive integers\n' >&2
  exit 1
fi
if [[ ! "${SYMBOL}" =~ ^[A-Z0-9._-]{1,20}$ ]]; then
  printf 'FAIL operating lifecycle symbol is not canonical: %s\n' "${SYMBOL}" >&2
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
  "--database=${OPERATING_SCHEMA}"
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
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e '.success == true' >/dev/null; then
    printf 'FAIL %s response=%s\n' "${label}" "${response}" >&2
    exit 1
  fi
}

clock_response() {
  curl -sS \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    "${BACK_URL}/api/stock/v1/markets/simulation-clock"
}

require_quiescent_regular_clock() {
  local response
  response="$(clock_response)"
  require_success_json 'operating lifecycle clock' "${response}"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
      '.data.marketSession == "REGULAR"
       and .data.running == false
       and .data.activeBusinessDate == .data.simulationDate
       and .data.preparingBusinessDate == null
       and .data.postClosePhase == null
       and .data.postCloseStatus == null' >/dev/null; then
    printf 'FAIL operating lifecycle requires a stopped aligned REGULAR clock response=%s\n' \
      "${response}" >&2
    exit 1
  fi
  printf '%s' "${response}" | "${JQ_BIN}" -r '.data.activeBusinessDate'
}

require_global_quiescence() {
  local state
  state="$(mysql_query "
    SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*)
         FROM stock_order
        WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
          AND quantity > filled_quantity),
      (SELECT COUNT(*)
         FROM stock_auto_participant_order_intent
        WHERE status = 'ACTIVE'),
      (SELECT COALESCE(SUM(reserved_quantity), 0)
         FROM stock_holding),
      (SELECT COALESCE(SUM(reserved_cash), 0)
         FROM stock_order
        WHERE status IN ('PENDING', 'PARTIALLY_FILLED')),
      (SELECT COUNT(*)
         FROM stock_scaled_market_liquidity_distribution_plan
        WHERE status IN ('SCHEDULED', 'ACTIVE'))
    )
  ")"
  if [[ "${state}" != "0|0|0|0.00|0" ]]; then
    printf 'FAIL operating lifecycle is not globally quiescent state=%s\n' \
      "${state}" >&2
    exit 1
  fi
}

contract_state() {
  mysql_query "
    SELECT contract.tradable_allocation_quantity,
           holding.quantity,
           contract.status,
           contract.policy_version,
           account.user_key IS NULL,
           mandate.account_id,
           mandate.status,
           funding.status,
           funding.participant_category,
           funding.cash_balance
      FROM stock_underwriting_contract contract
      JOIN stock_account account
        ON account.id = contract.account_id
      JOIN stock_holding holding
        ON holding.account_id = contract.account_id
       AND holding.symbol = contract.symbol
      JOIN stock_liquidity_mandate mandate
        ON mandate.id = ${TARGET_MANDATE_ID}
       AND mandate.symbol = contract.symbol
      JOIN stock_account funding
        ON funding.id = ${FUNDING_ACCOUNT_ID}
     WHERE contract.id = ${CONTRACT_ID}
       AND contract.symbol = '${SYMBOL}'
       AND contract.account_id = ${SOURCE_ACCOUNT_ID}
       AND account.status = 'ACTIVE'
       AND account.participant_category = 'ISSUE_UNDERWRITER'
  "
}

require_contract_boundary() {
  local row
  local tradable_quantity
  local source_quantity
  local contract_status
  local source_non_login
  local mandate_status
  local funding_status
  local funding_category

  row="$(contract_state)"
  if [[ -z "${row}" || "$(printf '%s\n' "${row}" | wc -l | tr -d ' ')" != "1" ]]; then
    printf 'FAIL operating lifecycle contract/account/mandate identity is not unique\n' >&2
    exit 1
  fi
  IFS=$'\t' read -r tradable_quantity source_quantity contract_status _ \
    source_non_login _ mandate_status funding_status funding_category _ <<< "${row}"
  if [[ ! "${tradable_quantity}" =~ ^[1-9][0-9]*$ \
      || ! "${source_quantity}" =~ ^[0-9]+$ \
      || (( source_quantity > tradable_quantity )) \
      || ( "${contract_status}" != "ALLOCATED" \
        && "${contract_status}" != "COMPLETED" ) \
      || "${source_non_login}" != "1" \
      || "${mandate_status}" != "ACTIVE" \
      || "${funding_status}" != "ACTIVE" \
      || "${funding_category}" != "LIQUIDITY_PROVIDER" ]]; then
    printf 'FAIL operating lifecycle role boundary is invalid contract=%s source=%s/%s nonLogin=%s mandate=%s funding=%s/%s\n' \
      "${contract_status}" "${source_quantity}" "${tradable_quantity}" \
      "${source_non_login}" "${mandate_status}" "${funding_status}" \
      "${funding_category}" >&2
    exit 1
  fi
  printf '%s\n' "${row}"
}

schedule_checkpoint() {
  local checkpoint="$1"
  local row
  local tradable_quantity
  local source_quantity
  local contract_status
  local policy_version
  local source_non_login
  local target_account_id
  local mandate_status
  local funding_status
  local funding_category
  local funding_cash
  local distributed_quantity
  local target_cumulative_quantity
  local required_quantity
  local activation_response
  local effective_date
  local scheduled_rate
  local create_payload
  local create_response
  local plan_id
  local schedule_response
  local expected_contract_status

  row="$(require_contract_boundary)"
  IFS=$'\t' read -r tradable_quantity source_quantity contract_status \
    policy_version source_non_login target_account_id mandate_status \
    funding_status funding_category funding_cash <<< "${row}"
  distributed_quantity=$((tradable_quantity - source_quantity))
  target_cumulative_quantity="$(mysql_query "
    SELECT CEIL(${tradable_quantity} * ${checkpoint})
  ")"
  required_quantity=$((target_cumulative_quantity - distributed_quantity))
  if (( required_quantity <= 0 )); then
    printf 'PASS checkpoint already satisfied symbol=%s rate=%s distributed=%s/%s\n' \
      "${SYMBOL}" "${checkpoint}" "${distributed_quantity}" \
      "${tradable_quantity}"
    return 0
  fi
  if [[ "${contract_status}" != "ALLOCATED" ]]; then
    printf 'FAIL checkpoint requires an ALLOCATED contract while quantity remains: status=%s remaining=%s\n' \
      "${contract_status}" "${required_quantity}" >&2
    exit 1
  fi

  require_quiescent_regular_clock >/dev/null
  require_global_quiescence
  activation_response="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    --data "{\"targetDistributedTradableShareRate\":${checkpoint},\"changeReason\":\"OPERATING_1_100_${SYMBOL}_${checkpoint}_CHECKPOINT\"}" \
    "${BACK_URL}/api/stock/v1/markets/underwriting-contracts/${CONTRACT_ID}/supply/activate")"
  require_success_json "${SYMBOL} checkpoint ${checkpoint} activation" \
    "${activation_response}"
  effective_date="$(printf '%s' "${activation_response}" | "${JQ_BIN}" -r \
    '.data.scheduledSupply.effectiveBusinessDate')"
  scheduled_rate="$(printf '%s' "${activation_response}" | "${JQ_BIN}" -r \
    '.data.scheduledSupply.targetDistributedTradableShareRate')"
  if [[ ! "${effective_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
      || ! printf '%s' "${activation_response}" | "${JQ_BIN}" -e \
        --arg checkpoint "${checkpoint}" \
        '.data.scheduledSupply.targetDistributedTradableShareRate
           == ($checkpoint | tonumber)' >/dev/null; then
    printf 'FAIL checkpoint activation response drifted effective=%s rate=%s/%s\n' \
      "${effective_date}" "${scheduled_rate}" "${checkpoint}" >&2
    exit 1
  fi

  create_payload="$(${JQ_BIN} -cn \
    --argjson sourceAccountId "${SOURCE_ACCOUNT_ID}" \
    --argjson targetLiquidityMandateId "${TARGET_MANDATE_ID}" \
    --argjson fundingSourceAccountId "${FUNDING_ACCOUNT_ID}" \
    --argjson targetQuantity "${required_quantity}" \
    --arg changeReason "OPERATING_1_100_${SYMBOL}_${checkpoint}_DISTRIBUTION" \
    '{sourceAccountId: $sourceAccountId,
      targetLiquidityMandateId: $targetLiquidityMandateId,
      fundingSourceAccountId: $fundingSourceAccountId,
      targetQuantity: $targetQuantity,
      changeReason: $changeReason}')"
  create_response="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    --data "${create_payload}" \
    "${BACK_URL}/api/stock/v1/markets/admin/scaled-market/contracts/${CONTRACT_VERSION}/symbols/${SYMBOL}/liquidity-distribution-plans")"
  require_success_json "${SYMBOL} checkpoint ${checkpoint} plan creation" \
    "${create_response}"
  plan_id="$(printf '%s' "${create_response}" | "${JQ_BIN}" -r '.data.planId')"
  if [[ ! "${plan_id}" =~ ^[1-9][0-9]*$ ]] \
      || ! printf '%s' "${create_response}" | "${JQ_BIN}" -e \
        --argjson requiredQuantity "${required_quantity}" \
        --argjson sourceAccountId "${SOURCE_ACCOUNT_ID}" \
        --argjson targetAccountId "${target_account_id}" \
        '.data.status == "DRAFT"
         and .data.targetQuantity == $requiredQuantity
         and .data.sourceAccountId == $sourceAccountId
         and .data.targetAccountId == $targetAccountId' >/dev/null; then
    printf 'FAIL checkpoint distribution draft response drifted response=%s\n' \
      "${create_response}" >&2
    exit 1
  fi

  schedule_response="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    --data "{\"effectiveBusinessDate\":\"${effective_date}\"}" \
    "${BACK_URL}/api/stock/v1/markets/admin/scaled-market/liquidity-distribution-plans/${plan_id}/schedule")"
  require_success_json "${SYMBOL} checkpoint ${checkpoint} plan schedule" \
    "${schedule_response}"
  if ! printf '%s' "${schedule_response}" | "${JQ_BIN}" -e \
      --arg effectiveDate "${effective_date}" \
      '.data.status == "SCHEDULED"
       and .data.effectiveBusinessDate == $effectiveDate' >/dev/null; then
    printf 'FAIL checkpoint distribution schedule response drifted response=%s\n' \
      "${schedule_response}" >&2
    exit 1
  fi
  printf 'PASS checkpoint scheduled symbol=%s rate=%s required=%s plan=%s effective=%s fundingCash=%s\n' \
    "${SYMBOL}" "${checkpoint}" "${required_quantity}" "${plan_id}" \
    "${effective_date}" "${funding_cash}"

  STOCK_V4_TARGET_ENVIRONMENT=operating \
  STOCK_V4_OPERATING_ALLOW_LIQUIDITY_DISTRIBUTION_COMPLETION=YES \
  STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION_COMPLETION=YES \
  STOCK_MYSQL_REPLAY_SCHEMA="${OPERATING_SCHEMA}" \
  STOCK_MYSQL_REPLAY_BATCH_SCHEMA="${OPERATING_BATCH_SCHEMA}" \
  STOCK_V4_REPLAY_LIQUIDITY_DISTRIBUTION_PLAN_ID="${plan_id}" \
    bash "${SCRIPT_DIR}/run-stock-v4-liquidity-distribution-to-completion.sh"

  final_row="$(mysql_query "
    SELECT CONCAT_WS(
      '|',
      plan.status,
      plan.target_quantity,
      plan.submitted_quantity,
      plan.filled_quantity,
      COALESCE(plan.open_slot, 0),
      contract.status,
      (SELECT COUNT(*)
         FROM stock_market_policy_version policy
        WHERE policy.policy_scope = 'UNDERWRITING_CONTRACT'
          AND policy.scope_key = contract.contract_code
          AND policy.status IN ('SCHEDULED', 'ACTIVE')),
      holding.quantity,
      holding.reserved_quantity
    )
      FROM stock_scaled_market_liquidity_distribution_plan plan
      JOIN stock_underwriting_contract contract
        ON contract.id = ${CONTRACT_ID}
      JOIN stock_holding holding
        ON holding.account_id = contract.account_id
       AND holding.symbol = contract.symbol
     WHERE plan.plan_id = ${plan_id}
  ")"
  expected_source_quantity=$((source_quantity - required_quantity))
  expected_contract_status="ALLOCATED"
  if [[ "${checkpoint}" == "1.00" ]]; then
    expected_contract_status="COMPLETED"
  fi
  expected_final="COMPLETED|${required_quantity}|${required_quantity}|${required_quantity}|0|${expected_contract_status}|0|${expected_source_quantity}|0"
  if [[ "${final_row}" != "${expected_final}" ]]; then
    printf 'FAIL checkpoint terminal reconciliation drifted expected=%s actual=%s\n' \
      "${expected_final}" "${final_row}" >&2
    exit 1
  fi
  printf 'PASS checkpoint completed symbol=%s rate=%s plan=%s sourceRemaining=%s\n' \
    "${SYMBOL}" "${checkpoint}" "${plan_id}" \
    "${expected_source_quantity}"
}

lock_dir="/tmp/stock-v4-operating-underwriter-lifecycle-${CONTRACT_ID}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  printf 'FAIL another operating underwriter lifecycle owns %s\n' \
    "${lock_dir}" >&2
  exit 1
fi
cleanup() {
  local exit_code=$?
  rmdir "${lock_dir}" 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT

initial_date="$(require_quiescent_regular_clock)"
require_global_quiescence
initial_contract="$(require_contract_boundary)"
IFS=$'\t' read -r initial_tradable initial_source initial_status _ \
  initial_non_login _ initial_mandate_status initial_funding_status \
  initial_funding_category initial_funding_cash <<< "${initial_contract}"
printf 'PASS operating underwriter lifecycle preflight date=%s contract=%s symbol=%s source=%s mandate=%s funding=%s\n' \
  "${initial_date}" "${CONTRACT_ID}" "${SYMBOL}" \
  "${SOURCE_ACCOUNT_ID}" "${TARGET_MANDATE_ID}" "${FUNDING_ACCOUNT_ID}"

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS operating underwriter lifecycle check-only finished without mutation status=%s source=%s/%s fundingCash=%s\n' \
    "${initial_status}" "${initial_source}" "${initial_tradable}" \
    "${initial_funding_cash}"
  exit 0
fi

for checkpoint in 0.05 0.10 0.25 0.50 0.75 1.00; do
  schedule_checkpoint "${checkpoint}"
done

final_contract="$(contract_state)"
IFS=$'\t' read -r final_tradable final_source final_status _ \
  final_non_login _ final_mandate_status final_funding_status \
  final_funding_category _ <<< "${final_contract}"
if [[ "${final_source}" != "0" \
    || "${final_status}" != "COMPLETED" \
    || "${final_non_login}" != "1" \
    || "${final_mandate_status}" != "ACTIVE" \
    || "${final_funding_status}" != "ACTIVE" \
    || "${final_funding_category}" != "LIQUIDITY_PROVIDER" ]]; then
  printf 'FAIL operating underwriter lifecycle final contract boundary drifted source=%s status=%s\n' \
    "${final_source}" "${final_status}" >&2
  exit 1
fi
require_global_quiescence
printf 'PASS operating underwriter lifecycle fully distributed contract=%s symbol=%s tradable=%s sourceRemaining=0\n' \
  "${CONTRACT_ID}" "${SYMBOL}" "${final_tradable}"
