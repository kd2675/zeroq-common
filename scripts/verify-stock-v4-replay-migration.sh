#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DDL_DIR="${ROOT_DIR}/stock-back-service/src/main/resources/db/ddl"
MAINTENANCE_DIR="${ROOT_DIR}/stock-back-service/src/main/resources/db/maintenance"

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

apply_sql_file() {
  local sql_file="$1"

  if [[ ! -f "${sql_file}" ]]; then
    printf 'FAIL missing SQL file %s\n' "${sql_file}" >&2
    exit 1
  fi

  sed "s/STOCK_SERVICE/${REPLAY_SCHEMA}/g" "${sql_file}" \
    | mysql_replay >/dev/null
}

hot_index_fingerprint() {
  mysql_replay --execute="
    SET SESSION group_concat_max_len = 1048576;
    SELECT CONCAT(
        COUNT(*),
        '|',
        COALESCE(
          SHA2(
            GROUP_CONCAT(
              CONCAT_WS(
                ':',
                table_name,
                index_name,
                non_unique,
                seq_in_index,
                column_name,
                COALESCE(sub_part, ''),
                COALESCE(collation, '')
              )
              ORDER BY table_name, index_name, seq_in_index
              SEPARATOR '|'
            ),
            256
          ),
          ''
        )
    )
      FROM information_schema.statistics
     WHERE table_schema = DATABASE()
       AND table_name IN ('stock_order', 'stock_execution');
  " | tail -n 1
}

baseline_business_fingerprint() {
  mysql_replay --execute="
    SELECT CONCAT_WS(
        '|',
        (SELECT COUNT(*) FROM stock_account),
        (
          SELECT CAST(SUM(cash_balance) AS DECIMAL(24,2))
            FROM stock_account
        ),
        (SELECT COUNT(*) FROM stock_holding),
        (SELECT SUM(quantity) FROM stock_holding),
        (SELECT SUM(reserved_quantity) FROM stock_holding),
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
    );
  "
}

SCHEMA_NAME="$(mysql_replay --execute="SELECT DATABASE()")"
if [[ "${SCHEMA_NAME}" != "${REPLAY_SCHEMA}" ]]; then
  printf 'FAIL connected schema mismatch expected=%s actual=%s\n' \
    "${REPLAY_SCHEMA}" "${SCHEMA_NAME}" >&2
  exit 1
fi
printf 'PASS connected isolated replay schema %s\n' "${REPLAY_SCHEMA}"

assert_equals \
  "materialized baseline marker" \
  "6|259|2027-02-09|7370" \
  "
  SELECT CONCAT_WS(
      '|',
      artifact_version,
      baseline_close_run_id,
      baseline_business_date,
      artifact_line_count
  )
    FROM stock_v4_replay_materialization_audit
   WHERE materialization_key = 'KOSPI_ONE_HUNDREDTH_V4'
  "

assert_equals \
  "migration marker absence" \
  "0" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_v4_replay_migration_audit'
  "

EXPECTED_BASELINE_FINGERPRINT=\
"179|288537382484.00|395|26650000|0|799|130|65|24108|282128590.00|16|4649|288537382484.00|8|72|7|7|25|37183802|14|8|41|719"
BASELINE_FINGERPRINT_BEFORE="$(baseline_business_fingerprint)"
if [[ "${BASELINE_FINGERPRINT_BEFORE}" != "${EXPECTED_BASELINE_FINGERPRINT}" ]]; then
  printf 'FAIL baseline business fingerprint expected=%s actual=%s\n' \
    "${EXPECTED_BASELINE_FINGERPRINT}" \
    "${BASELINE_FINGERPRINT_BEFORE}" >&2
  exit 1
fi
printf 'PASS baseline business fingerprint = %s\n' \
  "${BASELINE_FINGERPRINT_BEFORE}"

HOT_INDEX_FINGERPRINT_BEFORE="$(hot_index_fingerprint)"

