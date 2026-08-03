#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA:?STOCK_MYSQL_REPLAY_BATCH_SCHEMA is required}"
: "${STOCK_BATCH_INTERNAL_TOKEN:?STOCK_BATCH_INTERNAL_TOKEN is required}"

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
REPLAY_BATCH_SCHEMA="${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"
REPLAY_BATCH_PORT="${STOCK_V4_REPLAY_BATCH_PORT:-30491}"
REPLAY_UNDERWRITER_DAILY_SUBMISSION_RATE="${STOCK_V4_REPLAY_UNDERWRITER_DAILY_SUBMISSION_RATE:-0.100000}"
REPLAY_UNDERWRITER_SINGLE_ORDER_RATE="${STOCK_V4_REPLAY_UNDERWRITER_SINGLE_ORDER_RATE:-0.020000}"
REPLAY_UNDERWRITER_DAILY_ORDER_LIMIT="${STOCK_V4_REPLAY_UNDERWRITER_DAILY_ORDER_LIMIT:-20}"
TARGET_ENVIRONMENT="${STOCK_V4_TARGET_ENVIRONMENT:-replay}"
CHECK_ONLY=false
RUN_MODE="manual"
RESUME_SCALED_MARKET=false

for argument in "$@"; do
  case "${argument}" in
    --check-only)
      CHECK_ONLY=true
      ;;
    --eod-transition)
      RUN_MODE="eod-transition"
      ;;
    --checkpoint-trading)
      RUN_MODE="checkpoint-trading"
      ;;
    --liquidity-distribution-trading)
      RUN_MODE="liquidity-distribution-trading"
      ;;
    --role-redistribution-trading)
      RUN_MODE="role-redistribution-trading"
      ;;
    --scaled-market-trading)
      RUN_MODE="scaled-market-trading"
      ;;
    --resume-scaled-market-trading)
      RUN_MODE="scaled-market-trading"
      RESUME_SCALED_MARKET=true
      ;;
    *)
      printf 'FAIL unsupported argument: %s\n' "${argument}" >&2
      exit 1
      ;;
  esac
done

if [[ "${TARGET_ENVIRONMENT}" == "operating" ]]; then
  if [[ "${STOCK_V4_OPERATING_ALLOW_BATCH:-}" != "YES" ]]; then
    printf 'FAIL operating batch target requires STOCK_V4_OPERATING_ALLOW_BATCH=YES\n' >&2
    exit 1
  fi
  if [[ "${REPLAY_SCHEMA}" != "STOCK_SERVICE" \
      || "${REPLAY_BATCH_SCHEMA}" != "STOCK_BATCH_METADATA" ]]; then
    printf 'FAIL operating batch target requires exact STOCK_SERVICE and STOCK_BATCH_METADATA schemas\n' >&2
    exit 1
  fi
