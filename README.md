# zeroq-common Workspace

`zeroq-common`은 ZeroQ, Muse, Semo, SBNG 계열 서비스를 함께 다루는 혼합형 워크스페이스입니다.

- 백엔드: 루트 Gradle 멀티모듈 Spring Boot 워크스페이스
- 프론트엔드: 각 디렉토리에서 독립 실행하는 Next.js 앱
- 저장소 형태: 루트 집계 저장소 + 하위 서비스별 독립 Git 저장소 다수

## Current Baseline

- Backend baseline
  - Java `21`
  - 루트 Gradle Wrapper `9.2.1`
  - 일부 하위 백엔드 프로젝트는 독립 wrapper를 별도로 가질 수 있음
  - Spring Boot `4.0.2`
  - Spring Cloud BOM `2025.1.0`
- Frontend baseline
  - Next.js `16.x`
  - React `19.2.3`
  - TypeScript `5.x`
  - Tailwind CSS `4.x`

## Repository Layout

### Backend modules included by the root build
- `web-common-core`
- `auth-common-core`
- `auth-back-server`
- `cloud-back-server`
- `eureka-back-server`
- `zeroq-back-service`
- `zeroq-back-sensor`
- `zeroq-sensor-gateway`
- `semo-back-service`
- `muse-back-service`
- `image-back-server`
- `stock-back-service`
- `stock-batch-service`

### Frontend apps managed separately
- `zeroq-front-admin`
- `zeroq-front-service`
- `muse-front-service`
- `semo-front-service`
- `sbng-front-service`
- `stock-front-service`

## Service Map

### Common and infrastructure
- `web-common-core`: 공통 응답, 예외, 유틸리티 라이브러리
- `auth-common-core`: 인증 DTO, `UserContext`, 인증 클라이언트 공통 모듈
- `auth-back-server`: JWT, OAuth2, 사용자 관리 서버
- `cloud-back-server`: API Gateway
- `eureka-back-server`: 서비스 디스커버리 서버
- `image-back-server`: 이미지 임시 업로드/조회/확정 서버

### ZeroQ
- `zeroq-back-service`: 공간, 점유율, 리뷰, 즐겨찾기, 사용자 위치 API
- `zeroq-back-sensor`: 센서 device, ingest, command, monitoring API
- `zeroq-sensor-gateway`: 로컬 센서망과 클라우드 센서 서버 사이의 엣지 게이트웨이
- `zeroq-front-service`: 일반 사용자용 서비스 프론트엔드
- `zeroq-front-admin`: 관리자용 프론트엔드

### Muse / Semo / SBNG
- `muse-back-service`: contest, gallery, home, overview, profile API
- `muse-front-service`: Muse 메인 제품 프론트엔드
- `semo-back-service`: 실제 DB 기반 `club`, `profile`, `notice`, `schedule`, `poll`, `attendance`, `timeline`, `finance`, `tournament`, `bracket`, `role management`, `dashboard`, `activity log` API
- `semo-front-service`: 사용자 홈, 클럽 탐색/가입, 사용자/관리자 클럽 화면, `/more` 기반 기능 모듈, 관리자 메뉴/멤버/통계/로그 화면이 연결된 Next.js 앱
- `sbng-front-service`: 기업/브랜드 소개 사이트

### Stock
- `stock-back-service`: 주식 모의투자 주문, 계좌, 보유 종목, 체결 내역, 랭킹 API
- `stock-batch-service`: 외부 시세 수집, Redis 최신가 캐시, 미체결 주문 체결 판단, 일별 정산 워커
- `stock-front-service`: 주식 모의투자 사용자용 Next.js 앱

## Semo Snapshot

`semo`는 더 이상 인증 셸 단계가 아닙니다. 현재 코드는 아래 흐름을 기준으로 설명하는 편이 맞습니다.

- 클럽 생성, 클럽 탐색, 가입 신청/승인, 내 클럽 홈
- 게시판 공지, 게시글 읽음 상태, 캘린더 공유
- 일정 이벤트, 투표, 참석/불참 처리
- `/more` 기능 모듈
  - 공지관리
  - 출석 체크
  - 타임라인
  - 투표
  - 일정관리
  - 대회기록
  - 대진표
  - 재정관리
  - 회원 디렉터리
  - 직책관리(`ADMIN_ONLY`)
- 관리자 홈, 메뉴 편집, 멤버 관리, 활동 로그, 통계 화면

`semo`의 핵심 구조는 `feature_catalog -> feature_activation -> 기능 전용 API/화면/테이블`입니다.

## Local Ports

