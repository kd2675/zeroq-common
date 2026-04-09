<!-- Updated: 2026-04-08 -->

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

## Current Focus

- `semo-front-service/`, `semo-back-service/`는 더 이상 인증 셸만 있는 상태가 아닙니다.
- 현재 `semo`는 `club`, `profile`, `board notice`, `schedule`, `attendance`, `feature activation`, `bracket`, `tournament`까지 실제 API와 화면이 연결된 상태입니다.
- `semo`의 핵심 방향은 “모임별 기능을 켜고 끌 수 있는 모듈형 서비스”입니다.

## Semo Feature-Modular Pattern

- 기능 목록은 `feature_catalog`에 둡니다.
- 모임별 활성화는 `feature_activation`으로 관리합니다.
- 기능 전용 데이터는 기능명 기준 테이블로 분리합니다.
  - 예: `attendance_session`, `attendance_checkin`
- 새 기능을 넣을 때 `club_<feature>` 식으로 묶기보다 기능 도메인 자체를 경계로 보고 설계합니다.
- 프론트 라우트도 기능성 화면은 `more` 기준으로 맞춥니다.
  - 유저: `/clubs/[clubId]/more/<feature>`
  - 관리자: `/clubs/[clubId]/admin/more/<feature>`
- 관리자 `more`는 기능 설정/운영 쪽, 유저 `more`는 기능 사용 쪽이라는 역할 분리가 기본입니다.

## Sub-Agent Policy

- 서브 에이전트 관련 상세 규칙은 `AGENTS_SUBAGENT_POLICY.md`로 분리한다.
- 기본값은 **메인 에이전트 단독 처리**다.
- 서브에이전트는 `.codex` 에이전트 설정과 `AGENTS.md` **양쪽 모두**에 현재 작업에 대해 서브에이전트 사용을 **명시적이고 무조건적으로 강제하는 문구가 동시에 있을 때만** 사용할 수 있다.
- 위 조건이 하나라도 빠지면 planner / researcher / coder / reviewer / fixer / tester / worker / default를 포함한 모든 서브에이전트 호출은 금지한다.
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
  - 새 포맷을 임의로 만들기보다 해당 서비스의 기존 응답 계약에 맞춘다.
- 에러 응답은 이 저장소 전체가 단일 포맷으로 완전히 통일된 상태는 아니다.
  - `web-common-core` 계열 기본 포맷: `{ success, code, message }`
  - `semo` / `zeroq-back-service` 현재 포맷: `{ success, code, message, status, timestamp, path, fieldErrors? }`
  - 따라서 새 API/예외 처리는 해당 서비스의 기존 에러 계약을 따르고, 별도 `{ code, message, details }` 포맷을 새로 도입하지 않는다.
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
- `semo` 기능 추가 시에는 최소한 `:semo-back-service:test`, `semo-front-service`의 `npm run lint`, `npm run build`를 같이 확인합니다.

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
- `semo-front-service/AGENTS_SEMO_MORE_FEATURE_CHECKLIST.md`
- `muse-back-service/AGENTS_MUSE_CONTEST_UNIFIED.md`


## JavaScript REPL (Node)
- Use `js_repl` for Node-backed JavaScript with top-level await in a persistent kernel.
- `js_repl` is a freeform/custom tool. Direct `js_repl` calls must send raw JavaScript tool input (optionally with first-line `// codex-js-repl: timeout_ms=15000`). Do not wrap code in JSON (for example `{"code":"..."}`), quotes, or markdown code fences.
- Helpers: `codex.cwd`, `codex.homeDir`, `codex.tmpDir`, `codex.tool(name, args?)`, and `codex.emitImage(imageLike)`.
- `codex.tool` executes a normal tool call and resolves to the raw tool output object. Use it for shell and non-shell tools alike. Nested tool outputs stay inside JavaScript unless you emit them explicitly.
- `codex.emitImage(...)` adds one image to the outer `js_repl` function output each time you call it, so you can call it multiple times to emit multiple images. It accepts a data URL, a single `input_image` item, an object like `{ bytes, mimeType }`, or a raw tool response object with exactly one image and no text. It rejects mixed text-and-image content.
- `codex.tool(...)` and `codex.emitImage(...)` keep stable helper identities across cells. Saved references and persisted objects can reuse them in later cells, but async callbacks that fire after a cell finishes still fail because no exec is active.
- Request full-resolution image processing with `detail: "original"` only when the `view_image` tool schema includes a `detail` argument. The same availability applies to `codex.emitImage(...)`: if `view_image.detail` is present, you may also pass `detail: "original"` there. Use this when high-fidelity image perception or precise localization is needed, especially for CUA agents.
- Example of sharing an in-memory Playwright screenshot: `await codex.emitImage({ bytes: await page.screenshot({ type: "jpeg", quality: 85 }), mimeType: "image/jpeg", detail: "original" })`.
- Example of sharing a local image tool result: `await codex.emitImage(codex.tool("view_image", { path: "/absolute/path", detail: "original" }))`.
- When encoding an image to send with `codex.emitImage(...)` or `view_image`, prefer JPEG at about 85 quality when lossy compression is acceptable; use PNG when transparency or lossless detail matters. Smaller uploads are faster and less likely to hit size limits.
- Top-level bindings persist across cells. If a cell throws, prior bindings remain available and bindings that finished initializing before the throw often remain usable in later cells. For code you plan to reuse across cells, prefer declaring or assigning it in direct top-level statements before operations that might throw. If you hit `SyntaxError: Identifier 'x' has already been declared`, first reuse the existing binding, reassign a previously declared `let`, or pick a new descriptive name. Use `{ ... }` only for a short temporary block when you specifically need local scratch names; do not wrap an entire cell in block scope if you want those names reusable later. Reset the kernel with `js_repl_reset` only when you need a clean state.
- Top-level static import declarations (for example `import x from "./file.js"`) are currently unsupported in `js_repl`; use dynamic imports with `await import("pkg")`, `await import("./file.js")`, or `await import("/abs/path/file.mjs")` instead. Imported local files must be ESM `.js`/`.mjs` files and run in the same REPL VM context. Bare package imports always resolve from REPL-global search roots (`CODEX_JS_REPL_NODE_MODULE_DIRS`, then cwd), not relative to the imported file location. Local files may statically import only other local relative/absolute/`file://` `.js`/`.mjs` files; package and builtin imports from local files must stay dynamic. `import.meta.resolve()` returns importable strings such as `file://...`, bare package names, and `node:...` specifiers. Local file modules reload between execs, while top-level bindings persist until `js_repl_reset`.
- Avoid direct access to `process.stdout` / `process.stderr` / `process.stdin`; it can corrupt the JSON line protocol. Use `console.log`, `codex.tool(...)`, and `codex.emitImage(...)`.
