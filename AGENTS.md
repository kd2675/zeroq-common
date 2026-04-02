<!-- Updated: 2026-04-02 -->

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

## Sub-Agent Rules

### 아키텍처 원칙

#### 파일 수정은 메인 에이전트만 수행한다

- 모든 서브 에이전트는 `sandbox_mode = "read-only"`
- 서브 에이전트는 조언, 제안, 분석 결과만 텍스트로 출력한다
- 메인 에이전트가 서브 에이전트의 출력을 검토하고, 일관성을 확인한 뒤 직접 파일에 적용한다
- 이를 통해 동시성 충돌, 네이밍 불일치, 스타일 불일치를 원천 차단한다

#### 메인 에이전트의 책임

1. 서브 에이전트를 적절히 호출한다 (병렬 가능: 읽기 에이전트끼리)
2. 서브 에이전트의 제안을 검토한다
3. 프로젝트 컨벤션과 일치하는지 확인한 뒤 적용한다
4. 적용 후 빌드/타입 체크가 통과하는지 확인한다
5. 리뷰/테스트 루프가 상한에 도달하면 직접 판단하고 수정한다

### 단계 생략 금지

- 메인 에이전트는 파이프라인의 단계를 **절대로** 임의로 건너뛰면 안 된다
- "이미 구현된 것처럼 보인다", "diff가 작다", "시간이 부족하다", "테스트가 느리다" 같은 이유로 planner / researcher / coder / reviewer / tester 단계를 생략하면 안 된다
- 중규모 이상 작업에서 PHASE 1~5 중 필요한 단계가 정의되어 있다면, 완료 판정 전에 반드시 해당 단계를 실제로 수행해야 한다
- 리뷰에서 결함이 없다는 확인을 받기 전에는 "끝났다", "충분하다", "추가 작업 불필요"라고 판단하지 않는다
- 테스트 단계가 정의된 작업은 실제 실행 또는 명시적 실패 확인 없이 종료하지 않는다
- 루프 상한에 도달하기 전에는 fixer 재진입을 생략하지 않는다
- 루프 상한에 도달했다면 그 사실과 사유를 명시한 뒤에만 메인이 직접 판단한다
- 위 규칙은 "실질 코드 수정이 거의 없었던 경우"에도 동일하게 적용된다

#### 에이전트 등장 규칙

- **coder**: 파이프라인에서 딱 한 번, 최초 구현 단계에서만 등장
- **fixer**: 그 이후 모든 수정 담당 (리뷰 결함, 테스트 실패)
- 이유: coder를 다시 부르면 범위가 넓어지고 불필요한 변경이 섞일 위험이 있다. fixer의 "1 bug = 1 fix" 원칙이 수정 단계에 적합하다.

### 디폴트 코딩 파이프라인

모든 중규모 이상의 코딩 작업은 아래 파이프라인을 따른다.
소규모 작업(파일 1-2개, 명확한 요구사항)은 메인이 직접 처리한다.

> **중요**
>
> 아래 PHASE는 권장사항이 아니라 **기본 절차**다.
> 메인은 PHASE를 앞당겨 종료하거나, 중간 PASS 확인 없이 다음 단계로 건너뛰거나, reviewer / tester를 호출하지 않은 채 완료 처리하면 안 된다.
> 예외는 문서에 명시된 "소규모 작업"과 "루프 상한 도달 후 메인 직접 판단"뿐이다.
> 예외를 사용한 경우 최종 응답에서 어떤 예외를 적용했는지 분명하게 밝힌다.