MIGRATION_FILES=(
  "stock_eod_runtime_contract_alter.sql"
  "stock_market_reference_volume_snapshot_alter.sql"
  "stock_auto_participant_v4_cutover_alter.sql"
  "stock_auto_participant_v4_runtime_failure_alter.sql"
  "stock_auto_participant_v4_calibration_snapshot_alter.sql"
  "stock_scaled_market_v4_foundation_alter.sql"
  "stock_scaled_market_symbol_staging_alter.sql"
  "stock_scaled_market_symbol_maturity_alter.sql"
  "stock_scaled_market_rebase_plan_alter.sql"
  "stock_scaled_market_contract_activation_alter.sql"
  "stock_liquidity_provider_adaptive_execution_alter.sql"
  "stock_scaled_market_role_capacity_alter.sql"
  "stock_institution_participation_contract_alter.sql"
  "stock_scaled_market_role_redistribution_alter.sql"
  "stock_underwriter_distribution_checkpoint_alter.sql"
  "stock_scaled_market_liquidity_distribution_alter.sql"
)

for attempt in 1 2; do
  for migration_file in "${MIGRATION_FILES[@]}"; do
    apply_sql_file "${DDL_DIR}/${migration_file}"
  done
  apply_sql_file \
    "${MAINTENANCE_DIR}/stock_scaled_market_v4_contract_seed.sql"
  printf 'PASS replay V4 migration attempt %s applied\n' "${attempt}"
done

BASELINE_FINGERPRINT_AFTER="$(baseline_business_fingerprint)"
if [[ "${BASELINE_FINGERPRINT_AFTER}" != "${BASELINE_FINGERPRINT_BEFORE}" ]]; then
  printf 'FAIL replay migration changed baseline business data\n' >&2
  printf 'before=%s\nafter=%s\n' \
    "${BASELINE_FINGERPRINT_BEFORE}" \
    "${BASELINE_FINGERPRINT_AFTER}" >&2
  exit 1
fi
printf 'PASS baseline business data unchanged after migration\n'

HOT_INDEX_FINGERPRINT_AFTER="$(hot_index_fingerprint)"
if [[ "${HOT_INDEX_FINGERPRINT_AFTER}" != "${HOT_INDEX_FINGERPRINT_BEFORE}" ]]; then
  printf 'FAIL stock_order/stock_execution index fingerprint changed\n' >&2
  printf 'before=%s\nafter=%s\n' \
    "${HOT_INDEX_FINGERPRINT_BEFORE}" \
    "${HOT_INDEX_FINGERPRINT_AFTER}" >&2
  exit 1
fi
printf 'PASS stock_order/stock_execution index fingerprint unchanged = %s\n' \
  "${HOT_INDEX_FINGERPRINT_AFTER}"

assert_equals \
  "automatic-market capacity plan table" \
  "1" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = DATABASE()
     AND table_name =
         'stock_scaled_market_auto_market_capacity_plan'
  "

assert_equals \
  "adaptive LP daily execution constraint" \
  "1" \
  "
  SELECT COUNT(*)
    FROM information_schema.check_constraints
   WHERE constraint_schema = DATABASE()
     AND constraint_name = 'chk_stock_liquidity_mandate_volume'
     AND check_clause LIKE '%daily_execution_participation_rate%'
     AND check_clause LIKE '%1.000000%'
  "

assert_equals \
  "role-capacity automatic-market count column" \
  "1" \
  "
  SELECT COUNT(*)
    FROM information_schema.columns
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_scaled_market_role_capacity_plan'
     AND column_name = 'target_auto_market_config_count'
     AND is_nullable = 'NO'
  "

assert_equals \
  "role redistribution ledger tables" \
  "6" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = DATABASE()
     AND table_name IN (
       'stock_scaled_market_role_redistribution_plan',
       'stock_scaled_market_role_redistribution_symbol_plan',
       'stock_scaled_market_role_redistribution_recipient_plan',
       'stock_scaled_market_role_redistribution_recipient_holding_plan',
       'stock_scaled_market_role_redistribution_allocation_plan',
       'stock_scaled_market_role_redistribution_order_link'
     )
  "

assert_equals \
  "market reconstruction order origin constraint" \
  "1" \
  "
  SELECT COUNT(*)
    FROM information_schema.check_constraints
   WHERE constraint_schema = DATABASE()
     AND constraint_name = 'chk_stock_order_origin_type'
     AND check_clause LIKE '%MARKET_RECONSTRUCTION%'
  "

assert_equals \
  "single draft scaled-market contract" \
  "1" \
  "
  SELECT COUNT(*)
    FROM stock_scaled_market_contract
   WHERE reference_market = 'KOSPI_COMMON'
     AND reference_date = DATE '2026-07-30'
     AND baseline_close_run_id = 259
     AND baseline_business_date = DATE '2027-02-09'
     AND market_scale_rate = 0.01000000
     AND status = 'DRAFT'
     AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
  "

