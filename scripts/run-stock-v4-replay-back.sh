#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"
REPLAY_BACK_PORT="${STOCK_V4_REPLAY_BACK_PORT:-30490}"
CHECK_ONLY=false

if [[ "${1:-}" == "--check-only" ]]; then
  CHECK_ONLY=true
elif [[ $# -gt 0 ]]; then
  printf 'FAIL unsupported argument: %s\n' "$1" >&2
  exit 1
fi

if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]]; then
  printf 'FAIL business replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi
if [[ "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_ ]]; then
  printf 'FAIL business replay schema cannot be a batch metadata schema\n' >&2
  exit 1
fi
if [[ ! "${REPLAY_BACK_PORT}" =~ ^[0-9]+$ ]] \
    || (( REPLAY_BACK_PORT < 1024 || REPLAY_BACK_PORT > 65535 )); then
  printf 'FAIL STOCK_V4_REPLAY_BACK_PORT must be between 1024 and 65535\n' >&2
  exit 1
fi

if [[ -z "${MYSQL_BIN}" ]]; then
  MYSQL_BIN="$(command -v mysql || true)"
fi
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
  "--skip-column-names"
)

mysql_admin() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" "$@"
}

actual_marker_count="$(mysql_admin --execute="
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = '${REPLAY_SCHEMA}'
     AND table_name = 'stock_market_business_state'
")"
if [[ "${actual_marker_count}" != "1" ]]; then
  printf 'FAIL replay business schema marker expected=1 actual=%s\n' \
    "${actual_marker_count}" >&2
  exit 1
fi

printf 'PASS replay business schema marker = %s\n' "${actual_marker_count}"
printf 'PASS operating STOCK_SERVICE is outside the replay target\n'
printf 'PASS both read and write pools will use the same isolated replay schema\n'

if [[ "${CHECK_ONLY}" == "true" ]]; then
  printf 'PASS replay back launch preflight completed without starting a service\n'
  exit 0
fi

business_jdbc_url="jdbc:mysql://${STOCK_MYSQL_HOST}:${STOCK_MYSQL_PORT}/${REPLAY_SCHEMA}?zeroDateTimeBehavior=convertToNull&useLegacyDatetimeCode=false&serverTimezone=Asia/Seoul&noAccessToProcedureBodies=true&useSSL=false&allowPublicKeyRetrieval=true&connectTimeout=5000&socketTimeout=30000&tcpKeepAlive=true"

export SPRING_PROFILES_ACTIVE=local-direct
export SERVER_PORT="${REPLAY_BACK_PORT}"
export DATABASE_DATASOURCE_PUB_MASTER_URL="${business_jdbc_url}"
export DATABASE_DATASOURCE_PUB_MASTER_USERNAME="${STOCK_MYSQL_USER}"
export DATABASE_DATASOURCE_PUB_MASTER_PASSWORD="${STOCK_MYSQL_PASSWORD}"
export DATABASE_DATASOURCE_PUB_SLAVE1_URL="${business_jdbc_url}"
export DATABASE_DATASOURCE_PUB_SLAVE1_USERNAME="${STOCK_MYSQL_USER}"
export DATABASE_DATASOURCE_PUB_SLAVE1_PASSWORD="${STOCK_MYSQL_PASSWORD}"
export STOCK_SCHEMA_READINESS_ENABLED=true
export STOCK_PRICE_STREAM_REDIS_LISTENER_ENABLED=false
export MANAGEMENT_HEALTH_REDIS_ENABLED=false
export STOCK_INSTANCE_ID="v4-replay-back-${REPLAY_SCHEMA}"
if [[ "${STOCK_V4_REPLAY_ALLOW_LIQUIDITY_DISTRIBUTION:-}" == "YES" ]]; then
  export STOCK_SCALED_MARKET_LIQUIDITY_DISTRIBUTION_ENABLED=true
  printf 'PASS scaled-market liquidity distribution API explicitly enabled\n'
else
  export STOCK_SCALED_MARKET_LIQUIDITY_DISTRIBUTION_ENABLED=false
  printf 'PASS scaled-market liquidity distribution API remains disabled\n'
fi

printf 'INFO starting isolated stock back on port %s\n' "${REPLAY_BACK_PORT}"
cd "${ROOT_DIR}"
exec ./gradlew :stock-back-service:bootRun --no-daemon
