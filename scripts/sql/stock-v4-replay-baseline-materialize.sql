/*
 * Materialize the verified 2027-02-09 artifact into an isolated replay schema.
 *
 * Preconditions are enforced by scripts/materialize-stock-v4-replay-baseline.sh.
 * This file must never be applied to STOCK_SERVICE. Identity labels are
 * replay-only aliases; economic quantities, prices, cash, role policies,
 * orders, executions, and intent values come from the immutable artifact.
 */

START TRANSACTION;

DELETE FROM stock_order_strategy_origin;
DELETE FROM stock_auto_participant_order_intent;
DELETE FROM stock_execution;
DELETE FROM stock_order;
DELETE FROM stock_liquidity_daily_state;
DELETE FROM stock_liquidity_transition;
DELETE FROM stock_underwriting_daily_supply_state;
DELETE FROM stock_security_allocation_ledger;
DELETE FROM stock_market_policy_version;
DELETE FROM stock_institution_symbol_mandate;
DELETE FROM stock_institution_portfolio;
DELETE FROM stock_liquidity_mandate;
DELETE FROM stock_underwriting_contract;
DELETE FROM stock_market_reference_volume_snapshot;
DELETE FROM stock_corporate_action_entitlement;
DELETE FROM stock_account_cash_flow;
DELETE FROM stock_corporate_action;
DELETE FROM stock_holding_snapshot;
DELETE FROM stock_close_account_snapshot;
DELETE FROM stock_order_book_daily_snapshot;
DELETE FROM stock_market_close_run;
DELETE FROM stock_post_close_cycle;
DELETE FROM stock_holding;
DELETE FROM stock_auto_market_config;
DELETE FROM stock_order_book_market_config;
DELETE FROM stock_market_session_fence;
DELETE FROM stock_price;
DELETE FROM stock_order_book_instrument;
DELETE FROM stock_instrument;
DELETE FROM stock_auto_participant_policy_revision;
DELETE FROM stock_auto_participant_profile_config;
DELETE FROM stock_auto_participant;
DELETE FROM stock_market_participant_account;
DELETE FROM stock_market_participant;
DELETE FROM stock_account;
DELETE FROM stock_market_business_state;
DELETE FROM stock_simulation_clock;

INSERT INTO stock_simulation_clock(
    clock_id,
    base_simulation_date,
    real_seconds_per_simulation_day,
    accumulated_real_seconds,
    running,
    last_started_at,
    last_heartbeat_at,
    timezone,
    created_at,
    updated_at
)
VALUES(
    'DEFAULT',
    DATE '2027-02-10',
    7200,
    0,
    FALSE,
    NULL,
    NULL,
    'Asia/Seoul',
    TIMESTAMP '2027-02-10 00:00:00',
    TIMESTAMP '2027-02-10 00:00:00'
);

INSERT INTO stock_market_business_state(
    state_id,
    active_business_date,
    preparing_business_date,
    raw_simulation_date,
    version,
    created_at,
    updated_at
)
VALUES(
    'DEFAULT',
    DATE '2027-02-09',
    DATE '2027-02-10',
    DATE '2027-02-10',
    1,
    TIMESTAMP '2027-02-09 18:03:48',
    TIMESTAMP '2027-02-09 18:03:48'
);

