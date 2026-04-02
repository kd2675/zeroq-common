# zeroq-common Workspace

`zeroq-common`은 ZeroQ, Muse, Semo, SBNG 계열 서비스를 함께 다루는 혼합형 워크스페이스입니다.

- 백엔드: 루트 Gradle 멀티모듈 Spring Boot 워크스페이스
- 프론트엔드: 각 디렉토리에서 독립 실행하는 Next.js 앱
- 저장소 형태: 루트 집계 저장소 + 하위 서비스별 독립 Git 저장소 다수

## Current Baseline

- Backend baseline
  - Java `21`
  - Gradle `9.3.0` 계열 wrapper 사용
  - Spring Boot `4.0.2`
  - Spring Cloud BOM `2025.1.0`
- Frontend baseline
  - Next.js `16.1.x`
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

### Frontend apps managed separately
- `zeroq-front-admin`
- `zeroq-front-service`
- `muse-front-service`
- `semo-front-service`
- `sbng-front-service`

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
- `semo-back-service`: 실제 DB 기반 `club`, `profile`, `notice`, `schedule`, `poll`, `attendance`, `timeline`, `dues`, `tournament`, `bracket`, `role management`, `dashboard`, `activity log` API
- `semo-front-service`: 사용자 홈, 클럽 탐색/가입, 사용자/관리자 클럽 화면, `/more` 기반 기능 모듈, 관리자 메뉴/멤버/통계/로그 화면이 연결된 Next.js 앱
- `sbng-front-service`: 기업/브랜드 소개 사이트

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
  - 회비관리
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

### Frontend
- `muse-front-service`: `3000`
- `zeroq-front-service`: `3001`
- `zeroq-front-admin`: `3002`
- `semo-front-service`: `3003`
- `sbng-front-service`: `3004`

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

## Workspace Notes

- 루트 `settings.gradle`은 백엔드 모듈만 포함합니다.
- 프론트 앱은 루트 Gradle에 포함되지 않으며 각 디렉토리에서 독립적으로 관리합니다.
- `muse-back-service`와 `semo-back-service`는 기본 포트가 동일하므로 로컬에서 동시에 띄우려면 프로필 또는 포트를 조정해야 합니다.
- 실제 기술 스택, 포트, 라우트, 의존성은 각 프로젝트의 `build.gradle`, `package.json`, `application*.yml`, 서비스 `README.md`, `AGENTS.md`를 우선으로 봐야 합니다.

## Documentation Entry Points

- Workspace guide: `AGENTS.md`
- Command reference: `HELP.md`
- Documentation index: `AGENTS_DOCUMENTATION_INDEX.md`
- Semo more feature checklist: `AGENTS_SEMO_MORE_FEATURE_CHECKLIST.md`
- Muse operational note: `AGENTS_MUSE_CONTEST_UNIFIED.md`
- ZeroQ seat sensor hardware note: `AGENTS_ZEROQ_SEAT_SENSOR_HARDWARE.md`
