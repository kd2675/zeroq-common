# Zeroq 개발 전용 기준서 (Development Only)

- 기준 버전: `v2.0 통합본`
- 통합 작성일: `2026-03-04`
- 원본 기준일: `2025-01-17`
- 목적: Zeroq 개발/테스트/배포/운영의 단일 기준 문서
- 제외: 시장성/투자/매출/ROI/Exit 등 사업성 항목

---

## 0. 문서 범위와 사용 규칙

### 0.1 반영한 원본 문서
1. Zeroq-Project-Document (통합 문서)
2. Business Plan
3. Project Proposal
4. PRD
5. Technical Specification
6. Design Specification
7. Development Plan
8. Test & Operations Manual

### 0.2 이 문서의 범위
- 포함: 개발에 필요한 요구사항, 설계, 데이터, API, UI/UX, 인프라, 테스트, 운영, 로드맵
- 제외: 투자 제안 세부, 밸류에이션, IR 문구 등 개발 비직결 정보

### 0.3 우선순위 규칙
1. **현재 코드베이스(As-Is)**를 최우선 기준으로 적용
2. 목표 기능/행동은 `PRD`를 적용하되, As-Is와 충돌 시 갭 항목으로 관리
3. 기술 구현은 `Technical Specification`을 적용하되, 실제 모듈 설정값(gradle/yml/package.json)으로 보정
4. 일정/운영은 `Development Plan`, `Test & Operations Manual` 적용
5. 문서 간 충돌은 본 문서 `16. 충돌/결정 로그`의 결정값을 단일 기준으로 사용

### 0.4 현재 코드베이스 분석 요약 (2026-03-04)

#### 모노레포 구성(실제)
- 백엔드 Gradle 모듈: `zeroq-back-service`, `zeroq-back-sensor`, `auth-back-server`, `auth-common-core`, `cloud-back-server`, `eureka-back-server`, `web-common-core`, `semo-back-service`, `muse-back-service`, `image-back-server`
- 프론트 앱: `zeroq-front-service`, `zeroq-front-admin`, `muse-front-service`, `semo-front-service`, `sbng-front-service`

#### 실제 스택 버전(코드 기준)
- Backend:
  - Java `21` (toolchain)
  - Spring Boot `4.0.2`
  - Spring Cloud `2025.1.0`
  - MySQL Connector `8.3.0`
  - Caffeine Cache 사용
- Frontend(`zeroq-front-service`):
  - Next.js `16.1.4`
  - React `19.2.3`
  - TypeScript `^5`
  - Tailwind CSS `^4`
  - Axios `^1.13.4`

#### ZeroQ 백엔드 구현 범위(As-Is)
- Base path: `/api/zeroq/v1/**`
- 구현 도메인:
  - Spaces
  - Occupancy
  - Reviews
  - Favorites
  - User Locations
- 미구현(문서 대비):
  - ZeroQ/HotQ 전용 API
  - 체크인/포인트/리더보드/알림 API
  - 소셜 로그인 API(해당 기능은 auth-back-server 측)
  - ZeroQ Profile API(신규 도입 예정)

#### Gateway/인증 처리(As-Is)
- Gateway: `cloud-back-server` 포트 `8080`
- ZeroQ 라우팅: `/api/zeroq/v1/** -> lb://zeroq-back-service`
- OAuth2/인증 엔드포인트: `/auth/**`, `/oauth2/**`는 auth-back-server로 라우팅
- Gateway가 JWT 검증 및 `X-User-*` 헤더 주입 (`UserContextArgumentResolver` 연동 가능)
- ZeroQ는 사용자 상세 조회를 auth로 재조회하지 않고 `userId`만 신뢰해 처리

#### 프론트 구현 범위(As-Is)
- `zeroq-front-service`:
  - 페이지: `/`(홈), `/login`
  - 로그인 동선:
    - 네이버 로그인 시작: `${NEXT_PUBLIC_API_URL}/oauth2/authorize/naver`
    - 로그인 완료 후 query `token`을 localStorage `accessToken` 저장
    - 로그아웃: `${NEXT_PUBLIC_API_URL}/auth/logout`
  - 나머지 PRD 페이지(`/zeroq`, `/hotq`, `/map`, `/places/[id]` 등)는 미구현
- `zeroq-front-admin`:
  - 현재 기본 템플릿 수준(실운영 관리자 화면 미구현)

#### 테스트 현황(As-Is)
- Backend: `ZeroqBackServiceApplicationTests.contextLoads()` 1건
- Frontend: 앱 소스 내 테스트 파일 없음

---

## 1. 제품 정의

### 1.1 제품명
- `Zeroq (Zero Queue)`

### 1.2 핵심 가치
- "비어있거나, 핫한 곳 - 양쪽 모두 가치있다"

### 1.3 핵심 전략
- `ZeroQ`: 편의성 추구 사용자(조용함, 대기 회피)
- `HotQ`: 트렌드 추구 사용자(인기 장소, SNS)
- 양극단 전략으로 상반된 니즈를 동시에 충족

### 1.4 대상 카테고리
- 카페
- 마트
- 헬스장
- 확장 대상: 공원 등

### 1.5 사용자/운영 주체 구조 (확정)
- `USER` (일반 사용자)
  - 대상 채널: `zeroq-front-service`
- `MANAGER` (매장 중간관리자)
  - 대상 채널: `zeroq-front-admin`
- `ADMIN` (플랫폼 운영자, 최상위)
  - 운영/정책 관리 주체

