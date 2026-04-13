<!-- Updated: 2026-04-13 -->

# zeroq-common Agent Guide

## Purpose

`zeroq-common`은 ZeroQ, Muse, Semo, SBNG 서비스를 함께 다루는 혼합형 워크스페이스입니다.

- 백엔드: 루트 Gradle 멀티모듈
- 프론트엔드: 독립 Next.js 앱
- 저장소 형태: 루트 집계 저장소 + 하위 프로젝트 다수

## Workspace Map

### Backend modules in the root Gradle build
- `web-common-core/`
- `auth-common-core/`
- `auth-back-server/`
- `cloud-back-server/`
- `eureka-back-server/`
- `zeroq-back-service/`
- `zeroq-back-sensor/`
- `zeroq-sensor-gateway/`
- `semo-back-service/`
- `muse-back-service/`
- `image-back-server/`

### Frontend apps
- `zeroq-front-admin/`
- `zeroq-front-service/`
- `muse-front-service/`
- `semo-front-service/`
- `sbng-front-service/`

## Service-Specific Guidance

- 루트 `AGENTS.md`는 워크스페이스 공통 규칙만 유지합니다.
- 서비스별 설계 원칙, 기능 구조, 응답 계약 상세는 각 프로젝트의 `AGENTS.md`와 `README.md`를 우선 봅니다.
- `semo`, `muse`, `zeroq` 전용 구현 규칙은 루트에 길게 복제하지 말고 해당 프로젝트 문서에만 유지합니다.

## Sub-Agent Policy

- 이 워크스페이스의 기본 오케스트레이션은 `작업 지시자(depth 0) -> 중간관리자(depth 1) -> 서브에이전트(depth 2)` 구조다.
- 작업 지시자는 전체 목표를 분해하고, 중간관리자는 할당된 범위를 실행하며, 서브에이전트는 read-only advisory 역할만 수행한다.
- 중간관리자는 여러 개까지 둘 수 있지만, 각 중간관리자는 서로 겹치지 않는 파일 또는 모듈 범위만 소유한다.
- 작업 분할은 파일 소유권, 모듈 경계, 검증 독립성, 공통 계약 변경 여부를 기준으로 나눈다.
- 작업 플로우와 테스트 플로우는 같은 파일, 같은 모듈, 같은 검증 대상에 대해 동시에 겹치면 안 된다.
- 서브 에이전트 관련 상세 규칙은 `AGENTS_SUBAGENT_POLICY.md`로 분리한다.
- 이 규칙은 컨텍스트 압축 후에도 유지되어야 하는 **압축 불변 규칙**이다.

### 코딩 컨벤션

#### 네이밍

- **변수/함수**: camelCase (`getUserById`, `isValid`)
- **클래스/타입/인터페이스**: PascalCase (`UserService`, `CreateUserRequest`)
- **상수**: UPPER_SNAKE_CASE (`MAX_RETRY_COUNT`, `DEFAULT_PAGE_SIZE`)
- **파일명**: kebab-case (`user-service.ts`, `create-user.dto.ts`)
- **테스트 파일**: 원본 파일명 + `.test` 또는 `.spec` (`user-service.test.ts`)
- **DB 컬럼**: snake_case (`created_at`, `user_id`)

프론트엔드 App Router 예외:

- Next.js 예약 파일은 프레임워크 규칙을 따른다.
  - 예: `page.tsx`, `layout.tsx`, `loading.tsx`, `error.tsx`, `route.ts`, `providers.tsx`
- React 컴포넌트 파일은 해당 앱의 기존 패턴을 우선한다.
  - 기존 컴포넌트 파일이 PascalCase 위주면 신규 컴포넌트도 PascalCase로 맞춘다.
- hook 파일은 `use` prefix + camelCase를 유지한다.
  - 예: `useAuthSession.ts`, `useBottomNavScrollDocking.ts`
- util/store/type 성격 파일은 single-word면 소문자, multi-word면 camelCase를 기본으로 한다.
  - 예: `auth.ts`, `api.ts`, `queryClient.ts`, `statusTheme.ts`, `adminConsole.ts`
- 프론트 source에서 multi-word kebab-case 파일은 새로 만들지 않는다.
  - 예외는 Next.js 예약 파일, React Query의 `queries.ts` / `mutations.ts`처럼 이름이 고정된 파일뿐이다.
- 기존 파일을 rename했다면 import 경로와 서비스별 `AGENTS.md` 예시 경로도 함께 갱신한다.

#### API 설계

- REST 엔드포인트는 복수형 명사를 기본값으로 보되, 현재 코드베이스의 중첩 리소스/도메인 경로 규칙을 우선 유지한다.
  - 예: `/api/users`, `/api/posts`
  - 예: `/api/semo/v1/clubs/{clubId}/more/tournaments`
