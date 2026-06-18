#!/usr/bin/env bash
set -Eeuo pipefail

load_dotenv() {
  local env_file="${1:-.env}"
  local line key value

  if [[ ! -f "${env_file}" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" == \#* || "${line}" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    fi
  done <"${env_file}"
}

load_dotenv ".env"

STOCK_BACK_URL="${STOCK_H2_BACK_URL:-http://localhost:30480}"
STOCK_BATCH_URL="${STOCK_H2_BATCH_URL:-http://localhost:30481}"
STOCK_BATCH_INTERNAL_PORT="${STOCK_H2_BATCH_INTERNAL_PORT:-30482}"
STOCK_BATCH_INTERNAL_URL="${STOCK_H2_BATCH_INTERNAL_URL:-http://localhost:${STOCK_BATCH_INTERNAL_PORT}}"
STOCK_SMOKE_USER_KEY="${STOCK_SMOKE_USER_KEY:-h2-smoke-user}"
STOCK_SMOKE_SYMBOL="${STOCK_SMOKE_SYMBOL:-005930}"
STOCK_SMOKE_TIMEOUT_SECONDS="${STOCK_SMOKE_TIMEOUT_SECONDS:-40}"
STOCK_SMOKE_LOG_DIR="${STOCK_SMOKE_LOG_DIR:-artifacts/stock-h2-smoke}"

failures=0
back_pid=""
batch_pid=""

mkdir -p "${STOCK_SMOKE_LOG_DIR}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 127
  fi
}

cleanup() {
  if [[ -n "${back_pid}" ]] && kill -0 "${back_pid}" >/dev/null 2>&1; then
    kill "${back_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${batch_pid}" ]] && kill -0 "${batch_pid}" >/dev/null 2>&1; then
    kill "${batch_pid}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

