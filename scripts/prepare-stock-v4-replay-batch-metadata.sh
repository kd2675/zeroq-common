#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA_FILE="${ROOT_DIR}/stock-batch-service/src/main/resources/db/schema/batch-metadata-mysql.sql"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_BATCH_SCHEMA:?STOCK_MYSQL_REPLAY_BATCH_SCHEMA is required}"

REPLAY_BATCH_SCHEMA="${STOCK_MYSQL_REPLAY_BATCH_SCHEMA}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"
CREATED_SCHEMA=false

if [[ ! "${REPLAY_BATCH_SCHEMA}" =~ ^STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+$ ]]; then
  printf 'FAIL replay batch schema must match STOCK_V4_REPLAY_BATCH_[A-Za-z0-9_]+\n' >&2
  exit 1
fi

if [[ ! -f "${SCHEMA_FILE}" ]]; then
  printf 'FAIL batch metadata schema SQL is missing: %s\n' "${SCHEMA_FILE}" >&2
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

mysql_metadata() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" \
    "--database=${REPLAY_BATCH_SCHEMA}" "$@"
}

cleanup_failed_schema() {
  local exit_code=$?
  trap - EXIT

  if [[ "${exit_code}" -ne 0 && "${CREATED_SCHEMA}" == "true" ]]; then
    if mysql_admin \
      --execute="DROP DATABASE IF EXISTS \`${REPLAY_BATCH_SCHEMA}\`" >/dev/null; then
      printf 'PASS removed failed replay batch schema %s\n' \
        "${REPLAY_BATCH_SCHEMA}"
    else
      printf 'WARN failed to remove replay batch schema %s\n' \
        "${REPLAY_BATCH_SCHEMA}" >&2
    fi
  fi
  exit "${exit_code}"
}
trap cleanup_failed_schema EXIT

assert_equals() {
  local label="$1"
  local expected="$2"
  local query="$3"
  local actual

  actual="$(mysql_metadata --execute="${query}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL %s expected=%s actual=%s\n' \
      "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf 'PASS %s = %s\n' "${label}" "${actual}"
}

MYSQL_VERSION="$(mysql_admin --execute="SELECT VERSION()")"
if [[ "${MYSQL_VERSION}" != 8.* ]]; then
  printf 'FAIL MySQL 8.x is required, actual=%s\n' "${MYSQL_VERSION}" >&2
  exit 1
fi
printf 'PASS MySQL version = %s\n' "${MYSQL_VERSION}"

EXISTING_SCHEMA_COUNT="$(
  mysql_admin --execute="
    SELECT COUNT(*)
      FROM information_schema.schemata
     WHERE schema_name = '${REPLAY_BATCH_SCHEMA}'
  "
)"
if [[ "${EXISTING_SCHEMA_COUNT}" != "0" ]]; then
  printf 'FAIL replay batch schema already exists and will not be overwritten: %s\n' \
    "${REPLAY_BATCH_SCHEMA}" >&2
  exit 1
fi

sed "s/STOCK_BATCH_METADATA/${REPLAY_BATCH_SCHEMA}/g" "${SCHEMA_FILE}" \
  | mysql_admin >/dev/null
CREATED_SCHEMA=true
printf 'PASS created isolated replay batch schema %s\n' \
  "${REPLAY_BATCH_SCHEMA}"

assert_equals \
  "batch metadata table count" \
  "10" \
  "
  SELECT COUNT(*)
    FROM information_schema.tables
   WHERE table_schema = DATABASE()
  "

assert_equals \
  "batch metadata sequence basis" \
  "0|0|0" \
  "
  SELECT CONCAT_WS(
      '|',
      (SELECT ID FROM BATCH_JOB_INSTANCE_SEQ WHERE UNIQUE_KEY = '0'),
      (SELECT ID FROM BATCH_JOB_EXECUTION_SEQ WHERE UNIQUE_KEY = '0'),
      (SELECT ID FROM BATCH_STEP_EXECUTION_SEQ WHERE UNIQUE_KEY = '0')
  )
  "

trap - EXIT
printf 'PASS retained isolated replay batch schema %s\n' \
  "${REPLAY_BATCH_SCHEMA}"
printf 'INFO operating STOCK_BATCH_METADATA was not queried or changed\n'
