# Documentation Index

이 문서는 `zeroq-common` 루트에서 참조할 문서를 프로젝트별로 정리한 인덱스입니다.

## Root

| 파일 | 용도 |
|---|---|
| `README.md` | 워크스페이스 전체 구조와 실행 개요 |
| `HELP.md` | 루트에서 자주 쓰는 명령 모음 |
| `AGENTS.md` | 작업 규칙과 문서 유지 기준 |
| `COMMIT_MESSAGE_CONVENTION.md` | 한국어 커밋 메시지 작성 규칙 |
| `docs/ubuntu-data-nvme-migration-runbook.md` | Ubuntu `/data` HDD를 NVMe SSD로 이전하는 실행 절차 |
| `docs/ubuntu-data-nvme-migration-troubleshooting.md` | `/data` 마이그레이션 중 예외 상황 점검과 복구 부록 |

## Common / Infrastructure

| 경로 | 문서 |
|---|---|
| `web-common-core/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `auth-common-core/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `auth-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `cloud-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `eureka-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `image-back-server/` | `README.md`, `HELP.md`, `AGENTS.md` |

## Stock

| 경로 | 문서 |
|---|---|
| `stock-back-service/` | `README.md`, `AGENTS.md`, `STOCK_MARKET_FEATURE_ROADMAP.md`, `docs/market-simulation/00-overview.md`, `docs/market-simulation/13-code-ownership-map.md`, `docs/market-simulation/14-feature-change-playbooks.md`, `docs/market-simulation/15-corporate-action-scope.md`, `docs/market-simulation/16-initial-essential-scope-audit.md`, `docs/market-simulation/17-essential-completion-evidence.md`, `docs/market-simulation/21-kospi-one-hundredth-v5-fresh-start.md`, `docs/market-simulation/feature-handbook/`, `docs/market-simulation/development-specs/` |
| `stock-batch-service/` | `README.md`, `AGENTS.md`, `docs/architecture.md`, `docs/stock-eod-refactoring-plan-2026-07-15.md` |
| `stock-front-service/` | `README.md`, `AGENTS.md` |

## ZeroQ

| 경로 | 문서 |
|---|---|
| `zeroq-back-service/` | `README.md`, `HELP.md`, `AGENTS.md`, `AGENTS_ZEROQ_CURRENT_FLOW_ANALYSIS_REPORT.md`, `AGENTS_ZEROQ_DEVELOPMENT_ONLY.md` |
| `zeroq-back-sensor/` | `README.md`, `HELP.md`, `AGENTS.md`, `ZEROQ_SPOT_SENSOR_HARDWARE.md`, `examples/zeroq-spot-sensor-xiao-vl53l1x/README.md` |
| `zeroq-sensor-gateway/` | `README.md`, `HELP.md`, `AGENTS.md`, `ZEROQ_SENSOR_PROTOCOL.md`, `tools/ble-seat-scanner/README.md` |
| `zeroq-front-admin/` | `README.md`, `AGENTS.md` |
| `zeroq-front-service/` | `README.md`, `AGENTS.md` |

## Muse / Semo / SBNG

| 경로 | 문서 |
|---|---|
| `muse-back-service/` | `README.md`, `HELP.md`, `AGENTS.md`, `AGENTS_MUSE_CONTEST_UNIFIED.md` |
| `muse-front-service/` | `README.md`, `AGENTS.md` |
| `semo-back-service/` | `README.md`, `HELP.md`, `AGENTS.md` |
| `semo-front-service/` | `README.md`, `AGENTS.md`, `SEMO_MORE_FEATURE_GUIDE.md` |
| `sbng-front-service/` | `README.md`, `AGENTS.md` |

## Recommended Reading Order

1. `README.md`
2. `AGENTS.md`
3. `COMMIT_MESSAGE_CONVENTION.md`
4. 대상 프로젝트의 `README.md`
5. 대상 프로젝트의 `HELP.md` 또는 `AGENTS.md`
6. Stock 기능 개발이면 `stock-back-service/docs/market-simulation/00-overview.md`
7. Stock 코드 파일별 책임 확인이면 `stock-back-service/docs/market-simulation/13-code-ownership-map.md`
8. Stock 기능 변경 절차 확인이면 `stock-back-service/docs/market-simulation/14-feature-change-playbooks.md`
9. Stock 기업 이벤트 추가 판단이면 `stock-back-service/docs/market-simulation/15-corporate-action-scope.md`
10. Stock 초기 필수 기능 범위 감사이면 `stock-back-service/docs/market-simulation/16-initial-essential-scope-audit.md`
11. Stock 초기 필수 범위 완료 증거가 필요하면 `stock-back-service/docs/market-simulation/17-essential-completion-evidence.md`
12. Stock 항목별 개발 핸드오프가 필요하면 `stock-back-service/docs/market-simulation/feature-handbook/00-index.md`
13. Stock 실제 코드 변경 시작점이 필요하면 `stock-back-service/docs/market-simulation/development-specs/00-index.md`
14. Stock 장마감·정산·야간 후처리 또는 주문·체결 부하 보호 작업이면 `stock-batch-service/docs/stock-eod-refactoring-plan-2026-07-15.md`
15. Stock KOSPI 1/100 시장·V5 신규 시작이면 `stock-back-service/docs/market-simulation/21-kospi-one-hundredth-v5-fresh-start.md`
16. Muse 작업이면 `muse-back-service/AGENTS_MUSE_CONTEST_UNIFIED.md`
17. Semo 기능 판단·추가·재구성·UIUX 검증이면 `semo-front-service/SEMO_MORE_FEATURE_GUIDE.md`

## Maintenance Rules

- 프로젝트 구조가 바뀌면 루트 문서와 대상 프로젝트 문서를 함께 갱신한다.
- 문서보다 코드와 설정 파일이 우선이다.
- 프로젝트에 문서가 새로 추가되거나 삭제되면 이 인덱스를 같이 수정한다.