역할 전달 규칙:
- 인증은 `auth-back-server`가 담당
- Gateway가 JWT를 검증하고 `X-User-Role`, `X-User-Id` 헤더를 주입
- 각 백엔드는 `UserContext`를 통해 역할/사용자 ID를 사용

---

## 2. Queue 레벨/리워드 기준

### 2.1 공통 5단계 Queue 레벨

| 레벨 | 범위(기본) | 의미 | 컬러 | 포인트 |
|---|---:|---|---|---:|
| ZeroQ | 0-2 | 비어있음 | #4CAF50 | +15P |
| LowQ | 3-7 | 여유 | #FFEB3B | +3P |
| MidQ | 8-12 | 보통 | #FF9800 | +3P |
| HighQ | 13-19 | 혼잡 | #F44336 | +3P |
| HotQ | 20+ | 핫플레이스 | #FF1744 | +20P |

### 2.2 카테고리별 기준(점유율 기반 보조 기준)

#### 카페(30석 기준)
- ZeroQ: 0-2명 (0-7%)
- LowQ: 3-7명 (10-23%)
- MidQ: 8-12명 (27-40%)
- HighQ: 13-19명 (43-63%)
- HotQ: 20명+ (67%+)

#### 마트(200카트 기준)
- ZeroQ: 0-10대 (0-5%)
- LowQ: 11-40대 (6-20%)
- MidQ: 41-100대 (21-50%)
- HighQ: 101-150대 (51-75%)
- HotQ: 151대+ (76%+)

#### 헬스장(10기구 기준)
- ZeroQ: 0-1개 (0-10%)
- LowQ: 2-3개 (20-30%)
- MidQ: 4-6개 (40-60%)
- HighQ: 7-8개 (70-80%)
- HotQ: 9개+ (90%+)

### 2.3 리워드
- 체크인:
  - ZeroQ: +15P
  - HotQ: +20P
  - 기타 레벨: +3P
- 리뷰: +20P
- 사진 리뷰 추가: +10P
- SNS 공유: +5P
- 제약: 장소당 1일 1회 체크인
- 배지:
  - ZeroQ: 여유로운 발견자
  - HotQ: 트렌드세터

### 2.4 혼잡도 레벨 현재 구현값 (As-Is)
- 현재 코드(`CrowdLevel`)는 아래 5단계를 사용:
  - `EMPTY` (0~10%)
  - `LOW` (11~35%)
  - `MEDIUM` (36~65%)
  - `HIGH` (66~85%)
  - `FULL` (86~100%)
- 현재 `zeroq-back-service`는 `ZeroQ/HotQ` enum을 직접 사용하지 않음
- 개발 원칙:
  1. DB/백엔드 내부는 당분간 `CrowdLevel` 유지
  2. 프론트 표시는 필요 시 매핑 테이블로 변환
  3. ZeroQ/HotQ 도입은 별도 마이그레이션 작업으로 분리

---

## 3. 사용자/사용 시나리오

### 3.1 사용자군
- 편의성 추구자: 프리랜서, 학생, 재택근무자
- 트렌드 추구자: 20-30대, SNS 활동 활발 사용자

### 3.2 핵심 사용자 흐름
1. 앱 접속 후 현재 위치 기반 주변 장소 조회
2. Queue 레벨 확인
3. ZeroQ 또는 HotQ 필터 적용
4. 장소 상세 확인
5. 현장 체크인 및 포인트 적립
6. 리뷰 작성/리더보드 확인/즐겨찾기 관리

---

## 4. 기능 요구사항 (개발 기준)

### 4.1 Epic
- Epic 1: 실시간 Queue 확인
- Epic 2: ZeroQ/HotQ 필터
- Epic 3: 리워드/리더보드

### 4.2 User Story 목록
- US-001: 내 주변 장소 보기 (P0)
- US-002: Queue 5단계 확인 (P0)
- US-003: 장소 상세 정보 보기 (P0)
- US-004: ZeroQ만 보기 (P0)
- US-005: HotQ만 보기 (P0)
- US-006: 카테고리 필터 (P1)
- US-007: 체크인 포인트 적립 (P0)
- US-008: 리더보드 확인 (P1)
- US-009: 뱃지 시스템 (P2)

### 4.3 FR 상세

#### FR-001 Queue 레벨 표시
- 입력: `occupied_count`, `total_capacity`
- 처리:
  - 기본 구간 규칙 또는 카테고리별 기준 적용
  - 레벨/색상/아이콘 산출
- 출력:
  - 색상 배경
  - 숫자(점유 인원/가용 인원)
  - 레벨 텍스트(ZeroQ~HotQ)

#### FR-002 ZeroQ 필터
- 입력: ZeroQ 필터 탭 클릭
- 처리: `queue_level = 'ZeroQ'`
- 출력: ZeroQ 장소 리스트만 표시

#### FR-003 HotQ 필터
- 입력: HotQ 필터 탭 클릭
- 처리: `queue_level = 'HotQ'`
- 출력: HotQ 장소 리스트 + 리워드 안내

#### FR-004 체크인 포인트
- 입력: 장소/좌표 기반 체크인 요청
- 처리:
  - 거리 검증(100m 이내 정책)
  - 1일 1회/장소 제한
  - 당시 queue_level 기준 포인트 지급
- 출력: 체크인 결과 + 포인트

#### FR-005 리더보드
- HotQ 리더보드: HotQ 방문 횟수 순위
- ZeroQ 리더보드: ZeroQ 발견 횟수 순위
- 실시간 또는 단주기 캐시 갱신
- TOP 100 기준

