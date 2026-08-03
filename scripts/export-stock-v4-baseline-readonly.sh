#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_SOURCE_SCHEMA:?STOCK_MYSQL_SOURCE_SCHEMA is required}"
: "${STOCK_V4_EXPORT_RUN_ID:?STOCK_V4_EXPORT_RUN_ID is required}"

SOURCE_SCHEMA="${STOCK_MYSQL_SOURCE_SCHEMA}"
EXPORT_RUN_ID="${STOCK_V4_EXPORT_RUN_ID}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"
BASELINE_CLOSE_RUN_ID=259
BASELINE_BUSINESS_DATE="2027-02-09"
OUTPUT_ROOT="${ROOT_DIR}/artifacts/stock-v4-baseline"
OUTPUT_DIR="${OUTPUT_ROOT}/${EXPORT_RUN_ID}"
PARTIAL_FILE="${OUTPUT_DIR}/baseline.ndjson.tsv.partial"
OUTPUT_FILE="${OUTPUT_DIR}/baseline.ndjson.tsv"
CHECKSUM_FILE="${OUTPUT_DIR}/SHA256SUMS"

if [[ ! "${SOURCE_SCHEMA}" =~ ^[A-Za-z0-9_]+$ ]]; then
  printf 'FAIL source schema must contain only letters, numbers, and underscore\n' >&2
  exit 1
fi

if [[ ! "${EXPORT_RUN_ID}" =~ ^2027-02-09_[A-Za-z0-9_-]+$ ]]; then
  printf 'FAIL export run id must match 2027-02-09_[A-Za-z0-9_-]+\n' >&2
  exit 1
fi

if [[ -e "${OUTPUT_DIR}" ]]; then
  printf 'FAIL export directory already exists and will not be overwritten: %s\n' \
    "${OUTPUT_DIR}" >&2
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
  "--database=${SOURCE_SCHEMA}"
  "--connect-timeout=10"
  "--default-character-set=utf8mb4"
  "--batch"
  "--raw"
  "--skip-column-names"
)

mysql_source() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" "$@"
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local query="$3"
  local actual

  actual="$(
    mysql_source --execute="
      SET TRANSACTION READ ONLY;
      START TRANSACTION WITH CONSISTENT SNAPSHOT;
      ${query}
      COMMIT;
    " | tail -n 1
  )"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL %s expected=%s actual=%s\n' \
      "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf 'PASS %s = %s\n' "${label}" "${actual}"
}

assert_equals \
  "baseline close run" \
  "259|2027-02-09|COMPLETED|FULL" \
  "
  SELECT CONCAT_WS(
      '|',
      id,
      DATE_FORMAT(business_date, '%Y-%m-%d'),
      status,
      CASE WHEN symbol IS NULL THEN 'FULL' ELSE symbol END
  )
    FROM stock_market_close_run
   WHERE id = ${BASELINE_CLOSE_RUN_ID};
  "

assert_equals \
  "baseline market aggregate" \
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
   WHERE close_run_id = ${BASELINE_CLOSE_RUN_ID};
  "

assert_equals \
  "baseline holding snapshot reconciliation" \
  "0" \
  "
  SELECT COUNT(*)
    FROM stock_order_book_daily_snapshot daily_snapshot
    LEFT JOIN (
        SELECT symbol,
               SUM(quantity) AS holding_quantity
          FROM stock_holding_snapshot
         WHERE close_run_id = ${BASELINE_CLOSE_RUN_ID}
         GROUP BY symbol
    ) holding_snapshot
      ON holding_snapshot.symbol = daily_snapshot.symbol
   WHERE daily_snapshot.close_run_id = ${BASELINE_CLOSE_RUN_ID}
     AND COALESCE(holding_snapshot.holding_quantity, 0)
         <> daily_snapshot.issued_shares;
  "

assert_equals \
  "baseline account reconciliation" \
  "0" \
  "
  SELECT COUNT(*)
    FROM stock_close_account_snapshot
   WHERE close_run_id = ${BASELINE_CLOSE_RUN_ID}
     AND reconciliation_status <> 'MATCHED';
  "

assert_equals \
  "baseline cash-flow ledger boundary" \
  "4649|4649|288537382484.00|288537382484.00" \
  "
  SELECT CONCAT_WS(
      '|',
      MAX(account_snapshot.cash_flow_watermark_id),
      (
        SELECT COUNT(*)
          FROM stock_account_cash_flow cash_flow
         WHERE cash_flow.id <= (
             SELECT MAX(cash_flow_watermark_id)
               FROM stock_close_account_snapshot
              WHERE close_run_id = ${BASELINE_CLOSE_RUN_ID}
         )
      ),
      (
        SELECT CAST(
            SUM(
                CASE cash_flow.flow_type
                    WHEN 'DEPOSIT' THEN cash_flow.amount
                    ELSE -cash_flow.amount
                END
            )
            AS DECIMAL(24,2)
        )
          FROM stock_account_cash_flow cash_flow
         WHERE cash_flow.id <= (
             SELECT MAX(cash_flow_watermark_id)
               FROM stock_close_account_snapshot
              WHERE close_run_id = ${BASELINE_CLOSE_RUN_ID}
         )
      ),
      CAST(SUM(account_snapshot.post_cancel_cash) AS DECIMAL(24,2))
  )
    FROM stock_close_account_snapshot account_snapshot
   WHERE account_snapshot.close_run_id = ${BASELINE_CLOSE_RUN_ID};
  "

assert_equals \
  "baseline operational ledger counts" \
  "8|72|25|37183802|7|7|14|8|41|719" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_corporate_action corporate_action
         WHERE corporate_action.created_at <= (
             SELECT completed_at
               FROM stock_market_close_run
              WHERE id = ${BASELINE_CLOSE_RUN_ID}
         )
      ),
      (
        SELECT COUNT(*)
          FROM stock_corporate_action_entitlement entitlement
         WHERE entitlement.created_at <= (
             SELECT completed_at
               FROM stock_market_close_run
              WHERE id = ${BASELINE_CLOSE_RUN_ID}
         )
      ),
      (
        SELECT COUNT(*)
          FROM stock_security_allocation_ledger allocation
         WHERE allocation.effective_business_date
             <= DATE '${BASELINE_BUSINESS_DATE}'
      ),
      (
        SELECT SUM(allocation.quantity)
          FROM stock_security_allocation_ledger allocation
         WHERE allocation.effective_business_date
             <= DATE '${BASELINE_BUSINESS_DATE}'
      ),
      (SELECT COUNT(*) FROM stock_auto_market_config),
      (
        SELECT COUNT(*)
          FROM stock_liquidity_transition transition_state
         WHERE transition_state.effective_business_date
             <= DATE '${BASELINE_BUSINESS_DATE}'
      ),
      (
        SELECT COUNT(*)
          FROM stock_market_reference_volume_snapshot reference_volume
         WHERE reference_volume.simulation_trade_date
             <= DATE '${BASELINE_BUSINESS_DATE}'
      ),
      (
        SELECT COUNT(*)
          FROM stock_underwriting_daily_supply_state supply_state
         WHERE supply_state.simulation_trade_date
             <= DATE '${BASELINE_BUSINESS_DATE}'
      ),
      (
        SELECT COUNT(*)
          FROM stock_liquidity_daily_state liquidity_state
         WHERE liquidity_state.simulation_trade_date
             <= DATE '${BASELINE_BUSINESS_DATE}'
      ),
      (
        SELECT COUNT(*)
          FROM stock_order_strategy_origin strategy_origin
          JOIN stock_order strategy_order
            ON strategy_order.id = strategy_origin.order_id
         WHERE strategy_order.created_at
             >= TIMESTAMP '${BASELINE_BUSINESS_DATE} 00:00:00'
           AND strategy_order.created_at
             < TIMESTAMP '2027-02-10 00:00:00'
      )
  );
  "

