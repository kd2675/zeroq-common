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
: "${STOCK_MYSQL_VERIFY_SCHEMA:?STOCK_MYSQL_VERIFY_SCHEMA is required}"

VERIFY_SCHEMA="${STOCK_MYSQL_VERIFY_SCHEMA}"
KEEP_VERIFY_SCHEMA="${STOCK_MYSQL_KEEP_VERIFY_SCHEMA:-false}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"

if [[ ! "${VERIFY_SCHEMA}" =~ ^STOCK_V4_VERIFY_[A-Za-z0-9_]+$ ]]; then
  printf 'FAIL verification schema must match STOCK_V4_VERIFY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi

case "${KEEP_VERIFY_SCHEMA}" in
  true|false)
    ;;
  *)
    printf 'FAIL STOCK_MYSQL_KEEP_VERIFY_SCHEMA must be true or false\n' >&2
    exit 1
    ;;
esac

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
  "--connect-timeout=10"
  "--default-character-set=utf8mb4"
  "--batch"
  "--skip-column-names"
)

mysql_admin() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" "$@"
}

mysql_verify() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" \
    "--database=${VERIFY_SCHEMA}" "$@"
}

CREATED_SCHEMA=false

cleanup() {
  local exit_code=$?
  trap - EXIT

  if [[ "${CREATED_SCHEMA}" == "true" ]]; then
    if [[ "${KEEP_VERIFY_SCHEMA}" == "true" ]]; then
      printf 'INFO retained isolated verification schema %s\n' "${VERIFY_SCHEMA}"
    else
      if mysql_admin \
        --execute="DROP DATABASE IF EXISTS \`${VERIFY_SCHEMA}\`" >/dev/null; then
        printf 'PASS removed isolated verification schema %s\n' "${VERIFY_SCHEMA}"
      else
        printf 'WARN failed to remove isolated verification schema %s\n' \
          "${VERIFY_SCHEMA}" >&2
        if [[ "${exit_code}" -eq 0 ]]; then
          exit_code=1
        fi
      fi
    fi
  fi

  exit "${exit_code}"
}
trap cleanup EXIT

assert_equals() {
  local label="$1"
  local expected="$2"
  local query="$3"
  local actual

  actual="$(mysql_verify --execute="${query}")"
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

  sed "s/STOCK_SERVICE/${VERIFY_SCHEMA}/g" "${sql_file}" \
    | mysql_admin >/dev/null
}

