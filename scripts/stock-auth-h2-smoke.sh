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

STOCK_AUTH_SMOKE_LOG_DIR="${STOCK_AUTH_SMOKE_LOG_DIR:-artifacts/stock-auth-h2-smoke}"
STOCK_AUTH_SMOKE_TIMEOUT_SECONDS="${STOCK_AUTH_SMOKE_TIMEOUT_SECONDS:-90}"
STOCK_AUTH_SMOKE_USER="${STOCK_AUTH_SMOKE_USER:-stock-auth-smoke-${RANDOM}-${RANDOM}}"
STOCK_AUTH_SMOKE_PASSWORD="${STOCK_AUTH_SMOKE_PASSWORD:-stock-auth-smoke-password}"
STOCK_AUTH_SMOKE_EMAIL="${STOCK_AUTH_SMOKE_EMAIL:-${STOCK_AUTH_SMOKE_USER}@example.com}"
STOCK_AUTH_SMOKE_JWT_SECRET="${STOCK_AUTH_SMOKE_JWT_SECRET:-stock-auth-h2-smoke-jwt-secret-hs512-minimum-length-64-chars-1234567890}"

export AUTH_JWT_SECRET="${AUTH_JWT_SECRET:-${STOCK_AUTH_SMOKE_JWT_SECRET}}"
export CLOUD_JWT_SECRET="${CLOUD_JWT_SECRET:-${STOCK_AUTH_SMOKE_JWT_SECRET}}"
export NAVER_CLIENT_ID="${NAVER_CLIENT_ID:-stock-smoke-naver-client}"
export NAVER_CLIENT_SECRET="${NAVER_CLIENT_SECRET:-stock-smoke-naver-secret}"
export KAKAO_CLIENT_ID="${KAKAO_CLIENT_ID:-stock-smoke-kakao-client}"
export KAKAO_CLIENT_SECRET="${KAKAO_CLIENT_SECRET:-stock-smoke-kakao-secret}"

EUREKA_URL="${EUREKA_URL:-http://localhost:8761}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"

failures=0
eureka_pid=""
auth_pid=""
cloud_pid=""
cookie_jar=""

mkdir -p "${STOCK_AUTH_SMOKE_LOG_DIR}"
cookie_jar="${STOCK_AUTH_SMOKE_LOG_DIR}/cookies.txt"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 127
  fi
}

cleanup() {
  for pid in "${cloud_pid}" "${auth_pid}" "${eureka_pid}"; do
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

  deadline=$((SECONDS + STOCK_AUTH_SMOKE_TIMEOUT_SECONDS))
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

  deadline=$((SECONDS + STOCK_AUTH_SMOKE_TIMEOUT_SECONDS))
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

require_command curl
require_command node
require_command ./gradlew

echo "==> starting Eureka"
./gradlew :eureka-back-server:bootRun \
  >"${STOCK_AUTH_SMOKE_LOG_DIR}/eureka-back-server.log" 2>&1 &
eureka_pid="$!"
wait_for_contains "eureka started" "${EUREKA_URL}" "Eureka"

echo "==> starting auth-back-server H2 smoke profile"
./gradlew :auth-back-server:bootRun --args='--spring.profiles.active=test,smoke' \
  >"${STOCK_AUTH_SMOKE_LOG_DIR}/auth-back-server.log" 2>&1 &
auth_pid="$!"
wait_for_eureka_app "auth-back registered in eureka" "AUTH-BACK-SERVER"

echo "==> starting cloud-back-server"
./gradlew :cloud-back-server:bootRun \
  >"${STOCK_AUTH_SMOKE_LOG_DIR}/cloud-back-server.log" 2>&1 &
cloud_pid="$!"
wait_for_eureka_app "cloud gateway registered in eureka" "CLOUD-BACK-SERVER"

echo "==> creating stock user through gateway"
signup_body="{\"username\":\"${STOCK_AUTH_SMOKE_USER}\",\"password\":\"${STOCK_AUTH_SMOKE_PASSWORD}\",\"email\":\"${STOCK_AUTH_SMOKE_EMAIL}\",\"role\":\"USER\"}"
signup_response="$(curl -sS -X POST "${GATEWAY_URL}/api/users" \
  -H "Content-Type: application/json" \
  --data "${signup_body}")"
check_contains "stock signup through gateway" "${signup_response}" "User created successfully"

echo "==> logging in stock user through gateway"
login_body="{\"username\":\"${STOCK_AUTH_SMOKE_USER}\",\"password\":\"${STOCK_AUTH_SMOKE_PASSWORD}\"}"
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
fi

if [[ -n "${access_token}" ]]; then
  echo "==> loading current auth user through gateway"
  me_response="$(curl -sS -X GET "${GATEWAY_URL}/api/users/me" \
    -H "Authorization: Bearer ${access_token}")"
  check_contains "stock current user through gateway" "${me_response}" "${STOCK_AUTH_SMOKE_USER}"

  echo "==> refreshing stock access token through gateway"
  refresh_response="$(curl -sS -X POST "${GATEWAY_URL}/auth/refresh" \
    -H "Content-Type: application/json" \
    -H "X-Client-Id: stock-front-service" \
    -b "${cookie_jar}" \
    --data '{}')"
  refreshed_access_token="$(extract_access_token "${refresh_response}")"
  if [[ -z "${refreshed_access_token}" ]]; then
    echo "FAIL stock refresh through gateway"
    echo "${refresh_response}"
    failures=$((failures + 1))
  else
    echo "PASS stock refresh through gateway"
  fi
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "stock auth H2 smoke failed: ${failures} check(s)"
  echo "logs: ${STOCK_AUTH_SMOKE_LOG_DIR}"
  exit 1
fi

echo "stock auth H2 smoke passed"
echo "logs: ${STOCK_AUTH_SMOKE_LOG_DIR}"
