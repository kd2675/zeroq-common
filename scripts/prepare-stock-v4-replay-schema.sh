#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DDL_DIR="${ROOT_DIR}/stock-back-service/src/main/resources/db/ddl"

: "${STOCK_MYSQL_HOST:?STOCK_MYSQL_HOST is required}"
: "${STOCK_MYSQL_PORT:?STOCK_MYSQL_PORT is required}"
: "${STOCK_MYSQL_USER:?STOCK_MYSQL_USER is required}"
: "${STOCK_MYSQL_PASSWORD:?STOCK_MYSQL_PASSWORD is required}"
: "${STOCK_MYSQL_REPLAY_SCHEMA:?STOCK_MYSQL_REPLAY_SCHEMA is required}"
: "${STOCK_V4_BASELINE_ARTIFACT:?STOCK_V4_BASELINE_ARTIFACT is required}"

REPLAY_SCHEMA="${STOCK_MYSQL_REPLAY_SCHEMA}"
ARTIFACT_INPUT="${STOCK_V4_BASELINE_ARTIFACT}"
MYSQL_BIN="${STOCK_MYSQL_BIN:-}"
CREATED_SCHEMA=false

if [[ ! "${REPLAY_SCHEMA}" =~ ^STOCK_V4_REPLAY_[A-Za-z0-9_]+$ ]]; then
  printf 'FAIL replay schema must match STOCK_V4_REPLAY_[A-Za-z0-9_]+\n' >&2
  exit 1
fi

if [[ -z "${MYSQL_BIN}" ]]; then
  MYSQL_BIN="$(command -v mysql || true)"
fi
if [[ -z "${MYSQL_BIN}" || ! -x "${MYSQL_BIN}" ]]; then
  printf 'FAIL mysql client was not found; set STOCK_MYSQL_BIN\n' >&2
  exit 1
fi

if [[ -d "${ARTIFACT_INPUT}" ]]; then
  ARTIFACT_FILE="${ARTIFACT_INPUT}/baseline.ndjson.tsv"
else
  ARTIFACT_FILE="${ARTIFACT_INPUT}"
fi

if [[ ! -f "${ARTIFACT_FILE}" ]]; then
  printf 'FAIL baseline artifact does not exist: %s\n' "${ARTIFACT_FILE}" >&2
  exit 1
fi

ARTIFACT_DIRECTORY="$(
  cd "$(dirname "${ARTIFACT_FILE}")"
  pwd -P
)"
ARTIFACT_FILE="${ARTIFACT_DIRECTORY}/$(basename "${ARTIFACT_FILE}")"
EXPECTED_ARTIFACT_ROOT="${ROOT_DIR}/artifacts/stock-v4-baseline/"
case "${ARTIFACT_FILE}" in
  "${EXPECTED_ARTIFACT_ROOT}"*)
    ;;
  *)
    printf 'FAIL artifact must be under %s\n' "${EXPECTED_ARTIFACT_ROOT}" >&2
    exit 1
    ;;
esac

node "${SCRIPT_DIR}/verify-stock-v4-baseline-artifact.mjs" \
  "${ARTIFACT_FILE}" >/dev/null
printf 'PASS baseline artifact contract\n'

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

mysql_replay() {
  env MYSQL_PWD="${STOCK_MYSQL_PASSWORD}" \
    "${MYSQL_BIN}" "${MYSQL_CONNECTION_ARGS[@]}" \
    "--database=${REPLAY_SCHEMA}" "$@"
}

cleanup_failed_schema() {
  local exit_code=$?
  trap - EXIT

  if [[ "${exit_code}" -ne 0 && "${CREATED_SCHEMA}" == "true" ]]; then
    if mysql_admin \
      --execute="DROP DATABASE IF EXISTS \`${REPLAY_SCHEMA}\`" >/dev/null; then
      printf 'PASS removed failed replay schema %s\n' "${REPLAY_SCHEMA}"
    else
      printf 'WARN failed to remove replay schema %s\n' \
        "${REPLAY_SCHEMA}" >&2
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

  actual="$(mysql_replay --execute="${query}")"
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
     WHERE schema_name = '${REPLAY_SCHEMA}'
  "
)"
if [[ "${EXISTING_SCHEMA_COUNT}" != "0" ]]; then
  printf 'FAIL replay schema already exists and will not be overwritten: %s\n' \
    "${REPLAY_SCHEMA}" >&2
  exit 1
