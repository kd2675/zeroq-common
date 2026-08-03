#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY:?STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY is required}"
: "${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH:?STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_COUNTERPARTY_FUNDING:-}" != "YES" ]]; then
  printf 'FAIL counterparty funding requires STOCK_V4_REPLAY_ALLOW_COUNTERPARTY_FUNDING=YES\n' >&2
  exit 1
fi
if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  printf 'FAIL counterparty user key contains unsupported characters\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH}" =~ ^[0-9]+([.][0-9]{1,2})?$ ]] \
    || [[ "${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH}" =~ ^0+([.]0{1,2})?$ ]]; then
  printf 'FAIL required available cash must be a positive amount with at most two decimals\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
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
    printf 'FAIL counterparty funding requires replay batch port %s to be stopped\n' \
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
     and .data.marketSession == "REGULAR"
     and .data.running == false
     and .data.activeBusinessDate == .data.simulationDate
     and .data.preparingBusinessDate == null
     and .data.postClosePhase == null
     and .data.postCloseStatus == null' >/dev/null; then
  printf 'FAIL counterparty funding requires stopped aligned REGULAR state response=%s\n' \
    "${clock_response}" >&2
  exit 1
fi

preflight_row="$(mysql_query "
  SELECT account.id,
         account.status,
         account.participant_category,
         account.cash_balance,
         COALESCE((
           SELECT SUM(open_buy.reserved_cash)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_buy
            WHERE open_buy.account_id = account.id
              AND open_buy.side = 'BUY'
              AND open_buy.status IN ('PENDING', 'PARTIALLY_FILLED')
         ), 0) AS reserved_cash,
         account.cash_balance - COALESCE((
           SELECT SUM(open_buy.reserved_cash)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_buy
            WHERE open_buy.account_id = account.id
              AND open_buy.side = 'BUY'
              AND open_buy.status IN ('PENDING', 'PARTIALLY_FILLED')
         ), 0) AS available_cash,
         GREATEST(
           CAST('${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH}' AS DECIMAL(19,2))
             - (
               account.cash_balance - COALESCE((
                 SELECT SUM(open_buy.reserved_cash)
                   FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_buy
                  WHERE open_buy.account_id = account.id
                    AND open_buy.side = 'BUY'
                    AND open_buy.status IN ('PENDING', 'PARTIALLY_FILLED')
               ), 0)
             ),
           0
         ) AS cash_shortfall,
         COALESCE((
           SELECT MAX(flow.id)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account_cash_flow flow
            WHERE flow.account_id = account.id
         ), 0) AS latest_cash_flow_id
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
   WHERE account.user_key = '${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}'
")"
if [[ -z "${preflight_row}" ]]; then
  printf 'FAIL counterparty account was not found: %s\n' \
    "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" >&2
  exit 1
fi
IFS=$'\t' read -r account_id account_status participant_category \
  cash_balance reserved_cash available_cash cash_shortfall latest_cash_flow_id \
  <<< "${preflight_row}"
if [[ "${account_status}" != "ACTIVE" \
    || "${participant_category}" != "MANUAL_PARTICIPANT" ]]; then
  printf 'FAIL counterparty must be an active manual participant: status=%s category=%s\n' \
    "${account_status}" "${participant_category}" >&2
  exit 1
fi
if [[ "${reserved_cash}" != "0.00" && "${reserved_cash}" != "0" ]]; then
  printf 'FAIL counterparty funding requires zero open BUY reservation: reserved=%s\n' \
    "${reserved_cash}" >&2
  exit 1
fi