#### FR-006 장소 검색/조회
- 주변 조회(반경, 카테고리, queueLevel 필터)
- 키워드 검색
- 상세 조회
- 시간대 히스토리 조회

#### FR-007 즐겨찾기/알림
- 즐겨찾기 추가/삭제/수정
- ZeroQ/HotQ 조건 알림 설정

#### FR-008 리뷰
- 리뷰 목록 조회(정렬/페이징)
- 리뷰 작성(이미지 업로드 포함)
- 좋아요/취소

#### FR-009 사용자
- 내 프로필 조회/수정
- 회원 탈퇴

#### FR-010 알림
- FCM 토큰 등록
- 알림 설정 조회/수정

### 4.4 수락 기준(대표)

#### AC-001 홈 초기 표시
- Given: 앱 실행 + 위치 권한 허용
- When: 홈 진입
- Then: 3초 내 주변 장소 목록 및 Queue 5단계 색상 표시

#### AC-002 ZeroQ 필터
- Given: 홈 화면
- When: ZeroQ 탭 선택
- Then: ZeroQ만 표시, 없으면 안내 문구 노출

#### AC-003 HotQ 필터
- Given: 홈 화면
- When: HotQ 탭 선택
- Then: HotQ만 표시, +20P 안내 노출

#### AC-004 체크인
- Given: 사용자 위치가 장소 100m 이내
- When: 체크인 실행
- Then:
  - ZeroQ면 +15P
  - HotQ면 +20P
  - 그 외 +3P

---

## 5. 비기능 요구사항 (NFR)

### 5.1 성능
- API 응답: `p95 < 500ms`
- 앱 초기 로딩: `< 3초`
- 데이터 지연: `< 1분`
- 동시 접속: `10,000`
- RPS: `1,000` 목표

### 5.2 안정성/복구
- 가용성: `99.9%`
- RTO: `1시간`
- RPO: `5분`

### 5.3 품질
- 앱 크래시율: `< 1%`
- 테스트 커버리지: `80%`

### 5.4 보안
- HTTPS 필수(TLS 1.3)
- JWT 기반 인증
- SQL Injection/XSS/CSRF 대응
- Rate Limit: `100 req/min/user`
- CORS 허용 도메인 제한

---

## 6. 시스템 아키텍처

### 6.1 논리 구조 (As-Is)
1. 사용자 브라우저 (`zeroq-front-service`)
2. API Gateway (`cloud-back-server`, 8080)
3. ZeroQ Backend (`zeroq-back-service`, 20180 local)
4. Auth Backend (`auth-back-server`, 사용자/인증)
5. MySQL (master/slave routing in app layer)
6. Eureka 서비스 디스커버리

### 6.2 포트 구성 (현재 로컬 기준)
- Gateway: `8080`
- zeroq-back-service: `20180` (local/dev), `10180`(prod), `30180`(test)
- Frontend dev: `3001` (권장 실행값, 스크립트 인자)
- MySQL: `23306` (현재 local yml 기준 외부 주소 사용)
- Eureka: `8761`

### 6.3 라우팅/인증 흐름 (As-Is)
1. Frontend -> Gateway `http://localhost:8080`
2. Gateway route:
   - `/api/zeroq/v1/**` -> `zeroq-back-service`
   - `/auth/**`, `/oauth2/**`, `/api/users/**` -> `auth-back-server`
3. Gateway는 OAuth2 Resource Server로 JWT 검증 수행
4. Gateway가 `X-User-Id`, `X-User-Name`, `X-User-Role` 헤더 주입
5. Backend는 필요 시 `UserContextArgumentResolver`로 사용자 컨텍스트 수신

### 6.4 데이터 접근 구조 (As-Is)
- `zeroq-back-service`는 `PubDataConfig`로 master/slave DataSource 구성
- `RoutingDataSource`가 트랜잭션 readOnly 여부에 따라 slave/master 선택
- JPA `ddl-auto=validate`

### 6.5 네트워크 정책 (강제)
- 클라이언트(프론트)는 **반드시 Gateway만 호출**
- 금지:
  - 프론트 -> `zeroq-back-service:20180` 직접 호출
  - 프론트 -> 개별 마이크로서비스 포트 직접 호출
- 허용:
  - 프론트 -> `NEXT_PUBLIC_API_URL` (Gateway) 단일 경로

---

## 7. 기술 스택

### 7.1 Backend (As-Is)
- Java `21`
- Spring Boot `4.0.2`
- Spring Cloud `2025.1.0`
- Spring Data JPA
- Spring Validation / Actuator / Cache(Caffeine)
- OpenFeign + Eureka Client
- MySQL Connector `8.3.0`

### 7.2 Frontend (As-Is)
- Next.js `16.1.4` (App Router)
- React `19.2.3`
- TypeScript `^5`
- Tailwind CSS `^4`
- Axios `^1.13.4`

### 7.3 Data/Infra (As-Is)
- MySQL (master/slave 구성 사용)
- Redis: zeroq-back-service 기준 직접 연동 코드 없음(추후 도입 대상)
- Eureka
- API Gateway(cloud-back-server)
- JWT/OAuth2 인증은 auth-back-server + gateway 조합

### 7.4 목표 스택 대비 메모
- 기존 문서의 Java17/SpringBoot3.2/Next14 기준은 현재 코드와 불일치
- 본 문서에서는 **코드베이스 버전값(As-Is)**을 기준으로 유지

---

## 8. 백엔드 구현 기준