```
┌─────────────────────────────────────────────────────────┐
│ PHASE 1. 계획                                            │
│                                                         │
│  planner ↔ 메인 (반복 대화)                               │
│  → 방향 합의 → 계획 확정 → API 계약서                      │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ PHASE 2. 사전 조사                                       │
│                                                         │
│  researcher(s) 병렬 실행                                  │
│  → 구조 분석, 의존성 파악, 기존 패턴 수집                    │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ PHASE 3. 최초 구현                                       │
│                                                         │
│  메인이 항목 분류 → coder(s) 병렬 제안 → 메인이 순차 적용    │
│  (coder는 여기서만 등장)                                   │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ PHASE 4. 리뷰 루프 (항목당 최대 2회)                       │
│                                                         │
│  메인이 항목 분류 → reviewer(s) 병렬 리뷰                   │
│    → 전체 PASS: PHASE 5로                                │
│    → 항목별 FAIL: fixer(s) 패치 제안 → 메인 적용 → 재리뷰   │
│            2회 FAIL 초과: 메인이 직접 판단/수정              │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ PHASE 5. 테스트 검증 (최대 2회)                            │
│                                                         │
│  tester 테스트 제안 → 메인이 적용/실행                      │
│    → PASS: 완료                                          │
│    → FAIL: fixer 패치 제안 → 메인이 적용 → tester 재검증    │
│            2회 FAIL 초과: 메인에게 상황 보고, 수동 판단       │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

#### PHASE 1. 계획

- 소규모: 메인이 직접 계획하고 PHASE 3로 바로 진행
- 중규모 이상: planner와 반복 대화

```
메인 → planner: 요구사항 전달, 접근 방식 요청
planner → 메인: 방향 제안 + 트레이드오프 질문 2-3개
메인 → planner: 결정 사항 + 추가 요구
planner → 메인: 구체화된 계획 + 남은 쟁점
메인 → planner: 최종 확정
planner → 메인: 최종 계획서 + API 계약서
```

한 번에 완성된 계획을 받지 않는다. 짧은 교환을 여러 번 하며 보완한다.
트레이드오프는 planner가 선택지를 제시하고 메인이 결정한다.

#### PHASE 2. 사전 조사

researcher를 호출하여 구현에 필요한 맥락을 수집한다.
여러 researcher를 병렬 실행할 수 있다 (읽기 전용이므로 안전).

수집 대상:
- 관련 파일 구조 및 모듈 경계
- 기존 유사 기능의 구현 패턴
- 의존성 관계 (어떤 서비스가 어떤 서비스를 호출하는지)
- planner 계획에서 참조할 기존 코드

#### PHASE 3. 최초 구현

메인이 planner의 계획을 **항목별로 분류**하여 각 coder에게 분배한다.
coder는 자신이 받은 항목에 대해서만 코드를 제안한다.

```
메인: 계획을 항목별로 분류
  → coder A: "User 엔티티 + Repository 구현 제안해줘"
  → coder B: "UserService 비즈니스 로직 제안해줘"
  → coder C: "UserController + DTO 제안해줘"
  (병렬 실행 — 모두 read-only이므로 안전)

메인: 각 coder의 제안을 수집 → 일관성 검토 → 순차 적용
```

- 메인이 항목을 분류할 때 각 항목의 **범위와 참조 파일**을 명확히 지정한다
- planner의 API 계약서를 모든 coder에게 공유하여 필드명/타입 일관성을 보장한다
- 적용 순서는 메인이 의존 관계를 고려하여 결정한다 (예: 엔티티 → 서비스 → 컨트롤러)
- 적용 시 coder 간 네이밍 불일치가 발견되면 메인이 직접 통일한다

**coder는 전체 파이프라인에서 이 단계에서만 등장한다.**

#### PHASE 4. 리뷰 루프

메인이 적용한 코드를 **항목별로 분류**하여 각 reviewer에게 분배한다.
reviewer는 자신이 받은 항목에 대해서만 리뷰한다.

```
메인: 변경된 항목별로 분류
  → reviewer A: "User 엔티티 + Repository 리뷰해줘"
  → reviewer B: "UserService 비즈니스 로직 리뷰해줘"
  → reviewer C: "UserController + DTO 리뷰해줘"
  (병렬 실행 — 모두 read-only이므로 안전)

메인: 각 reviewer 결과 수집
  → 전체 PASS: PHASE 5로
  → 일부 FAIL: 해당 항목만 fixer에게 전달 → 메인이 적용 → 해당 reviewer 재리뷰
