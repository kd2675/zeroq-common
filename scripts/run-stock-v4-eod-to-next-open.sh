#!/usr/bin/env bash

set -euo pipefail

if [[ "${STOCK_V4_REPLAY_ALLOW_EOD_ADVANCE:-}" != "YES" ]]; then
  printf 'FAIL EOD advance requires STOCK_V4_REPLAY_ALLOW_EOD_ADVANCE=YES\n' >&2
  exit 1
fi

BACK_URL="${STOCK_V4_REPLAY_BACK_URL:-http://127.0.0.1:30490}"
ADMIN_USER_KEY="${STOCK_V4_REPLAY_ADMIN_USER_KEY:-codex-replay-admin}"
POLL_SECONDS="${STOCK_V4_REPLAY_EOD_POLL_SECONDS:-2}"
TIMEOUT_SECONDS="${STOCK_V4_REPLAY_EOD_TIMEOUT_SECONDS:-240}"
JQ_BIN="$(command -v jq || true)"
STOP_AFTER_REPORTS=false
STOP_AFTER_MARKET_DATA=false

for argument in "$@"; do
  case "${argument}" in
    --stop-after-reports)
      STOP_AFTER_REPORTS=true
      ;;
    --stop-after-market-data)
      STOP_AFTER_MARKET_DATA=true
      ;;
    *)
      printf 'FAIL unsupported argument: %s\n' "${argument}" >&2
      exit 1
      ;;
  esac
done
if [[ "${STOP_AFTER_REPORTS}" == "true" \
    && "${STOP_AFTER_MARKET_DATA}" == "true" ]]; then
  printf 'FAIL only one EOD stop point may be selected\n' >&2
  exit 1
fi

if [[ -z "${JQ_BIN}" || ! -x "${JQ_BIN}" ]]; then
  printf 'FAIL jq was not found\n' >&2
  exit 1
fi
if [[ ! "${POLL_SECONDS}" =~ ^[1-9][0-9]*$ || "${POLL_SECONDS}" -gt 30 ]]; then
  printf 'FAIL STOCK_V4_REPLAY_EOD_POLL_SECONDS must be between 1 and 30\n' >&2
  exit 1
