<!-- Updated: 2026-03-25 -->

# Semo Tournament Record Feature Implementation Plan

이 문서는 `semo`에 `대회기록` 기능을 도입할 때의 전체 구현 계획을 정리한 문서입니다.

기준:

- 현재 `semo`의 실제 코드 구조를 기준으로 작성합니다.
- `대회기록`은 독립 `more` 기능으로 구현합니다.
- `대회기록`의 중심은 `하위경기 링크`가 아니라 `참가신청 -> 엔트리 확정 -> 하위경기 편성`입니다.
- 이 문서는 대회 메타, 참가신청, 엔트리 확정, 라운드/브래킷, 하위경기 편성을 하나의 기능 안에서 완결하는 방향을 다룹니다.

---

## 1. 목표와 범위

### 목표

- 종목과 무관하게 대회를 생성하고 운영합니다.
- 대회 참가신청을 받고, 승인/확정된 참가자를 엔트리로 관리합니다.
- 확정된 엔트리를 기준으로 라운드와 하위경기를 편성합니다.
- 대회 단위 요약, 일정, 참가자, 브래킷 구조를 관리합니다.
- 유저 화면에서는 메인 대회목록과 내가 참여 중인 대회목록을 탭으로 나눠 봅니다.
- 유저는 권한이 있으면 대회 작성, 수정, 신청 취소를 할 수 있습니다.
- 삭제는 관리자 화면에서만 처리합니다.
- 게시판 공유, 캘린더 공유, 핀 고정, 활동 로그, 직책 권한, 홈 위젯까지 현재 `semo` 규칙에 맞게 연결합니다.

### 범위

- 포함:
  - `TOURNAMENT_RECORD` 기능 카탈로그 추가
  - 대회 메인 테이블
  - 참가신청 테이블
  - 참가 엔트리 테이블
  - 대회 라운드/브래킷 구조
  - 대회 내부 하위경기 테이블
  - 게시판 공유
  - 캘린더 공유
  - 핀 고정
  - 활동 로그
  - 직책 권한
  - 유저 홈 위젯
  - 유저 `/more/tournaments`
  - 관리자 `/admin/more/tournaments`

---

## 2. 핵심 방향

### 기능 구조 정책

- feature key: `TOURNAMENT_RECORD`
- user slug: `tournaments`
- admin slug: `tournaments`

### 유저/관리자 액션 정책

- 유저 화면:
  - 메인 대회목록
  - 내가 참여 중인 대회목록
  - 대회 상세
  - 대회 대진표/브래킷
- 유저가 가질 수 있는 권한:
  - 작성
  - 수정
  - 신청
  - 신청 취소
- 삭제는 유저 화면에서 제공하지 않습니다.
- 삭제는 관리자 화면의 운영 액션으로만 제공합니다.

원칙:

- 대회가 갑자기 사라지는 경험을 줄이기 위해 삭제는 일반 유저 동선에서 제외합니다.
- 유저 화면의 `취소`는 참가신청 취소 또는 참가 철회 의미로 한정합니다.

### 스포츠 분류 정책

- 대회는 종목을 필수로 가지지 않습니다.
- 종목 미설정 대회를 기본 전제로 둡니다.
- 경기 형식(`SINGLE`, `DOUBLE`, `TEAM`)과 참가/브래킷 정책만으로 운영 가능하게 설계합니다.

### 대진 형식 정책

- 각 대회는 하나의 `match_format`을 가집니다.
- `match_format` 기본값:
  - `SINGLE`
  - `DOUBLE`
  - `TEAM`
- `SINGLE`은 개인전입니다.
- `DOUBLE`은 복식입니다.
- `TEAM`은 단체전입니다.
- 단체전은 팀당 인원을 운영자가 직접 설정할 수 있어야 하며, 최소 `3명 이상`만 허용합니다.
- 대진표 생성과 엔트리 유효성 검사는 `match_format`과 `team_member_limit`을 기준으로 합니다.

### 도메인 흐름 정책

대회기록은 아래 순서로 동작합니다.

1. 대회 생성
2. 참가신청 오픈
3. 참가신청 접수
4. 참가 승인/반려 또는 확정
5. 엔트리 확정
6. 라운드/브래킷 생성
7. 하위경기 편성
8. 경기 결과 기록
9. 대회 종료

즉 하위경기는 외부 엔터티를 느슨하게 링크하는 구조가 아니라, 대회 기능 내부에서 직접 생성/관리되는 구조를 기본으로 봅니다.

---

## 3. DB 설계 원칙

### 3-1. 메인 테이블

- `tournament_record`

추천 컬럼:

- `tournament_record_id`
- `club_id`
- `author_club_profile_id`
- `title`
- `summary_text`
- `tournament_status`
  - 예: `DRAFT`, `APPLICATION_OPEN`, `ENTRY_CONFIRMED`, `ONGOING`, `COMPLETED`, `CANCELLED`
