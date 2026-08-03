#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION:?contract version is required}"
: "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID:?role redistribution plan id is required}"

ALLOW_MUTATION=false
if [[ "${1:-}" == "--check-only" ]]; then
  :
elif [[ $# -gt 0 ]]; then
  printf 'FAIL unsupported argument: %s\n' "$1" >&2
  exit 1
elif [[ "${STOCK_V4_REPLAY_ALLOW_ROLE_CAPITAL_PRESERVATION:-}" == "YES" ]]; then
  ALLOW_MUTATION=true
else
  printf 'FAIL mutation requires STOCK_V4_REPLAY_ALLOW_ROLE_CAPITAL_PRESERVATION=YES\n' >&2
  exit 1
fi

if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL contract version and role redistribution plan id must be positive integers\n' >&2
  exit 1
fi

MYSQL_BIN="${STOCK_MYSQL_BIN:-$(command -v mysql || true)}"
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
  "--raw"
  "--skip-column-names"
  "${STOCK_MYSQL_REPLAY_SCHEMA}"
)

mysql_query() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" --execute="$1"
}

CONTRACT_VERSION="${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}"
PLAN_ID="${STOCK_V4_REPLAY_ROLE_REDISTRIBUTION_PLAN_ID}"
FLOW_CREATOR="SCALED_ROLE_CASH_PRESERVE:${PLAN_ID}"

marker_count="$(mysql_query "
SELECT COUNT(*)
  FROM information_schema.tables
 WHERE table_schema = DATABASE()
   AND table_name = 'stock_market_business_state'
")"
if [[ "${marker_count}" != "1" ]]; then
  printf 'FAIL replay business schema marker expected=1 actual=%s\n' \
    "${marker_count}" >&2
  exit 1
fi

summary="$(mysql_query "
SELECT CONCAT_WS(
         '|',
         contract.contract_version,
         contract.status,
         plan.plan_id,
         plan.status,
         plan.target_transfer_amount,
         plan.planned_capital_transfer,
         plan.target_transfer_amount - plan.planned_capital_transfer,
         recipient.additional_transfer,
         plan.source_lp_account_count,
         recipient.recipient_count,
         recipient.deposit_count,
         recipient.withdraw_count,
         recipient.deposit_amount,
         recipient.withdraw_amount,
         audit.flow_count,
         audit.withdraw_amount,
         audit.deposit_amount,
         clock.running + 0,
         runtime.open_order_count,
         runtime.reserved_cash,
         runtime.reserved_quantity,
         runtime.active_intent_count,
         population.target_auto_participant_aum,
         recipient.old_auto_aum,
         recipient.new_auto_aum,
         CAST(
           ROUND(
             recipient.new_auto_aum
               / contract.target_market_capitalization,
             8
           ) AS DECIMAL(16, 8)
         ),
         market_cash.total_cash
       )
  FROM stock_scaled_market_contract contract
  JOIN stock_scaled_market_role_redistribution_plan plan
    ON plan.contract_version = contract.contract_version
   AND plan.plan_id = ${PLAN_ID}
  JOIN stock_auto_participant_population_contract population
    ON population.contract_version = contract.contract_version
  JOIN (
    SELECT plan_id,
           COUNT(*) AS recipient_count,
           SUM(target_purchase_amount - target_capital_transfer)
             AS additional_transfer,
           SUM(target_purchase_amount > target_capital_transfer)
             AS deposit_count,
           SUM(target_purchase_amount < target_capital_transfer)
             AS withdraw_count,
           SUM(
             CASE WHEN target_purchase_amount > target_capital_transfer
                  THEN target_purchase_amount - target_capital_transfer
                  ELSE 0 END
           ) AS deposit_amount,
           SUM(
             CASE WHEN target_purchase_amount < target_capital_transfer
                  THEN target_capital_transfer - target_purchase_amount
                  ELSE 0 END
           ) AS withdraw_amount,
           SUM(
             CASE WHEN participant_category = 'AUTO_PARTICIPANT'
                  THEN source_aum + target_capital_transfer
                  ELSE 0 END
           ) AS old_auto_aum,
           SUM(
             CASE WHEN participant_category = 'AUTO_PARTICIPANT'
                  THEN source_aum + target_purchase_amount
                  ELSE 0 END
           ) AS new_auto_aum
      FROM stock_scaled_market_role_redistribution_recipient_plan
     WHERE plan_id = ${PLAN_ID}
     GROUP BY plan_id
  ) recipient
    ON recipient.plan_id = plan.plan_id
  JOIN (
    SELECT COUNT(*) AS flow_count,
           COALESCE(SUM(CASE WHEN flow_type = 'WITHDRAW' THEN amount ELSE 0 END), 0)
             AS withdraw_amount,
           COALESCE(SUM(CASE WHEN flow_type = 'DEPOSIT' THEN amount ELSE 0 END), 0)
             AS deposit_amount
      FROM stock_account_cash_flow
     WHERE created_by = '${FLOW_CREATOR}'
  ) audit
  JOIN stock_simulation_clock clock
    ON clock.clock_id = 'DEFAULT'
  JOIN (
    SELECT
      (SELECT COUNT(*)
         FROM stock_order
        WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
          AND quantity > filled_quantity) AS open_order_count,
      (SELECT COALESCE(SUM(reserved_cash), 0)
         FROM stock_order
        WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
          AND quantity > filled_quantity) AS reserved_cash,
      (SELECT COALESCE(SUM(reserved_quantity), 0)
         FROM stock_holding) AS reserved_quantity,
      (SELECT COUNT(*)
         FROM stock_auto_participant_order_intent
        WHERE status = 'ACTIVE') AS active_intent_count
  ) runtime
  JOIN (
    SELECT SUM(cash_balance) AS total_cash
      FROM stock_account
  ) market_cash
 WHERE contract.contract_version = ${CONTRACT_VERSION}