hot_index_fingerprint() {
  mysql_verify --execute="
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

prepare_legacy_v3_fixture() {
  mysql_verify --execute="
    DELETE FROM stock_auto_participant_policy_revision;

    ALTER TABLE stock_auto_participant_policy_revision
      DROP CHECK chk_stock_auto_policy_model;
    ALTER TABLE stock_auto_participant_policy_revision
      MODIFY COLUMN behavior_model_version VARCHAR(20) NOT NULL DEFAULT 'V3';

    ALTER TABLE stock_auto_participant_profile_config
      DROP CHECK chk_stock_auto_profile_behavior_model;
    ALTER TABLE stock_auto_participant_profile_config
      MODIFY COLUMN behavior_model_version VARCHAR(20) NOT NULL DEFAULT 'V3';
    UPDATE stock_auto_participant_profile_config
       SET behavior_model_version = 'V3';

    ALTER TABLE stock_auto_participant_order_schedule
      DROP CHECK chk_stock_auto_order_schedule_model;
    ALTER TABLE stock_auto_participant_order_schedule
      MODIFY COLUMN behavior_model_version VARCHAR(20) NOT NULL DEFAULT 'V3';

    ALTER TABLE stock_order
      DROP CHECK chk_stock_order_auto_behavior_model,
      DROP CHECK chk_stock_order_origin_type,
      ADD CONSTRAINT chk_stock_order_auto_behavior_model CHECK (
        auto_behavior_model_version IS NULL
        OR auto_behavior_model_version = 'V3'
      ),
      ADD CONSTRAINT chk_stock_order_origin_type CHECK (
        origin_type IS NULL OR CASE origin_type
          WHEN 'MANUAL_PARTICIPANT' THEN 1
          WHEN 'AUTO_PARTICIPANT' THEN 1
          WHEN 'INSTITUTIONAL_INVESTOR' THEN 1
          WHEN 'LIQUIDITY_PROVIDER' THEN 1
          WHEN 'ISSUE_UNDERWRITER' THEN 1
          ELSE 0
        END = 1
      );

    ALTER TABLE stock_auto_participant_v4_calibration_snapshot
      DROP CHECK chk_stock_auto_v4_calibration_counts;
    ALTER TABLE stock_auto_participant_v4_calibration_snapshot
      DROP COLUMN participant_identity_mismatch_count;
    ALTER TABLE stock_auto_participant_v4_calibration_snapshot
      DROP COLUMN active_participant_count;

    INSERT INTO stock_auto_participant_policy_revision(
        behavior_model_version,
        status,
        effective_trade_date,
        runtime_enabled,
        policy_json,
        created_by,
        created_at,
        activated_at,
        retired_at
    )
    VALUES(
        'V3',
        'ACTIVE',
        DATE '2027-02-09',
        b'1',
        '{\"model\":\"V3\",\"flowCalibrationStage\":0}',
        'V3_LEGACY_FIXTURE',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP,
        NULL
    );
  " >/dev/null
  printf 'PASS isolated pre-cutover V3 fixture prepared\n'
}

MYSQL_VERSION="$(mysql_admin --execute="SELECT VERSION()")"
if [[ "${MYSQL_VERSION}" != 8.* ]]; then
  printf 'FAIL MySQL 8.x is required, actual=%s\n' "${MYSQL_VERSION}" >&2
  exit 1
fi
printf 'PASS MySQL version = %s\n' "${MYSQL_VERSION}"

EXISTING_SCHEMA_COUNT="$(
  mysql_admin --execute="
    SELECT COUNT(*)
      FROM information_schema.schemata
     WHERE schema_name = '${VERIFY_SCHEMA}'
  "
)"
if [[ "${EXISTING_SCHEMA_COUNT}" != "0" ]]; then
  printf 'FAIL verification schema already exists and will not be overwritten: %s\n' \
    "${VERIFY_SCHEMA}" >&2
  exit 1
fi