### 8.1 패키지/레이어 컨벤션
- 컨트롤러: `act`
- 서비스: `biz`
- 값 객체: `vo`
- DTO/Repository: `database/pub` 하위
- Java 네이밍:
  - 클래스: UpperCamelCase
  - 메서드/필드: lowerCamelCase
  - 패키지: 소문자
- 들여쓰기 4칸

### 8.2 트랜잭션 규칙
- 서비스 클래스 기본: `@Transactional(readOnly = true)`
- 쓰기 메서드만 별도 `@Transactional`로 override

### 8.3 Queue 계산 기준 로직
```java
public enum QueueLevel {
    ZEROQ(0, 2),
    LOWQ(3, 7),
    MIDQ(8, 12),
    HIGHQ(13, 19),
    HOTQ(20, Integer.MAX_VALUE);
}
```

### 8.4 서비스 경계 (As-Is + Target)
- As-Is:
  - `SpaceService`
  - `OccupancyService`
  - `ReviewService`
  - `FavoriteService`
  - `UserLocationService`
- Target(미구현):
  - ProfileService(ZeroQ, Muse 패턴)
  - CheckInService
  - PointService
  - LeaderboardService
  - NotificationService

---

## 9. 프론트엔드 구현 기준

### 9.1 라우트 구조
- As-Is:
  - `/` 홈 (로그인 상태 확인 + 로그아웃 버튼)
  - `/login` (네이버 OAuth2 진입 및 token 수신 처리)
- Target:
  - `/zeroq`
  - `/hotq`
  - `/map`
  - `/places/[id]`
  - `/favorites`
  - `/leaderboards/hotq`
  - `/leaderboards/zeroq`
  - `/points`
  - `/my/profile`
  - `/my/reviews`
  - `/my/settings`

### 9.2 핵심 UI 컴포넌트
- QueueBadge(large/medium)
- PlaceCard
- FilterTabs(전체/ZeroQ/HotQ)
- BottomNavigation
- LeaderboardList
- CheckInActionBar(하단 고정)

### 9.3 디자인 토큰
- Queue 색상:
  - ZeroQ #4CAF50
  - LowQ #FFEB3B
  - MidQ #FF9800
  - HighQ #F44336
  - HotQ #FF1744
- 브랜드:
  - Primary #FF5722
  - Secondary #212121

### 9.4 타이포그래피
- 한글: Pretendard
- 영문/숫자: Inter
- 로고: Montserrat Black

### 9.5 인터랙션
- Queue 변화: Pulse 200ms
- 카드 탭: Scale 0.95
- 화면 전환: Slide 300ms
- 로딩: Skeleton shimmer
- 제스처:
  - Pull to Refresh
  - 카드 스와이프(즐겨찾기)

### 9.6 접근성
- WCAG 2.1 AA
- 대비비 4.5:1 이상
- 터치 영역 44x44 이상
- 색맹 대응: 색상 + 아이콘 + 텍스트 동시 제공

### 9.7 타입 스케일 (원문값 보존)
- Display 1: 48px / Bold
- H1: 32px / Bold
- H2: 24px / Bold
- H3: 20px / SemiBold
- Body 1: 16px / Regular
- Body 2: 14px / Regular
- Caption: 12px / Regular
- Queue 숫자: 64px / Black

### 9.8 아이콘 기준 (원문값 보존)
- Queue 레벨:
  - ZeroQ: 체크 아이콘
  - LowQ: 물결 아이콘
  - MidQ: 느낌표 아이콘
  - HighQ: 경고 아이콘
  - HotQ: 불꽃 아이콘
- 주요 내비게이션:
  - 홈, 즐겨찾기, 리더보드, 마이, 검색, 필터

### 9.9 다크 모드 기준 (원문값 보존)
- Background: #121212
- Card: #1E1E1E
- Text: #FFFFFF
- Queue 조정색:
  - ZeroQ: #66BB6A
  - HotQ: #FF5252

### 9.10 화면 카피/레이아웃 가이드 (원문값 보존)
- 홈:
  - 위치 표기: `"강남역 · 지금"` 형태
  - 필터: `[전체] [🟢 ZeroQ만] [🔥 HotQ만]`
  - 하단 탭: `[홈] [즐겨찾기] [리더보드] [마이]`
- ZeroQ 전용:
  - 헤더 카피: `"🟢 ZeroQ - 여유로운 공간"`
  - 안내 카피: `"지금 비어있는 곳을 찾아드릴게요"`
  - 보상 카피: `"체크인 시 +15P"`
- HotQ 전용:
  - 헤더 카피: `"🔥 HotQ - 지금 핫한 곳"`
  - 안내 카피: `"지금 가장 인기있는 핫플레이스"`
  - 보상 카피: `"체크인 시 +20P, SNS 공유 시 +5P"`
- 장소 상세:
  - 핵심 정보: 장소명/주소/전화/영업시간
  - 상태 정보: 빈자리 수, 점유율 바, 마지막 업데이트
  - 하단 고정 액션: 길찾기/체크인

---

## 10. 데이터 모델 (MySQL)

### 10.1 핵심 엔티티/테이블 (As-Is)
- 공간/카테고리:
  - `space`
  - `category`
  - `location`
  - `amenity`
- 점유:
  - `occupancy_data`
  - `occupancy_history`
  - `crowd_level`(enum)
- 사용자 활동:
  - `review`
  - `favorite`
  - `user_location`
  - `user_behavior`
  - `user_preference`
