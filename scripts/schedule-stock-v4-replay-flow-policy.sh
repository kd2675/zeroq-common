#!/usr/bin/env bash

set -euo pipefail

if [[ "${STOCK_V4_REPLAY_ALLOW_FLOW_POLICY_SCHEDULE:-}" != "YES" ]]; then
  printf 'FAIL adaptive flow policy scheduling requires STOCK_V4_REPLAY_ALLOW_FLOW_POLICY_SCHEDULE=YES\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
DAILY_EXECUTION_RATE="${STOCK_V4_REPLAY_LP_DAILY_EXECUTION_RATE:-1.000000}"
SUBMISSION_MULTIPLIER="${STOCK_V4_REPLAY_LP_SUBMISSION_MULTIPLIER:-2.5000}"
EXTERNAL_DEPTH_RATE="${STOCK_V4_REPLAY_LP_EXTERNAL_DEPTH_RATE:-0.250000}"
CHECK_ONLY=false

if [[ "${1:-}" == "--check-only" ]]; then
  CHECK_ONLY=true
elif [[ $# -gt 0 ]]; then
  printf 'FAIL unsupported argument: %s\n' "$1" >&2
  exit 1
fi

if [[ ! "${BACK_URL}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
  printf 'FAIL replay back URL must be an explicit loopback HTTP endpoint\n' >&2
  exit 1
fi

JQ_BIN="$(command -v jq || true)"
if [[ -z "${JQ_BIN}" || ! -x "${JQ_BIN}" ]]; then
  printf 'FAIL jq was not found\n' >&2
  exit 1
fi

require_decimal_range() {
  local label="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"
  if ! "${JQ_BIN}" -en \
      --arg value "${value}" \
      --arg minimum "${minimum}" \
      --arg maximum "${maximum}" \
      '($value | tonumber) >= ($minimum | tonumber)
        and ($value | tonumber) <= ($maximum | tonumber)' >/dev/null; then
    printf 'FAIL %s must be between %s and %s: %s\n' \
      "${label}" "${minimum}" "${maximum}" "${value}" >&2
    exit 1
  fi
}

require_decimal_range 'LP daily execution rate' "${DAILY_EXECUTION_RATE}" 0.000001 1.000000
require_decimal_range 'LP submission multiplier' "${SUBMISSION_MULTIPLIER}" 1.0000 10.0000
require_decimal_range 'LP external-depth rate' "${EXTERNAL_DEPTH_RATE}" 0.000001 0.250000

admin_get() {
  curl -sS --max-time 15 \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    "${BACK_URL}$1"
}

clock_response="$(admin_get '/api/stock/v1/markets/simulation-clock')"
if ! printf '%s' "${clock_response}" | "${JQ_BIN}" -e \
    '.success == true and .data.running == false' >/dev/null; then
  printf 'FAIL adaptive flow policy must be scheduled while the replay clock is stopped response=%s\n' \
    "${clock_response}" >&2
  exit 1
fi
active_business_date="$(printf '%s' "${clock_response}" | "${JQ_BIN}" -r '.data.activeBusinessDate')"

mandates_response="$(admin_get '/api/stock/v1/markets/liquidity-mandates')"
if ! printf '%s' "${mandates_response}" | "${JQ_BIN}" -e \
    '.success == true
      and (.data | length) == 8
      and all(.data[]; .status == "ACTIVE" and .executionMode == "LIVE")' >/dev/null; then
  printf 'FAIL exactly eight active LIVE replay LP mandates are required response=%s\n' \
    "${mandates_response}" >&2
  exit 1
fi

printf 'PASS adaptive flow policy preflight activeBusinessDate=%s mandates=8 dailyExecution=%s submissionMultiplier=%s externalDepth=%s\n' \
  "${active_business_date}" "${DAILY_EXECUTION_RATE}" \
  "${SUBMISSION_MULTIPLIER}" "${EXTERNAL_DEPTH_RATE}"

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS adaptive flow policy check-only completed without scheduling changes\n'
  exit 0
fi

printf '%s' "${mandates_response}" | "${JQ_BIN}" -r '.data[] | @base64' \
  | while IFS= read -r encoded; do
      row="$(printf '%s' "${encoded}" | base64 --decode)"
      symbol="$(printf '%s' "${row}" | "${JQ_BIN}" -r '.symbol')"
      payload="$(printf '%s' "${row}" | "${JQ_BIN}" -c \
        --arg dailyExecution "${DAILY_EXECUTION_RATE}" \
        --arg submissionMultiplier "${SUBMISSION_MULTIPLIER}" \
        --arg externalDepth "${EXTERNAL_DEPTH_RATE}" \
        '(.account.availableCash
            + (.account.holdingQuantity * .account.currentPrice)) as $nav
          | .policy
          | del(.primaryRegimeWeight, .liquiditySizeSensitivity)
          | .passiveOnly = false
          | .dailyExecutionParticipationRate = ($dailyExecution | tonumber)
          | .dailySubmissionMultiplier = ($submissionMultiplier | tonumber)
          | .maxExternalDepthParticipationRate = ($externalDepth | tonumber)
          | .dailyLossLimitAmount = (($nav * 0.05) | floor)
        | .changeReason = "scaled-market target pacing adaptive LP backstop v2"')"
      response="$(curl -sS --max-time 15 -X PATCH \
        -H 'Content-Type: application/json' \
        -H "X-User-Key: ${ADMIN_USER_KEY}" \
        -H 'X-User-Role: ADMIN' \
        --data "${payload}" \
        "${BACK_URL}/api/stock/v1/markets/liquidity-mandates/${symbol}/policy")"
      if ! printf '%s' "${response}" | "${JQ_BIN}" -e \
          '.success == true
            and .data.scheduledPolicy.policy.passiveOnly == false
            and .data.scheduledPolicy.effectiveBusinessDate != null' >/dev/null; then
        printf 'FAIL adaptive LP policy scheduling symbol=%s response=%s\n' \
          "${symbol}" "${response}" >&2
        exit 1
      fi
      printf '%s' "${response}" | "${JQ_BIN}" -r \
        '"PASS adaptive LP scheduled symbol=\(.data.symbol) version=\(.data.scheduledPolicy.policyVersion) effective=\(.data.scheduledPolicy.effectiveBusinessDate)"'
    done

verification="$(admin_get '/api/stock/v1/markets/liquidity-mandates')"
if ! printf '%s' "${verification}" | "${JQ_BIN}" -e \
    --arg dailyExecution "${DAILY_EXECUTION_RATE}" \
    --arg submissionMultiplier "${SUBMISSION_MULTIPLIER}" \
    --arg externalDepth "${EXTERNAL_DEPTH_RATE}" \
    '.success == true
      and (.data | length) == 8
      and all(.data[];
        .scheduledPolicy != null
        and .scheduledPolicy.policy.passiveOnly == false
        and .scheduledPolicy.policy.dailyExecutionParticipationRate
          == ($dailyExecution | tonumber)
        and .scheduledPolicy.policy.dailySubmissionMultiplier
          == ($submissionMultiplier | tonumber)
        and .scheduledPolicy.policy.maxExternalDepthParticipationRate
          == ($externalDepth | tonumber))' >/dev/null; then
  printf 'FAIL scheduled adaptive LP policy verification failed response=%s\n' \
    "${verification}" >&2
  exit 1
fi

printf 'PASS all eight adaptive LP policies are scheduled through the policy-version ledger\n'
