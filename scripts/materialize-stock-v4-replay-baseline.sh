#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/sql/stock-v4-replay-baseline-materialize.sql"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"

if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]]; then
  printf 'FAIL replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi

if [[ ! -f "${SQL_FILE}" ]]; then
  printf 'FAIL replay materialization SQL is missing: %s\n' "${SQL_FILE}" >&2
  exit 1
fi

if [[ -z "${MYSQL_BIN}" ]]; then
  MYSQL_BIN="$(command -v mysql || true)"
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

SCHEMA_NAME="$(mysql_replay --execute="SELECT DATABASE()")"
if [[ "${SCHEMA_NAME}" != "${REPLAY_SCHEMA}" ]]; then
  printf 'FAIL connected schema mismatch expected=%s actual=%s\n' \
    "${REPLAY_SCHEMA}" "${SCHEMA_NAME}" >&2
  exit 1
fi
printf 'PASS connected isolated replay schema %s\n' "${REPLAY_SCHEMA}"

assert_equals \
  "staged artifact identity" \
  "6|259|2027-02-09|7370" \
  "
  SELECT CONCAT_WS(
      '|',
      JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.artifactVersion')),
      JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.baselineCloseRunId')),
      JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.baselineBusinessDate')),
      (SELECT COUNT(*) FROM stock_v4_replay_artifact_line)
  )
    FROM stock_v4_replay_artifact_line
   WHERE section_name = 'META'
     AND row_key = 'BASELINE'
  "

assert_equals \
  "materialization marker absence" \
  "0" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_v4_replay_materialization_audit'
  "

assert_equals \
  "empty canonical replay business state" \
  "0|0|0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*) FROM stock_instrument),
      (SELECT COUNT(*) FROM stock_holding),
      (SELECT COUNT(*) FROM stock_order),
      (SELECT COUNT(*) FROM stock_market_close_run)
  )
  "

mysql_replay <"${SQL_FILE}" >/dev/null
printf 'PASS materialized staged artifact into canonical replay tables\n'

assert_equals \
  "materialized market aggregate" \
  "7|26650000|19325000|333820000000.00|24108|282128590.00" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(*),
      SUM(issued_shares),
      SUM(tradable_shares),
      CAST(SUM(close_price * issued_shares) AS DECIMAL(19,2)),
      SUM(buy_quantity),
      CAST(SUM(turnover_amount) AS DECIMAL(19,2))
  )
    FROM stock_order_book_daily_snapshot
   WHERE close_run_id = 259
  "

assert_equals \
  "materialized current share ledger" \
  "7|26650000|0" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(DISTINCT symbol),
      SUM(quantity),
      SUM(reserved_quantity)
  )
    FROM stock_holding
  "

assert_equals \
  "materialized immutable holding snapshot" \
  "395|26650000|59203" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(*),
      SUM(quantity),
      SUM(reserved_quantity)
  )
    FROM stock_holding_snapshot
   WHERE close_run_id = 259
  "

assert_equals \
  "materialized account capital" \
  "179|288537382484.00|151|150" \
  "
  SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*) FROM stock_account),
      (SELECT CAST(SUM(cash_balance) AS DECIMAL(19,2)) FROM stock_account),
      (SELECT COUNT(*) FROM stock_auto_participant),
      (
        SELECT COUNT(*)
          FROM stock_auto_participant
         WHERE enabled = b'1'
           AND withdrawn_at IS NULL
      )
  )
  "

assert_equals \
  "materialized system-custody runtime identity" \
  "1|1|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_market_participant
         WHERE participant_type = 'SYSTEM_CUSTODY'
           AND status = 'ACTIVE'
      ),
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

assert_equals \
  "materialized V4 profile configuration" \
  "27|0" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(*),
      SUM(behavior_model_version <> 'V4')
  )
    FROM stock_auto_participant_profile_config
  "

assert_equals \
  "materialized role configuration" \
  "7|27|7|4|28|7|32" \
  "
  SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*) FROM stock_market_participant),
      (SELECT COUNT(*) FROM stock_market_participant_account),
      (SELECT COUNT(*) FROM stock_liquidity_mandate),
      (SELECT COUNT(*) FROM stock_institution_portfolio),
      (SELECT COUNT(*) FROM stock_institution_symbol_mandate),
      (SELECT COUNT(*) FROM stock_underwriting_contract),
      (SELECT COUNT(*) FROM stock_market_policy_version)
  )
  "

assert_equals \
  "materialized operational replay state" \
  "4649|288537382484.00|8|72|7|7|25|37183802|14|8|41|719" \
  "
  SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*) FROM stock_account_cash_flow),
      (
        SELECT CAST(
            SUM(
                CASE flow_type
                    WHEN 'DEPOSIT' THEN amount
                    WHEN 'WITHDRAW' THEN -amount
                END
            )
            AS DECIMAL(24,2)
        )
          FROM stock_account_cash_flow
      ),
      (SELECT COUNT(*) FROM stock_corporate_action),
      (SELECT COUNT(*) FROM stock_corporate_action_entitlement),
      (SELECT COUNT(*) FROM stock_auto_market_config),
      (SELECT COUNT(*) FROM stock_liquidity_transition),
      (SELECT COUNT(*) FROM stock_security_allocation_ledger),
      (SELECT SUM(quantity) FROM stock_security_allocation_ledger),
      (SELECT COUNT(*) FROM stock_market_reference_volume_snapshot),
      (SELECT COUNT(*) FROM stock_underwriting_daily_supply_state),
      (SELECT COUNT(*) FROM stock_liquidity_daily_state),
      (SELECT COUNT(*) FROM stock_order_strategy_origin)
  )
  "