- 센서/배터리:
  - `sensor`
  - `sensor_attachment`
  - `sensor_type`
  - `battery_status`
  - `battery_history`
  - `low_battery_alert`
  - `nfc_tag`
- 분석/통계/알림:
  - `analytics_data`
  - `space_insights`
  - `peak_hours`
  - `notification`
  - `notification_preference`

### 10.2 As-Is 스키마 특징
- `space` 중심 모델: 위치(`location`) 1:1, 카테고리(`category`) N:1
- 점유 모델:
  - `occupancy_data`: 현재 점유 상태
  - `occupancy_history`: 시계열 이력
- 리뷰/즐겨찾기/위치이력은 userId(Long) 기반 참조(사용자 엔티티 직접 조인 없음)
- 주요 인덱스:
  - `space(category_id, name)`
  - `occupancy_data(space_id, updated_at)`
  - `occupancy_history(space_id, created_at)`
  - `review(space_id, created_at), review(user_id)`
  - `favorite(user_id, space_id unique)`
  - `user_location(user_id, space_id), user_location(visited_at)`

### 10.3 Target 대비 갭(미구현 테이블)
- 현재 코드에 직접 정의되지 않은 모델:
  - `check_ins`
  - `points`
  - `leaderboards` 전용 테이블
  - `queue_level`(ZeroQ/HotQ) 전용 컬럼 체계
- 계획:
  1. `CrowdLevel` 기반 운영 유지
  2. 체크인/포인트 도입 시 신규 테이블 추가
  3. ZeroQ/HotQ는 뷰 계층 매핑 후 DB 확장 여부 결정

---

## 11. API 명세 (개발용 통합)

### 11.1 Base Path / 라우팅 (As-Is)
- Gateway 경유: `http://localhost:8080/api/zeroq/v1/**`
- 서비스 직행(local)은 **금지(운영/개발 정책)**
- 참고: 기존 문서의 `/api/v1/**` 표기는 현재 코드 기준과 다름

### 11.2 Spaces API (As-Is)
- `GET /api/zeroq/v1/spaces`
  - query: `page`(default 0), `size`(default 20)
- `GET /api/zeroq/v1/spaces/{id}`
- `GET /api/zeroq/v1/spaces/category/{categoryId}`
- `GET /api/zeroq/v1/spaces/search`
  - query: `keyword`, `categoryId?`, `page`, `size`
- `GET /api/zeroq/v1/spaces/top-rated`
- `POST /api/zeroq/v1/spaces` (현재 stub, TODO 존재)
- `PUT /api/zeroq/v1/spaces/{id}` (현재 stub, TODO 존재)
- `DELETE /api/zeroq/v1/spaces/{id}` (논리 삭제)

### 11.3 Occupancy API (As-Is)
- `GET /api/zeroq/v1/occupancy/spaces/{spaceId}`
- `GET /api/zeroq/v1/occupancy/spaces/{spaceId}/history`
  - query: `page`, `size`
- `GET /api/zeroq/v1/occupancy/spaces/{spaceId}/average`
  - query: `days`(default 7)

### 11.4 Reviews API (As-Is)
- `GET /api/zeroq/v1/reviews/spaces/{spaceId}`
  - query: `page`, `size`
- `GET /api/zeroq/v1/reviews/users/{userId}`
  - query: `page`, `size`
- `POST /api/zeroq/v1/reviews/spaces/{spaceId}`
  - query params: `title`, `content`, `rating`
  - userId는 Gateway `UserContext`에서 주입
- `DELETE /api/zeroq/v1/reviews/{reviewId}`
  - userId는 Gateway `UserContext`에서 주입
- `GET /api/zeroq/v1/reviews/spaces/{spaceId}/rating`

### 11.5 Favorites API (As-Is)
- `GET /api/zeroq/v1/favorites`
  - query: `page`, `size`
  - userId는 Gateway `UserContext`에서 주입
- `POST /api/zeroq/v1/favorites/{spaceId}`
  - query: `note?`
  - userId는 Gateway `UserContext`에서 주입
- `DELETE /api/zeroq/v1/favorites/{spaceId}`
  - userId는 Gateway `UserContext`에서 주입

### 11.6 User Locations API (As-Is, Muse 패턴 적용)
- `POST /api/zeroq/v1/user-locations`
  - body: `spaceId`, `visitedAt`, `leftAt?`, `durationMinutes?`, `latitude`, `longitude`, `note?`
  - userId는 Gateway `UserContext`에서 주입
- `GET /api/zeroq/v1/user-locations/{id}`
- `GET /api/zeroq/v1/user-locations/me`
- `GET /api/zeroq/v1/user-locations/me/space/{spaceId}`
- `GET /api/zeroq/v1/user-locations/me/after`
  - query: `startTime` (ISO datetime)
- `GET /api/zeroq/v1/user-locations/space/{spaceId}/visits/count`

### 11.7 Auth/OAuth2 경로 (As-Is, Gateway + auth-back-server)
- `GET /oauth2/authorize/naver`
- `POST /auth/logout`
- `POST /auth/login`
- `POST /auth/refresh`

### 11.8 Target API 대비 갭
- 현재 미구현:
  - `/places/nearby`, `/places/zeroq`, `/places/hotq`
  - 체크인/포인트/리더보드/알림 API
  - ZeroQ 프로필 API(`/api/zeroq/v1/profile/*`)
- 정리 원칙:
  1. As-Is API를 우선 문서화(OpenAPI)
  2. Target API는 `vNext`로 분리 설계
  3. 경로 정책은 `/api/zeroq/v1` 유지

---

## 12. IoT/센서 명세