- `application_start_at`
- `application_end_at`
- `start_date`
- `end_date`
- `location_label`
- `match_format`
- `team_member_limit`
- `max_entry_count`
- `shared_to_board`
- `shared_to_calendar`
- `pinned`
- `deleted`
- `create_date`
- `update_date`

원칙:

- 대회의 수명주기를 이 테이블이 대표합니다.
- 참가신청 가능 기간과 실제 대회 기간은 분리합니다.
- `team_member_limit`은 `TEAM`일 때만 사용합니다.
- `TEAM`이면 `team_member_limit >= 3` 제약을 둡니다.

### 3-2. 참가신청 테이블

- `tournament_application`

추천 컬럼:

- `tournament_application_id`
- `tournament_record_id`
- `club_profile_id`
- `application_status`
  - 예: `APPLIED`, `APPROVED`, `REJECTED`, `CANCELLED`
- `application_note`
- `approved_by_club_profile_id`
- `approved_at`
- `create_date`
- `update_date`

원칙:

- 참가신청은 모임 멤버 기준으로 받습니다.
- 신청 이력과 승인 이력을 남깁니다.
- 신청과 엔트리는 같은 개념으로 섞지 않습니다.

### 3-3. 참가 엔트리 테이블

- `tournament_entry`

추천 컬럼:

- `tournament_entry_id`
- `tournament_record_id`
- `entry_type`
  - 예: `INDIVIDUAL`, `PAIR`, `TEAM`
- `display_name`
- `source_application_id`
- `entry_status`
  - 예: `ACTIVE`, `ELIMINATED`, `WITHDRAWN`, `DISQUALIFIED`, `WINNER`
- `seed_number`
- `sort_order`
- `create_date`
- `update_date`

원칙:

- 실제 대진 편성은 `tournament_entry` 기준으로 합니다.
- `tournament_application`에서 승인된 멤버만 엔트리로 승격할 수 있게 설계합니다.
- `SINGLE`이면 엔트리 하나가 멤버 1명을 가집니다.
- `DOUBLE`이면 엔트리 하나가 멤버 2명을 가집니다.
- `TEAM`이면 엔트리 하나가 멤버 `3명 이상`을 가집니다.
- 엔트리 실제 멤버 구성은 별도 멤버 테이블에서 관리합니다.

### 3-4. 엔트리 멤버 테이블

- `tournament_entry_member`

추천 컬럼:

- `tournament_entry_member_id`
- `tournament_entry_id`
- `club_profile_id`
- `member_role`
  - 예: `PLAYER`, `CAPTAIN`
- `sort_order`
- `create_date`

원칙:

- `SINGLE`은 1행, `DOUBLE`은 2행, `TEAM`은 3행 이상을 가져야 합니다.
- 동일 멤버가 같은 대회 안에서 서로 다른 엔트리에 중복 소속되지 않게 제약을 검토합니다.
- 단체전은 운영자가 팀명을 직접 정하고 팀 멤버를 수동 편성할 수 있어야 합니다.

### 3-5. 라운드 테이블

- `tournament_round`

추천 컬럼:

- `tournament_round_id`
- `tournament_record_id`
- `round_key`
  - 예: `GROUP_A`, `ROUND_16`, `QUARTER_FINAL`, `SEMI_FINAL`, `FINAL`
- `display_name`
- `round_type`
  - 예: `GROUP`, `BRACKET`, `FINAL`
- `sort_order`
- `create_date`
- `update_date`

### 3-6. 대회 내부 하위경기 테이블

- `tournament_match`

추천 컬럼:

- `tournament_match_id`
- `tournament_record_id`
- `tournament_round_id`
- `match_status`
  - 예: `PLANNED`, `ONGOING`, `COMPLETED`, `CANCELLED`
- `title`
- `scheduled_at`
- `ended_at`
- `location_label`
- `winner_entry_id`
- `sort_order`
- `create_date`
- `update_date`

원칙:

- 하위경기는 대회 내부 경기입니다.
- 별도 범용 경기 테이블을 링크하지 않습니다.
- 대회 결과 관리의 일관성을 위해 대회 도메인 안에서 완결되게 둡니다.

### 3-7. 하위경기 참가측 테이블

- `tournament_match_side`

추천 컬럼:

- `tournament_match_side_id`
- `tournament_match_id`
- `side_no`
- `tournament_entry_id`
- `score_summary`
- `result_status`
  - 예: `WIN`, `LOSE`, `DRAW`, `PENDING`

원칙:

- 하위경기 한 판은 기본적으로 side 2개를 가집니다.
- side는 항상 `tournament_entry`를 참조합니다.
- 따라서 개인전, 복식, 단체전 차이는 경기 side 구조가 아니라 엔트리 구성 차이로 해결합니다.