INSERT INTO stock_account(
    id,
    user_key,
    account_code,
    recovery_code_hash,
    status,
    participant_category,
    self_trade_group_id,
    cash_balance,
    created_at,
    updated_at,
    detached_at,
    reconnected_at,
    recovery_expires_at,
    purge_after,
    previous_user_key_hash
)
SELECT
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.accountId'))
        AS UNSIGNED
    ),
    CASE
        WHEN auto_line.line_id IS NULL THEN NULL
        ELSE JSON_UNQUOTE(
            JSON_EXTRACT(auto_line.payload_json, '$.replayUserKey')
        )
    END,
    CONCAT(
        'REPLAY-',
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.accountId'))
    ),
    NULL,
    JSON_UNQUOTE(
        JSON_EXTRACT(account_line.payload_json, '$.accountStatus')
    ),
    JSON_UNQUOTE(
        JSON_EXTRACT(account_line.payload_json, '$.participantCategory')
    ),
    CONCAT(
        'REPLAY_ACCOUNT_GROUP_',
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.accountId'))
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.postCancelCash'))
        AS DECIMAL(19,2)
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
  FROM stock_v4_replay_artifact_line account_line
  LEFT JOIN stock_v4_replay_artifact_line auto_line
    ON auto_line.section_name = 'AUTO_PARTICIPANT'
   AND auto_line.row_key = account_line.row_key
 WHERE account_line.section_name = 'ACCOUNT_SNAPSHOT'
 ORDER BY CAST(account_line.row_key AS UNSIGNED);

INSERT INTO stock_auto_participant(
    user_key,
    display_name,
    enabled,
    profile_type,
    behavior_seed,
    recurring_cash_amount,
    recurring_cash_interval_value,
    recurring_cash_interval_unit,
    created_at,
    updated_at,
    withdrawn_at
)
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.replayUserKey')),
    CONCAT(
        'Replay Auto ',
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId'))
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.enabled')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.profileType')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.behaviorSeed')),
            'null'
        )
        AS SIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.recurringCashAmount')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.recurringCashIntervalValue')
            ),
            'null'
        )
        AS DECIMAL(12,4)
    ),
    NULLIF(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.recurringCashIntervalUnit')
        ),
        'null'
    ),
    TIMESTAMP '2027-02-09 18:03:48',
    TIMESTAMP '2027-02-09 18:03:48',
    STR_TO_DATE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.withdrawnAt')),
            'null'
        ),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'AUTO_PARTICIPANT'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_auto_participant_profile_config(
    profile_type,
    behavior_model_version,
    news_weight,
    momentum_weight,
    contrarian_weight,
    loss_aversion_weight,
    herding_weight,
    market_making_weight,
    overconfidence_weight,
    noise_weight,
    panic_sell_weight,
    dip_buy_weight,
    order_multiplier,
    decision_frequency_multiplier,
    orders_per_decision_multiplier,
    aggression_multiplier,
    price_pressure_sensitivity,
    order_ttl_multiplier,
    quantity_multiplier,
    holding_patience_weight,
    deep_loss_hold_weight,
    profit_taking_weight,
    pricing_mode,
    exit_mode,
    inventory_mode,
    recurring_deposit_amount,
    recurring_deposit_interval_days,
    recurring_deposit_interval_value,
    recurring_deposit_interval_unit,
    updated_at
)
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.profileType')),
    'V4',
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.newsWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.momentumWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.contrarianWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lossAversionWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.herdingWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.marketMakingWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.overconfidenceWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.noiseWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.panicSellWeight')), 'null') AS DECIMAL(8,4)),
    CAST(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.dipBuyWeight')), 'null') AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.orderMultiplier')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.decisionFrequencyMultiplier')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.ordersPerDecisionMultiplier')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.aggressionMultiplier')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.pricePressureSensitivity')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.orderTtlMultiplier')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quantityMultiplier')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.holdingPatienceWeight')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.deepLossHoldWeight')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.profitTakingWeight')) AS DECIMAL(8,4)),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.pricingMode')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.exitMode')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.inventoryMode')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.recurringDepositAmount')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.recurringDepositIntervalDays')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.recurringDepositIntervalValue')) AS DECIMAL(12,4)),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.recurringDepositIntervalUnit')),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'PROFILE_CONFIG'
 ORDER BY row_key;

INSERT INTO stock_auto_participant_policy_revision(
    policy_version,
    behavior_model_version,
    status,
    effective_trade_date,
    runtime_enabled,
    runtime_change_reason,
    runtime_changed_by,
    runtime_changed_at,
    policy_json,
    created_by,
    created_at,
    activated_at,
    retired_at
)
SELECT
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion'))
        AS UNSIGNED
    ),
    'V3',
    'RETIRED',
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.effectiveTradeDate'))
        AS DATE
    ),
    FALSE,
    'Replay import preserves source V3 as non-runnable history',
    'REPLAY_BASELINE',
    TIMESTAMP '2027-02-10 00:00:00',
    JSON_EXTRACT(payload_json, '$.policyJson'),
    'REPLAY_BASELINE',
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.activatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    TIMESTAMP '2027-02-10 00:00:00'
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'AUTO_POLICY';

INSERT INTO stock_market_participant(
    id,
    participant_code,
    display_name,
    participant_type,
    status,
    self_trade_group_id,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CASE JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantType'))
        WHEN 'SYSTEM_CUSTODY' THEN 'SYSTEM_CUSTODY'
        ELSE JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.replayParticipantCode')
        )
    END,
    CONCAT(
        'Replay Role ',
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id'))
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantType')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CASE JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantType'))
        WHEN 'SYSTEM_CUSTODY' THEN 'SYSTEM_CUSTODY:DEFAULT'
        ELSE JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.replaySelfTradeGroupId')
        )
    END,
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'MARKET_PARTICIPANT'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_market_participant_account(
    id,
    participant_id,
    account_id,
    account_role,
    desk_code,
    effective_from,
    effective_to,
    status,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantId'))
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountRole')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.deskCode')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.effectiveFrom'))
        AS DATE
    ),
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.effectiveTo')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.effectiveTo')),
            '%Y-%m-%d'
        )
    END,
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'PARTICIPANT_ACCOUNT'
 ORDER BY CAST(row_key AS UNSIGNED);

UPDATE stock_account account
JOIN stock_market_participant_account participant_account
  ON participant_account.account_id = account.id
JOIN stock_market_participant participant
  ON participant.id = participant_account.participant_id
   SET account.self_trade_group_id = participant.self_trade_group_id;

INSERT INTO stock_instrument(
    symbol,
    name,
    market,
    enabled,
    created_at
)
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.name')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.market')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.enabled')) AS UNSIGNED),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'DAILY_SYMBOL'
 ORDER BY row_key;

INSERT INTO stock_order_book_instrument(
    symbol,
    name,
    market,
    initial_price,
    issued_shares,
    tradable_shares,
    tick_size,
    price_limit_rate,
    enabled,
    created_at,
    updated_at
)
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.name')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.market')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.initialPrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.issuedShares')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.tradableShares')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.tickSize')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceLimitRate')) AS DECIMAL(5,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.enabled')) AS UNSIGNED),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')), '%Y-%m-%dT%H:%i:%s'),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')), '%Y-%m-%dT%H:%i:%s')
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'DAILY_SYMBOL'
 ORDER BY row_key;