### 12.1 하드웨어
- MCU: ESP32-WROOM-32D
- 센서: HC-SR04 (2-400cm)
- NFC: PN532
- 배터리: 18650 3000mAh
- 크기: 50x50x10mm
- 무게: 50g

### 12.2 통신
- BLE 5.0 + Wi-Fi 2.4GHz
- 프로토콜: MQTT

### 12.3 전력
- 평균 소비: 2.18mA
- 이론 수명: 57일
- 운영 수명 목표: 40일
- 교체 주기: 2개월

### 12.4 유지보수
- 일일: 활성 수, 저전력(<20%), 통신 두절 확인
- 주간: 교체 일정/현장 교체
- 월간: OTA 업데이트, 정확도 샘플링(10%)

### 12.5 BOM 단가표 (원문값 보존)
| 부품 | 모델 | 단가 |
|---|---|---:|
| MCU | ESP32 | $2.50 |
| 초음파 센서 | HC-SR04 | $1.00 |
| NFC | PN532 | $3.00 |
| 배터리 | 18650 | $3.50 |
| PCB | 2-Layer | $1.00 |
| 케이스 | ABS | $2.00 |
| 합계 |  | $15.80 |

### 12.6 센서 백엔드 모듈 구현 상태 (As-Is)
- `zeroq-back-sensor`는 현재 최소 부트스트랩 상태:
  - Spring Boot 4.0.2
  - Java 21
  - Caffeine Cache 설정
  - 실제 MQTT ingest/가공 로직 미구현
- 따라서 센서 데이터 파이프라인은 문서상 Target이고, 코드상 구현은 추후 작업 필요

---

## 13. 배포/운영 기준

### 13.1 서버 환경
- Ubuntu 22.04 LTS
- Nginx 1.24
- Java 21(OpenJDK)
- Node.js 20+
- MySQL 8.x
- Gateway: cloud-back-server(8080)
- Eureka: 8761

### 13.2 라우팅 기준 (As-Is)
- 로컬 개발 기본:
  - Frontend -> `http://localhost:8080` (Gateway)
  - Gateway `/api/zeroq/v1/**` -> zeroq-back-service
  - zeroq-back-service local port -> `20180`
- Frontend dev port:
  - `zeroq-front-admin`: `3000`
  - `zeroq-front-service`: `3001`
- Nginx/systemd는 운영 배포 단계에서 적용

### 13.3 배포 프로세스
1. 코드 푸시/풀
2. 백엔드 빌드 `./gradlew build`
3. 프론트 빌드 `npm run build`
4. 서비스 재시작(systemd)
5. 헬스체크
6. 모니터링 확인

### 13.4 systemd 관리 항목
- zeroq-backend.service
- zeroq-frontend.service
- mysql.service
- redis.service
- mosquitto.service

### 13.5 모니터링
- 시스템: 가용성, 응답시간, 에러율
- 센서: 활성/오프라인, 배터리, 정확도
- 비즈니스: DAU/MAU, 가입, 조회수

### 13.6 알림 규칙
- Critical(SMS): API 다운, DB 실패, 에러율 > 5%
- High(Slack): 응답 > 1초, 센서 100개+ 오프라인
- Medium(Slack): 저배터리 센서 10개+

### 13.7 장애 대응 등급
- L1 Critical: 전체 장애, 1시간 내 조치
- L2 High: 주요 기능 장애, 2시간 내 조치
- L3 Medium: 일부 기능, 다음 근무시간 조치

### 13.8 장애 대응 절차
1. 감지
2. 확인(영향/레벨)
3. 소통(Slack/공지)
4. 임시조치 -> 근본조치
5. 복구확인
6. Post-mortem

### 13.9 고객지원 SLA (원문값 보존)
- 웹 채팅: 평일 10-18시, 5분 내 1차 응답
- 이메일: 24시간 내 1차 응답
- 앱 내 FAQ 유지

### 13.10 롤백 트리거 (원문값 보존)
- 에러율 > 5%
- 크래시율 > 2%
- 주요 기능 장애 발생
- 의사결정자: Tech Lead

---

## 14. 테스트 기준

### 14.1 테스트 분배
- Unit 80%
- Integration 15%
- E2E 5%
- Manual: 매 Sprint

### 14.1.1 현재 테스트 현황 (As-Is)
- Backend:
  - `ZeroqBackServiceApplicationTests.contextLoads()` 1건만 존재
  - 도메인 서비스/컨트롤러 테스트 부재
- Frontend:
  - 앱 소스 테스트 파일 부재
- 결론:
  - 목표 분배는 유지하되, 현재는 테스트 기반이 미구축 상태

### 14.2 주요 테스트 케이스
- TC-001 ZeroQ 필터 동작
- TC-002 HotQ 필터 동작
- TC-003 체크인 포인트 지급 규칙

### 14.3 성능 테스트
- 동시접속 1,000
- RPS 500
- 10분 지속
- 목표:
  - p95 < 500ms
  - 에러율 < 1%

### 14.4 보안 테스트
- OWASP ZAP
- 릴리스 전 수행
- SQLi/XSS/CSRF 점검

### 14.5 Sprint 내 검증 흐름
1. 개발 중 Unit
2. PR 전 Integration
3. Staging 배포 후 Smoke
4. 금요일 Regression

### 14.6 릴리스 전
- D-7: 기능/성능/보안 전체
- D-3: 베타/버그수정
- D-1: 최종 Smoke

---

## 15. 개발 로드맵/실행 단계 (Step-by-Step)