### Backend
- `eureka-back-server`: `8761`
- `cloud-back-server`: `8080`
- `image-back-server`: `8081`
- `auth-back-server`: `9000` (`local`)
- `zeroq-back-service`: `20180`
- `zeroq-back-sensor`: `20181`
- `zeroq-sensor-gateway`: `20191`
- `muse-back-service`: `20280` (`local/dev`), `10280` (`prod`), `30280` (`test`)
- `semo-back-service`: `20280` (`local/dev`), `10280` (`prod`), `30280` (`test`)
- `stock-back-service`: `20480` (`local/dev`), `10480` (`prod`), `30480` (`test`)
- `stock-batch-service`: `20481` (`local/local-direct/dev`), `30481` (`test`), `10481` (`prod`)

### Frontend
- `muse-front-service`: `3000`
- `zeroq-front-service`: `3001`
- `zeroq-front-admin`: `3002`
- `semo-front-service`: `3003`
- `sbng-front-service`: `3004`
- `stock-front-service`: `3005`

## Requirements

- Java `21+`
- Node.js `20+` 권장
- npm `10+` 권장
- MySQL `8+`
- 백엔드 테스트용 H2

## Build and Run

### Backend aggregate build
```bash
./gradlew clean build -x test
```

### Backend aggregate test
```bash
./gradlew test
```

### Semo backend
```bash
./gradlew :semo-back-service:compileJava
./gradlew :semo-back-service:test
./gradlew :semo-back-service:bootRun
```

### Semo frontend
```bash
cd semo-front-service
npm install
npm run lint
npm run build
npm run dev
```

### Stock backend
```bash
./gradlew :stock-back-service:compileJava
./gradlew :stock-back-service:test
./gradlew :stock-batch-service:compileJava
./gradlew :stock-batch-service:test
```

Stock API는 Gateway를 통해 `/api/stock/v1/**`로 접근합니다. 로그인/회원가입은 기존 `auth-back-server`와 `cloud-back-server`를 사용하며, local OAuth client id는 `stock-front-service`입니다.
stock 프론트에서 받은 JWT를 gateway가 검증하므로 `AUTH_JWT_SECRET`과 `CLOUD_JWT_SECRET`은 같은 값이어야 합니다.

Stock `local`/`dev` profile은 별도 env가 없으면 다른 백엔드 서비스와 맞춰 원격 개발 인프라 `jdbc:mysql://kimd0.iptime.org:23306/STOCK_SERVICE`와 Redis `kimd0.iptime.org:26379`를 기본값으로 사용합니다. 별도 로컬 MySQL/Redis를 쓰려면 `.env`에서 `STOCK_DB_URL`, `STOCK_REDIS_HOST`, `STOCK_REDIS_PORT`를 직접 오버라이드합니다. `prod` profile은 `STOCK_DB_URL`, `STOCK_DB_USERNAME`, `STOCK_DB_PASSWORD`, `STOCK_REDIS_HOST`, `STOCK_REDIS_PORT`를 명시 주입하는 구조입니다. stock 서비스는 루트 `.env`와 각 서비스 `.env`를 optional import로 읽습니다.

`stock-back-service`는 다른 JPA 백엔드 서비스처럼 `database.datasource.pub.master/slave1`, `PubDataConfig`, `RoutingDataSource`를 사용합니다. read-only 트랜잭션은 slave로 라우팅되며, 현재 local/dev 기본값은 master와 slave가 같은 DB를 보도록 둡니다. `stock-batch-service`는 JPA가 아닌 `JdbcTemplate` 워커라서 단일 `spring.datasource` 자동 구성을 유지합니다.
루트 `.env.example`은 smoke check와 local/dev override에 쓰는 stock 기본 환경 변수 샘플입니다. 로컬 전용 값은 `.env`로 복사해 사용하고 커밋하지 않습니다.

Full local stock flow:

```bash
./gradlew :eureka-back-server:bootRun
./gradlew :auth-back-server:bootRun
./gradlew :cloud-back-server:bootRun
./gradlew :stock-back-service:bootRun
./gradlew :stock-batch-service:bootRun
cd stock-front-service && npm run dev
```

Stock smoke check after services are running:

```bash
scripts/stock-smoke.sh
STOCK_SMOKE_RUN_BATCH_JOBS=true scripts/stock-smoke.sh
STOCK_BATCH_INTERNAL_TOKEN=<token> STOCK_SMOKE_RUN_BATCH_JOBS=true scripts/stock-smoke.sh
ZEROQ_GATEWAY_SHARED_SECRET=<secret> STOCK_BATCH_INTERNAL_TOKEN=<token> STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS=true scripts/stock-smoke.sh
STOCK_ACCESS_TOKEN=<jwt> scripts/stock-smoke.sh
STOCK_ACCESS_TOKEN=<jwt> STOCK_SMOKE_PLACE_ORDER=true scripts/stock-smoke.sh
STOCK_ACCESS_TOKEN=<jwt> STOCK_SMOKE_PLACE_ORDER=true STOCK_SMOKE_CLIENT_ORDER_ID=my-repeatable-smoke-order scripts/stock-smoke.sh
```