elif [[ "${TARGET_ENVIRONMENT}" == "replay" ]]; then
  if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]]; then
    printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
    exit 1
  fi
  if [[ "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
    printf 'FAIL business replay schema cannot be a batch metadata schema\n' >&2
    exit 1
  fi
  if [[ ! "${REPLAY_BATCH_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$ ]]; then
    printf 'FAIL replay batch schema must match STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+\n' >&2
    exit 1
  fi
else
  printf 'FAIL STOCK_V4_TARGET_ENVIRONMENT must be replay or operating\n' >&2
  exit 1
fi
if [[ "${REPLAY_SCHEMA}" == "${REPLAY_BATCH_SCHEMA}" ]]; then
  printf 'FAIL business and batch metadata schemas must be different\n' >&2
  exit 1
fi
if [[ ! "${REPLAY_BATCH_PORT}" =~ ^[0-9]+$ ]] \
    || (( REPLAY_BATCH_PORT < 1024 || REPLAY_BATCH_PORT > 65535 )); then
  printf 'FAIL STOCK_V4_REPLAY_BATCH_PORT must be between 1024 and 65535\n' >&2
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
  "--connect-timeout=10"
  "--ssl-mode=DISABLED"
  "--default-character-set=utf8mb4"
  "--batch"
  "--skip-column-names"
)

mysql_admin() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" "$@"
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local query="$3"
  local actual

  actual="$(mysql_admin --execute="${query}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL %s expected=%s actual=%s\n' \
      "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf 'PASS %s = %s\n' "${label}" "${actual}"
}

assert_equals \
  "${TARGET_ENVIRONMENT} schemas exist" \
  "2" \
  "
  SELECT COUNT(*)
    FROM information_schema.schemata
   WHERE schema_name IN ('${REPLAY_SCHEMA}', '${REPLAY_BATCH_SCHEMA}')
  "
assert_equals \
  "business schema canonical marker count" \
  "1" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = '${REPLAY_SCHEMA}'
     AND table_name = 'stock_market_business_state'
  "
assert_equals \
  "batch metadata table count" \
  "10" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = '${REPLAY_BATCH_SCHEMA}'
  "

if [[ "${TARGET_ENVIRONMENT}" == "replay" ]]; then
  printf 'PASS operating STOCK_SERVICE and STOCK_BATCH_METADATA are outside replay targets\n'
else
  printf 'PASS exact operating schemas are explicitly authorized for this batch run\n'
fi
if [[ "${RUN_MODE}" == "manual" ]]; then
  printf 'PASS all automatic business schedulers, signal polling, and clock mutation will be disabled\n'
elif [[ "${RUN_MODE}" == "eod-transition" ]]; then
  if [[ "${STOCK_V4_REPLAY_ALLOW_EOD_TRANSITION:-}" != "YES" ]]; then
    printf 'FAIL eod-transition requires STOCK_V4_REPLAY_ALLOW_EOD_TRANSITION=YES\n' >&2
    exit 1
  fi
  printf 'PASS EOD transition is explicitly authorized for %s schemas\n' \
    "${TARGET_ENVIRONMENT}"
  printf 'PASS trading, execution, role-order, signal, cash-flow, and clock schedulers remain disabled\n'
  printf 'PASS market data uses replay-fixed so the EOD transition does not move prices\n'
elif [[ "${RUN_MODE}" == "checkpoint-trading" ]]; then
  if [[ "${STOCK_V4_REPLAY_ALLOW_CHECKPOINT_TRADING:-}" != "YES" ]]; then
    printf 'FAIL checkpoint-trading requires STOCK_V4_REPLAY_ALLOW_CHECKPOINT_TRADING=YES\n' >&2
    exit 1
  fi
  printf 'PASS checkpoint trading is explicitly authorized for isolated replay schemas\n'
  printf 'PASS only the simulation clock heartbeat is scheduled; all business jobs remain manual\n'
  printf 'PASS signal, market-data, role-order, cash-flow, and automatic execution remain disabled\n'
elif [[ "${RUN_MODE}" == "liquidity-distribution-trading" ]]; then
  if [[ "${STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION:-}" != "YES" ]]; then
    printf 'FAIL liquidity-distribution-trading requires STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION=YES\n' >&2
    exit 1
  fi
  printf 'PASS liquidity distribution trading is explicitly authorized for isolated replay schemas\n'
  printf 'PASS only the simulation clock heartbeat is scheduled; source, target, and execution jobs remain manual\n'
  printf 'PASS signal, market-data, normal role-order, cash-flow, and automatic execution remain disabled\n'
elif [[ "${RUN_MODE}" == "role-redistribution-trading" ]]; then
  if [[ "${STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION:-}" != "YES" ]]; then
    printf 'FAIL role-redistribution-trading requires STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION=YES\n' >&2
    exit 1
  fi
  if [[ "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_BULK_COMPLETION:-false}" != "true" \
      && "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_BULK_COMPLETION:-false}" != "false" ]]; then
    printf 'FAIL role redistribution bulk completion must be true or false\n' >&2
    exit 1
  fi
  if [[ "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_BULK_COMPLETION:-false}" == "true" \
      && "${STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_BULK_COMPLETION:-}" != "YES" ]]; then
    printf 'FAIL bulk role redistribution requires STOCK_V4_REPLAY_ALLOW_ROLE_REDISTRIBUTION_BULK_COMPLETION=YES\n' >&2
    exit 1
  fi
  printf 'PASS role redistribution is explicitly authorized for isolated replay schemas\n'
  printf 'PASS only the simulation clock heartbeat is scheduled; paired redistribution and execution jobs remain manual\n'
  printf 'PASS normal V4, LP, institution, underwriter, cash-flow, market-data, EOD, and signal jobs remain disabled\n'

  assert_equals \
    "single active role redistribution plan" \
    "1" \
    "
    SELECT COUNT(*)
      FROM ${REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan
     WHERE status = 'ACTIVE'
    "
  assert_equals \
    "role redistribution draft-contract and applied-capacity gate" \
    "DRAFT|APPLIED" \
    "
    SELECT CONCAT(contract.status, '|', role_rebase.status)
      FROM ${REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
      JOIN ${REPLAY_SCHEMA}.stock_scaled_market_contract contract
        ON contract.contract_version = redistribution.contract_version
      JOIN ${REPLAY_SCHEMA}.stock_scaled_market_rebase_plan role_rebase
        ON role_rebase.plan_id = redistribution.role_capacity_plan_id
       AND role_rebase.rebase_stage = 'MARKET_ROLE_CAPACITY'
     WHERE redistribution.status = 'ACTIVE'
    "
  assert_equals \
    "unauthorized affected-account orders after redistribution activation" \
    "0" \
    "
    SELECT COUNT(*)
      FROM ${REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_plan redistribution
      JOIN ${REPLAY_SCHEMA}.stock_order affected_order
        ON affected_order.created_at >= redistribution.activated_at
       AND affected_order.account_id IN (
         SELECT source_lp_account_id
           FROM ${REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_symbol_plan
          WHERE plan_id = redistribution.plan_id
         UNION
         SELECT account_id
           FROM ${REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_recipient_plan
          WHERE plan_id = redistribution.plan_id
       )
     WHERE redistribution.status = 'ACTIVE'
       AND NOT EXISTS (
         SELECT 1
           FROM ${REPLAY_SCHEMA}.stock_scaled_market_role_redistribution_order_link order_link
          WHERE order_link.plan_id = redistribution.plan_id
            AND order_link.order_id = affected_order.id
       )
    "
else
  if [[ "${STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_TRADING:-}" != "YES" ]]; then
    printf 'FAIL scaled-market-trading requires STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_TRADING=YES\n' >&2
    exit 1
  fi
  printf 'PASS scaled-market trading is explicitly authorized for isolated replay schemas\n'
  printf 'PASS V4 participants, LP, institutions, expiry, execution, and clock are enabled\n'
  printf 'PASS market-data, corporate-action, recurring-cash, underwriter, distribution, EOD, and signal jobs remain disabled\n'

  assert_equals \
    "single active scaled-market contract" \
    "1" \
    "
    SELECT COUNT(*)
      FROM ${REPLAY_SCHEMA}.stock_scaled_market_contract
     WHERE status = 'ACTIVE'
    "
  assert_equals \
    "active scaled-market target symbol count" \
    "8" \
    "
    SELECT COUNT(*)
      FROM ${REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
      JOIN ${REPLAY_SCHEMA}.stock_scaled_market_contract contract
        ON contract.contract_version = target.contract_version
       AND contract.status = 'ACTIVE'
     WHERE target.lifecycle_status = 'MATURE'
    "
  assert_equals \
    "V3 live and V4 active policy counts" \
    "0|1" \
    "
    SELECT CONCAT(
             SUM(CASE
                   WHEN behavior_model_version = 'V3'
                    AND (status <> 'RETIRED' OR runtime_enabled = true)
                   THEN 1 ELSE 0
                 END),
             '|',
             SUM(CASE
                   WHEN behavior_model_version = 'V4'
                    AND status = 'ACTIVE'
                    AND runtime_enabled = true
                   THEN 1 ELSE 0
                 END)
           )
      FROM ${REPLAY_SCHEMA}.stock_auto_participant_policy_revision
    "
  if [[ "${RESUME_SCALED_MARKET}" == "true" ]]; then
    if [[ "${STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_RESUME:-}" != "YES" ]]; then
      printf 'FAIL scaled-market resume requires STOCK_V4_REPLAY_ALLOW_SCALED_MARKET_RESUME=YES\n' >&2
      exit 1
    fi
    assert_equals \
      "stopped and business-date-aligned scaled-market clock" \
      "1" \
      "
      SELECT COUNT(*)
        FROM ${REPLAY_SCHEMA}.stock_simulation_clock clock
        CROSS JOIN ${REPLAY_SCHEMA}.stock_market_business_state business
       WHERE clock.clock_id = 'DEFAULT'
         AND clock.running = false
         AND business.active_business_date = business.raw_simulation_date
      "
    assert_equals \
      "valid resumed open-order reservations" \
      "0" \
      "
      SELECT COUNT(*)
        FROM ${REPLAY_SCHEMA}.stock_order
       WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
         AND (
           quantity <= filled_quantity
           OR (side = 'BUY' AND reserved_cash <= 0)
           OR (side = 'SELL' AND reserved_cash <> 0)
         )
      "
    assert_equals \
      "resumed sell-order holding reservation mismatches" \
      "0" \
      "
      SELECT COUNT(*)
        FROM (
          SELECT holding.account_id, holding.symbol
            FROM ${REPLAY_SCHEMA}.stock_holding holding
            LEFT JOIN (
              SELECT account_id, symbol, SUM(quantity - filled_quantity) AS quantity
                FROM ${REPLAY_SCHEMA}.stock_order
               WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
                 AND side = 'SELL'
               GROUP BY account_id, symbol
            ) sell_open
              ON sell_open.account_id = holding.account_id
             AND sell_open.symbol = holding.symbol
           WHERE holding.reserved_quantity <> COALESCE(sell_open.quantity, 0)
          UNION ALL
          SELECT sell_open.account_id, sell_open.symbol
            FROM (
              SELECT account_id, symbol, SUM(quantity - filled_quantity) AS quantity
                FROM ${REPLAY_SCHEMA}.stock_order
               WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
                 AND side = 'SELL'
               GROUP BY account_id, symbol
            ) sell_open
            LEFT JOIN ${REPLAY_SCHEMA}.stock_holding holding
              ON holding.account_id = sell_open.account_id
             AND holding.symbol = sell_open.symbol
           WHERE holding.account_id IS NULL
        ) mismatches
      "
    printf 'PASS interrupted scaled-market day is safe to resume with existing open ledgers\n'
  else
    assert_equals \
      "quiescent scaled-market opening ledgers" \
      "0|0|0" \
      "
      SELECT CONCAT(
               (SELECT COUNT(*)
                  FROM ${REPLAY_SCHEMA}.stock_order
                 WHERE status IN ('PENDING', 'PARTIALLY_FILLED')),
               '|',
               (SELECT COALESCE(SUM(reserved_quantity), 0)
                  FROM ${REPLAY_SCHEMA}.stock_holding),
               '|',
               (SELECT COUNT(*)
                  FROM ${REPLAY_SCHEMA}.stock_auto_participant_order_intent
                 WHERE status = 'ACTIVE')
             )
      "
  fi
fi

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS %s batch %s launch preflight completed without starting a service\n' \
    "${TARGET_ENVIRONMENT}" "${RUN_MODE}"
  exit 0
fi

business_jdbc_url="jdbc:mysql://${STOCK_MYSQL_HOST}:${STOCK_MYSQL_PORT}/${REPLAY_SCHEMA}?zeroDateTimeBehavior=convertToNull&useLegacyDatetimeCode=false&serverTimezone=Asia/Seoul&noAccessToProcedureBodies=true&useSSL=false&allowPublicKeyRetrieval=true&connectTimeout=5000&socketTimeout=60000&tcpKeepAlive=true"
metadata_jdbc_url="jdbc:mysql://${STOCK_MYSQL_HOST}:${STOCK_MYSQL_PORT}/${REPLAY_BATCH_SCHEMA}?zeroDateTimeBehavior=convertToNull&useLegacyDatetimeCode=false&serverTimezone=Asia/Seoul&noAccessToProcedureBodies=true&useSSL=false&allowPublicKeyRetrieval=true&connectTimeout=5000&socketTimeout=60000&tcpKeepAlive=true"

export SPRING_PROFILES_ACTIVE=local-direct
export SERVER_PORT="${REPLAY_BATCH_PORT}"
export SPRING_DATASOURCE_URL="${business_jdbc_url}"
export SPRING_DATASOURCE_USERNAME="${STOCK_MYSQL_USER}"
export SPRING_DATASOURCE_PASSWORD="${STOCK_MYSQL_PASSWORD}"
export STOCK_BATCH_REPOSITORY_DATASOURCE_URL="${metadata_jdbc_url}"
export STOCK_BATCH_REPOSITORY_DATASOURCE_USERNAME="${STOCK_MYSQL_USER}"
export STOCK_BATCH_REPOSITORY_DATASOURCE_PASSWORD="${STOCK_MYSQL_PASSWORD}"
export STOCK_SCHEMA_READINESS_ENABLED=true
export STOCK_BATCH_SCHEMA_READINESS_ENABLED=true
if [[ "${RUN_MODE}" == "checkpoint-trading"
    || "${RUN_MODE}" == "liquidity-distribution-trading"
    || "${RUN_MODE}" == "role-redistribution-trading"
    || "${RUN_MODE}" == "scaled-market-trading" ]]; then
  export STOCK_SIMULATION_CLOCK_SCHEDULER_ENABLED=true
else
  export STOCK_SIMULATION_CLOCK_SCHEDULER_ENABLED=false
fi
export STOCK_BATCH_SIGNAL_ENABLED=false
export STOCK_BATCH_ORDER_BOOK_EXECUTION_ENABLED=false
export STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_ENABLED=false
export STOCK_BATCH_EXECUTION_ACCOUNT_SUMMARY_ENABLED=false
export STOCK_BATCH_AUTO_MARKET_ENABLED=false
export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_SCHEDULER_ENABLED=false
export STOCK_BATCH_AUTO_MARKET_ORDER_EXPIRY_ENABLED=false
export STOCK_BATCH_LIQUIDITY_PROVIDER_MARKET_ENABLED=false
if [[ "${RUN_MODE}" == "liquidity-distribution-trading" ]]; then
  export STOCK_BATCH_SCALED_MARKET_LIQUIDITY_DISTRIBUTION_ENABLED=true
else
  export STOCK_BATCH_SCALED_MARKET_LIQUIDITY_DISTRIBUTION_ENABLED=false
fi
if [[ "${RUN_MODE}" == "role-redistribution-trading" ]]; then
  export STOCK_BATCH_SCALED_MARKET_ROLE_REDISTRIBUTION_ENABLED=true
  export STOCK_BATCH_SCALED_MARKET_ROLE_REDISTRIBUTION_BULK_COMPLETION_ENABLED="${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_BULK_COMPLETION:-false}"
  export STOCK_BATCH_EXECUTION_FEE_RATE=0.0000
  export STOCK_BATCH_EXECUTION_SELL_TAX_RATE=0.0000
else
  export STOCK_BATCH_SCALED_MARKET_ROLE_REDISTRIBUTION_ENABLED=false
  export STOCK_BATCH_SCALED_MARKET_ROLE_REDISTRIBUTION_BULK_COMPLETION_ENABLED=false
fi
export STOCK_BATCH_ISSUE_UNDERWRITER_MARKET_ENABLED=false
export STOCK_BATCH_ISSUE_UNDERWRITER_DAILY_SUBMISSION_RATE="${REPLAY_UNDERWRITER_DAILY_SUBMISSION_RATE}"
export STOCK_BATCH_ISSUE_UNDERWRITER_SINGLE_ORDER_RATE="${REPLAY_UNDERWRITER_SINGLE_ORDER_RATE}"
export STOCK_BATCH_ISSUE_UNDERWRITER_DAILY_ORDER_LIMIT="${REPLAY_UNDERWRITER_DAILY_ORDER_LIMIT}"
export STOCK_BATCH_INSTITUTION_MARKET_ENABLED=false
export STOCK_BATCH_AUTO_PARTICIPANT_CASH_FLOW_ENABLED=false
export STOCK_BATCH_HOLDING_CLEANUP_ENABLED=false
export STOCK_BATCH_METADATA_RETENTION_ENABLED=false
export STOCK_BATCH_EXECUTION_SYMBOL_LOCK_TYPE=none
export STOCK_BATCH_EXECUTION_READY_SYMBOL_QUEUE_TYPE=none
export STOCK_BATCH_AUTO_MARKET_PROFILE_LOCK_TYPE=none
export MANAGEMENT_HEALTH_REDIS_ENABLED=false

if [[ "${RUN_MODE}" == "scaled-market-trading" ]]; then
  export STOCK_BATCH_SCHEDULERS_ENABLED=true
  export STOCK_BATCH_MARKET_DATA_ENABLED=false
  export STOCK_BATCH_CORPORATE_ACTIONS_ENABLED=false
  export STOCK_BATCH_ORDER_BOOK_EXECUTION_ENABLED=true
  export STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_ENABLED=true
  export STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_COUNT="${STOCK_V4_REPLAY_EXECUTION_WORKER_COUNT:-8}"
  export STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_IDLE_DELAY_MS="${STOCK_V4_REPLAY_EXECUTION_WORKER_IDLE_DELAY_MS:-20}"
  export STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_MATCH_YIELD_MS="${STOCK_V4_REPLAY_EXECUTION_WORKER_MATCH_YIELD_MS:-0}"
  export STOCK_BATCH_EXECUTION_SYMBOL_LOCK_TYPE=memory
  export STOCK_BATCH_EXECUTION_SYMBOL_LOCK_MEMORY_WAIT_MS="${STOCK_V4_REPLAY_EXECUTION_SYMBOL_LOCK_WAIT_MS:-100}"
  export STOCK_BATCH_EXECUTION_SCAN_LIMIT="${STOCK_V4_REPLAY_EXECUTION_SCAN_LIMIT:-1000}"
  export STOCK_BATCH_EXECUTION_BUY_CANDIDATE_SCAN_LIMIT="${STOCK_V4_REPLAY_EXECUTION_BUY_CANDIDATE_SCAN_LIMIT:-100}"
  export STOCK_BATCH_EXECUTION_SYMBOL_CHUNK_LIMIT="${STOCK_V4_REPLAY_EXECUTION_SYMBOL_CHUNK_LIMIT:-20}"
  export STOCK_BATCH_EXECUTION_SYMBOL_CHUNK_MAX_DURATION_MS="${STOCK_V4_REPLAY_EXECUTION_SYMBOL_CHUNK_MAX_DURATION_MS:-250}"
  export STOCK_BATCH_EXECUTION_READY_SYMBOL_RECONCILIATION_INTERVAL_MS="${STOCK_V4_REPLAY_EXECUTION_RECONCILIATION_INTERVAL_MS:-1000}"
  export STOCK_BATCH_EXECUTION_ACCOUNT_SUMMARY_ENABLED=true
  export STOCK_BATCH_EXECUTION_READY_SYMBOL_QUEUE_TYPE=memory
  export STOCK_BATCH_AUTO_MARKET_ENABLED=true
  export STOCK_BATCH_AUTO_MARKET_DAILY_REGIME_ENABLED=false
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_SCHEDULER_ENABLED=true
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_RECONCILE_ENABLED=true
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_TYPE=memory
  export STOCK_BATCH_AUTO_MARKET_ORDER_EXPIRY_ENABLED=true
  export STOCK_BATCH_LIQUIDITY_PROVIDER_MARKET_ENABLED=true
  export STOCK_BATCH_SCALED_MARKET_LIQUIDITY_DISTRIBUTION_ENABLED=false
  export STOCK_BATCH_ISSUE_UNDERWRITER_MARKET_ENABLED=false
  export STOCK_BATCH_INSTITUTION_MARKET_ENABLED=true
  export STOCK_BATCH_AUTO_PARTICIPANT_CASH_FLOW_ENABLED=false
  export STOCK_BATCH_HOLDING_CLEANUP_ENABLED=false
  export STOCK_BATCH_MARKET_CLOSE_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_COORDINATOR_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_REPORT_AGGREGATION_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_READINESS_ENABLED=false
  export STOCK_BATCH_SETTLEMENT_ENABLED=false
  printf 'PASS scaled-market execution profile workers=%s idleMs=%s chunk=%s reconcileMs=%s symbolLock=%s\n' \
    "${STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_COUNT}" \
    "${STOCK_BATCH_ORDER_BOOK_EXECUTION_WORKER_IDLE_DELAY_MS}" \
    "${STOCK_BATCH_EXECUTION_SYMBOL_CHUNK_LIMIT}" \
    "${STOCK_BATCH_EXECUTION_READY_SYMBOL_RECONCILIATION_INTERVAL_MS}" \
    "${STOCK_BATCH_EXECUTION_SYMBOL_LOCK_TYPE}"
elif [[ "${RUN_MODE}" == "eod-transition" ]]; then
  export STOCK_BATCH_SCHEDULERS_ENABLED=true
  export STOCK_BATCH_MARKET_DATA_ENABLED=true
  export STOCK_BATCH_MARKET_DATA_PROVIDER=replay-fixed
  export STOCK_BATCH_CORPORATE_ACTIONS_ENABLED=true
  export STOCK_BATCH_AUTO_MARKET_DAILY_REGIME_ENABLED=true
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_RECONCILE_ENABLED=true
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_TYPE=memory
  export STOCK_BATCH_MARKET_CLOSE_ENABLED=true
  export STOCK_BATCH_MARKET_CLOSE_SETTLEMENT_DELAY_SIMULATION_MINUTES=0
  export STOCK_BATCH_MARKET_CLOSE_POLL_FIXED_DELAY_MS=1000
  export STOCK_BATCH_POST_CLOSE_COORDINATOR_ENABLED=true
  export STOCK_BATCH_POST_CLOSE_COORDINATOR_POLL_FIXED_DELAY_MS=1000
  export STOCK_BATCH_POST_CLOSE_REPORT_AGGREGATION_ENABLED=true
  export STOCK_BATCH_POST_CLOSE_POSITION_STATE_ACCOUNT_CHUNK_SIZE="${STOCK_V4_REPLAY_POSITION_STATE_ACCOUNT_CHUNK_SIZE:-100}"
  export STOCK_BATCH_POST_CLOSE_READINESS_ENABLED=true
  export STOCK_BATCH_SETTLEMENT_ENABLED=true
elif [[ "${RUN_MODE}" == "checkpoint-trading"
    || "${RUN_MODE}" == "liquidity-distribution-trading"
    || "${RUN_MODE}" == "role-redistribution-trading" ]]; then
  export STOCK_BATCH_SCHEDULERS_ENABLED=true
  export STOCK_BATCH_MARKET_DATA_ENABLED=false
  export STOCK_BATCH_CORPORATE_ACTIONS_ENABLED=false
  export STOCK_BATCH_AUTO_MARKET_DAILY_REGIME_ENABLED=false
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_RECONCILE_ENABLED=false
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_TYPE=none
  export STOCK_BATCH_MARKET_CLOSE_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_COORDINATOR_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_REPORT_AGGREGATION_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_READINESS_ENABLED=false
  export STOCK_BATCH_SETTLEMENT_ENABLED=false
else
  export STOCK_BATCH_SCHEDULERS_ENABLED=false
  export STOCK_BATCH_MARKET_DATA_ENABLED=false
  export STOCK_BATCH_CORPORATE_ACTIONS_ENABLED=false
  export STOCK_BATCH_AUTO_MARKET_DAILY_REGIME_ENABLED=false
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_RECONCILE_ENABLED=false
  export STOCK_BATCH_AUTO_MARKET_PROFILE_QUEUE_TYPE=none
  export STOCK_BATCH_MARKET_CLOSE_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_COORDINATOR_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_REPORT_AGGREGATION_ENABLED=false
  export STOCK_BATCH_POST_CLOSE_READINESS_ENABLED=false
  export STOCK_BATCH_SETTLEMENT_ENABLED=false
fi

printf 'INFO starting %s %s stock batch on port %s\n' \
  "${TARGET_ENVIRONMENT}" "${RUN_MODE}" "${REPLAY_BATCH_PORT}"
cd "${ROOT_DIR}"
exec ./gradlew :stock-batch-service:bootRun --no-daemon