### Step 0. As-Is 정합화 (즉시)
- API 경로 기준 통일: `/api/zeroq/v1/**`
- 문서/코드 불일치 제거(Java21/SpringBoot4/Next16)
- Frontend 하드코딩 URL을 `NEXT_PUBLIC_API_URL` 기반으로 정리

### Step 1. 백엔드 기능 완성도 보강
- `SpaceController`의 POST/PUT TODO 구현
- 즐겨찾기 reorder API 노출 검토
- 리뷰 작성을 request body DTO 방식으로 정규화 검토

### Step 2. ZeroQ 도메인 확장
- `CrowdLevel` -> ZeroQ/HotQ 매핑 계층 추가
- nearby/zeroq/hotq 조회 API 설계 및 구현
- user-location/occupancy 기반 추천 조회 흐름 연결

### Step 3. 포인트/체크인/리더보드 도입
- `check_ins`, `points` 스키마/엔티티 추가
- 체크인 거리 검증 및 1일 1회 규칙 구현
- 리더보드 집계 배치/캐시 전략 확정

### Step 4. 프론트 기능 확장
- `/zeroq`, `/hotq`, `/map`, `/places/[id]`, `/favorites` 구현
- 디자인 토큰/컴포넌트 시스템 도입
- API 에러/로딩/빈 상태 공통 처리

### Step 5. 품질/운영 체계 구축
- 서비스/컨트롤러 테스트 확충
- Gateway 통합 테스트 및 인증 헤더 시나리오 검증
- 모니터링 지표, 롤백 절차, 배포 자동화 정리

---

## 16. 충돌/결정 로그 (중요)

### 16.1 HotQ 포인트 상충
- 출처 충돌:
  - 일부 문서: HotQ +10P
  - 다수 문서/PRD: HotQ +20P
- 결정: `HotQ +20P`를 기준값으로 채택

### 16.2 ZeroQ/HotQ 레벨 기준 상충 가능성
- 절대 인원 기준 vs 카테고리별 점유율 기준이 동시에 존재
- 결정:
  - 1차: 카테고리별 기준 적용(운영 정확도 향상)
  - 2차: 기본 절대값은 fallback 룰로 유지

### 16.3 KPI/마일스톤 수치 일부 불일치
- Year 1 장소 수(50/500) 등 문서 간 차이 존재
- 결정:
  - 개발 게이트 기준은 `Phase 기반(5 -> 50 -> 500)`으로 사용
  - 사업/투자 수치는 개발 완료 정의에서 제외

### 16.4 보안 토큰 수명
- 기존 문서 표기(Access 7일/Refresh 30일)는 As-Is와 불일치
- 현재 적용값은 `16.8` 기준(Access 1시간/Refresh 14일)

### 16.5 프로젝트 구조 표기 차이
- 일부 문서의 샘플 경로와 실제 저장소 모듈 구조가 상이할 수 있음
- 결정:
  - 실제 구현은 현재 모노레포 모듈 구조(`zeroq-back-service`, `zeroq-front-service` 등)를 우선

### 16.6 API Base Path 충돌
- 출처 충돌:
  - 일부 문서: `/api/v1/**`
  - 실제 코드/Gateway: `/api/zeroq/v1/**`
- 결정: `zeroq-back-service` API는 `/api/zeroq/v1/**`를 단일 기준으로 사용

### 16.7 기술 스택 버전 충돌
- 출처 충돌:
  - 기존 문서: Java17, Spring Boot 3.2, Next.js 14
  - 실제 코드: Java21, Spring Boot 4.0.2, Next.js 16.1.4
- 결정: 실행/빌드/호환성은 **실제 코드 버전**을 기준으로 사용

### 16.8 JWT 만료 정책 충돌
- 출처 충돌:
  - 일부 문서: Access 7일 / Refresh 30일
  - `zeroq-back-service` 설정: Access 1시간 / Refresh 14일
- 결정: 현재 운영 기준은 1시간/14일, 정책 변경은 auth/gateway와 동시 변경

### 16.9 사용자 정보 조회 전략 변경
- 기존:
  - `zeroq-back-service`가 `UserServiceClient`로 auth-back-server 사용자 상세 재조회
  - `/api/zeroq/v1/users/*` 프록시 API 운영
- 변경:
  - 위 방식 전면 제거
  - Gateway 인증 + `UserContext(userId)` 기반으로만 사용자 식별
  - Muse처럼 로컬 프로필 도메인(향후)에서 `userId`를 키로 사용
- 결정: ZeroQ의 사용자 정보 기준키는 `auth userId` 단일값

### 16.10 Gateway 경유 정책
- 정책: 프론트의 모든 API/Auth 호출은 Gateway 단일 경유
- 결정:
  - `NEXT_PUBLIC_API_URL`을 Gateway URL로 고정
  - 프론트 코드에서 서비스 직행 URL 사용 금지

---

## 17. 개발 우선순위 백로그

### P0 (필수)
1. API 경로/스택 버전 기준 통일(`/api/zeroq/v1`, Java21/SB4/Next16)
2. Space 생성/수정 TODO 구현 완료
3. 사용자 상세 재조회 로직 제거 완료(UserServiceClient 제거)
4. Frontend API URL 환경변수화 및 Gateway 연동 정리
5. 테스트 기반 구축(도메인 서비스 테스트 우선)

### P1 (높음)
1. nearby/zeroq/hotq 조회 API 도입
2. 즐겨찾기 + 알림 설정 확장
3. 체크인/포인트 스키마 및 API
4. 프론트 주요 페이지 확장(`/zeroq`, `/hotq`, `/places/[id]`)

