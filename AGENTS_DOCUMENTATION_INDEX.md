# Documentation Index

이 문서는 `zeroq-common` 루트에서 참조할 문서를 프로젝트별로 정리한 인덱스입니다.

## Root

| 파일 | 용도 |
|---|---|
| `README.md` | 워크스페이스 전체 구조와 실행 개요 |
| `HELP.md` | 루트에서 자주 쓰는 명령 모음 |
| `AGENTS.md` | 작업 규칙과 문서 유지 기준 |
| `AGENTS_SUBAGENT_POLICY.md` | 서브 에이전트 사용 게이트, 파이프라인, reviewer/tester/fixer 규칙 |

## Common / Infrastructure

| 경로 | 문서 |
|---|---|
| `web-common-core/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `auth-common-core/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `auth-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `cloud-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `eureka-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `image-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |

## ZeroQ

| 경로 | 문서 |
|---|---|
| `zeroq-back-service/` | `README.md`, `HELP.md`, `AGENTS.md`, `AGENTS_ZEROQ_CURRENT_FLOW_ANALYSIS_REPORT.md`, `AGENTS_ZEROQ_DEVELOPMENT_ONLY.md` |
| `zeroq-back-sensor/` | `README.md`, `HELP.md`, `AGENTS.md`, `AGENTS_ZEROQ_SEAT_SENSOR_HARDWARE.md`, `examples/zeroq-seat-sensor-xiao/README.md` |
| `zeroq-sensor-gateway/` | `README.md`, `HELP.md`, `AGENTS.md`, `AGENTS_ZEROQ_SENSOR_PROTOCOL.md` |
| `zeroq-front-admin/` | `README.md`, `AGENTS.md` |
| `zeroq-front-service/` | `README.md`, `AGENTS.md` |

## Muse / Semo / SBNG

| 경로 | 문서 |
|---|---|
| `muse-back-service/` | `README.md`, `HELP.md`, `AGENTS.md`, `AGENTS_MUSE_CONTEST_UNIFIED.md` |
| `muse-front-service/` | `README.md`, `AGENTS.md` |
| `semo-back-service/` | `README.md`, `HELP.md`, `AGENTS.md`, `AGENTS_SEMO_TOURNAMENT_RECORD_IMPLEMENTATION_PLAN.md` |
| `semo-front-service/` | `README.md`, `AGENTS.md`, `AGENTS_SEMO_MORE_FEATURE_CHECKLIST.md` |
| `sbng-front-service/` | `README.md`, `AGENTS.md` |

## Recommended Reading Order

1. `README.md`
2. `AGENTS.md`
3. 대상 프로젝트의 `README.md`
4. 대상 프로젝트의 `HELP.md` 또는 `AGENTS.md`
5. Muse 작업이면 `muse-back-service/AGENTS_MUSE_CONTEST_UNIFIED.md`

## Maintenance Rules

- 프로젝트 구조가 바뀌면 루트 문서와 대상 프로젝트 문서를 함께 갱신한다.
- 문서보다 코드와 설정 파일이 우선이다.
- 프로젝트에 문서가 새로 추가되거나 삭제되면 이 인덱스를 같이 수정한다.
