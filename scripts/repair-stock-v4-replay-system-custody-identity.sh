#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"

if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
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
  "D8 pre-listing reconstruction boundary" \
  "1|7|1|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_scaled_market_contract
         WHERE contract_version = 1
           AND baseline_close_run_id = 259
           AND status = 'DRAFT'
      ),
      (
        SELECT COUNT(*)
          FROM stock_scaled_market_symbol_target
         WHERE contract_version = 1
           AND lifecycle_status = 'MATURE'
      ),
      (
        SELECT COUNT(*)
          FROM stock_scaled_market_symbol_target
         WHERE contract_version = 1
           AND symbol = 'DEMO008'
           AND lifecycle_status = 'PREPARING'
           AND distributed_tradable_share_rate = 0
           AND activation_business_date IS NULL
      ),
      (
        SELECT COUNT(*)
          FROM stock_order_book_instrument
         WHERE symbol = 'DEMO008'
      )
  )
  "

assert_equals \
  "quiescent replay ledgers" \
  "0|0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_order
         WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
           AND quantity > filled_quantity
      ),
      (
        SELECT COUNT(*)
          FROM stock_auto_participant_order_intent
         WHERE status = 'ACTIVE'
      ),
      (
        SELECT COALESCE(SUM(reserved_quantity), 0)
          FROM stock_holding
      )
  )
  "

assert_equals \
  "single active system-custody role" \
  "1" \
  "
  SELECT COUNT(*)
    FROM stock_market_participant
   WHERE participant_type = 'SYSTEM_CUSTODY'
     AND status = 'ACTIVE'
  "

assert_equals \
  "canonical system-custody identity conflicts" \
  "0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_market_participant
         WHERE participant_code = 'SYSTEM_CUSTODY'
           AND participant_type <> 'SYSTEM_CUSTODY'
      ),
      (
        SELECT COUNT(*)
          FROM stock_market_participant
         WHERE self_trade_group_id = 'SYSTEM_CUSTODY:DEFAULT'
           AND participant_type <> 'SYSTEM_CUSTODY'
      )
  )
  "

mysql_replay <<'SQL'
START TRANSACTION;

SET @stock_v4_system_custody_participant_id = (
    SELECT id
      FROM stock_market_participant
     WHERE participant_type = 'SYSTEM_CUSTODY'
       AND status = 'ACTIVE'
);

UPDATE stock_market_participant
   SET participant_code = 'SYSTEM_CUSTODY',
       self_trade_group_id = 'SYSTEM_CUSTODY:DEFAULT',
       updated_at = CURRENT_TIMESTAMP
 WHERE id = @stock_v4_system_custody_participant_id;

UPDATE stock_account account
JOIN stock_market_participant_account mapping
  ON mapping.account_id = account.id
 AND mapping.participant_id = @stock_v4_system_custody_participant_id
   SET account.self_trade_group_id = 'SYSTEM_CUSTODY:DEFAULT',
       account.updated_at = CURRENT_TIMESTAMP;

COMMIT;
SQL

assert_equals \
  "repaired system-custody runtime identity" \
  "1|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_market_participant
         WHERE participant_code = 'SYSTEM_CUSTODY'
           AND participant_type = 'SYSTEM_CUSTODY'
           AND status = 'ACTIVE'
           AND self_trade_group_id = 'SYSTEM_CUSTODY:DEFAULT'
      ),
      (
        SELECT COUNT(*)
          FROM stock_market_participant_account mapping
          JOIN stock_market_participant participant
            ON participant.id = mapping.participant_id
          JOIN stock_account account
            ON account.id = mapping.account_id
         WHERE participant.participant_type = 'SYSTEM_CUSTODY'
           AND mapping.status = 'ACTIVE'
           AND account.self_trade_group_id <>
               'SYSTEM_CUSTODY:DEFAULT'
      )
  )
  "

printf 'PASS repaired only the isolated replay system-custody runtime identity\n'