mysql_admin --execute="
  CREATE DATABASE \`${VERIFY_SCHEMA}\`
    DEFAULT CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci
" >/dev/null
CREATED_SCHEMA=true
printf 'PASS created isolated verification schema %s\n' "${VERIFY_SCHEMA}"

apply_sql_file "${DDL_DIR}/stock_all.sql"
printf 'PASS canonical stock schema applied\n'

prepare_legacy_v3_fixture

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
  printf 'PASS scoped V4 migration attempt %s applied\n' "${attempt}"
done

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
  "SELECT COUNT(*)
     FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name =
          'stock_scaled_market_auto_market_capacity_plan'"

assert_equals \
  "adaptive LP daily execution constraint" \
  "1" \
  "SELECT COUNT(*)
     FROM information_schema.check_constraints
    WHERE constraint_schema = DATABASE()
      AND constraint_name = 'chk_stock_liquidity_mandate_volume'
      AND check_clause LIKE '%daily_execution_participation_rate%'
      AND check_clause LIKE '%1.000000%'"

assert_equals \
  "role-capacity automatic-market count column" \
  "1" \
  "SELECT COUNT(*)
     FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'stock_scaled_market_role_capacity_plan'
      AND column_name = 'target_auto_market_config_count'
      AND is_nullable = 'NO'"

assert_equals \
  "role redistribution ledger tables" \
  "6" \
  "SELECT COUNT(*)
     FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name IN (
        'stock_scaled_market_role_redistribution_plan',
        'stock_scaled_market_role_redistribution_symbol_plan',
        'stock_scaled_market_role_redistribution_recipient_plan',
        'stock_scaled_market_role_redistribution_recipient_holding_plan',
        'stock_scaled_market_role_redistribution_allocation_plan',
        'stock_scaled_market_role_redistribution_order_link'
      )"

assert_equals \
  "role redistribution pinned numeric columns" \
  "9" \
  "SELECT COUNT(*)
     FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND (
        (
          table_name =
            'stock_scaled_market_role_redistribution_plan'
          AND column_name IN (
            'target_cash_buffer',
            'target_transfer_quantity',
            'target_transfer_amount',
            'theoretical_minimum_capital_transfer',
            'planned_capital_transfer',
            'capital_rounding_excess'
          )
        )
        OR (
          table_name =
            'stock_scaled_market_role_redistribution_symbol_plan'
          AND column_name IN (
            'source_holding_quantity',
            'target_final_quantity',
            'target_transfer_quantity'
          )
        )
      )"

assert_equals \
  "role redistribution recipient holding snapshot columns" \
  "7" \
  "SELECT COUNT(*)
     FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name =
          'stock_scaled_market_role_redistribution_recipient_holding_plan'
      AND column_name IN (
        'account_id',
        'symbol',
        'source_quantity',
        'source_reserved_quantity',
        'source_average_price',
        'reference_price',
        'source_market_value'
      )"

assert_equals \
  "role redistribution paired-order ledger columns" \
  "9" \
  "SELECT COUNT(*)
     FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name =
          'stock_scaled_market_role_redistribution_order_link'
      AND column_name IN (
        'order_id',
        'plan_id',
        'pair_id',
        'symbol',
        'source_account_id',
        'target_account_id',
        'order_account_id',
        'side',
        'submitted_quantity'
      )"

assert_equals \
  "market reconstruction order origin constraint" \
  "1" \
  "SELECT COUNT(*)
     FROM information_schema.check_constraints
    WHERE constraint_schema = DATABASE()
      AND constraint_name = 'chk_stock_order_origin_type'
      AND check_clause LIKE '%MARKET_RECONSTRUCTION%'"

assert_equals \
  "single draft contract" \
  "1" \
  "SELECT COUNT(*)
     FROM stock_scaled_market_contract
    WHERE reference_market = 'KOSPI_COMMON'
      AND reference_date = DATE '2026-07-30'
      AND baseline_close_run_id = 259
      AND baseline_business_date = DATE '2027-02-09'
      AND market_scale_rate = 0.01000000
      AND status = 'DRAFT'
      AND created_by = 'SYSTEM_V4_RECONSTRUCTION'"

assert_equals \
  "aggregate market target" \
  "8|577289815|402369898|44594000000000.00|3699844" \
  "SELECT CONCAT_WS(
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
    )"

assert_equals \
  "aggregate allocation weights" \
  "1.00000000|1.00000000" \
  "SELECT CONCAT_WS(
      '|',
      CAST(SUM(target_issued_share_weight) AS DECIMAL(10,8)),
      CAST(SUM(target_market_cap_weight) AS DECIMAL(10,8))
   )
     FROM stock_scaled_market_symbol_target
    WHERE contract_version = (
      SELECT contract_version
        FROM stock_scaled_market_contract
       WHERE status = 'DRAFT'
         AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
    )"

assert_equals \
  "all existing and new symbol targets" \
  "DEMO001:18945251:18945251:198600.00:3762526848600.00:121420|DEMO002:189550602:189550602:23350.00:4426006556700.00:1214828|DEMO003:18954126:18954126:518000.00:9818237268000.00:121477|DEMO004:189541726:94770863:20050.00:3800311606300.00:1214771|DEMO005:56862505:28431253:94600.00:5379192973000.00:364431|DEMO006:23692711:11846356:258000.00:6112719438000.00:151846|DEMO007:7581667:3790834:755000.00:5724158585000.00:48591|DEMO008:72161227:36080613:77200.00:5570846724400.00:462480" \
  "SELECT GROUP_CONCAT(
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
    )"

assert_equals \
  "existing seven-symbol intermediate target" \
  "7|505128588|366289285|39023153275600.00|3237364" \
  "SELECT CONCAT_WS(
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
      )"

assert_equals \
  "symbol share and market-capitalization arithmetic" \
  "0|0|44594000000000.00" \
  "SELECT CONCAT_WS(
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
    )"

assert_equals \
  "derived target reference turnover is inside the contract band" \
  "285802591950.00|1" \
  "SELECT CONCAT_WS(
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
    GROUP BY contract.contract_version"

assert_equals \
  "DEMO008 preparation and final target" \
  "3807143|1903571|12530.00|72161227|36080613|77200.00|PREPARING" \
  "SELECT CONCAT_WS(
      '|',
      pre_rebase_issued_shares,
      pre_rebase_tradable_shares,
      CAST(pre_rebase_reference_price AS DECIMAL(19,2)),
      target_issued_shares,
      target_tradable_shares,
      CAST(target_reference_price AS DECIMAL(19,2)),
      lifecycle_status
   )
     FROM stock_scaled_market_symbol_target
    WHERE symbol = 'DEMO008'
      AND contract_version = (
        SELECT contract_version
          FROM stock_scaled_market_contract
         WHERE status = 'DRAFT'
           AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
      )"

assert_equals \
  "population and auto-participant capital contract" \
  "150|15000|100.0000|16006366331295.49|0.35893542" \
  "SELECT CONCAT_WS(
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
    )"

assert_equals \
  "retired and disabled legacy V3 policy" \
  "1" \
  "SELECT COUNT(*)
     FROM stock_auto_participant_policy_revision
    WHERE behavior_model_version = 'V3'
      AND status = 'RETIRED'
      AND runtime_enabled = b'0'
      AND runtime_change_reason = 'V4 cutover retired historical V3 policy'
      AND runtime_changed_by = 'SYSTEM_V4_RECONSTRUCTION'
      AND runtime_changed_at IS NOT NULL
      AND retired_at IS NOT NULL"

assert_equals \
  "V3 non-retired policy count" \
  "0" \
  "SELECT COUNT(*)
     FROM stock_auto_participant_policy_revision
    WHERE behavior_model_version = 'V3'
      AND (status <> 'RETIRED' OR runtime_enabled <> b'0')"

assert_equals \
  "neutral V4 draft policy count" \
  "1" \
  "SELECT COUNT(*)
     FROM stock_auto_participant_policy_revision
    WHERE behavior_model_version = 'V4'
      AND status = 'DRAFT'
      AND runtime_enabled = b'0'
      AND created_by = 'SYSTEM_V4_RECONSTRUCTION'
      AND JSON_UNQUOTE(JSON_EXTRACT(policy_json, '$.model')) = 'V4'
      AND JSON_EXTRACT(policy_json, '$.ordinaryChildNotionalRate') = 0.0
      AND JSON_EXTRACT(policy_json, '$.rareChildNotionalRate') = 0.0
      AND JSON_EXTRACT(policy_json, '$.directionalUrgencyScale') = 0.0
      AND JSON_EXTRACT(policy_json, '$.maxAttentionEventsPerSession') = 0.0"

assert_equals \
  "V4-only profile configuration" \
  "0" \
  "SELECT COUNT(*)
     FROM stock_auto_participant_profile_config
    WHERE behavior_model_version <> 'V4'"

assert_equals \
  "V4-only rebuildable schedules" \
  "0" \
  "SELECT COUNT(*)
     FROM stock_auto_participant_order_schedule
    WHERE behavior_model_version <> 'V4'"

assert_equals \
  "calibration snapshot tables" \
  "2" \
  "SELECT COUNT(*)
     FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name IN (
        'stock_auto_participant_v4_calibration_snapshot',
        'stock_auto_participant_v4_calibration_symbol_snapshot'
      )"

assert_equals \
  "V4 runtime failure ledger" \
  "1|1" \
  "SELECT CONCAT_WS(
      '|',
      COUNT(DISTINCT table_name),
      COUNT(DISTINCT index_name)
   )
     FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND table_name = 'stock_auto_participant_v4_runtime_failure'
      AND index_name = 'idx_stock_auto_v4_runtime_failure_date'"

assert_equals \
  "calibration participant identity columns" \
  "2" \
  "SELECT COUNT(*)
     FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'stock_auto_participant_v4_calibration_snapshot'
      AND column_name IN (
        'active_participant_count',
        'participant_identity_mismatch_count'
      )"

assert_equals \
  "calibration basis unique index" \
  "3" \
  "SELECT COUNT(*)
     FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND table_name = 'stock_auto_participant_v4_calibration_snapshot'
      AND index_name = 'uk_stock_auto_v4_calibration_date'"

printf 'PASS isolated MySQL V4 migration and numeric contract verification completed\n'