")"

if [[ -z "${summary}" || "${summary}" == *$'\n'* ]]; then
  printf 'FAIL expected one contract and completed redistribution plan\n' >&2
  exit 1
fi

IFS='|' read -r \
  actual_contract_version contract_status actual_plan_id plan_status \
  target_transfer_amount old_capital_transfer correction_amount \
  recipient_correction source_count recipient_count recipient_deposit_count \
  recipient_withdraw_count recipient_deposit_amount recipient_withdraw_amount \
  existing_flow_count existing_withdraw existing_deposit clock_running \
  open_order_count reserved_cash reserved_quantity active_intent_count \
  current_auto_aum old_auto_aum new_auto_aum new_auto_aum_rate \
  total_market_cash \
  <<<"${summary}"

if [[ "${actual_contract_version}" != "${CONTRACT_VERSION}" \
    || "${actual_plan_id}" != "${PLAN_ID}" \
    || "${contract_status}" != "ACTIVE" \
    || "${plan_status}" != "COMPLETED" ]]; then
  printf 'FAIL reconciliation requires the selected ACTIVE contract and COMPLETED plan\n' >&2
  exit 1
fi
if [[ "${correction_amount}" != "${recipient_correction}" \
    || "${correction_amount}" == "0.00" ]]; then
  printf 'FAIL purchase consideration and recipient correction do not reconcile\n' >&2
  exit 1
fi
if [[ "${clock_running}" != "0" \
    || "${open_order_count}" != "0" \
    || "${reserved_cash}" != "0.00" \
    || "${reserved_quantity}" != "0" \
    || "${active_intent_count}" != "0" ]]; then
  printf 'FAIL role capital preservation requires a stopped and fully settled market\n' >&2
  exit 1
fi

printf 'PASS role capital preservation preflight contract=%s plan=%s correction=%s recipients=%s sources=%s\n' \
  "${CONTRACT_VERSION}" "${PLAN_ID}" "${correction_amount}" \
  "${recipient_count}" "${source_count}"
