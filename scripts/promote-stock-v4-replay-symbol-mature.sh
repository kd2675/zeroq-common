#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION:?STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION is required}"
: "${STOCK_V4_REPLAY_SYMBOL:?STOCK_V4_REPLAY_SYMBOL is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_MATURITY_PROMOTION:-}" != "YES" ]]; then
  printf 'FAIL maturity promotion requires STOCK_V4_REPLAY_ALLOW_MATURITY_PROMOTION=YES\n' >&2
  exit 1
fi
if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL scaled-market contract version must be a positive integer\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_SYMBOL}" =~ ^[A-Z0-9]{2,20}$ ]]; then
  printf 'FAIL replay symbol must be 2-20 uppercase letters or digits\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
CHANGE_REASON="${STOCK_V4_REPLAY_MATURITY_REASON:-Promote one isolated replay symbol after full real-fill distribution and completed close}"
CHECKPOINT_PORT="${STOCK_V4_REPLAY_CHECKPOINT_BATCH_PORT:-30492}"
EOD_PORT="${STOCK_V4_REPLAY_EOD_BATCH_PORT:-30491}"
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
if [[ -z "${CHANGE_REASON}" || ${#CHANGE_REASON} -gt 500 ]]; then
  printf 'FAIL maturity reason must contain 1-500 characters\n' >&2
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
    printf 'FAIL maturity promotion requires replay batch port %s to be stopped\n' \
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

clock_response="$(curl -sS \
  -H "X-User-Key: ${ADMIN_USER_KEY}" \
  -H 'X-User-Role: ADMIN' \
  "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
if ! printf '%s' "${clock_response}" | "${JQ_BIN}" -e \
    '.success == true
     and .data.marketSession == "PRE_OPEN"
     and .data.running == false
     and .data.activeBusinessDate != .data.simulationDate
     and .data.preparingBusinessDate == .data.simulationDate
     and .data.postCloseProcessingCompleted == true
     and .data.postClosePhase == "REPORTS_AGGREGATED"
     and .data.postCloseStatus == "PENDING"
     and (.data.availableJumpActions
          | index("NEXT_PREOPEN_TRANSFORM_START") != null)' >/dev/null; then
  printf 'FAIL maturity promotion requires stopped PRE_OPEN/REPORTS_AGGREGATED state response=%s\n' \
    "${clock_response}" >&2
  exit 1
fi
active_business_date="$(printf '%s' "${clock_response}" \
  | "${JQ_BIN}" -r '.data.activeBusinessDate')"
preparing_business_date="$(printf '%s' "${clock_response}" \
  | "${JQ_BIN}" -r '.data.preparingBusinessDate')"

preflight_row="$(mysql_query "
  SELECT scaled_contract.status,
         target.lifecycle_status,
         target.distributed_tradable_share_rate,
         DATE_FORMAT(target.activation_business_date, '%Y-%m-%d'),
         instrument.issued_shares,
         instrument.tradable_shares,
         CAST(instrument.enabled AS UNSIGNED),
         CAST(market.enabled AS UNSIGNED),
         market.market_status,
         underwriter.status,
         COALESCE(underwriter_holding.quantity, 0),
         COALESCE(underwriter_holding.reserved_quantity, 0),
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract candidate
            WHERE candidate.symbol = target.symbol
              AND candidate.status <> 'CANCELLED'
         ) AS underwriter_contract_count,
         (
           SELECT COALESCE(SUM(symbol_holding.quantity), 0)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding symbol_holding
            WHERE symbol_holding.symbol = target.symbol
         ) AS total_holding_quantity,
         (
           SELECT COALESCE(SUM(symbol_holding.reserved_quantity), 0)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding symbol_holding
            WHERE symbol_holding.symbol = target.symbol
         ) AS total_reserved_quantity,
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_order
            WHERE open_order.symbol = target.symbol
              AND open_order.status IN ('PENDING', 'PARTIALLY_FILLED')
              AND open_order.quantity > open_order.filled_quantity
         ) AS open_order_count,
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_participant_order_intent intent
            WHERE intent.symbol = target.symbol
              AND intent.status = 'ACTIVE'
         ) AS active_intent_count,
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
             JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract policy_contract
               ON policy_contract.contract_code = policy.scope_key
            WHERE policy_contract.symbol = target.symbol
              AND policy.policy_scope = 'UNDERWRITING_CONTRACT'
              AND policy.status IN ('ACTIVE', 'SCHEDULED')
         ) AS active_policy_count,
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_maturity_change existing_change
            WHERE existing_change.contract_version =
                  target.contract_version
              AND existing_change.symbol = target.symbol
              AND existing_change.target_lifecycle_status = 'MATURE'
              AND existing_change.observed_distributed_share_rate =
                  1.00000000
              AND existing_change.source_underwriter_quantity = 0
              AND existing_change.source_business_date =
                  '${active_business_date}'
              AND existing_change.effective_business_date =
                  target.activation_business_date
         ) AS exact_existing_audit_rows,
         COALESCE((
           SELECT DATE_FORMAT(snapshot.simulation_trade_date, '%Y-%m-%d')
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_daily_snapshot snapshot
             JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_close_run close_run
               ON close_run.id = snapshot.close_run_id
              AND close_run.status = 'COMPLETED'
            WHERE snapshot.symbol = target.symbol
            ORDER BY snapshot.simulation_trade_date DESC,
                     snapshot.close_run_id DESC
            LIMIT 1
         ), 'MISSING') AS latest_completed_close_date
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract scaled_contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
      ON target.contract_version = scaled_contract.contract_version
     AND target.symbol = '${STOCK_V4_REPLAY_SYMBOL}'
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_instrument instrument
      ON instrument.symbol = target.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_market_config market
      ON market.symbol = target.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract underwriter
      ON underwriter.symbol = target.symbol
     AND underwriter.status <> 'CANCELLED'
    LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding underwriter_holding
      ON underwriter_holding.account_id = underwriter.account_id
     AND underwriter_holding.symbol = underwriter.symbol
   WHERE scaled_contract.contract_version =
         ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