assert_equals \
  "aggregate scaled-market target" \
  "8|577289815|402369898|44594000000000.00|3699844|256330000000.00|383210000000.00" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(target.symbol),
      SUM(target.target_issued_shares),
      SUM(target.target_tradable_shares),
      CAST(
          SUM(target.target_market_capitalization)
          AS DECIMAL(24,2)
      ),
      SUM(target.target_daily_volume),
      CAST(contract.target_daily_turnover_lower AS DECIMAL(24,2)),
      CAST(contract.target_daily_turnover_upper AS DECIMAL(24,2))
  )
    FROM stock_scaled_market_contract contract
    JOIN stock_scaled_market_symbol_target target
      ON target.contract_version = contract.contract_version
   WHERE contract.status = 'DRAFT'
     AND contract.created_by = 'SYSTEM_V4_RECONSTRUCTION'
   GROUP BY contract.contract_version
  "

assert_equals \
  "all existing and new symbol targets" \
  "DEMO001:18945251:18945251:198600.00:3762526848600.00:121420|DEMO002:189550602:189550602:23350.00:4426006556700.00:1214828|DEMO003:18954126:18954126:518000.00:9818237268000.00:121477|DEMO004:189541726:94770863:20050.00:3800311606300.00:1214771|DEMO005:56862505:28431253:94600.00:5379192973000.00:364431|DEMO006:23692711:11846356:258000.00:6112719438000.00:151846|DEMO007:7581667:3790834:755000.00:5724158585000.00:48591|DEMO008:72161227:36080613:77200.00:5570846724400.00:462480" \
  "
  SELECT GROUP_CONCAT(
      CONCAT_WS(
        ':',
        symbol,
        target_issued_shares,
        target_tradable_shares,
        CAST(target_reference_price AS DECIMAL(19,2)),
        CAST(target_market_capitalization AS DECIMAL(24,2)),
        target_daily_volume
      )
      ORDER BY symbol
      SEPARATOR '|'
  )
    FROM stock_scaled_market_symbol_target
   WHERE contract_version = (
      SELECT contract_version
        FROM stock_scaled_market_contract
       WHERE status = 'DRAFT'
         AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
   )
  "

assert_equals \
  "existing seven-symbol intermediate target" \
  "7|505128588|366289285|39023153275600.00|3237364" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(*),
      SUM(target_issued_shares),
      SUM(target_tradable_shares),
      CAST(SUM(target_market_capitalization) AS DECIMAL(24,2)),
      SUM(target_daily_volume)
  )
    FROM stock_scaled_market_symbol_target
   WHERE contract_version = (
      SELECT contract_version
        FROM stock_scaled_market_contract
       WHERE status = 'DRAFT'
         AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
   )
     AND symbol IN (
       'DEMO001', 'DEMO002', 'DEMO003', 'DEMO004',
       'DEMO005', 'DEMO006', 'DEMO007'
     )
  "

assert_equals \
  "symbol share and market-capitalization arithmetic" \
  "0|0|44594000000000.00" \
  "
  SELECT CONCAT_WS(
      '|',
      SUM(target_tradable_shares > target_issued_shares),
      SUM(
        target_market_capitalization
          <> target_issued_shares * target_reference_price
      ),
      CAST(
        SUM(target_issued_shares * target_reference_price)
        AS DECIMAL(24,2)
      )
  )
    FROM stock_scaled_market_symbol_target
   WHERE contract_version = (
      SELECT contract_version
        FROM stock_scaled_market_contract
       WHERE status = 'DRAFT'
         AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
   )
  "

assert_equals \
  "derived target reference turnover is inside the contract band" \
  "285802591950.00|1" \
  "
  SELECT CONCAT_WS(
      '|',
      CAST(
        SUM(target.target_reference_price * target.target_daily_volume)
        AS DECIMAL(24,2)
      ),
      IF(
        SUM(target.target_reference_price * target.target_daily_volume)
          BETWEEN contract.target_daily_turnover_lower
              AND contract.target_daily_turnover_upper,
        1,
        0
      )
  )
    FROM stock_scaled_market_contract contract
    JOIN stock_scaled_market_symbol_target target
      ON target.contract_version = contract.contract_version
   WHERE contract.status = 'DRAFT'
     AND contract.created_by = 'SYSTEM_V4_RECONSTRUCTION'
   GROUP BY contract.contract_version
  "