printf 'INFO auto AUM target %s -> %s rate=%s; total market cash=%s\n' \
  "${old_auto_aum}" "${new_auto_aum}" "${new_auto_aum_rate}" \
  "${total_market_cash}"
printf 'INFO recipient adjustments deposits=%s/%s withdrawals=%s/%s gross=%s\n' \
  "${recipient_deposit_count}" "${recipient_deposit_amount}" \
  "${recipient_withdraw_count}" "${recipient_withdraw_amount}" \
  "${recipient_deposit_amount}"

if [[ "${existing_flow_count}" != "0" ]]; then
  expected_flow_count=$((source_count + recipient_count))
  if [[ "${existing_flow_count}" != "${expected_flow_count}" \
      || "${existing_withdraw}" != "${recipient_deposit_amount}" \
      || "${existing_deposit}" != "${recipient_deposit_amount}" \
      || "${current_auto_aum}" != "${new_auto_aum}" ]]; then
    printf 'FAIL existing preservation audit is partial or inconsistent\n' >&2
    exit 1
  fi
  printf 'PASS role capital preservation is already applied and reconciled\n'
  exit 0
fi

if [[ "${current_auto_aum}" != "${old_auto_aum}" ]]; then
  printf 'FAIL population AUM is not the pinned pre-preservation amount current=%s expected=%s\n' \
    "${current_auto_aum}" "${old_auto_aum}" >&2
  exit 1
fi
if [[ "${ALLOW_MUTATION}" != "true" ]]; then
  printf 'PASS check-only completed without changing the replay schema\n'
  exit 0
fi

mutation_result="$(mysql_query "
SELECT GET_LOCK(
         CONCAT('stock-v4-role-cash-preserve:', DATABASE(), ':', ${PLAN_ID}),
         10
       ) INTO @lock_acquired;
CREATE TEMPORARY TABLE tmp_guard(
  value INT NOT NULL,
  CONSTRAINT chk_tmp_guard CHECK (value = 1)
);
INSERT INTO tmp_guard VALUES (@lock_acquired);

START TRANSACTION;

SELECT target_transfer_amount, planned_capital_transfer
  INTO @target_transfer_amount, @old_capital_transfer
  FROM stock_scaled_market_role_redistribution_plan
 WHERE plan_id = ${PLAN_ID}
   AND contract_version = ${CONTRACT_VERSION}
   AND status = 'COMPLETED'
 FOR UPDATE;
INSERT INTO tmp_guard
SELECT COUNT(*) = 1
  FROM stock_scaled_market_contract
 WHERE contract_version = ${CONTRACT_VERSION}
   AND status = 'ACTIVE'
 FOR UPDATE;
INSERT INTO tmp_guard
SELECT COUNT(*) = 0
  FROM stock_account_cash_flow
 WHERE created_by = '${FLOW_CREATOR}';
INSERT INTO tmp_guard
SELECT running = 0
  FROM stock_simulation_clock
 WHERE clock_id = 'DEFAULT'
 FOR UPDATE;
INSERT INTO tmp_guard
SELECT COUNT(*) = 0
  FROM stock_order
 WHERE status IN ('PENDING', 'PARTIALLY_FILLED')
   AND quantity > filled_quantity;
INSERT INTO tmp_guard
SELECT COALESCE(SUM(reserved_quantity), 0) = 0
  FROM stock_holding;
INSERT INTO tmp_guard
SELECT COUNT(*) = 0
  FROM stock_auto_participant_order_intent
 WHERE status = 'ACTIVE';

SET @target_cents = CAST(ROUND(@target_transfer_amount * 100, 0) AS DECIMAL(65, 0));
SET @old_cents = CAST(ROUND(@old_capital_transfer * 100, 0) AS DECIMAL(65, 0));