### P2 (중간)
1. 뱃지 시스템
2. 예측 기능(AI)
3. 고급 분석 대시보드

### P3 (확장)
1. 소셜 기능
2. 외부 API 공개
3. 고급 데이터 판매 기능

---

## 18. Definition of Done (DoD)

### 18.1 기능 DoD
- 요구사항/수락 기준 충족
- 정상/예외 케이스 처리
- API 문서 반영
- UI 상태(로딩/빈화면/오류) 처리

### 18.2 품질 DoD
- 테스트 통과(Unit/Integration 해당 범위)
- 성능 목표 내 확인
- 보안 취약점 점검 통과

### 18.3 배포 DoD
- 릴리스 노트 작성
- 롤백 계획 검증
- 배포 후 헬스체크/모니터링 이상 없음

---

## 19. 운영 체크리스트

### 19.1 배포 전
- 테스트 완료
- 코드 리뷰 완료
- DB 마이그레이션 점검
- 롤백 플랜 준비

### 19.2 배포 중
- 서비스 재시작
- 헬스체크
- 5분 집중 모니터링

### 19.3 배포 후
- 핵심 사용자 플로우 점검
- 1시간 에러 추적
- 이상 시 즉시 롤백 검토

---

## 20. 팀/프로세스 기준

### 20.1 팀 구성(개발 기준)
- 초기 8명:
  - CEO/PM 1
  - Hardware 3
  - Backend 2
  - Frontend 2
- Year 1 확장 15명:
  - 영업/마케팅 +3
  - 고객지원 +2
  - 데이터분석 +1
  - QA +1

### 20.2 협업 프로세스
- Sprint 2주
- Daily Standup: 매일 10:00
- Planning: 격주 월요일
- Review/Retro: 격주 금요일

### 20.3 Git 전략
- `main` (production)
- `develop` (integration)
- `feature/*`
- `hotfix/*`

### 20.4 커밋 규칙
- Conventional Commits 권장:
  - feat, fix, refactor, chore, docs, test

### 20.5 코드리뷰/머지 규칙 (원문값 보존)
- 모든 PR 최소 1인 리뷰 필수
- 첫 리뷰 SLA: 24시간 이내
- 테스트 통과 필수
- 머지 전략: Squash merge

---

## 21. 개발 착수 체크포인트

1. 본 문서 기준값(특히 `16. 충돌/결정 로그`) 팀 승인
2. As-Is API를 OpenAPI로 먼저 동기화 (`/api/zeroq/v1/**`)
3. Target 기능(ZeroQ/HotQ, 체크인/포인트)용 DB migration 설계
4. P0 범위 Sprint 분할 및 담당 배정
5. Staging/Production 배포 파이프라인 확정

---

## 부록 A. 핵심 KPI(개발 관점)
- 정확도: 85%+(MVP), 90%+(확장)
- API p95: < 500ms
- 크래시율: < 1%
- 가용성: 99.9%
- 재방문율/NPS: 운영지표로 지속 추적

## 부록 B. 운영 리스크 요약
- 치킨-앤-에그(장소/사용자 동시 확보)
- 센서 정확도 편차
- 경쟁자 출현
- 예산/인력 부족
- 대응: 파일럿 집중, 데이터 품질 관리, 단계적 확장

---

문서 상태: `개발 기준 사용 가능`

---

## 22. 보강된 세부 규칙 (재점검 후 추가)

### 22.1 UI 세부값
- QueueBadge Large: 160x80, border 2px, radius 16
- QueueBadge Medium: 100x40, radius 8
- PlaceCard: 높이 120, 썸네일 80x80, border #EEEEEE, shadow `0 2px 8px rgba(0,0,0,0.08)`
- Primary 버튼: 높이 48, 배경 #FF5722, radius 8
- Secondary 버튼: 높이 48, 투명 배경 + 2px 테두리

### 22.2 테스트 목표값
- SUS 목표: 80+
- 보안 스캔 주기: 릴리스 전 필수
- 릴리스 테스트 일정: D-7/D-3/D-1 단계 유지

### 22.3 운영 상세 루틴
- 월간 운영:
  - 1주차 월간 리포트/센서 점검
  - 2주차 보안 스캔/DB 최적화
  - 3주차 All-hands
  - 4주차 차월 계획

### 22.4 서비스 운영 명령 표준
- backend:
  - `systemctl start zeroq-backend`
  - `systemctl stop zeroq-backend`
  - `systemctl restart zeroq-backend`
  - `systemctl status zeroq-backend`
  - `journalctl -u zeroq-backend -f`

---

## 23. 개발 착수 시 고정 파라미터

### 23.1 성능/품질 고정값
- API p95 `< 500ms`
- 앱 로딩 `< 3초`
- 데이터 지연 `< 1분`
- 가용성 `99.9%`
- 커버리지 `80%`
- 앱 크래시 `< 1%`

### 23.2 인프라 고정값
- Ubuntu `22.04 LTS`
- Java `21`
- Spring Boot `4.0.2`
- Next.js `16.1.4`
- React `19.2.3`
- MySQL `8.x`
- Gateway `cloud-back-server:8080`
- zeroq-back-service(local) `20180`
- Node.js `20+`

### 23.3 보안 고정값
- HTTPS(TLS1.3) 강제
- JWT(현재 운영값: Access 1h / Refresh 14d)
- Rate Limit `100 req/min/user`
- OWASP Top 10 점검 필수

---
