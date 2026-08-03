#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_REPLAY_ISSUE_UNDERWRITER_ACCOUNT_ID:?STOCK_V4_REPLAY_ISSUE_UNDERWRITER_ACCOUNT_ID is required}"
: "${STOCK_V4_REPLAY_ISSUE_UNDERWRITER_SYMBOL:?STOCK_V4_REPLAY_ISSUE_UNDERWRITER_SYMBOL is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_ISSUE_UNDERWRITER_IDENTITY_REPAIR:-}" != "YES" ]]; then
  printf 'FAIL issue-underwriter identity repair requires STOCK_V4_REPLAY_ALLOW_ISSUE_UNDERWRITER_IDENTITY_REPAIR=YES\n' >&2
  exit 1
fi

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
ACCOUNT_ID="${STOCK_V4_REPLAY_ISSUE_UNDERWRITER_ACCOUNT_ID}"
SYMBOL="${STOCK_V4_REPLAY_ISSUE_UNDERWRITER_SYMBOL}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"

if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${ACCOUNT_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL issue-underwriter account id must be a positive integer\n' >&2
  exit 1
fi
if [[ ! "${SYMBOL}" =~ ^[A-Z0-9._-]{1,20}$ ]]; then
  printf 'FAIL issue-underwriter symbol is not canonical: %s\n' "${SYMBOL}" >&2
  exit 1
fi
if [[ -z "${MYSQL_BIN}" || ! -x "${MYSQL_BIN}" ]]; then
  printf 'FAIL mysql client was not found; set STOCK_MYSQL_BIN\n' >&2
  exit 1
fi

MYSQL_CONNECTION_ARGS=(
  "--host=${STOCK_MYSQL_HOST}"
  "--port=${STOCK_MYSQL_PORT}"
  "--user=${STOCK_MYSQL_USER}"
  "--database=${REPLAY_SCHEMA}"
  "--connect-timeout=10"
  "--default-character-set=utf8mb4"
  "--batch"
  "--raw"
  "--skip-column-names"
)

mysql_replay() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" "$@"
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local query="$3"
  local actual

  actual="$(mysql_replay --execute="${query}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL %s expected=%s actual=%s\n' \
      "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf 'PASS %s = %s\n' "${label}" "${actual}"
}

assert_equals \
  "connected isolated replay schema" \
  "${REPLAY_SCHEMA}" \
  "SELECT DATABASE()"

assert_equals \
  "stopped simulation clock" \
  "1" \
  "
  SELECT COUNT(*)
    FROM stock_simulation_clock
   WHERE running = b'0'
  "

assert_equals \
  "exact issue-underwriter account contract" \
  "1" \
  "
  SELECT COUNT(*)
    FROM stock_underwriting_contract contract
    JOIN stock_account account
      ON account.id = contract.account_id
    JOIN stock_market_participant participant
      ON participant.id = contract.participant_id
    JOIN stock_market_participant_account mapping
      ON mapping.participant_id = participant.id
     AND mapping.account_id = account.id
   WHERE contract.symbol = '${SYMBOL}'
     AND contract.account_id = ${ACCOUNT_ID}
     AND account.account_code = 'UW-${SYMBOL}'
     AND account.status = 'ACTIVE'
     AND account.participant_category = 'ISSUE_UNDERWRITER'
     AND (
       account.user_key IS NULL
       OR account.user_key = LOWER(CONCAT('stock-issue-underwriter-', '${SYMBOL}'))
     )
     AND participant.participant_type = 'ISSUE_UNDERWRITER'
     AND participant.status = 'ACTIVE'
     AND mapping.account_role = 'ISSUE_UNDERWRITER'
     AND mapping.desk_code = '${SYMBOL}'
     AND mapping.status = 'ACTIVE'
     AND account.self_trade_group_id = participant.self_trade_group_id
  "

assert_equals \
  "quiescent issue-underwriter account" \
  "0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_order
         WHERE account_id = ${ACCOUNT_ID}
           AND status IN ('PENDING', 'PARTIALLY_FILLED')
           AND quantity > filled_quantity
      ),
      (
        SELECT COALESCE(SUM(reserved_quantity), 0)
          FROM stock_holding
         WHERE account_id = ${ACCOUNT_ID}
      )
  )
  "

mysql_replay --execute="
  START TRANSACTION;

  UPDATE stock_account
     SET user_key = NULL,
         updated_at = CURRENT_TIMESTAMP
   WHERE id = ${ACCOUNT_ID}
     AND account_code = 'UW-${SYMBOL}'
     AND status = 'ACTIVE'
     AND participant_category = 'ISSUE_UNDERWRITER'
     AND (
       user_key IS NULL
       OR user_key = LOWER(CONCAT('stock-issue-underwriter-', '${SYMBOL}'))
     );

  COMMIT;
"

assert_equals \
  "repaired non-login issue-underwriter identity" \
  "1" \
  "
  SELECT COUNT(*)
    FROM stock_account
   WHERE id = ${ACCOUNT_ID}
     AND account_code = 'UW-${SYMBOL}'
     AND status = 'ACTIVE'
     AND participant_category = 'ISSUE_UNDERWRITER'
     AND user_key IS NULL
  "

printf 'PASS repaired only the isolated replay issue-underwriter login identity account=%s symbol=%s\n' \
  "${ACCOUNT_ID}" "${SYMBOL}"