INSERT INTO stock_corporate_action(
    id,
    symbol,
    action_type,
    share_quantity,
    issue_price,
    dividend_amount,
    status,
    base_price,
    theoretical_ex_rights_price,
    ex_rights_date,
    record_date,
    entitlement_close_cycle_id,
    entitlement_close_run_id,
    payment_date,
    listing_date,
    delisting_date,
    offering_type,
    subscription_start_date,
    subscription_end_date,
    delisting_treatment,
    applied_at,
    paid_at,
    listed_at,
    split_from,
    split_to,
    description,
    created_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.actionType')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.shareQuantity')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.issuePrice')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.dividendAmount')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.basePrice')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.theoreticalExRightsPrice')
            ),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.exRightsDate'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.exRightsDate')),
            '%Y-%m-%d'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.recordDate'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.recordDate')),
            '%Y-%m-%d'
        )
    END,
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.entitlementCloseCycleId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.entitlementCloseRunId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.paymentDate'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.paymentDate')),
            '%Y-%m-%d'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.listingDate'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.listingDate')),
            '%Y-%m-%d'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.delistingDate'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.delistingDate')),
            '%Y-%m-%d'
        )
    END,
    NULLIF(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.offeringType')),
        'null'
    ),
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.subscriptionStartDate')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.subscriptionStartDate')
            ),
            '%Y-%m-%d'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.subscriptionEndDate')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.subscriptionEndDate')
            ),
            '%Y-%m-%d'
        )
    END,
    NULLIF(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.delistingTreatment')),
        'null'
    ),
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.appliedAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.appliedAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.paidAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.paidAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.listedAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.listedAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.splitFrom')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.splitTo')),
            'null'
        )
        AS UNSIGNED
    ),
    NULLIF(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.replayDescription')),
        'null'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'CORPORATE_ACTION'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_corporate_action_entitlement(
    id,
    action_id,
    account_id,
    symbol,
    quantity,
    share_quantity,
    cash_amount,
    subscribed_share_quantity,
    subscribed_cash_amount,
    forfeited_share_quantity,
    status,
    holding_snapshot_run_id,
    created_at,
    subscribed_at,
    paid_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.actionId')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quantity')) AS UNSIGNED),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.shareQuantity')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.cashAmount')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.subscribedShareQuantity')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.subscribedCashAmount')
            ),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.forfeitedShareQuantity')
        )
        AS UNSIGNED
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.holdingSnapshotRunId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.subscribedAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.subscribedAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.paidAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.paidAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'CORPORATE_ACTION_ENTITLEMENT'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_account_cash_flow(
    id,
    account_id,
    flow_type,
    amount,
    reason,
    created_by,
    corporate_action_id,
    corporate_action_entitlement_id,
    effective_business_date,
    created_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.flowType')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.amount')) AS DECIMAL(19,2)),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.reason')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.replayCreatedBy')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.corporateActionId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.corporateActionEntitlementId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.effectiveBusinessDate')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.effectiveBusinessDate')
            ),
            '%Y-%m-%d'
        )
    END,
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'ACCOUNT_CASH_FLOW'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_price(
    symbol,
    current_price,
    previous_close,
    price_time,
    provider
)
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.closePrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.previousClose')) AS DECIMAL(19,2)),
    COALESCE(
        STR_TO_DATE(
            NULLIF(
                JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceTime')),
                'null'
            ),
            '%Y-%m-%dT%H:%i:%s'
        ),
        STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    ),
    COALESCE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceProvider')),
            'null'
        ),
        'REPLAY_BASELINE'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'DAILY_SYMBOL'
 ORDER BY row_key;

INSERT INTO stock_order_book_market_config(
    symbol,
    enabled,
    market_status,
    updated_at
)
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.marketEnabled'))
        AS UNSIGNED
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.marketStatus')),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'DAILY_SYMBOL'
 ORDER BY row_key;

INSERT INTO stock_auto_market_config(
    symbol,
    enabled,
    primary_regime_count_1_weight,
    primary_regime_count_2_weight,
    primary_regime_count_3_weight,
    primary_regime_count_4_weight,
    primary_price_pressure_bias,
    primary_asset_preference_pressure_bias,
    primary_volatility_pressure_bias,
    primary_liquidity_pressure_bias,
    primary_execution_aggression_pressure_bias,
    secondary_price_pressure_bias,
    secondary_asset_preference_pressure_bias,
    secondary_volatility_pressure_bias,
    secondary_liquidity_pressure_bias,
    secondary_execution_aggression_pressure_bias,
    max_order_quantity,
    order_ttl_seconds,
    updated_at
)
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.enabled')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.primaryRegimeCount1Weight')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.primaryRegimeCount2Weight')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.primaryRegimeCount3Weight')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.primaryRegimeCount4Weight')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.primaryPricePressureBias')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                payload_json,
                '$.primaryAssetPreferencePressureBias'
            )
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.primaryVolatilityPressureBias')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.primaryLiquidityPressureBias')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                payload_json,
                '$.primaryExecutionAggressionPressureBias'
            )
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.secondaryPricePressureBias')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                payload_json,
                '$.secondaryAssetPreferencePressureBias'
            )
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.secondaryVolatilityPressureBias')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.secondaryLiquidityPressureBias')
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                payload_json,
                '$.secondaryExecutionAggressionPressureBias'
            )
        )
        AS SIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxOrderQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.orderTtlSeconds'))
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'AUTO_MARKET_CONFIG'
 ORDER BY row_key;

