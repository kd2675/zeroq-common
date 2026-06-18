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

STOCK_GATEWAY_H2_LOG_DIR="${STOCK_GATEWAY_H2_LOG_DIR:-artifacts/stock-gateway-h2-smoke}"
STOCK_GATEWAY_H2_TIMEOUT_SECONDS="${STOCK_GATEWAY_H2_TIMEOUT_SECONDS:-90}"
STOCK_GATEWAY_H2_JWT_SECRET="${STOCK_GATEWAY_H2_JWT_SECRET:-stock-gateway-h2-smoke-jwt-secret-hs512-minimum-length-64-chars-1234567890}"
STOCK_GATEWAY_H2_BATCH_TOKEN="${STOCK_GATEWAY_H2_BATCH_TOKEN:-stock-gateway-h2-smoke-internal-token}"
STOCK_GATEWAY_H2_SHARED_SECRET="${STOCK_GATEWAY_H2_SHARED_SECRET:-stock-gateway-h2-smoke-shared-secret}"
STOCK_GATEWAY_H2_USER="${STOCK_GATEWAY_H2_USER:-stock-gateway-h2-${RANDOM}-${RANDOM}}"
STOCK_GATEWAY_H2_PASSWORD="${STOCK_GATEWAY_H2_PASSWORD:-stock-gateway-h2-password}"
STOCK_GATEWAY_H2_EMAIL="${STOCK_GATEWAY_H2_EMAIL:-${STOCK_GATEWAY_H2_USER}@example.com}"

export AUTH_JWT_SECRET="${AUTH_JWT_SECRET:-${STOCK_GATEWAY_H2_JWT_SECRET}}"
export CLOUD_JWT_SECRET="${CLOUD_JWT_SECRET:-${STOCK_GATEWAY_H2_JWT_SECRET}}"
export NAVER_CLIENT_ID="${NAVER_CLIENT_ID:-stock-smoke-naver-client}"
export NAVER_CLIENT_SECRET="${NAVER_CLIENT_SECRET:-stock-smoke-naver-secret}"
export KAKAO_CLIENT_ID="${KAKAO_CLIENT_ID:-stock-smoke-kakao-client}"
export KAKAO_CLIENT_SECRET="${KAKAO_CLIENT_SECRET:-stock-smoke-kakao-secret}"
export STOCK_BATCH_INTERNAL_TOKEN="${STOCK_BATCH_INTERNAL_TOKEN:-${STOCK_GATEWAY_H2_BATCH_TOKEN}}"
export ZEROQ_GATEWAY_SHARED_SECRET="${ZEROQ_GATEWAY_SHARED_SECRET:-${STOCK_GATEWAY_H2_SHARED_SECRET}}"
export STOCK_SMOKE_RUN_BATCH_JOBS="${STOCK_SMOKE_RUN_BATCH_JOBS:-true}"
export STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS="${STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS:-true}"
export STOCK_SMOKE_PLACE_ORDER="${STOCK_SMOKE_PLACE_ORDER:-true}"

EUREKA_URL="${EUREKA_URL:-http://localhost:8761}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
STOCK_BACK_URL="${STOCK_H2_BACK_URL:-http://localhost:30480}"
STOCK_BATCH_URL="${STOCK_H2_BATCH_URL:-http://localhost:30481}"

failures=0
eureka_pid=""
auth_pid=""
cloud_pid=""
back_pid=""
batch_pid=""
cookie_jar=""

mkdir -p "${STOCK_GATEWAY_H2_LOG_DIR}"
cookie_jar="${STOCK_GATEWAY_H2_LOG_DIR}/cookies.txt"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 127
  fi
}

cleanup() {
  for pid in "${cloud_pid}" "${batch_pid}" "${back_pid}" "${auth_pid}" "${eureka_pid}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
    fi
  done
}

trap cleanup EXIT