assert_equals \
  "population and auto-participant capital contract" \
  "150|15000|100.0000|16006366331295.49|0.35893542" \
  "
  SELECT CONCAT_WS(
      '|',
      engine_participant_count,
      represented_participant_count,
      CAST(population_weight AS DECIMAL(12,4)),
      CAST(target_auto_participant_aum AS DECIMAL(24,2)),
      CAST(target_auto_participant_aum_rate AS DECIMAL(12,8))
  )
    FROM stock_auto_participant_population_contract
   WHERE contract_version = (
      SELECT contract_version
        FROM stock_scaled_market_contract
       WHERE status = 'DRAFT'
         AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
   )
  "

assert_equals \
  "non-runnable historical V3 policy" \
  "1|0" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(*),
      SUM(status <> 'RETIRED' OR runtime_enabled <> b'0')
  )
    FROM stock_auto_participant_policy_revision
   WHERE behavior_model_version = 'V3'
  "

assert_equals \
  "neutral V4 draft policy" \
  "1" \
  "
  SELECT COUNT(*)
    FROM stock_auto_participant_policy_revision
   WHERE behavior_model_version = 'V4'
     AND status = 'DRAFT'
     AND runtime_enabled = b'0'
     AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
     AND JSON_UNQUOTE(JSON_EXTRACT(policy_json, '$.model')) = 'V4'
     AND JSON_EXTRACT(policy_json, '$.ordinaryChildNotionalRate') = 0.0
     AND JSON_EXTRACT(policy_json, '$.rareChildNotionalRate') = 0.0
     AND JSON_EXTRACT(policy_json, '$.directionalUrgencyScale') = 0.0
     AND JSON_EXTRACT(policy_json, '$.maxAttentionEventsPerSession') = 0.0
  "

assert_equals \
  "V4-only runtime projections" \
  "0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_auto_participant_profile_config
         WHERE behavior_model_version <> 'V4'
      ),
      (
        SELECT COUNT(*)
          FROM stock_auto_participant_order_schedule
         WHERE behavior_model_version <> 'V4'
      )
  )
  "

assert_equals \
  "V4 runtime failure ledger" \
  "1|1" \
  "
  SELECT CONCAT_WS(
      '|',
      COUNT(DISTINCT table_name),
      COUNT(DISTINCT index_name)
  )
    FROM information_schema.statistics
   WHERE table_schema = DATABASE()
     AND table_name = 'stock_auto_participant_v4_runtime_failure'
     AND index_name = 'idx_stock_auto_v4_runtime_failure_date'
  "

mysql_replay --execute="
  CREATE TABLE stock_v4_replay_migration_audit (
    migration_key VARCHAR(80) NOT NULL,
    migration_attempt_count INT NOT NULL,
    contract_version BIGINT NOT NULL,
    target_symbol_count INT NOT NULL,
    target_issued_shares BIGINT NOT NULL,
    target_market_capitalization DECIMAL(24,2) NOT NULL,
    target_daily_volume BIGINT NOT NULL,
    verified_at DATETIME NOT NULL,
    PRIMARY KEY (migration_key)
  );

  INSERT INTO stock_v4_replay_migration_audit(
      migration_key,
      migration_attempt_count,
      contract_version,
      target_symbol_count,
      target_issued_shares,
      target_market_capitalization,
      target_daily_volume,
      verified_at
  )
  SELECT
      'KOSPI_ONE_HUNDREDTH_V4',
      2,
      contract.contract_version,
      COUNT(target.symbol),
      SUM(target.target_issued_shares),
      SUM(target.target_market_capitalization),
      SUM(target.target_daily_volume),
      CURRENT_TIMESTAMP
    FROM stock_scaled_market_contract contract
    JOIN stock_scaled_market_symbol_target target
      ON target.contract_version = contract.contract_version
   WHERE contract.status = 'DRAFT'
     AND contract.created_by = 'SYSTEM_V4_RECONSTRUCTION'
   GROUP BY contract.contract_version;
" >/dev/null

printf 'PASS replay migration audit marker\n'
printf 'INFO operating STOCK_SERVICE was not queried or changed by this command\n'