INSERT INTO stock_market_session_fence(
    market_type,
    symbol,
    business_date,
    session_epoch,
    session_state,
    state_changed_at,
    version,
    created_at,
    updated_at
)
SELECT
    'ORDER_BOOK',
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    DATE '2027-02-09',
    1,
    'CLOSED',
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    0,
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'DAILY_SYMBOL'
 ORDER BY row_key;

INSERT INTO stock_holding(
    account_id,
    symbol,
    quantity,
    reserved_quantity,
    average_price,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quantity')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.replayReservedQuantity'))
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.averagePrice')) AS DECIMAL(19,2)),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'HOLDING_SNAPSHOT'
 ORDER BY CAST(
      JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId'))
      AS UNSIGNED
  ), row_key;

INSERT INTO stock_market_close_run(
    id,
    symbol,
    business_date,
    closed_at,
    status,
    cancelled_order_count,
    holding_snapshot_count,
    price_rollover_count,
    created_at,
    completed_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    NULL,
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.businessDate'))
        AS DATE
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.cancelledOrderCount'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.holdingSnapshotCount'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceRolloverCount'))
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'CLOSE_RUN'
   AND row_key = '259';

INSERT INTO stock_post_close_cycle(
    id,
    business_date,
    scope_type,
    scope_key,
    cycle_kind,
    skip_reason,
    phase,
    status,
    phase_revision,
    version,
    owner_id,
    lease_until,
    next_retry_at,
    close_run_id,
    settlement_eligible_at,
    attempt_count,
    started_at,
    completed_at,
    last_error_code,
    last_error_message,
    build_version,
    schema_version,
    eod_contract_version,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.businessDate'))
        AS DATE
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.scopeType')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.scopeKey')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.cycleKind')),
    NULL,
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.phase')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.phaseRevision'))
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.version')) AS UNSIGNED),
    NULL,
    NULL,
    NULL,
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.closeRunId')) AS UNSIGNED),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.attemptCount'))
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    NULL,
    NULL,
    'REPLAY_BASELINE',
    'V4_REPLAY',
    'REPLAY_BASELINE_V1',
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'POST_CLOSE_CYCLE';

INSERT INTO stock_order_book_daily_snapshot(
    close_run_id,
    symbol,
    simulation_trade_date,
    snapshot_at,
    name,
    market,
    enabled,
    market_enabled,
    market_status,
    issued_shares,
    tradable_shares,
    initial_price,
    tick_size,
    price_limit_rate,
    close_price,
    previous_close,
    change_rate,
    price_time,
    price_provider,
    execution_count,
    execution_quantity,
    turnover_amount,
    open_price,
    high_price,
    low_price,
    last_execution_price,
    buy_quantity,
    sell_quantity,
    buy_net_amount,
    sell_net_amount,
    open_order_count,
    open_buy_order_count,
    open_sell_order_count,
    reserved_buy_cash,
    holder_count,
    holding_quantity,
    pending_corporate_action_count,
    first_executed_at,
    last_executed_at,
    created_at
)
SELECT
    259,
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    DATE '2027-02-09',
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.name')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.market')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.enabled')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.marketEnabled'))
        AS UNSIGNED
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.marketStatus')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.issuedShares')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.tradableShares')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.initialPrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.tickSize')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceLimitRate')) AS DECIMAL(5,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.closePrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.previousClose')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.changeRate')) AS DECIMAL(9,4)),
    STR_TO_DATE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceTime')),
            'null'
        ),
        '%Y-%m-%dT%H:%i:%s'
    ),
    NULLIF(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceProvider')),
        'null'
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executionCount')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executionQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.turnoverAmount')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.openPrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.highPrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lowPrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastExecutionPrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.buyQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sellQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.buyNetAmount')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sellNetAmount')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.openOrderCount')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.openBuyOrderCount')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.openSellOrderCount')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.reservedBuyCash')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.holderCount')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.holdingQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.pendingCorporateActionCount')) AS UNSIGNED),
    STR_TO_DATE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.firstExecutedAt')),
            'null'
        ),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastExecutedAt')),
            'null'
        ),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'DAILY_SYMBOL'
 ORDER BY row_key;

INSERT INTO stock_holding_snapshot(
    close_cycle_id,
    close_run_id,
    account_id,
    symbol,
    quantity,
    reserved_quantity,
    average_price,
    evaluation_price,
    snapshot_at
)
SELECT
    (
        SELECT id
          FROM stock_post_close_cycle
         WHERE close_run_id = 259
         LIMIT 1
    ),
    259,
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quantity')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.snapshotReservedQuantity')
        )
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.averagePrice')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.evaluationPrice')) AS DECIMAL(19,2)),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.snapshotAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'HOLDING_SNAPSHOT'
 ORDER BY row_key;