CREATE TEMPORARY TABLE tmp_lp_adjustment AS
WITH source_weight AS (
  SELECT source_lp_account_id AS account_id,
         CAST(ROUND(source_opening_cash * 100, 0) AS DECIMAL(65, 0))
           AS opening_cents,
         CAST(ROUND(source_capital_withdrawal * 100, 0) AS DECIMAL(65, 0))
           AS old_withdrawal_cents
    FROM stock_scaled_market_role_redistribution_symbol_plan
   WHERE plan_id = ${PLAN_ID}
), source_total AS (
  SELECT SUM(opening_cents) AS total_opening_cents
    FROM source_weight
), floor_allocation AS (
  SELECT source.account_id,
         source.old_withdrawal_cents,
         FLOOR(
           @target_cents * source.opening_cents
             / total.total_opening_cents
         ) AS floor_cents,
         MOD(
           @target_cents * source.opening_cents,
           total.total_opening_cents
         ) AS remainder_cents
    FROM source_weight source
    CROSS JOIN source_total total
), ranked AS (
  SELECT allocation.*,
         ROW_NUMBER() OVER (
           ORDER BY remainder_cents DESC, account_id
         ) AS remainder_rank,
         SUM(floor_cents) OVER () AS floor_total
    FROM floor_allocation allocation
)
SELECT account_id,
       CAST(
         floor_cents
           + CASE
               WHEN remainder_rank <= @target_cents - floor_total
               THEN 1 ELSE 0
             END
         AS DECIMAL(65, 0)
       ) AS target_withdrawal_cents,
       old_withdrawal_cents,
       CAST(
         floor_cents
           + CASE
               WHEN remainder_rank <= @target_cents - floor_total
               THEN 1 ELSE 0
             END
           - old_withdrawal_cents
         AS DECIMAL(65, 0)
       ) AS additional_withdrawal_cents
  FROM ranked;

CREATE TEMPORARY TABLE tmp_recipient_adjustment AS
SELECT account_id, participant_category,
       CAST(
         ROUND(
           (target_purchase_amount - target_capital_transfer) * 100,
           0
         ) AS DECIMAL(65, 0)
       ) AS cash_adjustment_cents
  FROM stock_scaled_market_role_redistribution_recipient_plan
 WHERE plan_id = ${PLAN_ID};

INSERT INTO tmp_guard
SELECT COUNT(*) = ${source_count}
   AND MIN(additional_withdrawal_cents) > 0
   AND SUM(additional_withdrawal_cents) = @target_cents - @old_cents
  FROM tmp_lp_adjustment;
INSERT INTO tmp_guard
SELECT COUNT(*) = ${recipient_count}
   AND SUM(cash_adjustment_cents = 0) = 0
   AND SUM(cash_adjustment_cents) = @target_cents - @old_cents
  FROM tmp_recipient_adjustment;
INSERT INTO tmp_guard
SELECT COUNT(*) = ${source_count}
  FROM stock_account account
  JOIN tmp_lp_adjustment adjustment
    ON adjustment.account_id = account.id
 WHERE CAST(ROUND(account.cash_balance * 100, 0) AS DECIMAL(65, 0))
       >= adjustment.additional_withdrawal_cents
 FOR UPDATE;
INSERT INTO tmp_guard
SELECT COUNT(*) = ${recipient_count}
  FROM stock_account account
  JOIN tmp_recipient_adjustment adjustment
    ON adjustment.account_id = account.id
 WHERE adjustment.cash_adjustment_cents >= 0
    OR CAST(ROUND(account.cash_balance * 100, 0) AS DECIMAL(65, 0))
       >= -adjustment.cash_adjustment_cents
 FOR UPDATE;

SELECT SUM(cash_balance) INTO @cash_before
  FROM stock_account
 FOR UPDATE;

