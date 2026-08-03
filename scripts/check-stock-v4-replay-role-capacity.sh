#!/usr/bin/env bash

set -euo pipefail

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_REPLAY_CONTRACT_ID:?STOCK_V4_REPLAY_CONTRACT_ID is required}"

CHECKPOINT_COUNTERPARTY_USER_KEY="${STOCK_V4_REPLAY_COUNTERPARTY_USER_KEY:-}"
CHECKPOINT_COUNTERPARTY_ACCOUNT_ID="${STOCK_V4_REPLAY_COUNTERPARTY_ACCOUNT_ID:-}"
REQUIRED_CHECKPOINT_QUANTITY_OVERRIDE="${STOCK_V4_REPLAY_REQUIRED_CHECKPOINT_QUANTITY:-}"
FILLED_CHECKPOINT_QUANTITY_OVERRIDE="${STOCK_V4_REPLAY_FILLED_CHECKPOINT_QUANTITY:-0}"
MINIMUM_ROLE_HEADROOM_AMOUNT="${STOCK_V4_ROLE_CAPACITY_MIN_HEADROOM_AMOUNT:-0}"

ROLE_TRANSFER_SOURCE_USER_KEY="${STOCK_V4_ROLE_TRANSFER_SOURCE_USER_KEY:-}"
ROLE_TRANSFER_TARGET_ACCOUNT_ID="${STOCK_V4_ROLE_TRANSFER_TARGET_ACCOUNT_ID:-}"
ROLE_TRANSFER_SYMBOL="${STOCK_V4_ROLE_TRANSFER_SYMBOL:-}"
ROLE_TRANSFER_QUANTITY="${STOCK_V4_ROLE_TRANSFER_QUANTITY:-}"