INSERT INTO stock_close_account_snapshot(
    close_cycle_id,
    close_run_id,
    account_id,
    user_key,
    account_status,
    participant_category,
    participant_profile_type,
    settlement_target,
    pre_cancel_cash,
    pre_cancel_order_reserved_cash,
    subscription_reserved_cash,
    post_cancel_cash,
    external_net_cash_flow,
    cash_flow_watermark_id,
    holding_market_value,
    holding_quantity,
    reserved_sell_quantity,
    holding_position_count,
    reconciliation_status,
    snapshot_at,
    created_at
)
SELECT
    (
        SELECT id
          FROM stock_post_close_cycle
         WHERE close_run_id = 259
         LIMIT 1
    ),
    259,
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.accountId'))
        AS UNSIGNED
    ),
    account.user_key,
    JSON_UNQUOTE(
        JSON_EXTRACT(account_line.payload_json, '$.accountStatus')
    ),
    JSON_UNQUOTE(
        JSON_EXTRACT(account_line.payload_json, '$.participantCategory')
    ),
    NULLIF(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                account_line.payload_json,
                '$.participantProfileType'
            )
        ),
        'null'
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.settlementTarget')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.preCancelCash')
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                account_line.payload_json,
                '$.preCancelOrderReservedCash'
            )
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                account_line.payload_json,
                '$.subscriptionReservedCash'
            )
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.postCancelCash')
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                account_line.payload_json,
                '$.externalNetCashFlow'
            )
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                account_line.payload_json,
                '$.cashFlowWatermarkId'
            )
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.holdingMarketValue')
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.holdingQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.reservedSellQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.holdingPositionCount')
        )
        AS UNSIGNED
    ),
    JSON_UNQUOTE(
        JSON_EXTRACT(account_line.payload_json, '$.reconciliationStatus')
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.snapshotAt')
        ),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(
            JSON_EXTRACT(account_line.payload_json, '$.snapshotAt')
        ),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line account_line
  JOIN stock_account account
    ON account.id = CAST(
        JSON_UNQUOTE(JSON_EXTRACT(account_line.payload_json, '$.accountId'))
        AS UNSIGNED
    )
 WHERE account_line.section_name = 'ACCOUNT_SNAPSHOT'
 ORDER BY CAST(account_line.row_key AS UNSIGNED);