fi
if [[ ! "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ || "${TIMEOUT_SECONDS}" -gt 1800 ]]; then
  printf 'FAIL STOCK_V4_REPLAY_EOD_TIMEOUT_SECONDS must be between 1 and 1800\n' >&2
  exit 1
fi

clock_response() {
  curl -sS \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    "${BACK_URL}/api/stock/v1/markets/simulation-clock"
}

require_success_json() {
  local label="$1"
  local response="$2"
  if ! printf '%s' "${response}" | "${JQ_BIN}" -e '.success == true' >/dev/null; then
    printf 'FAIL %s response=%s\n' "${label}" "${response}" >&2
    exit 1
  fi
}

clock_value() {
  local response="$1"
  local expression="$2"
  printf '%s' "${response}" | "${JQ_BIN}" -r "${expression}"
}

has_jump_action() {
  local response="$1"
  local action="$2"
  printf '%s' "${response}" \
    | "${JQ_BIN}" -e --arg action "${action}" \
      '.data.availableJumpActions | index($action) != null' >/dev/null
}

wait_for_clock() {
  local label="$1"
  local jq_condition="$2"
  local started_at
  local response
  local status
  local phase

  started_at="$(date +%s)"
  while true; do
    response="$(clock_response)"
    require_success_json "${label} clock" "${response}"
    if printf '%s' "${response}" | "${JQ_BIN}" -e "${jq_condition}" >/dev/null; then
      printf '%s' "${response}"
      return 0
    fi
    status="$(clock_value "${response}" '.data.postCloseStatus // ""')"
    phase="$(clock_value "${response}" '.data.postClosePhase // ""')"
    if [[ "${status}" == "FAILED" ]]; then
      printf 'WARN %s is fail-closed and waiting for the official retry: phase=%s\n' \
        "${label}" "${phase}" >&2
    fi
    if (( "$(date +%s)" - started_at >= TIMEOUT_SECONDS )); then
      printf 'FAIL %s timed out after %ss response=%s\n' \
        "${label}" "${TIMEOUT_SECONDS}" "${response}" >&2
      exit 1
    fi
    sleep "${POLL_SECONDS}"
  done
}

jump_and_require_post_state() {
  local label="$1"
  local action="$2"
  local post_condition="$3"
  local before
  local response

  before="$(clock_response)"
  require_success_json "${label} preflight" "${before}"
  if ! has_jump_action "${before}" "${action}"; then
    printf 'FAIL %s action=%s is not currently available response=%s\n' \
      "${label}" "${action}" "${before}" >&2
    exit 1
  fi

  response="$(curl -sS -X PATCH \
    -H 'Content-Type: application/json' \
    -H "X-User-Key: ${ADMIN_USER_KEY}" \
    -H 'X-User-Role: ADMIN' \
    --data "{\"action\":\"${action}\"}" \
    "${BACK_URL}/api/stock/v1/markets/simulation-clock")"
  if printf '%s' "${response}" | "${JQ_BIN}" -e '.success == true' >/dev/null; then
    if ! printf '%s' "${response}" | "${JQ_BIN}" -e "${post_condition}" >/dev/null; then
      printf 'FAIL %s returned success without the required post-state response=%s\n' \
        "${label}" "${response}" >&2
      exit 1
    fi
  else
    response="$(clock_response)"
    require_success_json "${label} post-error clock" "${response}"
    if ! printf '%s' "${response}" | "${JQ_BIN}" -e "${post_condition}" >/dev/null; then
      printf 'FAIL %s failed and the required post-state was not committed response=%s\n' \
        "${label}" "${response}" >&2
      exit 1
    fi
    printf 'WARN %s API failed after the required post-state was committed\n' \
      "${label}" >&2
  fi
  printf 'PASS %s action=%s simulationDateTime=%s\n' \
    "${label}" "${action}" "$(clock_value "${response}" '.data.simulationDateTime')"
}

initial_clock="$(clock_response)"
require_success_json 'initial EOD clock' "${initial_clock}"
closing_date="$(clock_value "${initial_clock}" '.data.activeBusinessDate')"
initial_session="$(clock_value "${initial_clock}" '.data.marketSession')"
initial_phase="$(clock_value "${initial_clock}" '.data.postClosePhase // ""')"
resume_completed_cycle=false
if [[ "${initial_session}" == "AFTER_CLOSE" \
    && "$(clock_value "${initial_clock}" '.data.running')" == "false" \
    && "$(clock_value "${initial_clock}" '.data.postCloseProcessingCompleted')" == "true" \
    && "${initial_phase}" == "PORTFOLIO_SETTLED" ]]; then
  jump_and_require_post_state \
    'next simulation day start' \
    'NEXT_SIMULATION_DAY_START' \
    '.data.marketSession == "PRE_OPEN"
      and (.data.simulationDateTime | endswith("T00:00:00"))
      and .data.activeBusinessDate == "'"${closing_date}"'"'
elif [[ "${initial_session}" == "PRE_OPEN" \
    && "$(clock_value "${initial_clock}" '.data.running')" == "false" \
    && "$(clock_value "${initial_clock}" '.data.preparingBusinessDate')" \
      == "$(clock_value "${initial_clock}" '.data.simulationDate')" \
    && "$(clock_value "${initial_clock}" '.data.activeBusinessDate')" \
      != "$(clock_value "${initial_clock}" '.data.simulationDate')" \
    && ( "${initial_phase}" == "PORTFOLIO_SETTLED" \
      || "${initial_phase}" == "OVERNIGHT_CASH_APPLIED" \
      || "${initial_phase}" == "REPORTS_AGGREGATED" \
      || "${initial_phase}" == "MARKET_DATA_PREPARED" \
      || "${initial_phase}" == "AUTO_MARKET_PREPARED" \
      || "${initial_phase}" == "READY_TO_OPEN" \
      || "${initial_phase}" == "COMPLETED" ) ]]; then
  if [[ "${initial_phase}" == "COMPLETED" \
      && "$(clock_value "${initial_clock}" '.data.postCloseStatus // ""')" == "COMPLETED" ]]; then
    resume_completed_cycle=true
  fi
  printf 'PASS EOD advance resumes committed PRE_OPEN phase=%s simulationDateTime=%s\n' \
    "${initial_phase}" \
    "$(clock_value "${initial_clock}" '.data.simulationDateTime')"
else
  printf 'FAIL EOD advance requires stopped AFTER_CLOSE/PORTFOLIO_SETTLED or resumable PRE_OPEN state response=%s\n' \
    "${initial_clock}" >&2
  exit 1
fi

if [[ "${resume_completed_cycle}" == "true" \
    && ( "${STOP_AFTER_REPORTS}" == "true" \
      || "${STOP_AFTER_MARKET_DATA}" == "true" ) ]]; then
  printf 'FAIL completed replay cycle has already passed reports and market-data stop points; open the prepared date first and use the next close cycle\n' >&2
  exit 1
fi

current_reports_clock="$(clock_response)"
require_success_json 'post-close reports current clock' "${current_reports_clock}"
if [[ "${STOP_AFTER_REPORTS}" == "true" ]] \
    && ! printf '%s' "${current_reports_clock}" | "${JQ_BIN}" -e \
      '.data.marketSession == "PRE_OPEN"
        and (.data.simulationDateTime | endswith("T00:00:00"))' >/dev/null; then
  printf 'FAIL reports-only EOD advance cannot continue after the midnight reports gate response=%s\n' \
    "${current_reports_clock}" >&2
  exit 1
fi
if printf '%s' "${current_reports_clock}" | "${JQ_BIN}" -e \
    '.data.marketSession == "PRE_OPEN"
      and (.data.simulationDateTime | endswith("T00:00:00"))' >/dev/null; then
  if printf '%s' "${current_reports_clock}" | "${JQ_BIN}" -e \
      '(
         (
           .data.postClosePhase == "REPORTS_AGGREGATED"
           and .data.postCloseStatus == "PENDING"
         )
         or (
           .data.postClosePhase == "COMPLETED"
           and .data.postCloseStatus == "COMPLETED"
         )
       )
        and (.data.availableJumpActions | index("NEXT_PREOPEN_TRANSFORM_START") != null)' \
        >/dev/null; then
    reports_clock="${current_reports_clock}"
  else
    reports_clock="$(wait_for_clock \
      'post-close reports' \
      '.data.postClosePhase == "REPORTS_AGGREGATED"
        and .data.postCloseStatus == "PENDING"
        and (.data.availableJumpActions | index("NEXT_PREOPEN_TRANSFORM_START") != null)')"
  fi
  printf 'PASS reports aggregated simulationDateTime=%s\n' \
    "$(clock_value "${reports_clock}" '.data.simulationDateTime')"

  if [[ "${STOP_AFTER_REPORTS}" == "true" ]]; then
    printf 'PASS EOD advance stopped after current-day reports closedDate=%s preparingDate=%s phase=REPORTS_AGGREGATED\n' \
      "${closing_date}" \
      "$(clock_value "${reports_clock}" '.data.preparingBusinessDate')"
    exit 0
  fi

  jump_and_require_post_state \
    'pre-open transform start' \
    'NEXT_PREOPEN_TRANSFORM_START' \
    '.data.marketSession == "PRE_OPEN"
      and (.data.simulationDateTime | endswith("T04:30:00"))'
fi

current_market_data_clock="$(clock_response)"
require_success_json 'market-data current clock' "${current_market_data_clock}"
if printf '%s' "${current_market_data_clock}" | "${JQ_BIN}" -e \
    '.data.marketSession == "PRE_OPEN"
      and (.data.simulationDateTime | endswith("T04:30:00"))' >/dev/null; then
  if printf '%s' "${current_market_data_clock}" | "${JQ_BIN}" -e \
      '.data.postClosePhase == "MARKET_DATA_PREPARED"
        and .data.postCloseStatus == "PENDING"
        and (.data.availableJumpActions | index("NEXT_AUTO_MARKET_PREPARATION_START") != null)' \
        >/dev/null; then
    market_data_clock="${current_market_data_clock}"
  elif [[ "${resume_completed_cycle}" == "true" ]] \
      && printf '%s' "${current_market_data_clock}" | "${JQ_BIN}" -e \
        '.data.postClosePhase == "COMPLETED"
          and .data.postCloseStatus == "COMPLETED"
          and .data.marketOpenReady == true
          and (.data.availableJumpActions | index("NEXT_AUTO_MARKET_PREPARATION_START") != null)' \
        >/dev/null; then
    market_data_clock="${current_market_data_clock}"
    printf 'PASS completed replay cycle already contains market-data preparation simulationDateTime=%s\n' \
      "$(clock_value "${market_data_clock}" '.data.simulationDateTime')"
  else
    market_data_clock="$(wait_for_clock \
      'market-data preparation' \
      '.data.postClosePhase == "MARKET_DATA_PREPARED"
        and .data.postCloseStatus == "PENDING"
        and (.data.availableJumpActions | index("NEXT_AUTO_MARKET_PREPARATION_START") != null)')"
  fi
  printf 'PASS market data prepared simulationDateTime=%s\n' \
    "$(clock_value "${market_data_clock}" '.data.simulationDateTime')"

  if [[ "${STOP_AFTER_MARKET_DATA}" == "true" ]]; then
    printf 'PASS EOD advance stopped after market-data preparation closedDate=%s preparingDate=%s phase=MARKET_DATA_PREPARED\n' \
      "${closing_date}" \
      "$(clock_value "${market_data_clock}" '.data.preparingBusinessDate')"
    exit 0
  fi

  jump_and_require_post_state \
    'auto-market preparation start' \
    'NEXT_AUTO_MARKET_PREPARATION_START' \
    '.data.marketSession == "PRE_OPEN"
      and (.data.simulationDateTime | endswith("T05:30:00"))'
fi

current_ready_clock="$(clock_response)"
require_success_json 'market-open readiness current clock' "${current_ready_clock}"
if ! printf '%s' "${current_ready_clock}" | "${JQ_BIN}" -e \
    '.data.marketSession == "PRE_OPEN"
      and (.data.simulationDateTime | endswith("T05:30:00"))' >/dev/null; then
  printf 'FAIL EOD advance reached an unsupported resumable state response=%s\n' \
    "${current_ready_clock}" >&2
  exit 1
fi

if [[ "${resume_completed_cycle}" == "true" ]] \
    && printf '%s' "${current_ready_clock}" | "${JQ_BIN}" -e \
      '.data.postClosePhase == "COMPLETED"
        and .data.postCloseStatus == "COMPLETED"
        and .data.marketOpenReady == true
        and (.data.availableJumpActions | index("NEXT_MARKET_OPEN") != null)' \
      >/dev/null; then
  ready_clock="${current_ready_clock}"
  printf 'PASS completed replay cycle already contains market-open readiness simulationDateTime=%s\n' \
    "$(clock_value "${ready_clock}" '.data.simulationDateTime')"
else
  ready_clock="$(wait_for_clock \
    'market-open readiness' \
    '.data.postClosePhase == "READY_TO_OPEN"
      and .data.postCloseStatus == "PENDING"
      and .data.marketOpenReady == true
      and (.data.availableJumpActions | index("NEXT_MARKET_OPEN") != null)')"
fi
next_business_date="$(clock_value "${ready_clock}" '.data.preparingBusinessDate')"
if [[ -z "${next_business_date}" || "${next_business_date}" == "null" ]]; then
  printf 'FAIL preparing business date is missing before market open\n' >&2
  exit 1
fi
printf 'PASS market open ready nextBusinessDate=%s\n' "${next_business_date}"

jump_and_require_post_state \
  'next market open' \
  'NEXT_MARKET_OPEN' \
  '.data.marketSession == "REGULAR"
    and (.data.simulationDateTime | endswith("T06:00:00"))'

opened_clock="$(wait_for_clock \
  'business-date promotion' \
  '.data.marketSession == "REGULAR"
    and .data.activeBusinessDate == .data.simulationDate
    and .data.preparingBusinessDate == null
    and .data.postClosePhase == null
    and .data.postCloseStatus == null
    and .data.marketOpenReady == true
    and .data.running == false')"
opened_date="$(clock_value "${opened_clock}" '.data.activeBusinessDate')"
if [[ "${opened_date}" != "${next_business_date}" ]]; then
  printf 'FAIL opened business date mismatch expected=%s actual=%s\n' \
    "${next_business_date}" "${opened_date}" >&2
  exit 1
fi

printf 'PASS EOD advance complete closedDate=%s openedDate=%s simulationDateTime=%s\n' \
  "${closing_date}" "${opened_date}" \
  "$(clock_value "${opened_clock}" '.data.simulationDateTime')"