if [[ ! "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]] \
    || [[ "${STOCK_MYSQL_REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ ! "${STOCK_V4_REPLAY_CONTRACT_ID}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL STOCK_V4_REPLAY_CONTRACT_ID must be a positive integer\n' >&2
  exit 1
fi
if [[ -n "${CHECKPOINT_COUNTERPARTY_USER_KEY}" \
    && -n "${CHECKPOINT_COUNTERPARTY_ACCOUNT_ID}" ]]; then
  printf 'FAIL set either checkpoint counterparty user key or account id, not both\n' >&2
  exit 1
fi
if [[ -n "${CHECKPOINT_COUNTERPARTY_USER_KEY}" ]]; then
  if [[ ! "${CHECKPOINT_COUNTERPARTY_USER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    printf 'FAIL counterparty user key contains unsupported characters\n' >&2
    exit 1
  fi
  checkpoint_counterparty_predicate="counterparty.user_key = '${CHECKPOINT_COUNTERPARTY_USER_KEY}'"
  checkpoint_counterparty_label="${CHECKPOINT_COUNTERPARTY_USER_KEY}"
elif [[ "${CHECKPOINT_COUNTERPARTY_ACCOUNT_ID}" =~ ^[1-9][0-9]*$ ]]; then
  checkpoint_counterparty_predicate="counterparty.id = ${CHECKPOINT_COUNTERPARTY_ACCOUNT_ID}"
  checkpoint_counterparty_label="account:${CHECKPOINT_COUNTERPARTY_ACCOUNT_ID}"
else
  printf 'FAIL checkpoint counterparty user key or positive account id is required\n' >&2
  exit 1
fi

explicit_checkpoint_forecast=false
if [[ -n "${REQUIRED_CHECKPOINT_QUANTITY_OVERRIDE}" ]]; then
  explicit_checkpoint_forecast=true
  if [[ ! "${REQUIRED_CHECKPOINT_QUANTITY_OVERRIDE}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL checkpoint quantity override must be a positive integer\n' >&2
    exit 1
  fi
  if [[ ! "${FILLED_CHECKPOINT_QUANTITY_OVERRIDE}" =~ ^[0-9]+$ ]] \
      || (( FILLED_CHECKPOINT_QUANTITY_OVERRIDE
            > REQUIRED_CHECKPOINT_QUANTITY_OVERRIDE )); then
    printf 'FAIL filled checkpoint override must be between zero and the required quantity\n' >&2
    exit 1
  fi
elif [[ "${FILLED_CHECKPOINT_QUANTITY_OVERRIDE}" != "0" ]]; then
  printf 'FAIL filled checkpoint override requires a required-quantity override\n' >&2
  exit 1
fi
if [[ ! "${MINIMUM_ROLE_HEADROOM_AMOUNT}" =~ ^[0-9]+([.][0-9]{1,2})?$ ]]; then
  printf 'FAIL minimum role-capacity headroom must be a non-negative amount with at most two decimals\n' >&2
  exit 1
fi

role_transfer_requested=false
if [[ -n "${ROLE_TRANSFER_SOURCE_USER_KEY}" \
    || -n "${ROLE_TRANSFER_TARGET_ACCOUNT_ID}" \
    || -n "${ROLE_TRANSFER_SYMBOL}" \
    || -n "${ROLE_TRANSFER_QUANTITY}" ]]; then
  role_transfer_requested=true
  if [[ ! "${ROLE_TRANSFER_SOURCE_USER_KEY}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    printf 'FAIL role-transfer source user key is missing or unsafe\n' >&2
    exit 1
  fi
  if [[ ! "${ROLE_TRANSFER_TARGET_ACCOUNT_ID}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL role-transfer target account id must be a positive integer\n' >&2
    exit 1
  fi
  if [[ ! "${ROLE_TRANSFER_SYMBOL}" =~ ^[A-Z0-9._-]+$ ]]; then
    printf 'FAIL role-transfer symbol is missing or unsafe\n' >&2
    exit 1
  fi
  if [[ ! "${ROLE_TRANSFER_QUANTITY}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL role-transfer quantity must be a positive integer\n' >&2
    exit 1
  fi
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
  "--default-character-set=utf8mb4"
  "--batch"
  "--raw"
  "--skip-column-names"
)

mysql_query() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" --execute="$1"
}

candidate_count="$(mysql_query "
  SELECT COUNT(*)
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
      ON policy.policy_scope = 'UNDERWRITING_CONTRACT'
     AND policy.scope_key = contract.contract_code
     AND policy.status IN ('SCHEDULED', 'ACTIVE')
     AND JSON_EXTRACT(
           policy.config_json,
           '$.requiredCheckpointQuantity'
         ) IS NOT NULL
   WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
")"
if [[ "${explicit_checkpoint_forecast}" == "true" \
    && "${candidate_count}" != "0" ]]; then
  printf 'FAIL explicit checkpoint forecast cannot override a scheduled or active checkpoint: count=%s\n' \
    "${candidate_count}" >&2
  exit 1
fi
if [[ "${explicit_checkpoint_forecast}" == "false" \
    && "${candidate_count}" != "1" ]]; then
  printf 'FAIL role-capacity forecast requires exactly one SCHEDULED or ACTIVE checkpoint policy: count=%s\n' \
    "${candidate_count}" >&2
  exit 1
fi

policy_version_expression='policy.version_no'
policy_status_expression='policy.status'
required_quantity_expression="CAST(
             JSON_UNQUOTE(JSON_EXTRACT(
               policy.config_json,
               '$.requiredCheckpointQuantity'
             )) AS UNSIGNED
           )"
filled_quantity_expression="COALESCE((
           SELECT SUM(execution.quantity)
             FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_strategy_origin origin
             JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_execution execution
               ON execution.order_id = origin.order_id
              AND execution.side = 'SELL'
            WHERE origin.underwriting_contract_id = contract.id
              AND origin.origin_type = 'ISSUE_UNDERWRITER'
              AND origin.policy_version = policy.version_no
         ), 0)"
if [[ "${explicit_checkpoint_forecast}" == "true" ]]; then
  policy_version_expression='0'
  policy_status_expression="'PLANNED'"
  required_quantity_expression="${REQUIRED_CHECKPOINT_QUANTITY_OVERRIDE}"
  filled_quantity_expression="${FILLED_CHECKPOINT_QUANTITY_OVERRIDE}"
fi

forecast_context_count="$(mysql_query "
  SELECT COUNT(*)
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      ON holding.account_id = contract.account_id
     AND holding.symbol = contract.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account counterparty
      ON ${checkpoint_counterparty_predicate}
     AND counterparty.status = 'ACTIVE'
    LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
      ON policy.policy_scope = 'UNDERWRITING_CONTRACT'
     AND policy.scope_key = contract.contract_code
     AND policy.status IN ('SCHEDULED', 'ACTIVE')
     AND JSON_EXTRACT(
           policy.config_json,
           '$.requiredCheckpointQuantity'
         ) IS NOT NULL
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target symbol_target
      ON symbol_target.symbol = contract.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract scaled_contract
      ON scaled_contract.contract_version = symbol_target.contract_version
     AND scaled_contract.status = 'DRAFT'
   WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
")"
if [[ "${forecast_context_count}" != "1" ]]; then
  printf 'FAIL role-capacity forecast requires exactly one complete context row: count=%s\n' \
    "${forecast_context_count}" >&2
  exit 1
fi

forecast_context="$(mysql_query "
  SELECT contract.symbol,
         contract.account_id,
         counterparty.id,
         counterparty.participant_category,
         ${policy_version_expression},
         ${policy_status_expression},
         ${required_quantity_expression},
         ${filled_quantity_expression},
         holding.quantity,
         holding.reserved_quantity,
         scaled_contract.contract_version,
         scaled_contract.baseline_close_run_id,
         scaled_contract.target_market_capitalization
    FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_underwriting_contract contract
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      ON holding.account_id = contract.account_id
     AND holding.symbol = contract.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account counterparty
      ON ${checkpoint_counterparty_predicate}
     AND counterparty.status = 'ACTIVE'
    LEFT JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_policy_version policy
      ON policy.policy_scope = 'UNDERWRITING_CONTRACT'
     AND policy.scope_key = contract.contract_code
     AND policy.status IN ('SCHEDULED', 'ACTIVE')
     AND JSON_EXTRACT(
           policy.config_json,
           '$.requiredCheckpointQuantity'
         ) IS NOT NULL
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target symbol_target
      ON symbol_target.symbol = contract.symbol
    JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_contract scaled_contract
      ON scaled_contract.contract_version = symbol_target.contract_version
     AND scaled_contract.status = 'DRAFT'
   WHERE contract.id = ${STOCK_V4_REPLAY_CONTRACT_ID}
")"
if [[ -z "${forecast_context}" ]]; then
  printf 'FAIL role-capacity forecast context is incomplete\n' >&2
  exit 1
fi

IFS=$'\t' read -r symbol underwriter_account_id counterparty_account_id \
  counterparty_category policy_version policy_status required_quantity \
  filled_quantity underwriter_quantity underwriter_reserved contract_version \
  baseline_close_run_id target_market_capitalization \
  <<< "${forecast_context}"

for integer_value in \
    "${underwriter_account_id}" \
    "${counterparty_account_id}" \
    "${policy_version}" \
    "${required_quantity}" \
    "${filled_quantity}" \
    "${underwriter_quantity}" \
    "${underwriter_reserved}" \
    "${contract_version}" \
    "${baseline_close_run_id}"; do
  if [[ ! "${integer_value}" =~ ^[0-9]+$ ]]; then
    printf 'FAIL role-capacity context contains a non-integer value\n' >&2
    exit 1
  fi
done
if [[ ! "${symbol}" =~ ^[A-Z0-9._-]+$ ]]; then
  printf 'FAIL role-capacity symbol is unsafe: %s\n' "${symbol}" >&2
  exit 1
fi
if [[ "${underwriter_account_id}" == "${counterparty_account_id}" ]]; then
  printf 'FAIL counterparty must differ from the issue-underwriter account\n' >&2
  exit 1
fi
if (( filled_quantity > required_quantity )); then
  printf 'FAIL checkpoint fills exceed its required quantity: filled=%s required=%s\n' \
    "${filled_quantity}" "${required_quantity}" >&2
  exit 1
fi

remaining_quantity=$((required_quantity - filled_quantity))
if (( remaining_quantity > underwriter_quantity )); then
  printf 'FAIL issue-underwriter inventory cannot finish the checkpoint: remaining=%s holding=%s\n' \
    "${remaining_quantity}" "${underwriter_quantity}" >&2
  exit 1
fi
if (( underwriter_reserved > 0 )); then
  printf 'FAIL role-capacity forecast requires zero reserved underwriter inventory: reserved=%s\n' \
    "${underwriter_reserved}" >&2
  exit 1
fi

transfer_source_account_id=0
transfer_target_account_id=0
transfer_source_category=''
transfer_target_category=''
transfer_quantity=0
transfer_symbol=''
if [[ "${role_transfer_requested}" == "true" ]]; then
  transfer_context="$(mysql_query "
    SELECT source.id,
           source.participant_category,
           target.id,
           target.participant_category,
           holding.quantity,
           holding.reserved_quantity
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account source
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
        ON holding.account_id = source.id
       AND holding.symbol = '${ROLE_TRANSFER_SYMBOL}'
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account target
        ON target.id = ${ROLE_TRANSFER_TARGET_ACCOUNT_ID}
       AND target.status = 'ACTIVE'
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target symbol_target
        ON symbol_target.contract_version = ${contract_version}
       AND symbol_target.symbol = '${ROLE_TRANSFER_SYMBOL}'
     WHERE source.user_key = '${ROLE_TRANSFER_SOURCE_USER_KEY}'
       AND source.status = 'ACTIVE'
  ")"
  if [[ -z "${transfer_context}" ]] \
      || [[ "$(printf '%s\n' "${transfer_context}" | wc -l | tr -d ' ')" != "1" ]]; then
    printf 'FAIL role-transfer forecast requires exactly one source/target context row\n' >&2
    exit 1
  fi
  IFS=$'\t' read -r transfer_source_account_id transfer_source_category \
    transfer_target_account_id transfer_target_category \
    transfer_source_quantity transfer_source_reserved <<< "${transfer_context}"
  if [[ "${transfer_source_account_id}" == "${transfer_target_account_id}" ]]; then
    printf 'FAIL role-transfer source and target accounts must differ\n' >&2
    exit 1
  fi
  if (( transfer_source_reserved > transfer_source_quantity \
        || ROLE_TRANSFER_QUANTITY > transfer_source_quantity - transfer_source_reserved )); then
    printf 'FAIL role-transfer source has insufficient available shares: available=%s required=%s\n' \
      "$((transfer_source_quantity - transfer_source_reserved))" \
      "${ROLE_TRANSFER_QUANTITY}" >&2
    exit 1
  fi
  if [[ "${transfer_target_category}" != 'AUTO_PARTICIPANT' \
      && "${transfer_target_category}" != 'INSTITUTIONAL_INVESTOR' \
      && "${transfer_target_category}" != 'LIQUIDITY_PROVIDER' ]]; then
    printf 'FAIL role-transfer target must be an auto, institution, or liquidity-provider account: category=%s\n' \
      "${transfer_target_category}" >&2
    exit 1
  fi
  transfer_quantity="${ROLE_TRANSFER_QUANTITY}"
  transfer_symbol="${ROLE_TRANSFER_SYMBOL}"
fi

capacity_rows="$(mysql_query "
  WITH adjusted_holding AS (
    SELECT holding.symbol,
           holding.account_id,
           account.participant_category,
           CASE WHEN EXISTS (
             SELECT 1
               FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_market_participant_account mapping
              WHERE mapping.account_id = holding.account_id
                AND mapping.account_role = 'SYSTEM_CUSTODY'
                AND mapping.desk_code = CONCAT(
                    'ISSUANCE_LOCKUP:', holding.symbol
                )
                AND mapping.status = 'ACTIVE'
           ) THEN 'LOCKED' ELSE 'TRADABLE' END AS allocation_bucket,
           holding.quantity
             - CASE
                 WHEN holding.account_id = ${underwriter_account_id}
                  AND holding.symbol = '${symbol}'
                 THEN ${remaining_quantity}
                 ELSE 0
               END
             - CASE
                 WHEN holding.account_id = ${transfer_source_account_id}
                  AND holding.symbol = '${transfer_symbol}'
                 THEN ${transfer_quantity}
                 ELSE 0
               END AS quantity
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_holding holding
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
        ON account.id = holding.account_id
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        ON target.contract_version = ${contract_version}
       AND target.symbol = holding.symbol
     WHERE holding.quantity > 0
    UNION ALL
    SELECT '${symbol}',
           ${counterparty_account_id},
           '${counterparty_category}',
           'TRADABLE',
           ${remaining_quantity}
    UNION ALL
    SELECT '${transfer_symbol}',
           ${transfer_target_account_id},
           '${transfer_target_category}',
           'TRADABLE',
           ${transfer_quantity}
     WHERE ${transfer_quantity} > 0
  ),
  source_holding AS (
    SELECT symbol, account_id, participant_category,
           allocation_bucket, SUM(quantity) AS quantity
      FROM adjusted_holding
     WHERE quantity > 0
     GROUP BY symbol, account_id, participant_category,
              allocation_bucket
  ),
  source_total AS (
    SELECT symbol, allocation_bucket, SUM(quantity) AS quantity
      FROM source_holding
     GROUP BY symbol, allocation_bucket
  ),
  allocation_draft AS (
    SELECT source.symbol,
           source.account_id,
           source.participant_category,
           source.allocation_bucket,
           target.target_reference_price,
           CASE
             WHEN source.allocation_bucket = 'TRADABLE'
             THEN target.target_tradable_shares
             ELSE target.target_issued_shares
                    - target.target_tradable_shares
           END AS target_bucket_quantity,
           FLOOR(
             source.quantity * CASE
               WHEN source.allocation_bucket = 'TRADABLE'
               THEN target.target_tradable_shares
               ELSE target.target_issued_shares
                      - target.target_tradable_shares
             END / source_total.quantity
           ) AS floor_target,
           MOD(
             source.quantity * CASE
               WHEN source.allocation_bucket = 'TRADABLE'
               THEN target.target_tradable_shares
               ELSE target.target_issued_shares
                      - target.target_tradable_shares
             END,
             source_total.quantity
           ) AS allocation_remainder
      FROM source_holding source
      JOIN source_total
        ON source_total.symbol = source.symbol
       AND source_total.allocation_bucket = source.allocation_bucket
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        ON target.contract_version = ${contract_version}
       AND target.symbol = source.symbol
  ),
  ranked_allocation AS (
    SELECT allocation_draft.*,
           ROW_NUMBER() OVER (
             PARTITION BY symbol, allocation_bucket
             ORDER BY allocation_remainder DESC, account_id
           ) AS allocation_rank,
           SUM(floor_target) OVER (
             PARTITION BY symbol, allocation_bucket
           ) AS floor_total
      FROM allocation_draft
  ),
  projected_holding AS (
    SELECT participant_category,
           SUM(
             (
               floor_target + CASE
                 WHEN allocation_rank
                      <= target_bucket_quantity - floor_total
                 THEN 1 ELSE 0
               END
             ) * target_reference_price
           ) AS target_holding_value
      FROM ranked_allocation
     GROUP BY participant_category
  ),
  baseline_market AS (
    SELECT COALESCE(SUM(snapshot.close_price * snapshot.issued_shares), 0)
             AS market_capitalization
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_order_book_daily_snapshot snapshot
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_scaled_market_symbol_target target
        ON target.contract_version = ${contract_version}
       AND target.symbol = snapshot.symbol
     WHERE snapshot.close_run_id = ${baseline_close_run_id}
  ),
  baseline_aum AS (
    SELECT snapshot.participant_category,
           SUM(
             snapshot.post_cancel_cash
             + snapshot.holding_market_value
           ) AS aum
      FROM ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_close_account_snapshot snapshot
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_account account
        ON account.id = snapshot.account_id
       AND account.status IN ('ACTIVE', 'DETACHED')
       AND account.participant_category = snapshot.participant_category
     WHERE snapshot.close_run_id = ${baseline_close_run_id}
       AND snapshot.reconciliation_status = 'MATCHED'
     GROUP BY snapshot.participant_category
  ),
  economic_category AS (
    SELECT 'MANUAL_PARTICIPANT' AS participant_category
    UNION ALL SELECT 'AUTO_PARTICIPANT'
    UNION ALL SELECT 'INSTITUTIONAL_INVESTOR'
    UNION ALL SELECT 'LIQUIDITY_PROVIDER'
  ),
  target_capacity AS (
    SELECT category.participant_category,
           CASE
             WHEN category.participant_category = 'AUTO_PARTICIPANT'
             THEN population.target_auto_participant_aum
             ELSE ROUND(
               COALESCE(baseline_aum.aum, 0)
               * ${target_market_capitalization}
               / NULLIF(baseline_market.market_capitalization, 0),
               2
             )
           END AS target_aum
      FROM economic_category category
      CROSS JOIN baseline_market
      JOIN ${STOCK_MYSQL_REPLAY_SCHEMA}.stock_auto_participant_population_contract population
        ON population.contract_version = ${contract_version}
      LEFT JOIN baseline_aum
        ON baseline_aum.participant_category = category.participant_category
  )
  SELECT capacity.participant_category,
         COALESCE(projected.target_holding_value, 0),
         capacity.target_aum,
         capacity.target_aum
           - COALESCE(projected.target_holding_value, 0),
         CASE
           WHEN capacity.target_aum
                  - COALESCE(projected.target_holding_value, 0)
                >= ${MINIMUM_ROLE_HEADROOM_AMOUNT}
           THEN 'PASS' ELSE 'FAIL'
         END
    FROM target_capacity capacity
    LEFT JOIN projected_holding projected
      ON projected.participant_category = capacity.participant_category
   ORDER BY capacity.participant_category
")"

printf 'ROLE_CAPACITY_FORECAST symbol=%s policy=%s/%s counterparty=%s category=%s remaining=%s\n' \
  "${symbol}" "${policy_version}" "${policy_status}" \
  "${checkpoint_counterparty_label}" \
  "${counterparty_category}" "${remaining_quantity}"
printf 'ROLE_CAPACITY_MINIMUM_HEADROOM amount=%s\n' \
  "${MINIMUM_ROLE_HEADROOM_AMOUNT}"
if [[ "${role_transfer_requested}" == "true" ]]; then
  printf 'ROLE_TRANSFER_FORECAST symbol=%s source=%s/%s target=%s/%s quantity=%s\n' \
    "${transfer_symbol}" "${transfer_source_account_id}" \
    "${transfer_source_category}" "${transfer_target_account_id}" \
    "${transfer_target_category}" "${transfer_quantity}"
fi
printf 'participant_category\tprojected_holding_value\ttarget_aum\theadroom\tstatus\n'
printf '%s\n' "${capacity_rows}"

if printf '%s\n' "${capacity_rows}" | awk -F '\t' '$5 == "FAIL" { found=1 } END { exit found ? 0 : 1 }'; then
  printf 'FAIL checkpoint would exceed at least one economic-role AUM capacity\n' >&2
  exit 1
fi

printf 'PASS checkpoint preserves non-negative economic-role AUM capacity\n'