INSERT INTO stock_market_policy_version(
    id,
    policy_scope,
    scope_key,
    version_no,
    effective_business_date,
    status,
    config_json,
    change_reason,
    changed_by,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyScope')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.scopeKey')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.versionNo')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.effectiveBusinessDate')
        )
        AS DATE
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    JSON_EXTRACT(payload_json, '$.configJson'),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.changeReason')),
    'REPLAY_BASELINE',
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'MARKET_POLICY'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_underwriting_contract(
    id,
    contract_code,
    corporate_action_id,
    symbol,
    participant_id,
    account_id,
    total_issue_quantity,
    tradable_allocation_quantity,
    locked_allocation_quantity,
    external_allocation_quantity,
    underwritten_quantity,
    issue_price,
    underwriting_type,
    stabilization_start_date,
    stabilization_end_date,
    stabilization_quantity_limit,
    stabilization_amount_limit,
    status,
    policy_version,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.contractCode')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.corporateActionId')),
            'null'
        )
        AS UNSIGNED
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantId'))
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.totalIssueQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.tradableAllocationQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.lockedAllocationQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.externalAllocationQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.underwrittenQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.issuePrice'))
        AS DECIMAL(19,2)
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.underwritingType')),
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.stabilizationStartDate')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.stabilizationStartDate')
            ),
            '%Y-%m-%d'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.stabilizationEndDate')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.stabilizationEndDate')
            ),
            '%Y-%m-%d'
        )
    END,
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.stabilizationQuantityLimit')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.stabilizationAmountLimit')
        )
        AS DECIMAL(19,2)
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion'))
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'UNDERWRITING_CONTRACT'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_liquidity_mandate(
    id,
    participant_id,
    account_id,
    symbol,
    mandate_code,
    execution_mode,
    status,
    contract_start_date,
    contract_end_date,
    target_spread_ticks,
    max_spread_ticks,
    max_order_quantity,
    reference_daily_volume,
    target_open_participation_rate,
    max_open_participation_rate,
    max_single_order_participation_rate,
    external_depth_levels,
    max_external_depth_participation_rate,
    daily_execution_participation_rate,
    daily_submission_multiplier,
    target_inventory_quantity,
    inventory_band_quantity,
    inventory_skew_ticks,
    primary_regime_weight,
    liquidity_size_sensitivity,
    volatility_spread_max_ticks,
    price_regime_max_skew_ticks,
    passive_only,
    minimum_quote_lifetime_seconds,
    reprice_threshold_ticks,
    order_ttl_seconds,
    quote_interval_seconds,
    daily_loss_limit_amount,
    next_quote_at,
    policy_version,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantId')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.mandateCode')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executionMode')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.contractStartDate')) AS DATE),
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.contractEndDate')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.contractEndDate')),
            '%Y-%m-%d'
        )
    END,
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.targetSpreadTicks')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxSpreadTicks')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxOrderQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.referenceDailyVolume')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.targetOpenParticipationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxOpenParticipationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxSingleOrderParticipationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.externalDepthLevels')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxExternalDepthParticipationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.dailyExecutionParticipationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.dailySubmissionMultiplier')) AS DECIMAL(8,4)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.targetInventoryQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.inventoryBandQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.inventorySkewTicks')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.primaryRegimeWeight')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.liquiditySizeSensitivity')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.volatilitySpreadMaxTicks')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.priceRegimeMaxSkewTicks')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.passiveOnly')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.minimumQuoteLifetimeSeconds')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.repriceThresholdTicks')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.orderTtlSeconds')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quoteIntervalSeconds')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.dailyLossLimitAmount')) AS DECIMAL(19,2)),
    STR_TO_DATE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.nextQuoteAt')),
            'null'
        ),
        '%Y-%m-%dT%H:%i:%s'
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion')) AS UNSIGNED),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')), '%Y-%m-%dT%H:%i:%s'),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')), '%Y-%m-%dT%H:%i:%s')
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'LIQUIDITY_MANDATE'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_liquidity_transition(
    id,
    transition_key,
    symbol,
    mandate_id,
    participant_id,
    liquidity_account_id,
    source_account_id,
    legacy_account_id,
    stage,
    reference_daily_volume,
    seed_inventory_quantity,
    seed_cash_amount,
    transferred_inventory_quantity,
    transferred_cash_amount,
    effective_business_date,
    legacy_disabled_at,
    legacy_retired_at,
    activated_at,
    requested_by,
    change_reason,
    policy_version,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.transitionKey')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.mandateId')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantId'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.liquidityAccountId'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceAccountId'))
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.legacyAccountId')),
            'null'
        )
        AS UNSIGNED
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.stage')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.referenceDailyVolume'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.seedInventoryQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.seedCashAmount'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.transferredInventoryQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.transferredCashAmount'))
        AS DECIMAL(19,2)
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.effectiveBusinessDate')
        ),
        '%Y-%m-%d'
    ),
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.legacyDisabledAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.legacyDisabledAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.legacyRetiredAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.legacyRetiredAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    CASE
        WHEN JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.activatedAt'))
             = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.activatedAt')),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.replayRequestedBy')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.changeReason')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion'))
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'LIQUIDITY_TRANSITION'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_security_allocation_ledger(
    id,
    idempotency_key,
    event_type,
    corporate_action_id,
    underwriting_contract_id,
    source_account_id,
    destination_account_id,
    symbol,
    quantity,
    unit_price,
    allocation_reason,
    tradability_status,
    effective_business_date,
    unlock_business_date,
    created_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.idempotencyKey')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.eventType')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.corporateActionId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.underwritingContractId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceAccountId')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.destinationAccountId'))
        AS UNSIGNED
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quantity')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.unitPrice'))
        AS DECIMAL(19,2)
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.allocationReason')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.tradabilityStatus')),
    STR_TO_DATE(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.effectiveBusinessDate')
        ),
        '%Y-%m-%d'
    ),
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.unlockBusinessDate')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.unlockBusinessDate')
            ),
            '%Y-%m-%d'
        )
    END,
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'SECURITY_ALLOCATION'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_market_reference_volume_snapshot(
    simulation_trade_date,
    symbol,
    reference_daily_volume,
    observed_daily_volume,
    observed_business_date,
    target_daily_volume,
    target_contract_version,
    tradable_shares,
    source,
    completed_history_days,
    calculated_at,
    created_at,
    updated_at
)
SELECT
    STR_TO_DATE(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.simulationTradeDate')
        ),
        '%Y-%m-%d'
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.referenceDailyVolume'))
        AS UNSIGNED
    ),
    NULL,
    NULL,
    NULL,
    NULL,
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.tradableShares'))
        AS UNSIGNED
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.source')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.completedHistoryDays'))
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.calculatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'MARKET_REFERENCE_VOLUME'
 ORDER BY row_key;

INSERT INTO stock_underwriting_daily_supply_state(
    simulation_trade_date,
    underwriting_contract_id,
    reference_daily_volume,
    submission_quantity_limit,
    submission_amount_limit,
    submitted_quantity,
    submitted_amount,
    generated_order_count,
    cancelled_order_count,
    last_order_price,
    state_status,
    gate_reason,
    policy_version,
    version,
    created_at,
    updated_at
)
SELECT
    STR_TO_DATE(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.simulationTradeDate')
        ),
        '%Y-%m-%d'
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.underwritingContractId')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.referenceDailyVolume'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.submissionQuantityLimit')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.submissionAmountLimit')
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.submittedQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.submittedAmount'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.generatedOrderCount'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.cancelledOrderCount'))
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastOrderPrice')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.stateStatus')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.gateReason')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion'))
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.version')) AS UNSIGNED),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'UNDERWRITING_DAILY_STATE'
 ORDER BY row_key;