wait_for_contains() {
  local label="$1"
  local url="$2"
  local expected="$3"
  local deadline
  local response

  deadline=$((SECONDS + STOCK_SMOKE_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    if response="$(curl -sS "${url}" 2>/dev/null)" && [[ "${response}" == *"${expected}"* ]]; then
      echo "PASS ${label}"
      return 0
    fi
    sleep 1
  done

  echo "FAIL ${label}: timed out waiting for ${url}"
  failures=$((failures + 1))
}

request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local headers=()

  if (($# >= 4)); then
    headers=("${@:4}")
  fi

  if [[ -n "${body}" ]]; then
    if ((${#headers[@]} > 0)); then
      curl -sS -X "${method}" "${url}" \
        -H "Content-Type: application/json" \
        "${headers[@]}" \
        --data "${body}"
      return
    fi

    curl -sS -X "${method}" "${url}" \
      -H "Content-Type: application/json" \
      --data "${body}"
    return
  fi

  if ((${#headers[@]} > 0)); then
    curl -sS -X "${method}" "${url}" "${headers[@]}"
    return
  fi

  curl -sS -X "${method}" "${url}"
}

check_contains() {
  local label="$1"
  local method="$2"
  local url="$3"
  local expected="$4"
  local body="${5:-}"
  local headers=()
  local response

  if (($# >= 6)); then
    headers=("${@:6}")
  fi

  echo "==> ${label}"
  if (($# >= 6)); then
    response="$(request "${method}" "${url}" "${body}" "${headers[@]}")" || {
      echo "FAIL ${label}: request failed"
      failures=$((failures + 1))
      return
    }
  else
    response="$(request "${method}" "${url}" "${body}")" || {
      echo "FAIL ${label}: request failed"
      failures=$((failures + 1))
      return
    }
  fi

  if [[ "${response}" == *"${expected}"* ]]; then
    echo "PASS ${label}"
    return
  fi

  echo "FAIL ${label}: expected '${expected}'"
  echo "${response}"
  failures=$((failures + 1))
}

check_status_code() {
  local label="$1"
  local url="$2"
  local expected_status="$3"
  local status

  echo "==> ${label}"
  status="$(curl -sS -o /dev/null -w '%{http_code}' "${url}")"
  if [[ "${status}" == "${expected_status}" ]]; then
    echo "PASS ${label}"
    return
  fi

  echo "FAIL ${label}: expected HTTP ${expected_status}, got ${status}"
  failures=$((failures + 1))
}

require_command curl
require_command ./gradlew

echo "==> starting stock-back-service test profile"
./gradlew :stock-back-service:bootRun --args='--spring.profiles.active=test,smoke' \
  >"${STOCK_SMOKE_LOG_DIR}/stock-back-service.log" 2>&1 &
back_pid="$!"
wait_for_contains "stock-back started" "${STOCK_BACK_URL}/api/stock/v1/system/status" "stock-back-service"

check_contains "stock-back public prices" "GET" "${STOCK_BACK_URL}/api/stock/v1/markets/prices" "currentPrice"
check_contains "stock-back public instruments" "GET" "${STOCK_BACK_URL}/api/stock/v1/markets/instruments" "${STOCK_SMOKE_SYMBOL}"
check_contains "stock-back public price ticks" "GET" "${STOCK_BACK_URL}/api/stock/v1/markets/prices/${STOCK_SMOKE_SYMBOL}/ticks" "success"
check_contains "stock-back public order book" "GET" "${STOCK_BACK_URL}/api/stock/v1/markets/order-books/${STOCK_SMOKE_SYMBOL}" "bids"
check_contains "stock-back public rankings" "GET" "${STOCK_BACK_URL}/api/stock/v1/markets/rankings" "success"
check_status_code "stock-back protected portfolio without principal" "${STOCK_BACK_URL}/api/stock/v1/portfolio/me" "401"
check_contains "stock-back user profile with auth fallback" "GET" "${STOCK_BACK_URL}/api/stock/v1/users/me" "${STOCK_SMOKE_USER_KEY}" "" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Name: h2-smoke" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back account with user principal" "GET" "${STOCK_BACK_URL}/api/stock/v1/accounts/me" "cashBalance" "" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back portfolio with user principal" "GET" "${STOCK_BACK_URL}/api/stock/v1/portfolio/me" "totalAsset" "" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back holdings with user principal" "GET" "${STOCK_BACK_URL}/api/stock/v1/holdings" "success" "" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back market order ignores non-positive limit" "POST" "${STOCK_BACK_URL}/api/stock/v1/orders" "\"limitPrice\":null" \
  "{\"symbol\":\"${STOCK_SMOKE_SYMBOL}\",\"side\":\"BUY\",\"orderType\":\"MARKET\",\"limitPrice\":0,\"quantity\":1}" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back idempotent order with client order id" "POST" "${STOCK_BACK_URL}/api/stock/v1/orders" "\"clientOrderId\":\"h2-smoke-idempotent-order\"" \
  "{\"symbol\":\"${STOCK_SMOKE_SYMBOL}\",\"side\":\"BUY\",\"orderType\":\"LIMIT\",\"limitPrice\":70000,\"quantity\":1,\"clientOrderId\":\"h2-smoke-idempotent-order\"}" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back duplicate idempotent order returns existing order" "POST" "${STOCK_BACK_URL}/api/stock/v1/orders" "\"clientOrderId\":\"h2-smoke-idempotent-order\"" \
  "{\"symbol\":\"${STOCK_SMOKE_SYMBOL}\",\"side\":\"BUY\",\"orderType\":\"LIMIT\",\"limitPrice\":71000,\"quantity\":2,\"clientOrderId\":\"h2-smoke-idempotent-order\"}" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back orders with user principal" "GET" "${STOCK_BACK_URL}/api/stock/v1/orders" "${STOCK_SMOKE_SYMBOL}" "" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back executions with user principal" "GET" "${STOCK_BACK_URL}/api/stock/v1/executions" "success" "" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"
check_contains "stock-back portfolio snapshots with user principal" "GET" "${STOCK_BACK_URL}/api/stock/v1/portfolio/me/snapshots" "success" "" \
  -H "X-User-Key: ${STOCK_SMOKE_USER_KEY}" \
  -H "X-User-Role: ROLE_USER"

echo "==> stopping stock-back-service"
if kill -0 "${back_pid}" >/dev/null 2>&1; then
  kill "${back_pid}" >/dev/null 2>&1 || true
  wait "${back_pid}" >/dev/null 2>&1 || true
fi
back_pid=""

echo "==> starting stock-batch-service test profile"
./gradlew :stock-batch-service:bootRun --args='--spring.profiles.active=test,smoke' \
  >"${STOCK_SMOKE_LOG_DIR}/stock-batch-service.log" 2>&1 &
batch_pid="$!"
wait_for_contains "stock-batch started" "${STOCK_BATCH_URL}/internal/stock-batch/v1/system/status" "stock-batch-service"

check_contains "stock-batch market data job" "POST" "${STOCK_BATCH_URL}/internal/stock-batch/v1/jobs/market-data/refresh" "\"processedCount\":1"
check_contains "stock-batch order execution job" "POST" "${STOCK_BATCH_URL}/internal/stock-batch/v1/jobs/order-execution/run" "\"processedCount\":1"
check_contains "stock-batch portfolio settlement job" "POST" "${STOCK_BATCH_URL}/internal/stock-batch/v1/jobs/portfolio-settlement/run" "\"processedCount\":2"

if kill -0 "${batch_pid}" >/dev/null 2>&1; then
  kill "${batch_pid}" >/dev/null 2>&1 || true
  wait "${batch_pid}" >/dev/null 2>&1 || true
fi
batch_pid=""

echo "==> starting stock-batch-service internal order book smoke"
./gradlew :stock-batch-service:bootRun --args="--spring.profiles.active=test,smoke --server.port=${STOCK_BATCH_INTERNAL_PORT} --stock.batch.execution.mode=internal-order-book" \
  >"${STOCK_SMOKE_LOG_DIR}/stock-batch-service-internal-order-book.log" 2>&1 &
batch_pid="$!"
wait_for_contains "stock-batch internal order book started" "${STOCK_BATCH_INTERNAL_URL}/internal/stock-batch/v1/system/status" "stock-batch-service"

check_contains "stock-batch internal order book execution job" "POST" "${STOCK_BATCH_INTERNAL_URL}/internal/stock-batch/v1/jobs/order-execution/run" "\"processedCount\":1"

if [[ "${failures}" -gt 0 ]]; then
  echo "stock H2 smoke failed: ${failures} check(s)"
  echo "logs: ${STOCK_SMOKE_LOG_DIR}"
  exit 1
fi

echo "stock H2 smoke passed"
echo "logs: ${STOCK_SMOKE_LOG_DIR}"