UPDATE stock_account account
JOIN tmp_lp_adjustment adjustment
  ON adjustment.account_id = account.id
   SET account.cash_balance = account.cash_balance
       - adjustment.additional_withdrawal_cents / 100,
       account.updated_at = CONCAT(
         (SELECT active_business_date
            FROM stock_market_business_state
           WHERE state_id = 'DEFAULT'),
         ' 06:00:00'
       );
SET @source_updated = ROW_COUNT();

UPDATE stock_account account
JOIN tmp_recipient_adjustment adjustment
  ON adjustment.account_id = account.id
   SET account.cash_balance = account.cash_balance
       + adjustment.cash_adjustment_cents / 100,
       account.updated_at = CONCAT(
         (SELECT active_business_date
            FROM stock_market_business_state
           WHERE state_id = 'DEFAULT'),
         ' 06:00:00'
       );
SET @recipient_updated = ROW_COUNT();

INSERT INTO stock_account_cash_flow(
  account_id, flow_type, amount, reason, created_by,
  corporate_action_id, corporate_action_entitlement_id,
  effective_business_date, created_at
)
SELECT adjustment.account_id, 'WITHDRAW',
       adjustment.additional_withdrawal_cents / 100,
       'MARKET_ROLE_TRANSFER', '${FLOW_CREATOR}',
       NULL, NULL, state.active_business_date,
       CONCAT(state.active_business_date, ' 06:00:00')
  FROM tmp_lp_adjustment adjustment
  JOIN stock_market_business_state state
    ON state.state_id = 'DEFAULT';
SET @source_flow_count = ROW_COUNT();

INSERT INTO stock_account_cash_flow(
  account_id, flow_type, amount, reason, created_by,
  corporate_action_id, corporate_action_entitlement_id,
  effective_business_date, created_at
)
SELECT adjustment.account_id, 'DEPOSIT',
       adjustment.cash_adjustment_cents / 100,
       'MARKET_ROLE_TRANSFER', '${FLOW_CREATOR}',
       NULL, NULL, state.active_business_date,
       CONCAT(state.active_business_date, ' 06:00:00')
  FROM tmp_recipient_adjustment adjustment
  JOIN stock_market_business_state state
    ON state.state_id = 'DEFAULT'
 WHERE adjustment.cash_adjustment_cents > 0;
SET @recipient_deposit_flow_count = ROW_COUNT();

INSERT INTO stock_account_cash_flow(
  account_id, flow_type, amount, reason, created_by,
  corporate_action_id, corporate_action_entitlement_id,
  effective_business_date, created_at
)
SELECT adjustment.account_id, 'WITHDRAW',
       -adjustment.cash_adjustment_cents / 100,
       'MARKET_ROLE_TRANSFER', '${FLOW_CREATOR}',
       NULL, NULL, state.active_business_date,
       CONCAT(state.active_business_date, ' 06:00:00')
  FROM tmp_recipient_adjustment adjustment
  JOIN stock_market_business_state state
    ON state.state_id = 'DEFAULT'
 WHERE adjustment.cash_adjustment_cents < 0;
SET @recipient_withdraw_flow_count = ROW_COUNT();
SET @recipient_flow_count =
    @recipient_deposit_flow_count + @recipient_withdraw_flow_count;

UPDATE stock_auto_participant_population_contract population
JOIN stock_scaled_market_contract contract
  ON contract.contract_version = population.contract_version
JOIN (
  SELECT SUM(source_aum + target_purchase_amount) AS new_auto_aum
    FROM stock_scaled_market_role_redistribution_recipient_plan
   WHERE plan_id = ${PLAN_ID}
     AND participant_category = 'AUTO_PARTICIPANT'
) target
   SET population.target_auto_participant_aum = target.new_auto_aum,
       population.target_auto_participant_aum_rate = ROUND(
         target.new_auto_aum / contract.target_market_capitalization,
         8
       ),
       population.updated_at = CONCAT(
         (SELECT active_business_date
            FROM stock_market_business_state
           WHERE state_id = 'DEFAULT'),
         ' 06:00:00'
       )
 WHERE population.contract_version = ${CONTRACT_VERSION}
   AND population.target_auto_participant_aum = (
     SELECT SUM(source_aum + target_capital_transfer)
       FROM stock_scaled_market_role_redistribution_recipient_plan
      WHERE plan_id = ${PLAN_ID}
        AND participant_category = 'AUTO_PARTICIPANT'
   );