INSERT INTO stock_liquidity_daily_state(
    simulation_trade_date,
    mandate_id,
    reference_daily_volume,
    execution_quantity_limit,
    submission_quantity_limit,
    submitted_buy_quantity,
    submitted_sell_quantity,
    submitted_buy_amount,
    submitted_sell_amount,
    cancelled_buy_quantity,
    cancelled_sell_quantity,
    executed_buy_quantity,
    executed_sell_quantity,
    executed_buy_amount,
    executed_sell_amount,
    realized_profit,
    unrealized_profit,
    opening_net_asset_value,
    current_net_asset_value,
    risk_profit,
    opening_inventory_quantity,
    opening_inventory_mark_price,
    inventory_market_move_profit,
    controllable_risk_profit,
    target_buy_open_quantity,
    target_sell_open_quantity,
    last_open_buy_quantity,
    last_open_sell_quantity,
    external_buy_depth_quantity,
    external_sell_depth_quantity,
    last_bid_price,
    last_ask_price,
    last_inventory_quantity,
    last_projected_inventory_quantity,
    blended_price_pressure,
    blended_volatility_pressure,
    blended_liquidity_pressure,
    state_status,
    gate_reason,
    quote_run_count,
    limit_breached,
    eligible_regular_seconds,
    bid_covered_seconds,
    ask_covered_seconds,
    two_sided_covered_seconds,
    last_coverage_observed_at,
    quote_gap_count,
    current_quote_gap_seconds,
    max_quote_gap_seconds,
    policy_version,
    version,
    created_at,
    updated_at
)
SELECT
    STR_TO_DATE(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.simulationTradeDate')
        ),
        '%Y-%m-%d'
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.mandateId')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.referenceDailyVolume'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executionQuantityLimit'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.submissionQuantityLimit')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.submittedBuyQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.submittedSellQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.submittedBuyAmount'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.submittedSellAmount'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.cancelledBuyQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.cancelledSellQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executedBuyQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executedSellQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executedBuyAmount'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executedSellAmount'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.realizedProfit'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.unrealizedProfit'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.openingNetAssetValue'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.currentNetAssetValue'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.riskProfit'))
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.openingInventoryQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.openingInventoryMarkPrice')
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.inventoryMarketMoveProfit')
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.controllableRiskProfit')
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.targetBuyOpenQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.targetSellOpenQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastOpenBuyQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastOpenSellQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.externalBuyDepthQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.externalSellDepthQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastBidPrice')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastAskPrice')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.lastInventoryQuantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.lastProjectedInventoryQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.blendedPricePressure'))
        AS DECIMAL(8,6)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.blendedVolatilityPressure')
        )
        AS DECIMAL(8,6)
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.blendedLiquidityPressure')
        )
        AS DECIMAL(8,6)
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.stateStatus')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.gateReason')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quoteRunCount'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.limitBreached'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.eligibleRegularSeconds'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.bidCoveredSeconds'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.askCoveredSeconds'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.twoSidedCoveredSeconds'))
        AS UNSIGNED
    ),
    CASE
        WHEN JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.lastCoverageObservedAt')
        ) = 'null'
        THEN NULL
        ELSE STR_TO_DATE(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.lastCoverageObservedAt')
            ),
            '%Y-%m-%dT%H:%i:%s'
        )
    END,
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quoteGapCount'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(payload_json, '$.currentQuoteGapSeconds')
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxQuoteGapSeconds'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion'))
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.version')) AS UNSIGNED),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'LIQUIDITY_DAILY_STATE'
 ORDER BY row_key;