`STOCK_SMOKE_PLACE_ORDER=true`는 기본적으로 실행 시각 기반 `clientOrderId`를 만들고 같은 실행 안에서 동일 주문키를 한 번 더 보내 중복 접수 방지를 확인합니다. 특정 주문키로 재현하고 싶을 때만 `STOCK_SMOKE_CLIENT_ORDER_ID`를 지정합니다.

현재 repo만으로 HTTP smoke를 빠르게 확인하려면 H2 기반 test/smoke profile smoke를 사용합니다.
H2 smoke 포트는 일반 local 포트와 분리되어 있으며, 필요하면 `STOCK_H2_BACK_URL`, `STOCK_H2_BATCH_URL`, `STOCK_H2_BATCH_INTERNAL_PORT`로 바꿉니다.
H2 smoke는 기본 현재가 체결 모드와 `internal-order-book` 모드를 모두 bootRun 경로로 확인합니다.

```bash
scripts/stock-h2-smoke.sh
```

Eureka, auth, Cloud Gateway까지 포함해 Docker 없이 gateway 회원가입/로그인, stock public/protected route, 주문 접수/중복/취소, direct batch job, gateway HMAC batch job 경로를 함께 확인하려면 gateway H2 smoke를 사용합니다.

```bash
scripts/stock-gateway-h2-smoke.sh
```

auth/gateway 로그인 흐름만 Docker 없이 확인하려면 auth H2 smoke를 사용합니다. 이 스크립트는 Eureka, auth-back H2 smoke profile, cloud gateway를 띄운 뒤 gateway 경유 회원가입, 로그인, 현재 사용자 조회, refresh를 확인합니다.

```bash
scripts/stock-auth-h2-smoke.sh
```

Stock front contract check:

```bash
cd stock-front-service
npm run verify:contract
```

`stock-batch-service` job 실행/제어 API는 `X-Internal-Token` 헤더가 `STOCK_BATCH_INTERNAL_TOKEN`과 일치해야 실행됩니다. 기본 `local-direct`는 `local-stock-batch-internal-token`을 사용하고 `20481` 포트로 뜹니다. `local`/`dev`도 `20481`, `test`는 `30481`, `prod`는 `10481`을 사용하며, 빈 token 허용은 테스트/smoke 편의 profile에서만 켭니다.

Cloud Gateway를 통해 batch job을 실행할 때는 `/internal/stock-batch/v1/jobs/**` 경로를 사용합니다. 이 경로는 일반 사용자 JWT가 아니라 `X-Gateway-Id`, `X-Gateway-Timestamp`, `X-Gateway-Nonce`, `X-Gateway-Signature` 기반 내부 HMAC 인증을 통과해야 하며, gateway가 `STOCK_BATCH_INTERNAL_TOKEN` 값을 `X-Internal-Token`으로 batch 서버에 전달합니다.
`scripts/stock-smoke.sh`에서 gateway batch job 경로까지 검증하려면 `ZEROQ_GATEWAY_SHARED_SECRET`과 `STOCK_SMOKE_RUN_GATEWAY_BATCH_JOBS=true`를 함께 설정합니다.

장 마감 정산 스케줄은 기본적으로 평일 15:40 `Asia/Seoul` 기준입니다. 운영 시간이나 시장 기준을 바꿔야 하면 `STOCK_BATCH_SETTLEMENT_CRON`, `STOCK_BATCH_SETTLEMENT_ZONE`으로 조정합니다.

### Stock frontend
```bash
cd stock-front-service
npm install
npm run lint
npm run build
```

## Workspace Notes

- 루트 `settings.gradle`은 백엔드 모듈만 포함합니다.
- 프론트 앱은 루트 Gradle에 포함되지 않으며 각 디렉토리에서 독립적으로 관리합니다.
- `muse-back-service`와 `semo-back-service`는 기본 포트가 동일하므로 로컬에서 동시에 띄우려면 프로필 또는 포트를 조정해야 합니다.
- 실제 기술 스택, 포트, 라우트, 의존성은 각 프로젝트의 `build.gradle`, `package.json`, `application*.yml`, 서비스 `README.md`, `AGENTS.md`를 우선으로 봐야 합니다.

## Documentation Entry Points

- Workspace guide: `AGENTS.md`
- Sub-agent policy: `AGENTS_SUBAGENT_POLICY.md`
- Command reference: `HELP.md`
- Documentation index: `AGENTS_DOCUMENTATION_INDEX.md`
- Semo more feature checklist: `semo-front-service/AGENTS_SEMO_MORE_FEATURE_CHECKLIST.md`
- Muse operational note: `muse-back-service/AGENTS_MUSE_CONTEST_UNIFIED.md`
- ZeroQ seat sensor hardware note: `zeroq-back-sensor/AGENTS_ZEROQ_SEAT_SENSOR_HARDWARE.md`