SET @population_updated = ROW_COUNT();

SELECT SUM(cash_balance) INTO @cash_after
  FROM stock_account;
INSERT INTO tmp_guard
SELECT @source_updated = ${source_count}
   AND @recipient_updated = ${recipient_count}
   AND @source_flow_count = ${source_count}
   AND @recipient_flow_count = ${recipient_count}
   AND @recipient_deposit_flow_count = ${recipient_deposit_count}
   AND @recipient_withdraw_flow_count = ${recipient_withdraw_count}
   AND @population_updated = 1
   AND @cash_before = @cash_after;
INSERT INTO tmp_guard
SELECT COUNT(*) = ${source_count} + ${recipient_count}
   AND SUM(CASE WHEN flow_type = 'WITHDRAW' THEN amount ELSE 0 END)
       = ${recipient_deposit_amount}
   AND SUM(CASE WHEN flow_type = 'DEPOSIT' THEN amount ELSE 0 END)
       = ${recipient_deposit_amount}
  FROM stock_account_cash_flow
 WHERE created_by = '${FLOW_CREATOR}';

COMMIT;
SELECT CONCAT_WS(
         '|',
         @source_updated,
         @recipient_updated,
         @source_flow_count,
         @recipient_flow_count,
         @population_updated,
         @cash_before,
         @cash_after
       );
SELECT RELEASE_LOCK(
         CONCAT('stock-v4-role-cash-preserve:', DATABASE(), ':', ${PLAN_ID})
       );
")"

mutation_summary="$(printf '%s\n' "${mutation_result}" | head -n 1)"
lock_released="$(printf '%s\n' "${mutation_result}" | tail -n 1)"
if [[ "${mutation_summary}" != \
    "${source_count}|${recipient_count}|${source_count}|${recipient_count}|1|${total_market_cash}|${total_market_cash}" \
    || "${lock_released}" != "1" ]]; then
  printf 'FAIL role capital preservation mutation summary mismatch: %s / lock=%s\n' \
    "${mutation_summary}" "${lock_released}" >&2
  exit 1
fi

post_summary="$(mysql_query "
SELECT CONCAT_WS(
         '|',
         COUNT(*),
         SUM(CASE WHEN flow_type = 'WITHDRAW' THEN amount ELSE 0 END),
         SUM(CASE WHEN flow_type = 'DEPOSIT' THEN amount ELSE 0 END),
         (SELECT target_auto_participant_aum
            FROM stock_auto_participant_population_contract
           WHERE contract_version = ${CONTRACT_VERSION}),
         (SELECT target_auto_participant_aum_rate
            FROM stock_auto_participant_population_contract
           WHERE contract_version = ${CONTRACT_VERSION}),
         (SELECT SUM(cash_balance) FROM stock_account)
       )
  FROM stock_account_cash_flow
 WHERE created_by = '${FLOW_CREATOR}'
")"
if [[ "${post_summary}" != \
    "$((source_count + recipient_count))|${recipient_deposit_amount}|${recipient_deposit_amount}|${new_auto_aum}|${new_auto_aum_rate}|${total_market_cash}" ]]; then
  printf 'FAIL role capital preservation postflight mismatch: %s\n' \
    "${post_summary}" >&2
  exit 1
fi

printf 'PASS role capital preservation applied correction=%s flows=%s autoAum=%s rate=%s totalCash=%s\n' \
  "${correction_amount}" "$((source_count + recipient_count))" \
  "${new_auto_aum}" "${new_auto_aum_rate}" "${total_market_cash}"