")"
if [[ -z "${preflight_row}" ]]; then
  printf 'FAIL scaled-market target or maturity dependencies were not found\n' >&2
  exit 1
fi

IFS=$'\t' read -r scaled_contract_status target_lifecycle target_rate \
  target_activation_date issued_shares tradable_shares instrument_enabled \
  market_enabled market_status underwriting_status underwriter_quantity \
  underwriter_reserved underwriter_contract_count total_holding_quantity \
  total_reserved_quantity open_order_count active_intent_count \
  active_policy_count exact_existing_audit_rows latest_close_date \
  <<< "${preflight_row}"

if [[ "${scaled_contract_status}" != "DRAFT" \
    || "${instrument_enabled}" != "1" \
    || "${market_enabled}" != "1" \
    || "${market_status}" != "CLOSED" \
    || "${underwriting_status}" != "COMPLETED" \
    || "${underwriter_quantity}" != "0" \
    || "${underwriter_reserved}" != "0" \
    || "${underwriter_contract_count}" != "1" \
    || "${total_holding_quantity}" != "${issued_shares}" \
    || "${total_reserved_quantity}" != "0" \
    || "${open_order_count}" != "0" \
    || "${active_intent_count}" != "0" \
    || "${active_policy_count}" != "0" \
    || "${latest_close_date}" != "${active_business_date}" ]]; then
  printf 'FAIL symbol is not maturity-ready symbol=%s scaledContract=%s lifecycle=%s targetRate=%s activation=%s issued=%s holdings=%s reserved=%s market=%s/%s underwriting=%s/%s/%s contracts=%s openOrders=%s activeIntents=%s activePolicies=%s auditRows=%s latestClose=%s activeDate=%s\n' \
    "${STOCK_V4_REPLAY_SYMBOL}" "${scaled_contract_status}" \
    "${target_lifecycle}" "${target_rate}" "${target_activation_date}" \
    "${issued_shares}" \
    "${total_holding_quantity}" "${total_reserved_quantity}" \
    "${market_enabled}" "${market_status}" "${underwriting_status}" \
    "${underwriter_quantity}" "${underwriter_reserved}" \
    "${underwriter_contract_count}" "${open_order_count}" \
    "${active_intent_count}" "${active_policy_count}" \
    "${exact_existing_audit_rows}" \
    "${latest_close_date}" "${active_business_date}" >&2
  exit 1
fi

if [[ "${target_lifecycle}" == "MATURE" ]]; then
  if [[ "${target_rate}" != "1.00000000" \
      || "${target_activation_date}" != "${preparing_business_date}" \
      || "${exact_existing_audit_rows}" != "1" ]]; then
    printf 'FAIL existing maturity promotion is not exact lifecycle=%s rate=%s activation=%s expectedActivation=%s auditRows=%s\n' \
      "${target_lifecycle}" "${target_rate}" "${target_activation_date}" \
      "${preparing_business_date}" "${exact_existing_audit_rows}" >&2
    exit 1
  fi
  printf 'PASS symbol maturity already promoted and reconciled contractVersion=%s symbol=%s closeDate=%s effectiveDate=%s auditRows=1\n' \
    "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
    "${STOCK_V4_REPLAY_SYMBOL}" "${active_business_date}" \
    "${target_activation_date}"
  exit 0
