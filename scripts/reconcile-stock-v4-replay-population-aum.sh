#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION:?STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION is required}"

if [[ "${STOCK_V4_REPLAY_ALLOW_POPULATION_AUM_RECONCILIATION:-}" != "YES" ]]; then
  printf 'FAIL population AUM reconciliation requires STOCK_V4_REPLAY_ALLOW_POPULATION_AUM_RECONCILIATION=YES\n' >&2
  exit 1
fi
if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_SCALED_MARKET_CONTRACT_VERSION}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL contract version must be a positive integer\n' >&2
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
SUMMARY_QUERY="
SELECT CONCAT_WS(
         '|',
         contract.contract_version,
         contract.status,
         redistribution.plan_id,
         redistribution.status,
         population.engine_participant_count,
         recipient.auto_recipient_count,
         population.target_auto_participant_aum,
         recipient.source_auto_aum,
         recipient.final_auto_aum,
         live_auto.current_auto_aum,
         ROUND(
           recipient.final_auto_aum
             / contract.target_market_capitalization,
           8
         ),
         population.target_auto_participant_aum_rate,
         redistribution.planned_capital_transfer,
         recipient.total_capital_transfer,
         cash_flow.withdrawal_amount,
         cash_flow.deposit_amount,
         population.target_auto_participant_aum
           = recipient.final_auto_aum,
         population.target_auto_participant_aum_rate = ROUND(
           recipient.final_auto_aum
             / contract.target_market_capitalization,
           8
         ),
         live_auto.current_auto_aum = recipient.final_auto_aum,
         population.target_auto_participant_aum
           = recipient.source_auto_aum,
         redistribution.planned_capital_transfer
           = recipient.total_capital_transfer
           AND redistribution.planned_capital_transfer
             = cash_flow.withdrawal_amount
           AND redistribution.planned_capital_transfer
             = cash_flow.deposit_amount
       )
  FROM stock_scaled_market_contract contract
  JOIN stock_auto_participant_population_contract population
    ON population.contract_version = contract.contract_version
  JOIN stock_scaled_market_role_redistribution_plan redistribution
    ON redistribution.contract_version = contract.contract_version
   AND redistribution.status = 'COMPLETED'
  JOIN (
    SELECT plan_id,
           SUM(
             CASE WHEN participant_category = 'AUTO_PARTICIPANT'
                  THEN 1 ELSE 0 END
           ) AS auto_recipient_count,
           SUM(
             CASE WHEN participant_category = 'AUTO_PARTICIPANT'
                  THEN source_aum ELSE 0 END
           ) AS source_auto_aum,
           SUM(
             CASE WHEN participant_category = 'AUTO_PARTICIPANT'
                  THEN source_aum + target_capital_transfer
                  ELSE 0 END
           ) AS final_auto_aum,
           SUM(target_capital_transfer) AS total_capital_transfer
      FROM stock_scaled_market_role_redistribution_recipient_plan
     GROUP BY plan_id
  ) recipient
    ON recipient.plan_id = redistribution.plan_id
  JOIN (
    SELECT COUNT(*) AS enabled_auto_count,
           (
             SELECT COALESCE(SUM(account.cash_balance), 0)
               FROM stock_auto_participant participant
               JOIN stock_account account
                 ON account.user_key = participant.user_key
              WHERE participant.enabled = true
                AND participant.withdrawn_at IS NULL
           ) + (
             SELECT COALESCE(
                      SUM(
                        holding.quantity
                          * target.target_reference_price
                      ),
                      0
                    )
               FROM stock_auto_participant participant
               JOIN stock_account account
                 ON account.user_key = participant.user_key
               JOIN stock_holding holding
                 ON holding.account_id = account.id
               JOIN stock_scaled_market_symbol_target target
                 ON target.symbol = holding.symbol
                AND target.contract_version = ${CONTRACT_VERSION}
              WHERE participant.enabled = true
                AND participant.withdrawn_at IS NULL
           ) AS current_auto_aum
      FROM stock_auto_participant
     WHERE enabled = true
       AND withdrawn_at IS NULL
  ) live_auto
    ON live_auto.enabled_auto_count = population.engine_participant_count
  JOIN (
    SELECT SUBSTRING_INDEX(created_by, ':', -1) AS plan_id,
           SUM(
             CASE WHEN flow_type = 'WITHDRAW'
                  THEN amount ELSE 0 END
           ) AS withdrawal_amount,
           SUM(
             CASE WHEN flow_type = 'DEPOSIT'
                  THEN amount ELSE 0 END
           ) AS deposit_amount
      FROM stock_account_cash_flow
     WHERE reason = 'MARKET_ROLE_TRANSFER'
       AND created_by = CONCAT(
         'SCALED_ROLE_REDISTRIBUTION:',
         (
           SELECT plan_id
             FROM stock_scaled_market_role_redistribution_plan
            WHERE contract_version = ${CONTRACT_VERSION}
              AND status = 'COMPLETED'
         )
       )
     GROUP BY created_by
  ) cash_flow
    ON cash_flow.plan_id = redistribution.plan_id
 WHERE contract.contract_version = ${CONTRACT_VERSION}
   AND contract.status IN ('DRAFT', 'SCHEDULED')