account_response="$(curl -sS \
  -H "X-User-Key: ${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" \
  -H 'X-User-Role: USER' \
  "${BACK_URL}/api/stock/v1/accounts/me")"
if ! printf '%s' "${account_response}" | "${JQ_BIN}" -e \
    --arg userKey "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" \
    --arg accountId "${account_id}" \
    --arg cashBalance "${cash_balance}" \
    '.success == true
     and .data.userKey == $userKey
     and .data.accountId == ($accountId | tonumber)
     and .data.cashBalance == ($cashBalance | tonumber)' >/dev/null; then
  printf 'FAIL replay back account does not match the selected replay schema response=%s\n' \
    "${account_response}" >&2
  exit 1
fi
if [[ "${cash_shortfall}" == "0.00" || "${cash_shortfall}" == "0" ]]; then
  printf 'PASS counterparty already meets cash floor user=%s available=%s required=%s deposited=0.00\n' \
    "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" "${available_cash}" \
    "${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH}"
  exit 0
fi

payload="$("${JQ_BIN}" -cn \
  --arg adjustmentType 'DEPOSIT' \
  --arg amount "${cash_shortfall}" \
  '{adjustmentType: $adjustmentType, amount: $amount}')"
adjustment_response="$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-User-Key: ${ADMIN_USER_KEY}" \
  -H 'X-User-Role: ADMIN' \
  --data "${payload}" \
  "${BACK_URL}/api/stock/v1/accounts/admin/users/${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}/cash-adjustments")"
if ! printf '%s' "${adjustment_response}" | "${JQ_BIN}" -e \
    --arg userKey "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" \
    '.success == true
     and .data.userKey == $userKey
     and .data.adjustmentType == "DEPOSIT"' >/dev/null; then
  printf 'FAIL counterparty cash adjustment response=%s\n' \
    "${adjustment_response}" >&2
  exit 1
fi

postflight_row="$(mysql_query "
  SELECT account.cash_balance,
         account.cash_balance - COALESCE((
           SELECT SUM(open_buy.reserved_cash)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order open_buy
            WHERE open_buy.account_id = account.id
              AND open_buy.side = 'BUY'
              AND open_buy.status IN ('PENDING', 'PARTIALLY_FILLED')
         ), 0) AS available_cash,
         account.cash_balance =
           CAST('${cash_balance}' AS DECIMAL(19,2))
             + CAST('${cash_shortfall}' AS DECIMAL(19,2)) AS exact_cash_delta,
         (
           SELECT COUNT(*)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account_cash_flow flow
            WHERE flow.account_id = account.id
              AND flow.id > ${latest_cash_flow_id}
              AND flow.flow_type = 'DEPOSIT'
              AND flow.reason = 'ADMIN_DEPOSIT'
              AND flow.created_by = '${ADMIN_USER_KEY}'
              AND flow.amount = CAST('${cash_shortfall}' AS DECIMAL(19,2))
         ) AS exact_audit_rows
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
   WHERE account.id = ${account_id}
")"
IFS=$'\t' read -r final_cash_balance final_available_cash exact_cash_delta \
  exact_audit_rows <<< "${postflight_row}"
if [[ "${exact_cash_delta}" != "1" || "${exact_audit_rows}" != "1" ]]; then
  printf 'FAIL counterparty cash adjustment did not reconcile: exactDelta=%s auditRows=%s\n' \
    "${exact_cash_delta}" "${exact_audit_rows}" >&2
  exit 1
fi
meets_required="$(mysql_query "
  SELECT CAST('${final_available_cash}' AS DECIMAL(19,2))
           >= CAST('${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH}' AS DECIMAL(19,2))
")"
if [[ "${meets_required}" != "1" ]]; then
  printf 'FAIL counterparty remains below the required cash floor: available=%s required=%s\n' \
    "${final_available_cash}" "${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH}" >&2
  exit 1
fi

printf 'PASS counterparty cash floor funded user=%s before=%s deposited=%s final=%s required=%s auditRows=1\n' \
  "${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY}" "${cash_balance}" \
  "${cash_shortfall}" "${final_cash_balance}" \
  "${STOCK_V4_REPLAY_REQUIRED_AVAILABLE_CASH}"
