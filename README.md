# zeroq-common Workspace

`zeroq-common`은 ZeroQ, Muse, Semo, SBNG 계열 서비스가 함께 있는 혼합형 워크스페이스입니다.

- 백엔드: 루트 Gradle에 포함된 Spring Boot 멀티모듈
- 프론트엔드: 각 디렉토리에서 독립적으로 실행하는 Next.js 앱
- 운영 형태: 루트 워크스페이스 + 하위 독립 Git 저장소 다수

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
- `web-common-core`: 공통 응답/예외/유틸 라이브러리
- `auth-common-core`: 인증 DTO, `UserContext`, Feign client 라이브러리
- `auth-back-server`: JWT, OAuth2, 사용자 관리 서버
- `cloud-back-server`: API Gateway
- `eureka-back-server`: 서비스 디스커버리 서버
- `image-back-server`: 이미지 업로드/조회 서버

### ZeroQ
- `zeroq-back-service`: 공간, 점유율, 리뷰, 즐겨찾기, 사용자 위치 API
- `zeroq-back-sensor`: 센서 device, ingest, command, monitoring API
- `zeroq-sensor-gateway`: 로컬 센서망과 클라우드 센서 서버 사이의 엣지 게이트웨이
- `zeroq-front-service`: 일반 사용자용 인증 셸
- `zeroq-front-admin`: 관리자용 인증/세션 셸

### Muse / Semo / SBNG
- `muse-back-service`: contest, gallery, home, overview, profile API
- `muse-front-service`: Muse 메인 제품 프론트엔드
- `semo-back-service`: 현재는 공통/DB 중심의 초기 백엔드 골격
- `semo-front-service`: Semo 인증 셸
- `sbng-front-service`: 기업/브랜드 소개 사이트

## Local Ports

### Backend
- `eureka-back-server`: `8761`
- `cloud-back-server`: `8080`
- `image-back-server`: `8081`
- `auth-back-server`: `9000` (`local`)
- `zeroq-back-service`: `20180`
- `zeroq-back-sensor`: `20181`
- `zeroq-sensor-gateway`: `20191`
- `muse-back-service`: `20280`
- `semo-back-service`: `20280`

### Frontend
- `muse-front-service`: `3000`
- `zeroq-front-service`: `3001`
- `zeroq-front-admin`: `3002`
- `semo-front-service`: `3003`
- `sbng-front-service`: `3004`

## Requirements

- Java 21+
- Node.js 18+
- MySQL 8+

## Build and Run

### Backend aggregate build
```bash
./gradlew clean build -x test
```

### Typical backend startup order
```bash
./gradlew eureka-back-server:bootRun
./gradlew auth-back-server:bootRun
./gradlew cloud-back-server:bootRun
./gradlew zeroq-back-service:bootRun
```

### Frontend examples
```bash
cd muse-front-service && npm install && npm run dev
cd zeroq-front-service && npm install && npm run dev
cd zeroq-front-admin && npm install && npm run dev
```

## Documentation Entry Points

- Workspace guide: `AGENTS.md`
- Command reference: `HELP.md`
- Documentation index: `AGENTS_DOCUMENTATION_INDEX.md`
- Muse operational note: `AGENTS_MUSE_CONTEST_UNIFIED.md`
- ZeroQ seat sensor hardware note: `AGENTS_ZEROQ_SEAT_SENSOR_HARDWARE.md`

## Structural Caveats

- 루트 `settings.gradle`은 백엔드 모듈만 포함합니다.
- 프론트 앱은 루트 Gradle에 포함되지 않으며 각 디렉토리에서 독립적으로 관리합니다.
- 루트 저장소 외에 각 서비스/앱 안에도 `.git`이 있어, 변경 추적과 브랜치 상태는 루트와 하위 프로젝트에서 다르게 보일 수 있습니다.
- 실제 기술 스택과 실행 정보는 루트 문서보다 각 프로젝트의 `build.gradle`, `package.json`, `application*.yml`, 서비스별 문서를 우선으로 봐야 합니다.