wait_for_contains() {
  local label="$1"
  local url="$2"
  local expected="$3"
  local deadline response

  deadline=$((SECONDS + STOCK_GATEWAY_H2_TIMEOUT_SECONDS))
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

wait_for_eureka_app() {
  local label="$1"
  local app_name="$2"
  local deadline response status body

  deadline=$((SECONDS + STOCK_GATEWAY_H2_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    if response="$(curl -sS -H "Accept: application/json" -w $'\n%{http_code}' "${EUREKA_URL}/eureka/apps/${app_name}" 2>/dev/null)"; then
      status="${response##*$'\n'}"
      body="${response%$'\n'*}"
      if [[ "${status}" == "200" && "${body}" == *"\"name\":\"${app_name}\""* && "${body}" == *"\"status\":\"UP\""* ]]; then
        echo "PASS ${label}"
        return 0
      fi
    fi
    sleep 1
  done

  echo "FAIL ${label}: timed out waiting for Eureka app ${app_name}"
  failures=$((failures + 1))
}

require_command curl
require_command ./gradlew
require_command openssl
require_command node

extract_access_token() {
  node -e '
const input = process.argv[1];
try {
  const parsed = JSON.parse(input);
  const token = parsed?.data?.accessToken;
  if (typeof token === "string" && token.length > 0) {
    process.stdout.write(token);
  }
} catch {}
' "$1"
}

check_contains() {
  local label="$1"
  local response="$2"
  local expected="$3"

  if [[ "${response}" == *"${expected}"* ]]; then
    echo "PASS ${label}"
    return
  fi

  echo "FAIL ${label}: expected '${expected}'"
  echo "${response}"
  failures=$((failures + 1))
}

echo "==> starting Eureka"
./gradlew :eureka-back-server:bootRun \
  >"${STOCK_GATEWAY_H2_LOG_DIR}/eureka-back-server.log" 2>&1 &
eureka_pid="$!"
wait_for_contains "eureka started" "${EUREKA_URL}" "Eureka"

echo "==> starting auth-back-server H2 smoke profile"
./gradlew :auth-back-server:bootRun --args='--spring.profiles.active=test,smoke' \
  >"${STOCK_GATEWAY_H2_LOG_DIR}/auth-back-server.log" 2>&1 &
auth_pid="$!"
wait_for_eureka_app "auth-back registered in eureka" "AUTH-BACK-SERVER"

echo "==> starting stock-back-service H2 smoke profile with Eureka"
./gradlew :stock-back-service:bootRun --args='--spring.profiles.active=test,smoke --spring.cloud.discovery.enabled=true --eureka.client.enabled=true --eureka.client.register-with-eureka=true --eureka.client.fetch-registry=true' \
  >"${STOCK_GATEWAY_H2_LOG_DIR}/stock-back-service.log" 2>&1 &
back_pid="$!"
wait_for_contains "stock-back started" "${STOCK_BACK_URL}/api/stock/v1/system/status" "stock-back-service"
wait_for_eureka_app "stock-back registered in eureka" "STOCK-BACK-SERVICE"

echo "==> starting stock-batch-service H2 smoke profile with Eureka"
./gradlew :stock-batch-service:bootRun --args="--spring.profiles.active=test,smoke --spring.cloud.discovery.enabled=true --eureka.client.enabled=true --eureka.client.register-with-eureka=true --eureka.client.fetch-registry=true --stock.batch.internal.allow-empty-token=false --stock.batch.internal.token=${STOCK_BATCH_INTERNAL_TOKEN}" \
  >"${STOCK_GATEWAY_H2_LOG_DIR}/stock-batch-service.log" 2>&1 &
batch_pid="$!"
wait_for_contains "stock-batch started" "${STOCK_BATCH_URL}/internal/stock-batch/v1/system/status" "stock-batch-service"
wait_for_eureka_app "stock-batch registered in eureka" "STOCK-BATCH-SERVICE"

echo "==> starting cloud-back-server"
./gradlew :cloud-back-server:bootRun \
  >"${STOCK_GATEWAY_H2_LOG_DIR}/cloud-back-server.log" 2>&1 &
cloud_pid="$!"
wait_for_eureka_app "cloud gateway registered in eureka" "CLOUD-BACK-SERVER"
wait_for_contains "stock-back route through gateway ready" "${GATEWAY_URL}/api/stock/v1/system/status" "stock-back-service"

echo "==> creating stock user through gateway"
signup_body="{\"username\":\"${STOCK_GATEWAY_H2_USER}\",\"password\":\"${STOCK_GATEWAY_H2_PASSWORD}\",\"email\":\"${STOCK_GATEWAY_H2_EMAIL}\",\"role\":\"USER\"}"
signup_response="$(curl -sS -X POST "${GATEWAY_URL}/api/users" \
  -H "Content-Type: application/json" \
  --data "${signup_body}")"
check_contains "stock signup through gateway" "${signup_response}" "User created successfully"

echo "==> logging in stock user through gateway"
login_body="{\"username\":\"${STOCK_GATEWAY_H2_USER}\",\"password\":\"${STOCK_GATEWAY_H2_PASSWORD}\"}"
login_response="$(curl -sS -X POST "${GATEWAY_URL}/auth/login" \
  -H "Content-Type: application/json" \
  -H "X-Client-Id: stock-front-service" \
  -c "${cookie_jar}" \
  --data "${login_body}")"
access_token="$(extract_access_token "${login_response}")"
if [[ -z "${access_token}" ]]; then
  echo "FAIL stock login through gateway"
  echo "${login_response}"
  failures=$((failures + 1))
else
  echo "PASS stock login through gateway"
  export STOCK_ACCESS_TOKEN="${access_token}"
fi

echo "==> running stock smoke through H2 gateway services"
GATEWAY_URL="${GATEWAY_URL}" \
STOCK_BACK_URL="${STOCK_BACK_URL}" \
STOCK_BATCH_URL="${STOCK_BATCH_URL}" \
EUREKA_URL="${EUREKA_URL}" \
scripts/stock-smoke.sh

if [[ "${failures}" -gt 0 ]]; then
  echo "stock gateway H2 smoke failed: ${failures} check(s)"
  echo "logs: ${STOCK_GATEWAY_H2_LOG_DIR}"
  exit 1
fi

echo "stock gateway H2 smoke passed"
echo "logs: ${STOCK_GATEWAY_H2_LOG_DIR}"