assert_equals \
  "materialized underwriting allocation reconciliation" \
  "0" \
  "
  SELECT COUNT(*)
    FROM stock_underwriting_contract contract
    LEFT JOIN (
        SELECT
            underwriting_contract_id,
            SUM(quantity) AS total_quantity,
            SUM(
                CASE
                    WHEN tradability_status = 'TRADABLE' THEN quantity
                    ELSE 0
                END
            ) AS tradable_quantity,
            SUM(
                CASE
                    WHEN tradability_status = 'LOCKED' THEN quantity
                    ELSE 0
                END
            ) AS locked_quantity
          FROM stock_security_allocation_ledger
         WHERE event_type = 'INITIAL_ISSUE'
         GROUP BY underwriting_contract_id
    ) allocation
      ON allocation.underwriting_contract_id = contract.id
   WHERE COALESCE(allocation.total_quantity, 0)
             <> contract.total_issue_quantity
      OR COALESCE(allocation.tradable_quantity, 0)
             <> contract.tradable_allocation_quantity
      OR COALESCE(allocation.locked_quantity, 0)
             <> contract.locked_allocation_quantity
  "

assert_equals \
  "materialized underwriter inventory" \
  "DEMO004:4974998|DEMO005:1492500|DEMO006:621875|DEMO007:198999" \
  "
  SELECT GROUP_CONCAT(
      CONCAT(holding.symbol, ':', holding.quantity)
      ORDER BY holding.symbol
      SEPARATOR '|'
  )
    FROM stock_holding holding
    JOIN stock_account account
      ON account.id = holding.account_id
   WHERE account.participant_category = 'ISSUE_UNDERWRITER'
     AND holding.quantity > 0
  "

assert_equals \
  "materialized order execution intent basis" \
  "799|130|65|24108|282128590.00|16|13|54283" \
  "
  SELECT CONCAT_WS(
      '|',
      (SELECT COUNT(*) FROM stock_order),
      (SELECT COUNT(*) FROM stock_execution),
      (
        SELECT COUNT(*)
          FROM stock_execution
         WHERE side = 'BUY'
      ),
      (
        SELECT SUM(quantity)
          FROM stock_execution
         WHERE side = 'BUY'
      ),
      (
        SELECT CAST(SUM(gross_amount) AS DECIMAL(19,2))
          FROM stock_execution
         WHERE side = 'BUY'
      ),
      (SELECT COUNT(*) FROM stock_auto_participant_order_intent),
      (
        SELECT COUNT(*)
          FROM stock_auto_participant_order_intent
         WHERE status = 'ACTIVE'
      ),
      (
        SELECT SUM(open_quantity)
          FROM stock_auto_participant_order_intent
         WHERE status = 'ACTIVE'
      )
  )
  "

assert_equals \
  "materialized V3 audit is non-runnable" \
  "1|0" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(*),
      SUM(
          status <> 'RETIRED'
          OR runtime_enabled <> b'0'
      )
  )
    FROM stock_auto_participant_policy_revision
   WHERE behavior_model_version = 'V3'
  "

assert_equals \
  "materialized identity sanitization" \
  "0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      SUM(
          participant_category = 'AUTO_PARTICIPANT'
          AND user_key NOT LIKE 'REPLAY_AUTO_%'
      ),
      SUM(
          participant_category <> 'AUTO_PARTICIPANT'
          AND user_key IS NOT NULL
      )
  )
    FROM stock_account
  "

mysql_replay --execute="
  CREATE TABLE stock_v4_replay_materialization_audit (
    materialization_key VARCHAR(80) NOT NULL,
    artifact_version INT NOT NULL,
    baseline_close_run_id BIGINT NOT NULL,
    baseline_business_date DATE NOT NULL,
    artifact_line_count BIGINT NOT NULL,
    materialized_at DATETIME NOT NULL,
    PRIMARY KEY (materialization_key)
  );

  INSERT INTO stock_v4_replay_materialization_audit(
      materialization_key,
      artifact_version,
      baseline_close_run_id,
      baseline_business_date,
      artifact_line_count,
      materialized_at
  )
  VALUES(
      'KOSPI_ONE_HUNDREDTH_V4',
      6,
      259,
      DATE '2027-02-09',
      7370,
      CURRENT_TIMESTAMP
  );
" >/dev/null

printf 'PASS materialization audit marker\n'
printf 'INFO operating STOCK_SERVICE was not queried or changed by this command\n'