- 응답 래퍼는 서비스가 이미 채택한 공통 타입을 반드시 따른다.
  - `web-common-core` 기반 서비스는 `ResponseDataDTO`, `ResponseErrorDTO`를 우선 사용한다.
  - 새 포맷을 임의로 만들기보다 기존 공통 계약에 맞춘다.
- 에러 응답은 기본적으로 `web-common-core`의 `{ success, code, message }` 포맷을 사용한다.
- 별도 `{ code, message, details }` 류의 신규 포맷이나 서비스 전용 에러 바디를 추가하지 않는다.
- HTTP 상태코드는 현재 공통 `Code`/서비스별 예외 매핑에 맞춰 사용한다.
  - 기본 집합: 200, 201, 400, 401, 403, 404, 409, 500
  - 다만 생성 API의 `201 Created` 적용은 서비스별로 아직 완전히 통일되지 않았으므로, 신규 구현은 대상 서비스의 기존 패턴과 주변 API를 먼저 맞춘다.

#### 타입

- TypeScript: `strict: true`, `any` 사용 금지
- Java: 제네릭 활용, `Optional` 적극 사용, raw type 금지
- DTO와 엔티티를 반드시 분리

#### 에러 처리

- 외부 호출(API, DB)에는 반드시 try-catch
- 에러 메시지는 디버깅 가능하도록 구체적으로
- 사용자에게 노출되는 메시지와 내부 로그 메시지를 분리

#### Import 순서

1. 언어/프레임워크 내장 모듈
2. 외부 라이브러리
3. 프로젝트 내부 모듈 (절대 경로)
4. 상대 경로 import

각 그룹 사이에 빈 줄 하나.

#### 테스트

- 네이밍: `[대상]_[상황]_[기대결과]` (`createUser_duplicateEmail_throwsConflict`)
- 하나의 테스트에 하나의 assertion 원칙
- 외부 의존성은 mock/stub
- 테스트 간 상태 공유 금지

## Build / Verify

### Backend
- 전체 빌드: `./gradlew clean build` 또는 `./gradlew clean build -x test`
- 전체 테스트: `./gradlew test`
- 모듈 실행: `./gradlew :<module>:bootRun`
- 모듈 컴파일: `./gradlew :<module>:compileJava`

### Frontend
- 앱 디렉토리에서 `npm install && npm run dev`
- 린트: `npm run lint`
- 배포 확인: `npm run build && npm run start`

## Documentation Rules

- 루트 문서를 바꾸면 관련 서비스 문서와 `AGENTS_DOCUMENTATION_INDEX.md` 정합성도 확인합니다.
- 서비스별 상세 규칙은 루트에 중복해서 적지 않고 각 프로젝트 문서에 둡니다.
- 서비스 문서에는 최소한 역할, 실행 명령, 포트, 주요 경로, 통합 의존성을 넣습니다.
- 구현이 아직 얕은 프로젝트는 그 상태를 그대로 적고 과장하지 않습니다.
- `semo` 문서는 mock 라우트와 실제 API 라우트를 구분해서 쓰지 말고, 현재 실제 동선 기준으로 설명합니다.
- `semo` 기능 문서는 “기능 카탈로그 -> 활성화 -> 기능 전용 API/화면” 순서로 설명하는 편이 맞습니다.
- `semo`의 신규 `/more` 기능 추가나 대규모 재구성은 `semo-front-service/AGENTS_SEMO_MORE_FEATURE_CHECKLIST.md`를 기준으로 진행합니다.

## Testing Rules

- 백엔드 테스트는 `src/test/java` 기준입니다.
- 버그 수정은 가능하면 재현 테스트와 함께 처리합니다.
- 프론트는 현재 린트와 빌드 확인이 기본 검증입니다.
- 테스트 공백이 큰 모듈은 문서에도 그 사실을 남깁니다.
- 백엔드 모듈을 수정했으면 해당 모듈의 테스트 또는 최소 컴파일 검증을 수행합니다.
- 프론트 앱을 수정했으면 해당 앱의 `npm run lint`, `npm run build`를 기본 검증으로 봅니다.
- 하나의 기능이 백엔드와 프론트를 함께 수정했다면 양쪽 검증을 같이 수행합니다.

## Security / Config

- 비밀값은 커밋하지 않습니다.
- 환경별 설정은 `application-*.yml` 또는 `.env*`를 우선 봅니다.
- 포트 충돌과 auth/gateway/frontend 환경 값 정합성을 먼저 확인합니다.
- 이미지 업로드처럼 별도 서버가 끼는 작업은 프론트 업로드, 서비스 DB 저장값, 응답 URL 조립 책임을 어느 계층이 갖는지 문서에 명시합니다.

## Key Documents

- `README.md`
- `HELP.md`
- `AGENTS_DOCUMENTATION_INDEX.md`
- `AGENTS_SUBAGENT_POLICY.md`