assert_equals \
  "baseline operational reference coverage" \
  "0|0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (
        SELECT COUNT(*)
          FROM stock_account_cash_flow cash_flow
          LEFT JOIN stock_close_account_snapshot account_snapshot
            ON account_snapshot.close_run_id =
               ${BASELINE_CLOSE_RUN_ID}
           AND account_snapshot.account_id = cash_flow.account_id
         WHERE cash_flow.id <= (
             SELECT MAX(cash_flow_watermark_id)
               FROM stock_close_account_snapshot
              WHERE close_run_id = ${BASELINE_CLOSE_RUN_ID}
         )
           AND account_snapshot.account_id IS NULL
      ),
      (
        SELECT COUNT(*)
          FROM stock_security_allocation_ledger allocation
          LEFT JOIN stock_close_account_snapshot destination
            ON destination.close_run_id = ${BASELINE_CLOSE_RUN_ID}
           AND destination.account_id = allocation.destination_account_id
          LEFT JOIN stock_close_account_snapshot source
            ON source.close_run_id = ${BASELINE_CLOSE_RUN_ID}
           AND source.account_id = allocation.source_account_id
         WHERE allocation.effective_business_date
             <= DATE '${BASELINE_BUSINESS_DATE}'
           AND (
               destination.account_id IS NULL
               OR (
                   allocation.source_account_id IS NOT NULL
                   AND source.account_id IS NULL
               )
           )
      ),
      (
        SELECT COUNT(*)
          FROM stock_order_strategy_origin strategy_origin
          JOIN stock_order strategy_order
            ON strategy_order.id = strategy_origin.order_id
          LEFT JOIN stock_market_participant participant
            ON participant.id = strategy_origin.participant_id
         WHERE strategy_order.created_at
             >= TIMESTAMP '${BASELINE_BUSINESS_DATE} 00:00:00'
           AND strategy_order.created_at
             < TIMESTAMP '2027-02-10 00:00:00'
           AND participant.id IS NULL
      )
  );
  "

mkdir -p "${OUTPUT_DIR}"

mysql_source >"${PARTIAL_FILE}" <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION READ ONLY;
START TRANSACTION WITH CONSISTENT SNAPSHOT;

SELECT
    'META',
    'BASELINE',
    JSON_OBJECT(
        'artifactVersion', 6,
        'sourceSchema', DATABASE(),
        'serverVersion', VERSION(),
        'baselineCloseRunId', 259,
        'baselineBusinessDate', '2027-02-09',
        'exportedAt', DATE_FORMAT(NOW(), '%Y-%m-%dT%H:%i:%s'),
        'holdingReplayRule',
        'Use snapshot quantity and averagePrice; reset reservedQuantity to zero after completed close cancellation',
        'cashReplayRule',
        'Use close-account postCancelCash and cash-flow rows only through the close snapshot watermark',
        'operationalReplayRule',
        'Preserve role ledgers, daily capacity states, and order origins; rebuild V4 schedules and V4 behavior state'
    );