INSERT INTO stock_institution_portfolio(
    id,
    participant_id,
    account_id,
    portfolio_code,
    display_name,
    investment_style,
    execution_mode,
    status,
    base_stock_allocation_rate,
    min_stock_allocation_rate,
    max_stock_allocation_rate,
    primary_regime_weight,
    asset_preference_sensitivity,
    volatility_sensitivity,
    entry_threshold_rate,
    exit_threshold_rate,
    daily_turnover_limit_rate,
    max_decision_turnover_rate,
    decision_interval_minutes,
    build_horizon_days,
    build_participation_rate,
    next_decision_at,
    policy_version,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantId')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.portfolioCode')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.replayDisplayName')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.investmentStyle')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executionMode')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.baseStockAllocationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.minStockAllocationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxStockAllocationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.primaryRegimeWeight')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.assetPreferenceSensitivity')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.volatilitySensitivity')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.entryThresholdRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.exitThresholdRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.dailyTurnoverLimitRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxDecisionTurnoverRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.decisionIntervalMinutes')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.buildHorizonDays')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.buildParticipationRate')) AS DECIMAL(8,6)),
    STR_TO_DATE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.nextDecisionAt')),
            'null'
        ),
        '%Y-%m-%dT%H:%i:%s'
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion')) AS UNSIGNED),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')), '%Y-%m-%dT%H:%i:%s'),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')), '%Y-%m-%dT%H:%i:%s')
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'INSTITUTION_PORTFOLIO'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_institution_symbol_mandate(
    id,
    portfolio_id,
    symbol,
    base_symbol_weight,
    min_portfolio_allocation_rate,
    max_portfolio_allocation_rate,
    price_pressure_sensitivity,
    momentum_sensitivity,
    value_sensitivity,
    report_sensitivity,
    reference_daily_volume,
    daily_participation_rate,
    enabled,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.portfolioId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.baseSymbolWeight')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.minPortfolioAllocationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.maxPortfolioAllocationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.pricePressureSensitivity')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.momentumSensitivity')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.valueSensitivity')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.reportSensitivity')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.referenceDailyVolume')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.dailyParticipationRate')) AS DECIMAL(8,6)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.enabled')) AS UNSIGNED),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')), '%Y-%m-%dT%H:%i:%s'),
    STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.sourceUpdatedAt')), '%Y-%m-%dT%H:%i:%s')
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'INSTITUTION_MANDATE'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_order(
    id,
    client_order_id,
    account_id,
    origin_type,
    self_trade_group_id,
    symbol,
    market_type,
    side,
    order_type,
    status,
    limit_price,
    quantity,
    filled_quantity,
    average_fill_price,
    reserved_cash,
    funding_budget_type,
    expires_at,
    auto_profile_type,
    auto_behavior_model_version,
    auto_policy_version,
    auto_behavior_event_sequence,
    auto_decision_trace,
    auto_intent_id,
    decision_urgency,
    post_only,
    cancel_reason,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.id')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.clientOrderId')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.accountId'))
        AS UNSIGNED
    ),
    NULLIF(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.originType')),
        'null'
    ),
    account.self_trade_group_id,
    JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.symbol')),
    JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.marketType')),
    JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.side')),
    JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.orderType')),
    JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.status')),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.limitPrice')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.quantity'))
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(
            JSON_EXTRACT(order_line.payload_json, '$.filledQuantity')
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(order_line.payload_json, '$.averageFillPrice')
            ),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.reservedCash'))
        AS DECIMAL(19,2)
    ),
    NULLIF(
        JSON_UNQUOTE(
            JSON_EXTRACT(order_line.payload_json, '$.fundingBudgetType')
        ),
        'null'
    ),
    STR_TO_DATE(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.expiresAt')),
            'null'
        ),
        '%Y-%m-%dT%H:%i:%s'
    ),
    NULLIF(
        JSON_UNQUOTE(
            JSON_EXTRACT(order_line.payload_json, '$.autoProfileType')
        ),
        'null'
    ),
    NULLIF(
        JSON_UNQUOTE(
            JSON_EXTRACT(
                order_line.payload_json,
                '$.autoBehaviorModelVersion'
            )
        ),
        'null'
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(order_line.payload_json, '$.autoPolicyVersion')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(
                    order_line.payload_json,
                    '$.autoBehaviorEventSequence'
                )
            ),
            'null'
        )
        AS UNSIGNED
    ),
    NULL,
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(order_line.payload_json, '$.autoIntentId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    NULLIF(
        JSON_UNQUOTE(
            JSON_EXTRACT(order_line.payload_json, '$.decisionUrgency')
        ),
        'null'
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.postOnly'))
        AS UNSIGNED
    ),
    NULLIF(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.cancelReason')),
        'null'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.updatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line order_line
  JOIN stock_account account
    ON account.id = CAST(
        JSON_UNQUOTE(JSON_EXTRACT(order_line.payload_json, '$.accountId'))
        AS UNSIGNED
    )
 WHERE order_line.section_name = 'ORDER'
 ORDER BY CAST(order_line.row_key AS UNSIGNED);

INSERT INTO stock_order_strategy_origin(
    order_id,
    origin_type,
    participant_id,
    portfolio_id,
    decision_run_id,
    liquidity_mandate_id,
    underwriting_contract_id,
    policy_version,
    created_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.orderId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.originType')),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.participantId'))
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.portfolioId')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.decisionRunId')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.liquidityMandateId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        NULLIF(
            JSON_UNQUOTE(
                JSON_EXTRACT(payload_json, '$.underwritingContractId')
            ),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion'))
        AS UNSIGNED
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'ORDER_STRATEGY_ORIGIN'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_execution(
    id,
    order_id,
    account_id,
    symbol,
    side,
    quantity,
    price,
    gross_amount,
    fee_amount,
    tax_amount,
    net_amount,
    realized_profit,
    source,
    executed_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.orderId')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.side')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.quantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.price')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.grossAmount')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.feeAmount')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.taxAmount')) AS DECIMAL(19,2)),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.netAmount')) AS DECIMAL(19,2)),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.realizedProfit')),
            'null'
        )
        AS DECIMAL(19,2)
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.source')),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'EXECUTION'
 ORDER BY CAST(row_key AS UNSIGNED);

INSERT INTO stock_auto_participant_order_intent(
    id,
    simulation_trade_date,
    account_id,
    symbol,
    intent_family,
    execution_objective,
    side,
    target_quantity,
    filled_quantity,
    open_quantity,
    remaining_quantity,
    active_child_order_id,
    active_child_quantity,
    active_child_filled_quantity,
    deadline_at,
    status,
    policy_version,
    behavior_event_sequence,
    superseded_by,
    optimistic_version,
    created_at,
    updated_at
)
SELECT
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id')) AS UNSIGNED),
    CAST(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.simulationTradeDate'))
        AS DATE
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.accountId')) AS UNSIGNED),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.symbol')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.intentFamily')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.executionObjective')),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.side')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.targetQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.filledQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.openQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.remainingQuantity')) AS UNSIGNED),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.activeChildOrderId')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.activeChildQuantity')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.activeChildFilledQuantity')) AS UNSIGNED),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.deadlineAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.status')),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.policyVersion')) AS UNSIGNED),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.behaviorEventSequence')) AS UNSIGNED),
    CAST(
        NULLIF(
            JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.supersededBy')),
            'null'
        )
        AS UNSIGNED
    ),
    CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.optimisticVersion')) AS UNSIGNED),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.createdAt')),
        '%Y-%m-%dT%H:%i:%s'
    ),
    STR_TO_DATE(
        JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.updatedAt')),
        '%Y-%m-%dT%H:%i:%s'
    )
  FROM stock_v4_replay_artifact_line
 WHERE section_name = 'AUTO_INTENT'
 ORDER BY CAST(row_key AS UNSIGNED);

COMMIT;
