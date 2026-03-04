# zeroq-common Workspace

`zeroq-common`은 ZeroQ/Muse/Semo 계열 서비스를 함께 운영하는 모노레포 워크스페이스입니다.

## Repository 구성

### Gradle 백엔드 모듈 (`settings.gradle` 포함)
- `zeroq-back-service`
- `zeroq-back-sensor`
- `auth-back-server`
- `auth-common-core`
- `cloud-back-server`
- `eureka-back-server`
- `web-common-core`
- `semo-back-service`
- `muse-back-service`
- `image-back-server`

### 독립 프론트엔드 앱 (Node/Next.js)
- `zeroq-front-admin`
- `zeroq-front-service`
- `muse-front-service`
- `semo-front-service`
- `sbng-front-service`

## 빠른 시작

### 요구사항
- Java 21+
- Node.js 18+
- MySQL 8+

### 백엔드 빌드
```bash
./gradlew clean build -x test
```

### 개별 서비스 실행 예시
```bash
# ZeroQ 메인 API
./gradlew zeroq-back-service:bootRun

# Muse API
./gradlew muse-back-service:bootRun

# 이미지 서버
./gradlew image-back-server:bootRun
```

### 프론트 실행 예시
```bash
cd zeroq-front-admin && npm install && npm run dev
cd zeroq-front-service && npm install && npm run dev -- -p 3001
cd muse-front-service && npm install && npm run dev
cd semo-front-service && npm install && npm run dev
cd sbng-front-service && npm install && npm run dev
```

## 문서 시작점
- 전체 문서 맵: `AGENTS_DOCUMENTATION_INDEX.md`
- 에이전트 작업 가이드: `AGENTS.md`
- 프로젝트 컨텍스트 요약: `GEMINI.md`
- Muse 운영 문서(로컬 통합본): `AGENTS_MUSE_CONTEST_UNIFIED.md` *(gitignore 대상)*

## 참고
- 루트 `settings.gradle`은 백엔드 모듈만 포함합니다.
- 프론트 앱은 각 디렉토리에서 별도 `npm` 명령으로 관리합니다.