---

## 4. 조회 전략

### 목록 조회

- `tournament_record` 중심
- 상태별 필터
- 핀 고정/공유 여부 포함
- 참가신청 수, 확정 엔트리 수, 진행 경기 수 같은 요약값 포함

### 상세 조회

- `tournament_record`
- `tournament_application` 요약
- `tournament_entry`
- `tournament_entry_member`
- `tournament_round`
- `tournament_match`
- `tournament_match_side`

브래킷형 UI가 필요하면 round/order 기준으로 정렬합니다.

---

## 5. API 설계 초안

### 유저

- `GET /api/semo/v1/clubs/{clubId}/more/tournaments`
- `GET /api/semo/v1/clubs/{clubId}/more/tournaments/{tournamentId}`
- `GET /api/semo/v1/clubs/{clubId}/more/tournaments/my`
  - 내가 참여 중인 대회목록
- `POST /api/semo/v1/clubs/{clubId}/more/tournaments/{tournamentId}/applications`
  - 참가신청
- `DELETE /api/semo/v1/clubs/{clubId}/more/tournaments/{tournamentId}/applications/me`
  - 참가신청 취소

### 관리자

- `GET /api/semo/v1/clubs/{clubId}/admin/more/tournaments`
- `POST /api/semo/v1/clubs/{clubId}/admin/more/tournaments`
- `PUT /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}`
- `DELETE /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}`
- `POST /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/applications/{applicationId}/approve`
- `POST /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/applications/{applicationId}/reject`
- `POST /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/entries`
  - 엔트리 수동 추가 또는 신청 승인 기반 확정
- `DELETE /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/entries/{entryId}`
- `POST /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/entries/{entryId}/members`
  - 엔트리 멤버 구성
- `POST /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/rounds`
- `PUT /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/rounds/{roundId}`
- `DELETE /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/rounds/{roundId}`
- `POST /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/matches`
  - 하위경기 편성
- `PUT /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/matches/{matchId}`
- `DELETE /api/semo/v1/clubs/{clubId}/admin/more/tournaments/{tournamentId}/matches/{matchId}`

---

## 6. 권한 모델

권한 key 제안:

- `TOURNAMENT_RECORD_VIEW`
- `TOURNAMENT_RECORD_CREATE`
- `TOURNAMENT_RECORD_UPDATE_SELF`
- `TOURNAMENT_RECORD_UPDATE_ANY`
- `TOURNAMENT_RECORD_DELETE_ANY`
- `TOURNAMENT_RECORD_PIN`
- `TOURNAMENT_RECORD_APPLICATION_REVIEW`
- `TOURNAMENT_RECORD_ENTRY_MANAGE`
- `TOURNAMENT_RECORD_BRACKET_MANAGE`

원칙:

- 신청은 일반 멤버가 가능하게 두되, 승인/반려/엔트리 확정은 운영 권한으로 묶습니다.
- 브래킷 편성과 하위경기 생성은 별도 관리 권한으로 둡니다.
- 삭제는 관리자 전용 정책으로 고정하고, 유저용 `DELETE_SELF`는 두지 않습니다.

---

## 7. 공유 / 핀 / 활동 로그

### 공유 정책

- `postedToBoard = true`면 게시판 피드에 실제 노출
- `postedToCalendar = true`면 캘린더에 실제 노출

원칙:

- 대회기록은 게시판 공유, 캘린더 공유를 모두 기본 지원 대상으로 둡니다.
- 대회 상세나 카드에서도 공유 배지를 숨기지 않습니다.

### 핀 정책

- `pinned = true`면 게시판 중요 고정 영역 우선 노출

원칙:

- 대회기록도 다른 more 도메인과 동일하게 중요 고정 영역에 올라갈 수 있어야 합니다.
- 중요 고정 영역 라벨 규칙은 기존 게시판 카드와 같은 배지 체계를 따릅니다.

### 활동 로그

기록 대상:

- 대회 생성
- 대회 수정
- 대회 삭제
- 대회 핀 변경
- 참가신청 승인/반려
- 엔트리 확정/제거
- 엔트리 멤버 편성
- 라운드 생성/수정/삭제
- 하위경기 편성/수정/삭제

subject:

- `대회기록`

---

## 8. 유저 / 관리자 화면 계획

### 유저 `/more/tournaments`

- 기본 구조는 탭 2개를 둡니다.
  - `전체 대회`
  - `내가 참여 중`
- 공통 요소:
  - 진행 중 대회
  - 종목 필터
  - 핀 고정 대회
  - 게시판/캘린더 공유 배지

`전체 대회` 탭:

- 전체 대회 목록
- 신청 가능한 대회
- 최근 업데이트 대회