SELECT
    'CLOSE_RUN',
    CAST(close_run.id AS CHAR),
    JSON_OBJECT(
        'id', close_run.id,
        'businessDate', DATE_FORMAT(close_run.business_date, '%Y-%m-%d'),
        'scope', CASE
            WHEN close_run.symbol IS NULL THEN 'FULL'
            ELSE close_run.symbol
        END,
        'status', close_run.status,
        'cancelledOrderCount', close_run.cancelled_order_count,
        'holdingSnapshotCount', close_run.holding_snapshot_count,
        'priceRolloverCount', close_run.price_rollover_count,
        'completedAt', DATE_FORMAT(
            close_run.completed_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_market_close_run close_run
 WHERE close_run.id = 259;

SELECT
    'POST_CLOSE_CYCLE',
    CAST(cycle.id AS CHAR),
    JSON_OBJECT(
        'id', cycle.id,
        'businessDate', DATE_FORMAT(cycle.business_date, '%Y-%m-%d'),
        'scopeType', cycle.scope_type,
        'scopeKey', cycle.scope_key,
        'cycleKind', cycle.cycle_kind,
        'phase', cycle.phase,
        'status', cycle.status,
        'phaseRevision', cycle.phase_revision,
        'version', cycle.version,
        'closeRunId', cycle.close_run_id,
        'attemptCount', cycle.attempt_count,
        'completedAt', DATE_FORMAT(cycle.completed_at, '%Y-%m-%dT%H:%i:%s')
    )
  FROM stock_post_close_cycle cycle
 WHERE cycle.close_run_id = 259
 ORDER BY cycle.id;

SELECT
    'DAILY_SYMBOL',
    daily_snapshot.symbol,
    JSON_OBJECT(
        'symbol', daily_snapshot.symbol,
        'name', daily_snapshot.name,
        'market', daily_snapshot.market,
        'enabled', daily_snapshot.enabled + 0,
        'marketEnabled', daily_snapshot.market_enabled + 0,
        'marketStatus', daily_snapshot.market_status,
        'issuedShares', daily_snapshot.issued_shares,
        'tradableShares', daily_snapshot.tradable_shares,
        'initialPrice', daily_snapshot.initial_price,
        'tickSize', daily_snapshot.tick_size,
        'priceLimitRate', daily_snapshot.price_limit_rate,
        'closePrice', daily_snapshot.close_price,
        'previousClose', daily_snapshot.previous_close,
        'changeRate', daily_snapshot.change_rate,
        'priceTime', DATE_FORMAT(
            daily_snapshot.price_time,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'priceProvider', daily_snapshot.price_provider,
        'executionCount', daily_snapshot.execution_count,
        'executionQuantity', daily_snapshot.execution_quantity,
        'openPrice', daily_snapshot.open_price,
        'highPrice', daily_snapshot.high_price,
        'lowPrice', daily_snapshot.low_price,
        'lastExecutionPrice',
            daily_snapshot.last_execution_price,
        'buyQuantity', daily_snapshot.buy_quantity,
        'sellQuantity', daily_snapshot.sell_quantity,
        'buyNetAmount', daily_snapshot.buy_net_amount,
        'sellNetAmount', daily_snapshot.sell_net_amount,
        'turnoverAmount', daily_snapshot.turnover_amount,
        'holderCount', daily_snapshot.holder_count,
        'holdingQuantity', daily_snapshot.holding_quantity,
        'openOrderCount', daily_snapshot.open_order_count,
        'openBuyOrderCount',
            daily_snapshot.open_buy_order_count,
        'openSellOrderCount',
            daily_snapshot.open_sell_order_count,
        'reservedBuyCash', daily_snapshot.reserved_buy_cash,
        'pendingCorporateActionCount',
            daily_snapshot.pending_corporate_action_count,
        'firstExecutedAt', DATE_FORMAT(
            daily_snapshot.first_executed_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'lastExecutedAt', DATE_FORMAT(
            daily_snapshot.last_executed_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'snapshotAt', DATE_FORMAT(
            daily_snapshot.snapshot_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_order_book_daily_snapshot daily_snapshot
 WHERE daily_snapshot.close_run_id = 259
 ORDER BY daily_snapshot.symbol;

SELECT
    'ACCOUNT_SNAPSHOT',
    CAST(account_snapshot.account_id AS CHAR),
    JSON_OBJECT(
        'accountId', account_snapshot.account_id,
        'accountStatus', account_snapshot.account_status,
        'participantCategory', account_snapshot.participant_category,
        'participantProfileType',
            account_snapshot.participant_profile_type,
        'settlementTarget', account_snapshot.settlement_target + 0,
        'preCancelCash', account_snapshot.pre_cancel_cash,
        'preCancelOrderReservedCash',
            account_snapshot.pre_cancel_order_reserved_cash,
        'subscriptionReservedCash',
            account_snapshot.subscription_reserved_cash,
        'postCancelCash', account_snapshot.post_cancel_cash,
        'externalNetCashFlow', account_snapshot.external_net_cash_flow,
        'cashFlowWatermarkId',
            account_snapshot.cash_flow_watermark_id,
        'holdingMarketValue', account_snapshot.holding_market_value,
        'holdingQuantity', account_snapshot.holding_quantity,
        'reservedSellQuantity',
            account_snapshot.reserved_sell_quantity,
        'holdingPositionCount',
            account_snapshot.holding_position_count,
        'reconciliationStatus',
            account_snapshot.reconciliation_status,
        'snapshotAt', DATE_FORMAT(
            account_snapshot.snapshot_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_close_account_snapshot account_snapshot
 WHERE account_snapshot.close_run_id = 259
 ORDER BY account_snapshot.account_id;

SELECT
    'HOLDING_SNAPSHOT',
    CONCAT(
        LPAD(CAST(holding_snapshot.account_id AS CHAR), 20, '0'),
        ':',
        holding_snapshot.symbol
    ),
    JSON_OBJECT(
        'accountId', holding_snapshot.account_id,
        'symbol', holding_snapshot.symbol,
        'quantity', holding_snapshot.quantity,
        'snapshotReservedQuantity',
            holding_snapshot.reserved_quantity,
        'replayReservedQuantity', 0,
        'averagePrice', holding_snapshot.average_price,
        'evaluationPrice', holding_snapshot.evaluation_price,
        'snapshotAt', DATE_FORMAT(
            holding_snapshot.snapshot_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_holding_snapshot holding_snapshot
 WHERE holding_snapshot.close_run_id = 259
 ORDER BY holding_snapshot.account_id, holding_snapshot.symbol;

SELECT
    'AUTO_PARTICIPANT',
    CAST(account.id AS CHAR),
    JSON_OBJECT(
        'accountId', account.id,
        'replayUserKey', CONCAT('REPLAY_AUTO_', account.id),
        'enabled', participant.enabled + 0,
        'profileType', participant.profile_type,
        'behaviorSeed', participant.behavior_seed,
        'recurringCashAmount', participant.recurring_cash_amount,
        'recurringCashIntervalValue',
            participant.recurring_cash_interval_value,
        'recurringCashIntervalUnit',
            participant.recurring_cash_interval_unit,
        'withdrawnAt', DATE_FORMAT(
            participant.withdrawn_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_close_account_snapshot account_snapshot
  JOIN stock_account account
    ON account.id = account_snapshot.account_id
  JOIN stock_auto_participant participant
    ON participant.user_key = account.user_key
 WHERE account_snapshot.close_run_id = 259
   AND account_snapshot.participant_category = 'AUTO_PARTICIPANT'
 ORDER BY account.id;

SELECT
    'PROFILE_CONFIG',
    profile.profile_type,
    JSON_OBJECT(
        'profileType', profile.profile_type,
        'sourceBehaviorModelVersion',
            profile.behavior_model_version,
        'newsWeight', profile.news_weight,
        'momentumWeight', profile.momentum_weight,
        'contrarianWeight', profile.contrarian_weight,
        'lossAversionWeight', profile.loss_aversion_weight,
        'herdingWeight', profile.herding_weight,
        'marketMakingWeight', profile.market_making_weight,
        'overconfidenceWeight', profile.overconfidence_weight,
        'noiseWeight', profile.noise_weight,
        'panicSellWeight', profile.panic_sell_weight,
        'dipBuyWeight', profile.dip_buy_weight,
        'orderMultiplier', profile.order_multiplier,
        'decisionFrequencyMultiplier',
            profile.decision_frequency_multiplier,
        'ordersPerDecisionMultiplier',
            profile.orders_per_decision_multiplier,
        'aggressionMultiplier', profile.aggression_multiplier,
        'pricePressureSensitivity',
            profile.price_pressure_sensitivity,
        'orderTtlMultiplier', profile.order_ttl_multiplier,
        'quantityMultiplier', profile.quantity_multiplier,
        'holdingPatienceWeight',
            profile.holding_patience_weight,
        'deepLossHoldWeight', profile.deep_loss_hold_weight,
        'profitTakingWeight', profile.profit_taking_weight,
        'pricingMode', profile.pricing_mode,
        'exitMode', profile.exit_mode,
        'inventoryMode', profile.inventory_mode,
        'recurringDepositAmount',
            profile.recurring_deposit_amount,
        'recurringDepositIntervalDays',
            profile.recurring_deposit_interval_days,
        'recurringDepositIntervalValue',
            profile.recurring_deposit_interval_value,
        'recurringDepositIntervalUnit',
            profile.recurring_deposit_interval_unit,
        'sourceUpdatedAt', DATE_FORMAT(
            profile.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_auto_participant_profile_config profile
 ORDER BY profile.profile_type;

SELECT
    'MARKET_PARTICIPANT',
    CAST(participant.id AS CHAR),
    JSON_OBJECT(
        'id', participant.id,
        'replayParticipantCode',
            CONCAT('REPLAY_ROLE_', participant.id),
        'participantType', participant.participant_type,
        'status', participant.status,
        'replaySelfTradeGroupId',
            CONCAT('REPLAY_ROLE_GROUP_', participant.id),
        'sourceUpdatedAt', DATE_FORMAT(
            participant.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_market_participant participant
 WHERE EXISTS (
     SELECT 1
       FROM stock_market_participant_account participant_account
       JOIN stock_close_account_snapshot account_snapshot
         ON account_snapshot.account_id =
            participant_account.account_id
        AND account_snapshot.close_run_id = 259
      WHERE participant_account.participant_id = participant.id
 )
 ORDER BY participant.id;

SELECT
    'PARTICIPANT_ACCOUNT',
    CAST(participant_account.id AS CHAR),
    JSON_OBJECT(
        'id', participant_account.id,
        'participantId', participant_account.participant_id,
        'accountId', participant_account.account_id,
        'accountRole', participant_account.account_role,
        'deskCode', participant_account.desk_code,
        'effectiveFrom', DATE_FORMAT(
            participant_account.effective_from,
            '%Y-%m-%d'
        ),
        'effectiveTo', DATE_FORMAT(
            participant_account.effective_to,
            '%Y-%m-%d'
        ),
        'status', participant_account.status,
        'sourceUpdatedAt', DATE_FORMAT(
            participant_account.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_market_participant_account participant_account
  JOIN stock_close_account_snapshot account_snapshot
    ON account_snapshot.account_id = participant_account.account_id
   AND account_snapshot.close_run_id = 259
 ORDER BY participant_account.id;

SELECT
    'UNDERWRITING_CONTRACT',
    CAST(underwriting.id AS CHAR),
    JSON_OBJECT(
        'id', underwriting.id,
        'contractCode', underwriting.contract_code,
        'corporateActionId', underwriting.corporate_action_id,
        'symbol', underwriting.symbol,
        'participantId', underwriting.participant_id,
        'accountId', underwriting.account_id,
        'totalIssueQuantity', underwriting.total_issue_quantity,
        'tradableAllocationQuantity',
            underwriting.tradable_allocation_quantity,
        'lockedAllocationQuantity',
            underwriting.locked_allocation_quantity,
        'externalAllocationQuantity',
            underwriting.external_allocation_quantity,
        'underwrittenQuantity', underwriting.underwritten_quantity,
        'issuePrice', underwriting.issue_price,
        'underwritingType', underwriting.underwriting_type,
        'stabilizationStartDate', DATE_FORMAT(
            underwriting.stabilization_start_date,
            '%Y-%m-%d'
        ),
        'stabilizationEndDate', DATE_FORMAT(
            underwriting.stabilization_end_date,
            '%Y-%m-%d'
        ),
        'stabilizationQuantityLimit',
            underwriting.stabilization_quantity_limit,
        'stabilizationAmountLimit',
            underwriting.stabilization_amount_limit,
        'status', underwriting.status,
        'policyVersion', underwriting.policy_version,
        'sourceUpdatedAt', DATE_FORMAT(
            underwriting.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_underwriting_contract underwriting
 WHERE underwriting.symbol BETWEEN 'DEMO001' AND 'DEMO007'
 ORDER BY underwriting.symbol, underwriting.id;

SELECT
    'LIQUIDITY_MANDATE',
    CAST(mandate.id AS CHAR),
    JSON_OBJECT(
        'id', mandate.id,
        'participantId', mandate.participant_id,
        'accountId', mandate.account_id,
        'symbol', mandate.symbol,
        'mandateCode', mandate.mandate_code,
        'executionMode', mandate.execution_mode,
        'status', mandate.status,
        'contractStartDate', DATE_FORMAT(
            mandate.contract_start_date,
            '%Y-%m-%d'
        ),
        'contractEndDate', DATE_FORMAT(
            mandate.contract_end_date,
            '%Y-%m-%d'
        ),
        'targetSpreadTicks', mandate.target_spread_ticks,
        'maxSpreadTicks', mandate.max_spread_ticks,
        'referenceDailyVolume', mandate.reference_daily_volume,
        'maxOrderQuantity', mandate.max_order_quantity,
        'targetOpenParticipationRate',
            mandate.target_open_participation_rate,
        'maxOpenParticipationRate',
            mandate.max_open_participation_rate,
        'maxSingleOrderParticipationRate',
            mandate.max_single_order_participation_rate,
        'externalDepthLevels', mandate.external_depth_levels,
        'maxExternalDepthParticipationRate',
            mandate.max_external_depth_participation_rate,
        'dailyExecutionParticipationRate',
            mandate.daily_execution_participation_rate,
        'dailySubmissionMultiplier',
            mandate.daily_submission_multiplier,
        'targetInventoryQuantity',
            mandate.target_inventory_quantity,
        'inventoryBandQuantity', mandate.inventory_band_quantity,
        'inventorySkewTicks', mandate.inventory_skew_ticks,
        'primaryRegimeWeight', mandate.primary_regime_weight,
        'liquiditySizeSensitivity',
            mandate.liquidity_size_sensitivity,
        'volatilitySpreadMaxTicks',
            mandate.volatility_spread_max_ticks,
        'priceRegimeMaxSkewTicks',
            mandate.price_regime_max_skew_ticks,
        'passiveOnly', mandate.passive_only + 0,
        'minimumQuoteLifetimeSeconds',
            mandate.minimum_quote_lifetime_seconds,
        'repriceThresholdTicks',
            mandate.reprice_threshold_ticks,
        'orderTtlSeconds', mandate.order_ttl_seconds,
        'quoteIntervalSeconds', mandate.quote_interval_seconds,
        'dailyLossLimitAmount', mandate.daily_loss_limit_amount,
        'nextQuoteAt', DATE_FORMAT(
            mandate.next_quote_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'policyVersion', mandate.policy_version,
        'sourceUpdatedAt', DATE_FORMAT(
            mandate.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_liquidity_mandate mandate
 WHERE mandate.symbol BETWEEN 'DEMO001' AND 'DEMO007'
 ORDER BY mandate.symbol, mandate.id;

SELECT
    'INSTITUTION_PORTFOLIO',
    CAST(portfolio.id AS CHAR),
    JSON_OBJECT(
        'id', portfolio.id,
        'participantId', portfolio.participant_id,
        'accountId', portfolio.account_id,
        'portfolioCode', portfolio.portfolio_code,
        'replayDisplayName',
            CONCAT('Replay Institution ', portfolio.id),
        'investmentStyle', portfolio.investment_style,
        'executionMode', portfolio.execution_mode,
        'status', portfolio.status,
        'baseStockAllocationRate',
            portfolio.base_stock_allocation_rate,
        'minStockAllocationRate',
            portfolio.min_stock_allocation_rate,
        'maxStockAllocationRate',
            portfolio.max_stock_allocation_rate,
        'primaryRegimeWeight',
            portfolio.primary_regime_weight,
        'assetPreferenceSensitivity',
            portfolio.asset_preference_sensitivity,
        'volatilitySensitivity',
            portfolio.volatility_sensitivity,
        'entryThresholdRate', portfolio.entry_threshold_rate,
        'exitThresholdRate', portfolio.exit_threshold_rate,
        'dailyTurnoverLimitRate',
            portfolio.daily_turnover_limit_rate,
        'maxDecisionTurnoverRate',
            portfolio.max_decision_turnover_rate,
        'decisionIntervalMinutes',
            portfolio.decision_interval_minutes,
        'buildHorizonDays', portfolio.build_horizon_days,
        'buildParticipationRate',
            portfolio.build_participation_rate,
        'nextDecisionAt', DATE_FORMAT(
            portfolio.next_decision_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'policyVersion', portfolio.policy_version,
        'sourceUpdatedAt', DATE_FORMAT(
            portfolio.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_institution_portfolio portfolio
 WHERE portfolio.execution_mode = 'LIVE'
 ORDER BY portfolio.portfolio_code, portfolio.id;

SELECT
    'INSTITUTION_MANDATE',
    CAST(mandate.id AS CHAR),
    JSON_OBJECT(
        'id', mandate.id,
        'portfolioId', mandate.portfolio_id,
        'symbol', mandate.symbol,
        'baseSymbolWeight', mandate.base_symbol_weight,
        'minPortfolioAllocationRate',
            mandate.min_portfolio_allocation_rate,
        'maxPortfolioAllocationRate',
            mandate.max_portfolio_allocation_rate,
        'pricePressureSensitivity',
            mandate.price_pressure_sensitivity,
        'momentumSensitivity', mandate.momentum_sensitivity,
        'valueSensitivity', mandate.value_sensitivity,
        'reportSensitivity', mandate.report_sensitivity,
        'referenceDailyVolume', mandate.reference_daily_volume,
        'dailyParticipationRate',
            mandate.daily_participation_rate,
        'enabled', mandate.enabled + 0,
        'sourceUpdatedAt', DATE_FORMAT(
            mandate.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_institution_symbol_mandate mandate
  JOIN stock_institution_portfolio portfolio
    ON portfolio.id = mandate.portfolio_id
 WHERE portfolio.execution_mode = 'LIVE'
 ORDER BY mandate.portfolio_id, mandate.symbol, mandate.id;

SELECT
    'MARKET_POLICY',
    CAST(policy.id AS CHAR),
    JSON_OBJECT(
        'id', policy.id,
        'policyScope', policy.policy_scope,
        'scopeKey', policy.scope_key,
        'versionNo', policy.version_no,
        'effectiveBusinessDate', DATE_FORMAT(
            policy.effective_business_date,
            '%Y-%m-%d'
        ),
        'status', policy.status,
        'configJson', JSON_REMOVE(
            policy.config_json,
            '$.displayName'
        ),
        'changeReason', policy.change_reason,
        'sourceUpdatedAt', DATE_FORMAT(
            policy.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_market_policy_version policy
 WHERE policy.policy_scope IN (
     'LIQUIDITY_MANDATE',
     'INSTITUTIONAL_PORTFOLIO',
     'UNDERWRITING_CONTRACT'
 )
 ORDER BY policy.id;

SELECT
    'AUTO_POLICY',
    CAST(policy.policy_version AS CHAR),
    JSON_OBJECT(
        'policyVersion', policy.policy_version,
        'sourceBehaviorModelVersion', 'V3',
        'status', policy.status,
        'effectiveTradeDate', DATE_FORMAT(
            policy.effective_trade_date,
            '%Y-%m-%d'
        ),
        'runtimeEnabled', policy.runtime_enabled + 0,
        'runtimeChangeReason', policy.runtime_change_reason,
        'runtimeChangedAt', DATE_FORMAT(
            policy.runtime_changed_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'policyJson', CAST(policy.policy_json AS JSON),
        'createdAt', DATE_FORMAT(
            policy.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'activatedAt', DATE_FORMAT(
            policy.activated_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'retiredAt', DATE_FORMAT(
            policy.retired_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_auto_participant_policy_revision policy
 ORDER BY policy.policy_version;

SELECT
    'ACCOUNT_CASH_FLOW',
    CAST(cash_flow.id AS CHAR),
    JSON_OBJECT(
        'id', cash_flow.id,
        'accountId', cash_flow.account_id,
        'flowType', cash_flow.flow_type,
        'amount', cash_flow.amount,
        'reason', cash_flow.reason,
        'replayCreatedBy', 'REPLAY_BASELINE',
        'corporateActionId', cash_flow.corporate_action_id,
        'corporateActionEntitlementId',
            cash_flow.corporate_action_entitlement_id,
        'effectiveBusinessDate', DATE_FORMAT(
            cash_flow.effective_business_date,
            '%Y-%m-%d'
        ),
        'createdAt', DATE_FORMAT(
            cash_flow.created_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_account_cash_flow cash_flow
 WHERE cash_flow.id <= (
     SELECT MAX(cash_flow_watermark_id)
       FROM stock_close_account_snapshot
      WHERE close_run_id = 259
 )
 ORDER BY cash_flow.id;

SELECT
    'CORPORATE_ACTION',
    CAST(corporate_action.id AS CHAR),
    JSON_OBJECT(
        'id', corporate_action.id,
        'symbol', corporate_action.symbol,
        'actionType', corporate_action.action_type,
        'shareQuantity', corporate_action.share_quantity,
        'issuePrice', corporate_action.issue_price,
        'dividendAmount', corporate_action.dividend_amount,
        'status', corporate_action.status,
        'basePrice', corporate_action.base_price,
        'theoreticalExRightsPrice',
            corporate_action.theoretical_ex_rights_price,
        'exRightsDate', DATE_FORMAT(
            corporate_action.ex_rights_date,
            '%Y-%m-%d'
        ),
        'recordDate', DATE_FORMAT(
            corporate_action.record_date,
            '%Y-%m-%d'
        ),
        'entitlementCloseCycleId',
            corporate_action.entitlement_close_cycle_id,
        'entitlementCloseRunId',
            corporate_action.entitlement_close_run_id,
        'paymentDate', DATE_FORMAT(
            corporate_action.payment_date,
            '%Y-%m-%d'
        ),
        'listingDate', DATE_FORMAT(
            corporate_action.listing_date,
            '%Y-%m-%d'
        ),
        'delistingDate', DATE_FORMAT(
            corporate_action.delisting_date,
            '%Y-%m-%d'
        ),
        'offeringType', corporate_action.offering_type,
        'subscriptionStartDate', DATE_FORMAT(
            corporate_action.subscription_start_date,
            '%Y-%m-%d'
        ),
        'subscriptionEndDate', DATE_FORMAT(
            corporate_action.subscription_end_date,
            '%Y-%m-%d'
        ),
        'delistingTreatment',
            corporate_action.delisting_treatment,
        'appliedAt', DATE_FORMAT(
            corporate_action.applied_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'paidAt', DATE_FORMAT(
            corporate_action.paid_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'listedAt', DATE_FORMAT(
            corporate_action.listed_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'splitFrom', corporate_action.split_from,
        'splitTo', corporate_action.split_to,
        'replayDescription',
            CONCAT('Replay baseline ', corporate_action.action_type),
        'createdAt', DATE_FORMAT(
            corporate_action.created_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_corporate_action corporate_action
 WHERE corporate_action.created_at <= (
     SELECT completed_at
       FROM stock_market_close_run
      WHERE id = 259
 )
 ORDER BY corporate_action.id;

SELECT
    'CORPORATE_ACTION_ENTITLEMENT',
    CAST(entitlement.id AS CHAR),
    JSON_OBJECT(
        'id', entitlement.id,
        'actionId', entitlement.action_id,
        'accountId', entitlement.account_id,
        'symbol', entitlement.symbol,
        'quantity', entitlement.quantity,
        'shareQuantity', entitlement.share_quantity,
        'cashAmount', entitlement.cash_amount,
        'subscribedShareQuantity',
            entitlement.subscribed_share_quantity,
        'subscribedCashAmount',
            entitlement.subscribed_cash_amount,
        'forfeitedShareQuantity',
            entitlement.forfeited_share_quantity,
        'status', entitlement.status,
        'holdingSnapshotRunId',
            entitlement.holding_snapshot_run_id,
        'createdAt', DATE_FORMAT(
            entitlement.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'subscribedAt', DATE_FORMAT(
            entitlement.subscribed_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'paidAt', DATE_FORMAT(
            entitlement.paid_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_corporate_action_entitlement entitlement
 WHERE entitlement.created_at <= (
     SELECT completed_at
       FROM stock_market_close_run
      WHERE id = 259
 )
 ORDER BY entitlement.id;

SELECT
    'AUTO_MARKET_CONFIG',
    auto_config.symbol,
    JSON_OBJECT(
        'symbol', auto_config.symbol,
        'enabled', auto_config.enabled + 0,
        'primaryRegimeCount1Weight',
            auto_config.primary_regime_count_1_weight,
        'primaryRegimeCount2Weight',
            auto_config.primary_regime_count_2_weight,
        'primaryRegimeCount3Weight',
            auto_config.primary_regime_count_3_weight,
        'primaryRegimeCount4Weight',
            auto_config.primary_regime_count_4_weight,
        'primaryPricePressureBias',
            auto_config.primary_price_pressure_bias,
        'primaryAssetPreferencePressureBias',
            auto_config.primary_asset_preference_pressure_bias,
        'primaryVolatilityPressureBias',
            auto_config.primary_volatility_pressure_bias,
        'primaryLiquidityPressureBias',
            auto_config.primary_liquidity_pressure_bias,
        'primaryExecutionAggressionPressureBias',
            auto_config.primary_execution_aggression_pressure_bias,
        'secondaryPricePressureBias',
            auto_config.secondary_price_pressure_bias,
        'secondaryAssetPreferencePressureBias',
            auto_config.secondary_asset_preference_pressure_bias,
        'secondaryVolatilityPressureBias',
            auto_config.secondary_volatility_pressure_bias,
        'secondaryLiquidityPressureBias',
            auto_config.secondary_liquidity_pressure_bias,
        'secondaryExecutionAggressionPressureBias',
            auto_config.secondary_execution_aggression_pressure_bias,
        'maxOrderQuantity', auto_config.max_order_quantity,
        'orderTtlSeconds', auto_config.order_ttl_seconds,
        'sourceUpdatedAt', DATE_FORMAT(
            auto_config.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_auto_market_config auto_config
 ORDER BY auto_config.symbol;

SELECT
    'LIQUIDITY_TRANSITION',
    CAST(transition_state.id AS CHAR),
    JSON_OBJECT(
        'id', transition_state.id,
        'transitionKey', transition_state.transition_key,
        'symbol', transition_state.symbol,
        'mandateId', transition_state.mandate_id,
        'participantId', transition_state.participant_id,
        'liquidityAccountId',
            transition_state.liquidity_account_id,
        'sourceAccountId', transition_state.source_account_id,
        'legacyAccountId', transition_state.legacy_account_id,
        'stage', transition_state.stage,
        'referenceDailyVolume',
            transition_state.reference_daily_volume,
        'seedInventoryQuantity',
            transition_state.seed_inventory_quantity,
        'seedCashAmount', transition_state.seed_cash_amount,
        'transferredInventoryQuantity',
            transition_state.transferred_inventory_quantity,
        'transferredCashAmount',
            transition_state.transferred_cash_amount,
        'effectiveBusinessDate', DATE_FORMAT(
            transition_state.effective_business_date,
            '%Y-%m-%d'
        ),
        'legacyDisabledAt', DATE_FORMAT(
            transition_state.legacy_disabled_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'legacyRetiredAt', DATE_FORMAT(
            transition_state.legacy_retired_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'activatedAt', DATE_FORMAT(
            transition_state.activated_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'replayRequestedBy', 'REPLAY_BASELINE',
        'changeReason', transition_state.change_reason,
        'policyVersion', transition_state.policy_version,
        'createdAt', DATE_FORMAT(
            transition_state.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'sourceUpdatedAt', DATE_FORMAT(
            transition_state.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_liquidity_transition transition_state
 WHERE transition_state.effective_business_date
     <= DATE '2027-02-09'
 ORDER BY transition_state.id;

SELECT
    'SECURITY_ALLOCATION',
    CAST(allocation.id AS CHAR),
    JSON_OBJECT(
        'id', allocation.id,
        'idempotencyKey', allocation.idempotency_key,
        'eventType', allocation.event_type,
        'corporateActionId', allocation.corporate_action_id,
        'underwritingContractId',
            allocation.underwriting_contract_id,
        'sourceAccountId', allocation.source_account_id,
        'destinationAccountId', allocation.destination_account_id,
        'symbol', allocation.symbol,
        'quantity', allocation.quantity,
        'unitPrice', allocation.unit_price,
        'allocationReason', allocation.allocation_reason,
        'tradabilityStatus', allocation.tradability_status,
        'effectiveBusinessDate', DATE_FORMAT(
            allocation.effective_business_date,
            '%Y-%m-%d'
        ),
        'unlockBusinessDate', DATE_FORMAT(
            allocation.unlock_business_date,
            '%Y-%m-%d'
        ),
        'createdAt', DATE_FORMAT(
            allocation.created_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_security_allocation_ledger allocation
 WHERE allocation.effective_business_date <= DATE '2027-02-09'
 ORDER BY allocation.id;

SELECT
    'MARKET_REFERENCE_VOLUME',
    CONCAT(
        DATE_FORMAT(
            reference_volume.simulation_trade_date,
            '%Y-%m-%d'
        ),
        ':',
        reference_volume.symbol
    ),
    JSON_OBJECT(
        'simulationTradeDate', DATE_FORMAT(
            reference_volume.simulation_trade_date,
            '%Y-%m-%d'
        ),
        'symbol', reference_volume.symbol,
        'referenceDailyVolume',
            reference_volume.reference_daily_volume,
        'tradableShares', reference_volume.tradable_shares,
        'source', reference_volume.source,
        'completedHistoryDays',
            reference_volume.completed_history_days,
        'calculatedAt', DATE_FORMAT(
            reference_volume.calculated_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'createdAt', DATE_FORMAT(
            reference_volume.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'sourceUpdatedAt', DATE_FORMAT(
            reference_volume.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_market_reference_volume_snapshot reference_volume
 WHERE reference_volume.simulation_trade_date <= DATE '2027-02-09'
 ORDER BY reference_volume.simulation_trade_date,
          reference_volume.symbol;

SELECT
    'UNDERWRITING_DAILY_STATE',
    CONCAT(
        DATE_FORMAT(supply_state.simulation_trade_date, '%Y-%m-%d'),
        ':',
        supply_state.underwriting_contract_id
    ),
    JSON_OBJECT(
        'simulationTradeDate', DATE_FORMAT(
            supply_state.simulation_trade_date,
            '%Y-%m-%d'
        ),
        'underwritingContractId',
            supply_state.underwriting_contract_id,
        'referenceDailyVolume',
            supply_state.reference_daily_volume,
        'submissionQuantityLimit',
            supply_state.submission_quantity_limit,
        'submissionAmountLimit',
            supply_state.submission_amount_limit,
        'submittedQuantity', supply_state.submitted_quantity,
        'submittedAmount', supply_state.submitted_amount,
        'generatedOrderCount',
            supply_state.generated_order_count,
        'cancelledOrderCount',
            supply_state.cancelled_order_count,
        'lastOrderPrice', supply_state.last_order_price,
        'stateStatus', supply_state.state_status,
        'gateReason', supply_state.gate_reason,
        'policyVersion', supply_state.policy_version,
        'version', supply_state.version,
        'createdAt', DATE_FORMAT(
            supply_state.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'sourceUpdatedAt', DATE_FORMAT(
            supply_state.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_underwriting_daily_supply_state supply_state
 WHERE supply_state.simulation_trade_date <= DATE '2027-02-09'
 ORDER BY supply_state.simulation_trade_date,
          supply_state.underwriting_contract_id;

SELECT
    'LIQUIDITY_DAILY_STATE',
    CONCAT(
        DATE_FORMAT(liquidity_state.simulation_trade_date, '%Y-%m-%d'),
        ':',
        liquidity_state.mandate_id
    ),
    JSON_OBJECT(
        'simulationTradeDate', DATE_FORMAT(
            liquidity_state.simulation_trade_date,
            '%Y-%m-%d'
        ),
        'mandateId', liquidity_state.mandate_id,
        'referenceDailyVolume',
            liquidity_state.reference_daily_volume,
        'executionQuantityLimit',
            liquidity_state.execution_quantity_limit,
        'submissionQuantityLimit',
            liquidity_state.submission_quantity_limit,
        'submittedBuyQuantity',
            liquidity_state.submitted_buy_quantity,
        'submittedSellQuantity',
            liquidity_state.submitted_sell_quantity,
        'submittedBuyAmount',
            liquidity_state.submitted_buy_amount,
        'submittedSellAmount',
            liquidity_state.submitted_sell_amount,
        'cancelledBuyQuantity',
            liquidity_state.cancelled_buy_quantity,
        'cancelledSellQuantity',
            liquidity_state.cancelled_sell_quantity,
        'executedBuyQuantity',
            liquidity_state.executed_buy_quantity,
        'executedSellQuantity',
            liquidity_state.executed_sell_quantity,
        'executedBuyAmount',
            liquidity_state.executed_buy_amount,
        'executedSellAmount',
            liquidity_state.executed_sell_amount,
        'realizedProfit', liquidity_state.realized_profit,
        'unrealizedProfit', liquidity_state.unrealized_profit,
        'openingNetAssetValue',
            liquidity_state.opening_net_asset_value,
        'currentNetAssetValue',
            liquidity_state.current_net_asset_value,
        'riskProfit', liquidity_state.risk_profit,
        'openingInventoryQuantity',
            liquidity_state.opening_inventory_quantity,
        'openingInventoryMarkPrice',
            liquidity_state.opening_inventory_mark_price,
        'inventoryMarketMoveProfit',
            liquidity_state.inventory_market_move_profit,
        'controllableRiskProfit',
            liquidity_state.controllable_risk_profit,
        'targetBuyOpenQuantity',
            liquidity_state.target_buy_open_quantity,
        'targetSellOpenQuantity',
            liquidity_state.target_sell_open_quantity,
        'lastOpenBuyQuantity',
            liquidity_state.last_open_buy_quantity,
        'lastOpenSellQuantity',
            liquidity_state.last_open_sell_quantity,
        'externalBuyDepthQuantity',
            liquidity_state.external_buy_depth_quantity,
        'externalSellDepthQuantity',
            liquidity_state.external_sell_depth_quantity,
        'lastBidPrice', liquidity_state.last_bid_price,
        'lastAskPrice', liquidity_state.last_ask_price,
        'lastInventoryQuantity',
            liquidity_state.last_inventory_quantity,
        'lastProjectedInventoryQuantity',
            liquidity_state.last_projected_inventory_quantity,
        'blendedPricePressure',
            liquidity_state.blended_price_pressure,
        'blendedVolatilityPressure',
            liquidity_state.blended_volatility_pressure,
        'blendedLiquidityPressure',
            liquidity_state.blended_liquidity_pressure,
        'stateStatus', liquidity_state.state_status,
        'gateReason', liquidity_state.gate_reason,
        'quoteRunCount', liquidity_state.quote_run_count,
        'limitBreached', liquidity_state.limit_breached + 0,
        'eligibleRegularSeconds',
            liquidity_state.eligible_regular_seconds,
        'bidCoveredSeconds',
            liquidity_state.bid_covered_seconds,
        'askCoveredSeconds',
            liquidity_state.ask_covered_seconds,
        'twoSidedCoveredSeconds',
            liquidity_state.two_sided_covered_seconds,
        'lastCoverageObservedAt', DATE_FORMAT(
            liquidity_state.last_coverage_observed_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'quoteGapCount', liquidity_state.quote_gap_count,
        'currentQuoteGapSeconds',
            liquidity_state.current_quote_gap_seconds,
        'maxQuoteGapSeconds',
            liquidity_state.max_quote_gap_seconds,
        'policyVersion', liquidity_state.policy_version,
        'version', liquidity_state.version,
        'createdAt', DATE_FORMAT(
            liquidity_state.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'sourceUpdatedAt', DATE_FORMAT(
            liquidity_state.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_liquidity_daily_state liquidity_state
 WHERE liquidity_state.simulation_trade_date <= DATE '2027-02-09'
 ORDER BY liquidity_state.simulation_trade_date,
          liquidity_state.mandate_id;

SELECT
    'ORDER',
    CAST(stock_order.id AS CHAR),
    JSON_OBJECT(
        'id', stock_order.id,
        'clientOrderId', stock_order.client_order_id,
        'accountId', stock_order.account_id,
        'originType', stock_order.origin_type,
        'selfTradeGroupId', stock_order.self_trade_group_id,
        'symbol', stock_order.symbol,
        'marketType', stock_order.market_type,
        'side', stock_order.side,
        'orderType', stock_order.order_type,
        'status', stock_order.status,
        'limitPrice', stock_order.limit_price,
        'quantity', stock_order.quantity,
        'filledQuantity', stock_order.filled_quantity,
        'averageFillPrice', stock_order.average_fill_price,
        'reservedCash', stock_order.reserved_cash,
        'fundingBudgetType', stock_order.funding_budget_type,
        'expiresAt', DATE_FORMAT(
            stock_order.expires_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'cancelReason', stock_order.cancel_reason,
        'autoProfileType', stock_order.auto_profile_type,
        'autoBehaviorModelVersion',
            stock_order.auto_behavior_model_version,
        'autoPolicyVersion', stock_order.auto_policy_version,
        'autoBehaviorEventSequence',
            stock_order.auto_behavior_event_sequence,
        'autoIntentId', stock_order.auto_intent_id,
        'decisionUrgency', stock_order.decision_urgency,
        'postOnly', stock_order.post_only + 0,
        'createdAt', DATE_FORMAT(
            stock_order.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'updatedAt', DATE_FORMAT(
            stock_order.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_order stock_order
 WHERE stock_order.market_type = 'ORDER_BOOK'
   AND stock_order.created_at >= TIMESTAMP '2027-02-09 00:00:00'
   AND stock_order.created_at < TIMESTAMP '2027-02-10 00:00:00'
 ORDER BY stock_order.id;

SELECT
    'ORDER_STRATEGY_ORIGIN',
    CAST(strategy_origin.order_id AS CHAR),
    JSON_OBJECT(
        'orderId', strategy_origin.order_id,
        'originType', strategy_origin.origin_type,
        'participantId', strategy_origin.participant_id,
        'portfolioId', strategy_origin.portfolio_id,
        'decisionRunId', strategy_origin.decision_run_id,
        'liquidityMandateId',
            strategy_origin.liquidity_mandate_id,
        'underwritingContractId',
            strategy_origin.underwriting_contract_id,
        'policyVersion', strategy_origin.policy_version,
        'createdAt', DATE_FORMAT(
            strategy_origin.created_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_order_strategy_origin strategy_origin
  JOIN stock_order strategy_order
    ON strategy_order.id = strategy_origin.order_id
 WHERE strategy_order.created_at
     >= TIMESTAMP '2027-02-09 00:00:00'
   AND strategy_order.created_at
     < TIMESTAMP '2027-02-10 00:00:00'
 ORDER BY strategy_origin.order_id;

SELECT
    'EXECUTION',
    CAST(execution.id AS CHAR),
    JSON_OBJECT(
        'id', execution.id,
        'orderId', execution.order_id,
        'accountId', execution.account_id,
        'symbol', execution.symbol,
        'side', execution.side,
        'quantity', execution.quantity,
        'price', execution.price,
        'grossAmount', execution.gross_amount,
        'feeAmount', execution.fee_amount,
        'taxAmount', execution.tax_amount,
        'netAmount', execution.net_amount,
        'realizedProfit', execution.realized_profit,
        'source', execution.source,
        'executedAt', DATE_FORMAT(
            execution.executed_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_execution execution
 WHERE execution.executed_at >= TIMESTAMP '2027-02-09 00:00:00'
   AND execution.executed_at < TIMESTAMP '2027-02-10 00:00:00'
 ORDER BY execution.id;

SELECT
    'AUTO_INTENT',
    CAST(intent.id AS CHAR),
    JSON_OBJECT(
        'id', intent.id,
        'simulationTradeDate',
            DATE_FORMAT(intent.simulation_trade_date, '%Y-%m-%d'),
        'accountId', intent.account_id,
        'symbol', intent.symbol,
        'intentFamily', intent.intent_family,
        'executionObjective', intent.execution_objective,
        'side', intent.side,
        'targetQuantity', intent.target_quantity,
        'filledQuantity', intent.filled_quantity,
        'openQuantity', intent.open_quantity,
        'remainingQuantity', intent.remaining_quantity,
        'activeChildOrderId', intent.active_child_order_id,
        'activeChildQuantity', intent.active_child_quantity,
        'activeChildFilledQuantity',
            intent.active_child_filled_quantity,
        'deadlineAt', DATE_FORMAT(
            intent.deadline_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'status', intent.status,
        'policyVersion', intent.policy_version,
        'behaviorEventSequence',
            intent.behavior_event_sequence,
        'supersededBy', intent.superseded_by,
        'optimisticVersion', intent.optimistic_version,
        'createdAt', DATE_FORMAT(
            intent.created_at,
            '%Y-%m-%dT%H:%i:%s'
        ),
        'updatedAt', DATE_FORMAT(
            intent.updated_at,
            '%Y-%m-%dT%H:%i:%s'
        )
    )
  FROM stock_auto_participant_order_intent intent
 WHERE intent.simulation_trade_date = DATE '2027-02-09'
 ORDER BY intent.id;

COMMIT;
SQL

mv "${PARTIAL_FILE}" "${OUTPUT_FILE}"
(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "$(basename "${OUTPUT_FILE}")" >"${CHECKSUM_FILE}"
)

LINE_COUNT="$(wc -l <"${OUTPUT_FILE}" | tr -d ' ')"
SECTION_COUNTS="$(
  awk -F $'\t' '
    { counts[$1] += 1 }
    END {
      for (section in counts) {
        print section "=" counts[section]
      }
    }
  ' "${OUTPUT_FILE}" | sort
)"

printf 'PASS exported immutable baseline artifact\n'
printf 'INFO close_run_id=%s business_date=%s lines=%s\n' \
  "${BASELINE_CLOSE_RUN_ID}" "${BASELINE_BUSINESS_DATE}" "${LINE_COUNT}"
printf '%s\n' "${SECTION_COUNTS}"
printf 'INFO artifact=%s\n' "${OUTPUT_FILE}"
printf 'INFO checksum=%s\n' "${CHECKSUM_FILE}"