```

- FAIL이 발생한 항목만 fixer → 재리뷰 루프에 진입한다
- PASS된 항목은 루프에 재진입하지 않는다
- fixer도 항목별로 병렬 실행할 수 있다 (각 fixer는 자기 항목의 결함만 패치 제안)

루프 상한: **항목당 최대 2회**
2회 초과 FAIL 시: 메인이 해당 항목의 reviewer 피드백을 직접 분석하고 수동으로 수정한다.

> **절대 규칙**
>
> - reviewer 결과를 받기 전에는 PHASE 4를 완료로 간주하지 않는다
> - 메인이 스스로 "문제 없어 보인다"고 판단해 reviewer 호출을 생략하면 안 된다
> - reviewer가 결함을 보고했다면, 루프 상한 전까지 fixer 또는 메인 수정 없이 종료하면 안 된다

#### PHASE 5. 테스트 검증

tester가 테스트 코드를 제안한다. 메인이 적용하고 실행한다.

- PASS → 완료
- FAIL → fixer가 실패 내역을 받아 최소 패치 제안 → 메인이 적용 → tester 재검증

루프 상한: **최대 2회**
2회 초과 FAIL 시: 메인에게 실패 상황을 상세 보고하고, 메인이 수동 판단한다.

> **절대 규칙**
>
> - tester 검증 또는 동등한 실제 실행 검증 없이 완료 처리하지 않는다
> - 메인이 "빌드는 될 것 같다", "변경이 UI뿐이라 괜찮다" 같은 추정으로 테스트 단계를 생략하면 안 된다
> - 테스트를 실행하지 못했다면 완료가 아니라 **미검증** 상태로 보고해야 하며, 왜 실행하지 못했는지 분명히 남긴다

### 버그 수정 파이프라인

기존 코드의 버그를 수정할 때는 별도의 단축 파이프라인을 사용한다.
coder는 등장하지 않는다.

```
1. researcher    → 원인 추적 (스택 트레이스, git blame, 호출 관계)
2. fixer         → 최소 패치 제안
3. 메인          → 적용
4. reviewer(s)   → 리뷰 (FAIL 시 fixer 재제안, 최대 2회)
5. tester        → 검증 (FAIL 시 fixer 재제안, 최대 2회)
```

- 버그 수정 파이프라인도 reviewer / tester 단계를 **절대로** 생략하지 않는다
- 버그가 재현되지 않더라도 researcher 조사와 reviewer 검토는 수행한다
- "간단한 한 줄 수정"이라도 버그 수정으로 분류했다면 위 순서를 따른다

### 리뷰 전용 파이프라인

PR이나 브랜치를 리뷰만 할 때 사용한다. 병렬 실행 가능.

```
researcher + reviewer 병렬
→ researcher: 영향받는 코드 경로 매핑
→ reviewer: 정확성, 보안, 회귀 위험 검토
→ 결과 종합하여 메인에게 보고
```

### 서브 에이전트 목록

| 에이전트 | 모델 | 역할 | 등장 시점 |
|---------|------|------|----------|
| planner | gpt-5.4 | 메인과 반복 대화로 계획 수립 | PHASE 1 |
| researcher | gpt-5.3-codex-spark | 코드 탐색, 의존성 추적, 원인 조사 | PHASE 2 (병렬) |
| coder | gpt-5.4 | 항목별 코드 제안 (diff 형태) | PHASE 3 (병렬, 1회만) |
| reviewer | gpt-5.3-codex-spark | 항목별 코드 리뷰, 결함 보고 | PHASE 4 (병렬) |
| fixer | gpt-5.4 | 항목별 결함에 대한 최소 패치 제안 | PHASE 4, 5 (병렬) |
| tester | gpt-5.4 | 테스트 코드 제안, 결과 분석 | PHASE 5 |

모든 서브 에이전트: `sandbox_mode = "read-only"`, 수정 권한 없음.

### 서브 에이전트 제안 적용 절차

메인 에이전트가 서브 에이전트의 코드 제안을 받았을 때:

1. **컨벤션 확인**: 이 문서의 네이밍, import 순서, 에러 처리 규칙에 맞는지
2. **일관성 확인**: 기존 코드와 스타일이 일치하는지 (변수명, 패턴)
3. **계약 확인**: planner가 정의한 API 계약과 일치하는지 (필드명, 타입)
4. **적용**: 문제없으면 파일에 반영
5. **검증**: 빌드/타입 체크 통과 확인

사소한 컨벤션 불일치는 서브 에이전트에 재요청하지 말고 메인이 직접 수정한다.
왕복을 최소화하고 메인이 최종 품질을 보장한다.

### 코딩 컨벤션

#### 네이밍

- **변수/함수**: camelCase (`getUserById`, `isValid`)
- **클래스/타입/인터페이스**: PascalCase (`UserService`, `CreateUserRequest`)
- **상수**: UPPER_SNAKE_CASE (`MAX_RETRY_COUNT`, `DEFAULT_PAGE_SIZE`)
- **파일명**: kebab-case (`user-service.ts`, `create-user.dto.ts`)
- **테스트 파일**: 원본 파일명 + `.test` 또는 `.spec` (`user-service.test.ts`)
- **DB 컬럼**: snake_case (`created_at`, `user_id`)

#### API 설계

- REST 엔드포인트: 복수형 명사 (`/api/users`, `/api/posts`)
- 응답 래퍼: 프로젝트에 공통 응답 타입이 있으면 반드시 사용
- 에러 응답: `{ code: string, message: string, details?: any }` 형식 통일
- HTTP 상태코드: 200(성공), 201(생성), 400(잘못된 요청), 401(미인증), 403(권한 없음), 404(없음), 409(충돌), 500(서버 오류)

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
- `semo`의 신규 `/more` 기능 추가나 대규모 재구성은 `AGENTS_SEMO_MORE_FEATURE_CHECKLIST.md`를 기준으로 진행합니다.

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
- `AGENTS_SEMO_MORE_FEATURE_CHECKLIST.md`
- `AGENTS_MUSE_CONTEST_UNIFIED.md`


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