`내가 참여 중` 탭:

- 신청한 대회
- 승인된 대회
- 현재 진행 중인 대회
- 내가 속한 엔트리/팀 요약

상세:

- 대회 요약
- 신청 기간
- 현재 신청 인원
- 신청 상태
- 확정 엔트리
- 엔트리 구성원
- 브래킷/라운드
- 하위경기 목록
- 게시판/캘린더 공유 상태

유저 액션:

- 권한 있으면 작성
- 권한 있으면 수정
- 참가신청
- 참가신청 취소 또는 참가 철회
- 삭제는 없음

### 관리자 `/admin/more/tournaments`

- 운영 요약
- 상태별 대회 수
- 신청 대기 인원
- 확정 엔트리 수
- 최근 업데이트 대회
- 브래킷/하위경기 편성 현황

상세:

- 대회 수정
- 대회 삭제
- 신청 승인/반려
- 엔트리 확정
- 개인전/복식/단체전 엔트리 편성
- 라운드 생성
- 하위경기 편성
- 결과 입력

---

## 9. 위젯 계획

위젯 키 제안:

- `TOURNAMENT_RECORD_LATEST`

required feature:

- `TOURNAMENT_RECORD`

내용:

- 홈 위젯은 이 기능에서 우선순위가 높습니다.
- 가장 최근 대회 1건보다 `신청 중` 또는 `진행 중` 대회를 우선 노출합니다.
- 위젯은 아래 중 하나를 빠르게 보여줘야 합니다.
  - 지금 신청 가능한 대회
  - 지금 진행 중인 대회
  - 내가 참여 중인 가장 가까운 대회

위젯 표시 항목 권장:

- 대회명
- 종목
- 진행 상태
- 신청 기간 또는 대회 날짜
- 내가 참여 중인지 여부
- 클릭 시 상세 이동

---

## 10. 구현 순서

### Step 1. 기능/권한/공유 기준 확정

- `TOURNAMENT_RECORD`
- 권한 key
- 공유/핀 정책

### Step 2. DB + seed

- `tournament_record`
- `tournament_application`
- `tournament_entry`
- `tournament_entry_member`
- `tournament_round`
- `tournament_match`
- `tournament_match_side`
- `semo_ddl_all.sql`
- `semo_seed_all.sql`

### Step 3. 기능 카탈로그 / 활성화 / 권한

- `feature_catalog`
- `feature_permission_catalog`
- `ClubFeatureService`
- `ClubPositionService`

### Step 4. 백엔드 CRUD / 신청 / 엔트리 / 편성

- 대회 생성/수정/삭제
- 참가신청/취소
- 신청 승인/반려
- 엔트리 확정/제거
- 엔트리 멤버 편성
- 라운드 관리
- 하위경기 편성/결과 기록
- 활동 로그

### Step 5. 공유 브리지 / 피드 확장

- content type 추가
- board/calendar query 확장
- DTO 확장

### Step 6. 위젯

- widget catalog
- dashboard path
- 위젯 렌더링

### Step 7. 프론트 유저/관리자 화면

- home
- detail
- create/edit
- tabbed list UI
- application UI
- application review UI
- bracket/round UI
- tournament match UI

---

## 11. 최종 권장 결론

`대회기록`은 독립 기능으로 두고, 중심 개념을 아래처럼 잡습니다.

- `TOURNAMENT_RECORD`: 대회 자체 메타와 상태
- `TOURNAMENT_APPLICATION`: 참가신청
- `TOURNAMENT_ENTRY`: 확정 엔트리
- `TOURNAMENT_ENTRY_MEMBER`: 엔트리 구성원
- `TOURNAMENT_ROUND`: 라운드 구조
- `TOURNAMENT_MATCH`: 대회 내부 하위경기

즉 대회기록은 `하위경기를 외부에서 가져와 묶는 기능`이 아니라, `참가신청을 받아 엔트리를 확정하고 그 엔트리로 하위경기를 편성하는 기능`으로 설계하는 것이 현재 요구와 이후 확장성에 가장 잘 맞습니다.

추가로 대진표는 아래 형식을 기본 지원 대상으로 둡니다.

- 개인전: 엔트리당 1명
- 복식: 엔트리당 2명
- 단체전: 엔트리당 3명 이상, 인원은 운영자가 직접 설정

그리고 사용자 경험 기준으로는 아래를 고정 원칙으로 둡니다.

- 유저 화면은 `전체 대회`와 `내가 참여 중` 탭을 기본 구조로 둡니다.
- 삭제는 관리자 전용 액션으로 둡니다.
- 게시판 공유, 캘린더 공유, 핀 고정을 모두 지원합니다.
- 홈 위젯은 부가 요소가 아니라 핵심 진입점으로 보고 우선 설계합니다.