fi

if [[ ! "${target_lifecycle}" =~ ^(PREPARING|PRE_OPEN|STRESS)$ ]]; then
  printf 'FAIL symbol lifecycle is not eligible for maturity promotion: %s\n' \
    "${target_lifecycle}" >&2
  exit 1
fi

payload="$("${JQ_BIN}" -cn \
  --arg changeReason "${CHANGE_REASON}" \
  '{changeReason: $changeReason}')"
promotion_response="$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-User-Key: ${ADMIN_USER_KEY}" \
  -H 'X-User-Role: ADMIN' \
  --data "${payload}" \
  "${BACK_URL}/api/stock/v1/markets/admin/scaled-market/contracts/${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}/symbols/${STOCK_V4_REPLAY_SYMBOL}/promote-mature")"
if ! printf '%s' "${promotion_response}" | "${JQ_BIN}" -e \
    --arg symbol "${STOCK_V4_REPLAY_SYMBOL}" \
    --arg contractVersion "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
    '.success == true
     and .data.contractVersion == ($contractVersion | tonumber)
     and .data.symbol == $symbol
     and .data.targetLifecycleStatus == "MATURE"
     and .data.observedDistributedShareRate == 1
     and .data.sourceUnderwriterQuantity == 0' >/dev/null; then
  printf 'FAIL maturity promotion response=%s\n' \
    "${promotion_response}" >&2
  exit 1
fi

change_id="$(printf '%s' "${promotion_response}" \
  | "${JQ_BIN}" -r '.data.changeId')"
effective_business_date="$(printf '%s' "${promotion_response}" \
  | "${JQ_BIN}" -r '.data.effectiveBusinessDate')"
if [[ ! "${change_id}" =~ ^[1-9][0-9]*$ \
    || ! "${effective_business_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  printf 'FAIL maturity promotion returned an unsafe audit identity changeId=%s effectiveDate=%s\n' \
    "${change_id}" "${effective_business_date}" >&2
  exit 1
fi
postflight_row="$(mysql_query "
  SELECT target.lifecycle_status,
         target.distributed_tradable_share_rate,
         DATE_FORMAT(target.activation_business_date, '%Y-%m-%d'),
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_maturity_change change_row
            WHERE change_row.change_id = ${change_id}
              AND change_row.contract_version =
                  ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
              AND change_row.symbol = '${STOCK_V4_REPLAY_SYMBOL}'
              AND change_row.target_lifecycle_status = 'MATURE'
              AND change_row.observed_distributed_share_rate = 1.00000000
              AND change_row.source_underwriter_quantity = 0
              AND change_row.source_business_date = '${active_business_date}'
              AND change_row.effective_business_date =
                  '${effective_business_date}'
              AND change_row.changed_by = '${ADMIN_USER_KEY}'
         ) AS exact_audit_rows
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
   WHERE target.contract_version =
         ${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}
     AND target.symbol = '${STOCK_V4_REPLAY_SYMBOL}'
")"
IFS=$'\t' read -r final_lifecycle final_rate final_activation_date \
  exact_audit_rows <<< "${postflight_row}"
if [[ "${final_lifecycle}" != "MATURE" \
    || "${final_rate}" != "1.00000000" \
    || "${final_activation_date}" != "${effective_business_date}" \
    || "${exact_audit_rows}" != "1" ]]; then
  printf 'FAIL maturity promotion did not reconcile lifecycle=%s rate=%s activation=%s expectedActivation=%s auditRows=%s\n' \
    "${final_lifecycle}" "${final_rate}" "${final_activation_date}" \
    "${effective_business_date}" "${exact_audit_rows}" >&2
  exit 1
fi

printf 'PASS symbol maturity promoted contractVersion=%s symbol=%s sourceLifecycle=%s sourceRate=%s closeDate=%s effectiveDate=%s changeId=%s auditRows=1\n' \
  "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" \
  "${STOCK_V4_REPLAY_SYMBOL}" "${target_lifecycle}" "${target_rate}" \
  "${active_business_date}" "${effective_business_date}" "${change_id}"