fi

mysql_admin --execute="
  CREATE DATABASE \`${REPLAY_SCHEMA}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci
" >/dev/null
CREATED_SCHEMA=true
printf 'PASS created isolated replay schema %s\n' "${REPLAY_SCHEMA}"

sed "s/STOCK_SERVICE/${REPLAY_SCHEMA}/g" "${DDL_DIR}/stock_all.sql" \
  | mysql_admin >/dev/null
printf 'PASS canonical MySQL DDL\n'

mysql_replay --execute="
  CREATE TABLE stock_v4_replay_artifact_line (
    line_id BIGINT NOT NULL AUTO_INCREMENT,
    section_name VARCHAR(40) NOT NULL,
    row_key VARCHAR(160) NOT NULL,
    payload_json JSON NOT NULL,
    loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (line_id),
    UNIQUE KEY uk_stock_v4_replay_artifact_section_key (
      section_name,
      row_key
    ),
    KEY idx_stock_v4_replay_artifact_section (
      section_name,
      line_id
    ),
    CONSTRAINT chk_stock_v4_replay_artifact_section
      CHECK (section_name <> ''),
    CONSTRAINT chk_stock_v4_replay_artifact_key
      CHECK (row_key <> '')
  );
" >/dev/null

node "${SCRIPT_DIR}/emit-stock-v4-baseline-insert-sql.mjs" \
  "${ARTIFACT_FILE}" \
  | mysql_replay >/dev/null
printf 'PASS loaded baseline artifact into isolated staging table\n'

assert_equals \
  "artifact line count" \
  "7370" \
  "SELECT COUNT(*) FROM stock_v4_replay_artifact_line"

assert_equals \
  "artifact section fingerprint" \
  "ACCOUNT_CASH_FLOW:4649|ACCOUNT_SNAPSHOT:179|AUTO_INTENT:16|AUTO_MARKET_CONFIG:7|AUTO_PARTICIPANT:151|AUTO_POLICY:1|CLOSE_RUN:1|CORPORATE_ACTION:8|CORPORATE_ACTION_ENTITLEMENT:72|DAILY_SYMBOL:7|EXECUTION:130|HOLDING_SNAPSHOT:395|INSTITUTION_MANDATE:28|INSTITUTION_PORTFOLIO:4|LIQUIDITY_DAILY_STATE:41|LIQUIDITY_MANDATE:7|LIQUIDITY_TRANSITION:7|MARKET_PARTICIPANT:7|MARKET_POLICY:32|MARKET_REFERENCE_VOLUME:14|META:1|ORDER:799|ORDER_STRATEGY_ORIGIN:719|PARTICIPANT_ACCOUNT:27|POST_CLOSE_CYCLE:1|PROFILE_CONFIG:27|SECURITY_ALLOCATION:25|UNDERWRITING_CONTRACT:7|UNDERWRITING_DAILY_STATE:8" \
  "
  SELECT GROUP_CONCAT(
      CONCAT(section_name, ':', row_count)
      ORDER BY section_name
      SEPARATOR '|'
  )
    FROM (
        SELECT section_name, COUNT(*) AS row_count
          FROM stock_v4_replay_artifact_line
         GROUP BY section_name
    ) section_count
  "

assert_equals \
  "artifact baseline identity" \
  "6|259|2027-02-09" \
  "
  SELECT CONCAT_WS(
      '|',
      JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.artifactVersion')),
      JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.baselineCloseRunId')),
      JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.baselineBusinessDate'))
  )
    FROM stock_v4_replay_artifact_line
   WHERE section_name = 'META'
     AND row_key = 'BASELINE'
  "

assert_equals \
  "canonical non-V4 profile configuration" \
  "0" \
  "
  SELECT COUNT(*)
    FROM stock_auto_participant_profile_config
   WHERE behavior_model_version <> 'V4'
  "

trap - EXIT
printf 'PASS retained isolated replay schema %s\n' "${REPLAY_SCHEMA}"
printf 'INFO next step loads staged rows into canonical current-state tables\n'