"

summary="$(mysql_query "${SUMMARY_QUERY}")"
if [[ -z "${summary}" || "${summary}" == *$'\n'* ]]; then
  printf 'FAIL expected one reconcilable completed role redistribution plan\n' >&2
  exit 1
fi

IFS='|' read -r \
  actual_contract_version contract_status plan_id plan_status \
  engine_count auto_recipient_count current_target_aum source_auto_aum \
  final_auto_aum current_auto_aum expected_rate current_rate \
  planned_capital_transfer recipient_capital_transfer \
  withdrawal_amount deposit_amount target_matches_final \
  rate_matches_final live_matches_final target_matches_source \
  capital_matches <<<"${summary}"

if [[ "${actual_contract_version}" != "${CONTRACT_VERSION}" \
    || "${plan_status}" != "COMPLETED" \
    || "${engine_count}" != "${auto_recipient_count}" ]]; then
  printf 'FAIL contract, completed-plan, or recipient-count contract does not reconcile\n' >&2
  exit 1
fi
if [[ "${capital_matches}" != "1" ]]; then
  printf 'FAIL role capital-transfer plan and cash-flow audit do not reconcile\n' >&2
  exit 1
fi
if [[ "${live_matches_final}" != "1" ]]; then
  printf 'FAIL live auto-participant AUM expected=%s actual=%s\n' \
    "${final_auto_aum}" "${current_auto_aum}" >&2
  exit 1
fi

if [[ "${target_matches_final}" == "1" \
    && "${rate_matches_final}" == "1" ]]; then
  printf 'PASS population AUM is already reconciled: contract=%s plan=%s target=%s rate=%s\n' \
    "${CONTRACT_VERSION}" "${plan_id}" "${final_auto_aum}" "${expected_rate}"
  exit 0
fi
if [[ "${target_matches_source}" != "1" ]]; then
  printf 'FAIL population AUM is neither the pinned source nor final target: current=%s source=%s final=%s\n' \
    "${current_target_aum}" "${source_auto_aum}" "${final_auto_aum}" >&2
  exit 1
fi

updated="$(mysql_query "
START TRANSACTION;
UPDATE stock_auto_participant_population_contract population
JOIN stock_scaled_market_contract contract
  ON contract.contract_version = population.contract_version
JOIN stock_scaled_market_role_redistribution_plan redistribution
  ON redistribution.contract_version = contract.contract_version
 AND redistribution.plan_id = ${plan_id}
 AND redistribution.status = 'COMPLETED'
JOIN (
  SELECT plan_id,
         SUM(
           CASE WHEN participant_category = 'AUTO_PARTICIPANT'
                THEN source_aum ELSE 0 END
         ) AS source_auto_aum,
         SUM(
           CASE WHEN participant_category = 'AUTO_PARTICIPANT'
                THEN source_aum + target_capital_transfer
                ELSE 0 END
         ) AS final_auto_aum
    FROM stock_scaled_market_role_redistribution_recipient_plan
   WHERE plan_id = ${plan_id}
   GROUP BY plan_id
) recipient
  ON recipient.plan_id = redistribution.plan_id
SET population.target_auto_participant_aum = recipient.final_auto_aum,
    population.target_auto_participant_aum_rate = ROUND(
      recipient.final_auto_aum / contract.target_market_capitalization,
      8
    ),
    population.updated_at = redistribution.completed_at
WHERE population.contract_version = ${CONTRACT_VERSION}
  AND contract.status IN ('DRAFT', 'SCHEDULED')
  AND population.target_auto_participant_aum = recipient.source_auto_aum;
SELECT ROW_COUNT();
COMMIT;
")"
if [[ "${updated}" != "1" ]]; then
  printf 'FAIL population AUM compare-and-set affected %s rows\n' "${updated}" >&2
  exit 1
fi

verified="$(mysql_query "${SUMMARY_QUERY}")"
IFS='|' read -r \
  _ _ _ _ _ _ verified_target _ verified_final verified_live \
  verified_rate current_verified_rate _ _ _ _ \
  verified_target_match verified_rate_match verified_live_match \
  _ _ <<<"${verified}"
if [[ "${verified_target_match}" != "1" \
    || "${verified_rate_match}" != "1" \
    || "${verified_live_match}" != "1" ]]; then
  printf 'FAIL population AUM post-update verification failed\n' >&2
  exit 1
fi

printf 'PASS population AUM reconciled: contract=%s status=%s plan=%s target=%s rate=%s\n' \
  "${CONTRACT_VERSION}" "${contract_status}" "${plan_id}" \
  "${verified_target}" "${verified_rate}"
