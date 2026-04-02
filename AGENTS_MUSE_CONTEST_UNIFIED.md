# Muse Contest 통합 운영 문서 (로컬 합본)

기준일: 2026-03-04  
대상: `MUSE_CONTEST_FLOW_KO.md`, `MUSE_CONTEST_E2E_CHECKLIST_KO.md`, `MUSE_CONTEST_DEPLOY_CHECKLIST_KO.md` 통합본

## 1) 도메인 규칙/상태
### 핵심 규칙
- 작가는 콘테스트별 `출품권 결제` 후 `출품 등록`
- 관람자는 `VOTING` 단계 공개 작품에 투표
- 출품권은 콘테스트 간 공유되지 않음

### 콘테스트 phase
- `UPCOMING -> SUBMISSION -> REVIEW -> VOTING -> ENDED`
- 일정(`submission/voting` 시작·종료)으로 phase 자동 계산

### 출품 상태
- `SUBMITTED`, `APPROVED`, `REJECTED`

## 2) 구현 범위
1. 공개 조회: 목록/상세/출품/출품페이지/랭킹
2. 출품: 결제/등록/내 출품 조회/삭제(조건부 환불)
3. 투표: 동일 작품 중복 투표 차단
4. 관리자: 콘테스트 생성·수정·심사·결과확정
5. 오버뷰: `/api/muse/v1/overview` 전용 서비스

## 3) 정렬/노출 정책
1. 공개 출품 페이지는 `mode=SUBMITTED_ASC`만 허용
2. 정렬은 `createDate ASC, entryId ASC`(제출순)
3. `VOTING` 공개 목록은 `APPROVED`만 노출
4. `ENDED` 공개 목록은 `SUBMITTED/APPROVED/REJECTED` 아카이브 노출
5. 관리자 심사 상태 변경은 `REVIEW` 단계에서만 허용

## 4) 결과 확정 동작
1. `ENDED` 단계에서만 실행 가능
2. 이미 확정된 콘테스트는 `CONFLICT`
3. 대상 출품 0건은 실패가 아니라 `winners=[]` 성공 응답
4. 수상자는 득표수/제출시각/entryId 기준 정렬 후 상위 3개
5. 수상 외 출품은 `REJECTED` 처리, 수상자는 `profile_award/profile_stat` 누적

## 5) E2E 체크리스트
### 관리자
1. `/admin/contests` 생성/수정
2. `/admin/contests/review` 상태 변경(`REVIEW` 단계)
3. `ENDED`에서 결과 확정, 재확정 충돌 확인

### 작가
1. `SUBMISSION`에서 결제(+1) -> 출품(-1)
2. 콘테스트별 출품권 분리 확인
3. `SUBMITTED + SUBMISSION`에서만 삭제/환불(+1)

### 관람자
1. `VOTING`에서 타인 작품 투표
2. 중복 투표 `Already voted for this entry`
3. 자기 작품 투표 금지 확인

### 노출/권한
1. `/entries/page?mode=SUBMITTED_ASC` 제출순 확인
2. 비로그인 조회 허용, 쓰기 액션 로그인 필요
3. `/admin/*` 비관리자 접근 차단

### 정합성
1. `contest_entry_credit` 잔액 일치
2. `contest_entry_ledger.reason='VOTE'` + `ref_id='ENTRY:{entryId}'`
3. 결과 확정 시 수상/통계 반영 확인

## 6) 배포 체크리스트
### DB
1. `muse_all.sql`
2. 필요 시 `muse_content_seed.sql`

### 빌드
1. `./gradlew muse-back-service:compileJava`
2. `./gradlew cloud-back-server:compileJava`

### 게이트웨이
1. `GET /api/muse/v1/overview` 공개 허용
2. 공개 API 권한 정책 확인
3. CORS에 `http://localhost:3001` 포함

### 프론트
1. `muse-front-service` 포트 `3001`
2. `NEXT_PUBLIC_API_BASE_URL` 확인
3. 관리자 로그인 시 하단 네비 어드민 아이콘 노출 확인

### 롤백
1. 코드 롤백 우선
2. 결과 확정 반영 데이터(`contest_entry`, `profile_award`, `profile_stat`)는 별도 롤백 SQL/백업 복구 필요
