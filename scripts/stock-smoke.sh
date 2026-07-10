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

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
STOCK_BACK_URL="${STOCK_BACK_URL:-http://localhost:20480}"
STOCK_BATCH_URL="${STOCK_BATCH_URL:-http://localhost:20481}"
EUREKA_URL="${EUREKA_URL:-http://localhost:8761}"
STOCK_ACCESS_TOKEN="${STOCK_ACCESS_TOKEN:-}"
STOCK_BATCH_INTERNAL_TOKEN="${STOCK_BATCH_INTERNAL_TOKEN:-local-stock-batch-internal-token}"
STOCK_SMOKE_RUN_BATCH_JOBS="${STOCK_SMOKE_RUN_BATCH_JOBS:-false}"
STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS="${STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS:-false}"
STOCK_SMOKE_GATEWAY_ID="${STOCK_SMOKE_GATEWAY_ID:-stock-smoke-gateway}"
ZEROQ_GATEWAY_SHARED_SECRET="${ZEROQ_GATEWAY_SHARED_SECRET:-}"
STOCK_SMOKE_PLACE_ORDER="${STOCK_SMOKE_PLACE_ORDER:-false}"
STOCK_SMOKE_EXPECT_SEEDED_MARKET="${STOCK_SMOKE_EXPECT_SEEDED_MARKET:-false}"
STOCK_SMOKE_SYMBOL="${STOCK_SMOKE_SYMBOL:-}"
STOCK_SMOKE_LIMIT_PRICE="${STOCK_SMOKE_LIMIT_PRICE:-70000}"
STOCK_SMOKE_QUANTITY="${STOCK_SMOKE_QUANTITY:-1}"
STOCK_SMOKE_RUN_ID="${STOCK_SMOKE_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
STOCK_SMOKE_CLIENT_ORDER_ID="${STOCK_SMOKE_CLIENT_ORDER_ID:-stock-smoke-${STOCK_SMOKE_SYMBOL}-${STOCK_SMOKE_RUN_ID}}"

failures=0

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 127
  fi
}

request_path_from_url() {
  local url="$1"
  local without_scheme path

  without_scheme="${url#*://}"
  if [[ "${without_scheme}" == "${url}" ]]; then
    path="${url}"
  else
    path="/${without_scheme#*/}"
  fi
  [[ "${path}" == "/"* ]] || path="/${path}"
  printf '%s' "${path}"
}

gateway_signature() {
  local method="$1"
  local request_path="$2"
  local timestamp="$3"
  local nonce="$4"
  local signature

  signature="$(printf '%s\n%s\n%s\n%s\n%s' \
    "${STOCK_SMOKE_GATEWAY_ID}" \
    "${method}" \
    "${request_path}" \
    "${timestamp}" \
    "${nonce}" |
    openssl dgst -sha256 -hmac "${ZEROQ_GATEWAY_SHARED_SECRET}" -hex)"
  printf '%s' "${signature##* }"
}

gateway_headers_for() {
  local method="$1"
  local url="$2"
  local request_path timestamp nonce signature

  request_path="$(request_path_from_url "${url}")"
  timestamp="$(date +%s)000"
  nonce="${STOCK_SMOKE_RUN_ID}-${RANDOM}-${RANDOM}"
  signature="$(gateway_signature "${method}" "${request_path}" "${timestamp}" "${nonce}")"

  printf '%s\n' \
    "-H" "X-Gateway-Id: ${STOCK_SMOKE_GATEWAY_ID}" \
    "-H" "X-Gateway-Timestamp: ${timestamp}" \
    "-H" "X-Gateway-Nonce: ${nonce}" \
    "-H" "X-Gateway-Signature: ${signature}"
}

request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local headers=()

  if [[ -n "${STOCK_ACCESS_TOKEN}" ]]; then
    headers+=(-H "Authorization: Bearer ${STOCK_ACCESS_TOKEN}")
  fi
  if [[ -n "${STOCK_BATCH_INTERNAL_TOKEN}" && "${url}" == "${STOCK_BATCH_URL}/internal/stock-batch/v1/jobs/"* ]]; then
    headers+=(-H "X-Internal-Token: ${STOCK_BATCH_INTERNAL_TOKEN}")
  fi

  if [[ -n "${body}" ]]; then
    if ((${#headers[@]} > 0)); then
      curl -sS -X "${method}" "${url}" \
        -H "Content-Type: application/json" \
        "${headers[@]}" \
        --data "${body}"
    else
      curl -sS -X "${method}" "${url}" \
        -H "Content-Type: application/json" \
        --data "${body}"
    fi
    return
  fi

  if ((${#headers[@]} > 0)); then
    curl -sS -X "${method}" "${url}" "${headers[@]}"
    return
  fi

  curl -sS -X "${method}" "${url}"
}

request_with_headers() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  shift 3
  local headers=("$@")

  if [[ -n "${body}" ]]; then
    curl -sS -X "${method}" "${url}" \
      -H "Content-Type: application/json" \
      "${headers[@]}" \
      --data "${body}"
    return
  fi

  curl -sS -X "${method}" "${url}" "${headers[@]}"
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
  if ((${#headers[@]} > 0)); then
    response="$(request_with_headers "${method}" "${url}" "${body}" "${headers[@]}")" || {
      echo "FAIL ${label}: request failed"
      failures=$((failures + 1))
      return
    }
  elif ! response="$(request "${method}" "${url}" "${body}")"; then
    echo "FAIL ${label}: request failed"
    failures=$((failures + 1))
    return
  fi

  if [[ "${response}" == *"${expected}"* ]]; then
    echo "PASS ${label}"
    return
  fi

  echo "FAIL ${label}: expected '${expected}'"
  echo "${response}"
  failures=$((failures + 1))
}

extract_data_id() {
  node -e '
const input = process.argv[1];
try {
  const parsed = JSON.parse(input);
  const id = parsed?.data?.id;
  if (Number.isInteger(id) || typeof id === "string") {
    process.stdout.write(String(id));
  }
} catch {}
' "$1"
}

require_command curl
if [[ "${STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS}" == "true" ]]; then
  require_command openssl
  if [[ -z "${ZEROQ_GATEWAY_SHARED_SECRET}" ]]; then
    echo "missing env: ZEROQ_GATEWAY_SHARED_SECRET is required for gateway batch job smoke" >&2
    exit 2
  fi
fi
if [[ "${STOCK_SMOKE_PLACE_ORDER}" == "true" ]]; then
  require_command node
fi
if [[ ("${STOCK_SMOKE_EXPECT_SEEDED_MARKET}" == "true" || "${STOCK_SMOKE_PLACE_ORDER}" == "true") && -z "${STOCK_SMOKE_SYMBOL}" ]]; then
  echo "missing env: STOCK_SMOKE_SYMBOL is required when seeded market or order placement smoke checks are enabled" >&2
  exit 2
fi

check_contains "eureka page" "GET" "${EUREKA_URL}" "Eureka"
check_contains "stock-back status direct" "GET" "${STOCK_BACK_URL}/api/stock/v1/system/status" "stock-back-service"
check_contains "stock-batch status direct" "GET" "${STOCK_BATCH_URL}/internal/stock-batch/v1/system/status" "stock-batch-service"

if [[ "${STOCK_SMOKE_RUN_BATCH_JOBS}" == "true" ]]; then
  check_contains "stock-batch market data job direct" "POST" "${STOCK_BATCH_URL}/internal/stock-batch/v1/jobs/market-data/refresh" "COMPLETED"
  check_contains "stock-batch order book execution job direct" "POST" "${STOCK_BATCH_URL}/internal/stock-batch/v1/jobs/order-book-execution/run" "COMPLETED"
  check_contains "stock-batch portfolio settlement job direct" "POST" "${STOCK_BATCH_URL}/internal/stock-batch/v1/jobs/portfolio-settlement/run" "COMPLETED"
fi

if [[ "${STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS}" == "true" ]]; then
  for job_path in \
    "/internal/stock-batch/v1/jobs/market-data/refresh" \
    "/internal/stock-batch/v1/jobs/order-book-execution/run" \
    "/internal/stock-batch/v1/jobs/portfolio-settlement/run"; do
    gateway_headers=()
    while IFS= read -r header_arg; do
      gateway_headers+=("${header_arg}")
    done < <(gateway_headers_for "POST" "${GATEWAY_URL}${job_path}")
    check_contains "stock-batch job through gateway ${job_path##*/}" "POST" "${GATEWAY_URL}${job_path}" "COMPLETED" "" "${gateway_headers[@]}"
  done

  gateway_headers=()
  while IFS= read -r header_arg; do
    gateway_headers+=("${header_arg}")
  done < <(gateway_headers_for "GET" "${GATEWAY_URL}/internal/stock-batch/v1/jobs/runtime-controls")
  check_contains "stock-batch runtime controls through gateway" "GET" "${GATEWAY_URL}/internal/stock-batch/v1/jobs/runtime-controls" "auto-market" "" "${gateway_headers[@]}"

  gateway_headers=()
  while IFS= read -r header_arg; do
    gateway_headers+=("${header_arg}")
  done < <(gateway_headers_for "PATCH" "${GATEWAY_URL}/internal/stock-batch/v1/jobs/runtime-controls/%20")
  check_contains "stock-batch runtime control validation through gateway" "PATCH" "${GATEWAY_URL}/internal/stock-batch/v1/jobs/runtime-controls/%20" "jobName is required" '{"runtimeEnabled":true,"updatedBy":"stock-smoke"}' "${gateway_headers[@]}"
fi

check_contains "stock instruments through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/markets/instruments" "success"
check_contains "stock prices through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/markets/prices" "success"
check_contains "stock rankings through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/markets/rankings" "success"
if [[ "${STOCK_SMOKE_EXPECT_SEEDED_MARKET}" == "true" ]]; then
  check_contains "stock seeded instrument through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/markets/instruments" "${STOCK_SMOKE_SYMBOL}"
  check_contains "stock ticks through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/markets/prices/${STOCK_SMOKE_SYMBOL}/ticks" "success"
  check_contains "stock order book through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/markets/order-books/${STOCK_SMOKE_SYMBOL}" "bids"
fi

if [[ -n "${STOCK_ACCESS_TOKEN}" ]]; then
  check_contains "stock user profile through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/users/me" "userKey"
  check_contains "stock account through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/accounts/me" "cashBalance"
  check_contains "stock portfolio through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/portfolio/me" "totalAsset"
  check_contains "stock holdings through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/holdings" "success"
  check_contains "stock portfolio snapshots through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/portfolio/me/snapshots" "success"
  check_contains "stock orders through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/orders" "success"
  check_contains "stock executions through gateway" "GET" "${GATEWAY_URL}/api/stock/v1/executions" "success"

  if [[ "${STOCK_SMOKE_PLACE_ORDER}" == "true" ]]; then
    order_body="{\"symbol\":\"${STOCK_SMOKE_SYMBOL}\",\"side\":\"BUY\",\"orderType\":\"LIMIT\",\"limitPrice\":${STOCK_SMOKE_LIMIT_PRICE},\"quantity\":${STOCK_SMOKE_QUANTITY},\"clientOrderId\":\"${STOCK_SMOKE_CLIENT_ORDER_ID}\"}"
    echo "==> stock place order through gateway"
    order_response="$(request "POST" "${GATEWAY_URL}/api/stock/v1/orders" "${order_body}")" || {
      echo "FAIL stock place order through gateway: request failed"
      failures=$((failures + 1))
      order_response=""
    }
    if [[ "${order_response}" == *"Order accepted"* ]]; then
      echo "PASS stock place order through gateway"
    else
      echo "FAIL stock place order through gateway: expected 'Order accepted'"
      echo "${order_response}"
      failures=$((failures + 1))
    fi
    order_id="$(extract_data_id "${order_response}")"
    check_contains "stock place duplicate order through gateway" "POST" "${GATEWAY_URL}/api/stock/v1/orders" "${STOCK_SMOKE_CLIENT_ORDER_ID}" "${order_body}"
    if [[ -n "${order_id}" ]]; then
      check_contains "stock cancel order through gateway" "DELETE" "${GATEWAY_URL}/api/stock/v1/orders/${order_id}" "Order cancelled"
    else
      echo "FAIL stock cancel order through gateway: order id was not returned"
      failures=$((failures + 1))
    fi
  fi
else
  echo "SKIP authenticated stock checks: set STOCK_ACCESS_TOKEN to enable"
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "stock smoke failed: ${failures} check(s)"
  exit 1
fi

echo "stock smoke passed"
