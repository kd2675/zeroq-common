# ZeroQ Current Flow Analysis Report (As-Is)

- 작성일: 2026-03-05
- 기준: 현재 저장소 실제 코드 기준 분석
- 범위:
  - `zeroq-front-service`
  - `zeroq-front-admin`
  - `cloud-back-server`
  - `auth-back-server`
  - `zeroq-back-service`
  - `zeroq-back-sensor`
  - `zeroq-sensor-gateway`
  - `eureka-back-server`

---

## 1. 전체 구조

```text
[User Web]
  - zeroq-front-service (3000)
  - zeroq-front-admin (3001)
        ↓
[cloud-back-server :8080]
  - JWT 검증 + 라우팅 + X-User-* 헤더 주입
        ↓
  - /auth/**, /oauth2/**, /api/users/** -> auth-back-server
  - /api/zeroq/v1/sensor/**            -> zeroq-back-sensor
  - /api/zeroq/v1/**                   -> zeroq-back-service
        ↓
[DB]
  - AUTH (auth-back-server)
  - ZEROQ (zeroq-back-service)
  - ZEROQ_SENSOR (zeroq-back-sensor)

[Store Edge]
Sensor -> zeroq-sensor-gateway(20191, 로컬 H2 버퍼)
      -> cloud-back-server(8080)
      -> zeroq-back-sensor(20181)
      -> ZEROQ_SENSOR
```

핵심 라우팅 근거:
- `cloud-back-server/src/main/java/cloud/back/server/config/AdvancedGatewayConfiguration.java`

---

## 2. 서버별 역할 및 동작

## 2.1 eureka-back-server
- 역할: 서비스 디스커버리 레지스트리
- 포트: `8761`
- 근거:
  - `eureka-back-server/src/main/java/eureka/back/server/EurekaBackServerApplication.java`
  - `eureka-back-server/src/main/resources/application.yml`

## 2.2 cloud-back-server (Gateway)
- 역할:
  - 단일 진입점
  - JWT 검증
  - 라우팅
  - `X-User-Id`, `X-User-Role` 헤더 주입
- 주요 동작:
  - `POST /api/users`는 공개
  - 그 외는 인증 필요
- 근거:
  - `cloud-back-server/src/main/java/cloud/back/server/config/SecurityConfiguration.java`
  - `cloud-back-server/src/main/java/cloud/back/server/filter/UserHeaderFilter.java`
  - `cloud-back-server/src/main/java/cloud/back/server/config/AdvancedGatewayConfiguration.java`

## 2.3 auth-back-server
- 역할:
  - 로그인/리프레시/로그아웃
  - OAuth2 로그인 처리
  - 사용자 생성/조회/수정/삭제
- 주요 정책:
  - 공개 회원가입 허용 역할: `USER`, `MANAGER`
  - `MANAGER` 가입 시 `manager-secret` 필수
- 근거:
  - `auth-back-server/src/main/java/auth/back/server/controller/AuthController.java`
  - `auth-back-server/src/main/java/auth/back/server/controller/UserController.java`
  - `auth-back-server/src/main/java/auth/back/server/service/UserService.java`
  - `auth-back-server/src/main/resources/application.yml`

## 2.4 zeroq-back-service
- 역할: 사용자 서비스 핵심 API
- 구현 도메인:
  - spaces
  - occupancy
  - reviews
  - favorites
  - user-locations
- 인증 처리 방식:
  - 직접 JWT 검증하지 않음
  - Gateway 헤더를 `UserContextArgumentResolver`로 주입받아 사용
- 근거:
  - `zeroq-back-service/src/main/java/com/zeroq/back/service/space/act/SpaceController.java`
  - `zeroq-back-service/src/main/java/com/zeroq/back/service/occupancy/act/OccupancyController.java`
  - `zeroq-back-service/src/main/java/com/zeroq/back/service/review/act/ReviewController.java`
  - `zeroq-back-service/src/main/java/com/zeroq/back/service/user/act/FavoriteController.java`
  - `zeroq-back-service/src/main/java/com/zeroq/back/service/userlocation/act/UserLocationController.java`
  - `zeroq-back-service/src/main/java/com/zeroq/back/common/config/MvcConfig.java`
  - `auth-common-core/src/main/java/auth/common/core/context/UserContextArgumentResolver.java`

## 2.5 zeroq-back-sensor
- 역할: 클라우드 센서 수집/집계/명령 API
- 구현 기능:
  - 센서 등록/설치/상태 변경
  - telemetry/heartbeat/batch 수집
  - place snapshot 집계
  - 명령 생성/전송/ACK
  - 모니터링
- 권한:
  - `MANAGER` 또는 `ADMIN`만 허용 (`X-User-Role`)
- MQTT:
  - 설정값 `sensor.mqtt.enabled`로 활성/비활성
- 근거:
  - `zeroq-back-sensor/src/main/java/com/zeroq/sensor/service/ingest/act/SensorIngestController.java`
  - `zeroq-back-sensor/src/main/java/com/zeroq/sensor/service/device/act/SensorDeviceController.java`
  - `zeroq-back-sensor/src/main/java/com/zeroq/sensor/service/command/act/SensorCommandController.java`
  - `zeroq-back-sensor/src/main/java/com/zeroq/sensor/service/monitoring/act/SensorMonitoringController.java`
  - `zeroq-back-sensor/src/main/java/com/zeroq/sensor/common/security/SensorRoleGuard.java`
  - `zeroq-back-sensor/src/main/java/com/zeroq/sensor/service/ingest/biz/SnapshotAggregationService.java`
  - `zeroq-back-sensor/src/main/resources/db/ddl/zeroq_sensor_all.sql`

## 2.6 zeroq-sensor-gateway
- 역할: 매장 엣지 게이트웨이
- 구현 기능:
  - 로컬 ingest API (`X-Gateway-Key` 검증)
  - 로컬 버퍼 저장 + 중복 제거
  - 주기적 클라우드 동기화
  - 주기적 클라우드 명령 pull
  - 주기적 ACK outbox sync
  - 큐 상태 모니터링
- 스케줄러:
  - `flushPendingBuffers`
  - `pollPendingCommands`
  - `flushPendingAcks`
- 근거:
  - `zeroq-sensor-gateway/src/main/java/com/zeroq/gateway/service/ingest/act/LocalSensorIngestController.java`
  - `zeroq-sensor-gateway/src/main/java/com/zeroq/gateway/common/security/GatewayApiKeyGuard.java`
  - `zeroq-sensor-gateway/src/main/java/com/zeroq/gateway/service/ingest/biz/CloudIngestSyncService.java`
  - `zeroq-sensor-gateway/src/main/java/com/zeroq/gateway/service/command/biz/CommandPullSyncService.java`
  - `zeroq-sensor-gateway/src/main/java/com/zeroq/gateway/service/command/biz/CommandAckSyncService.java`
  - `zeroq-sensor-gateway/src/main/java/com/zeroq/gateway/infrastructure/cloud/CloudSensorApiClient.java`
  - `zeroq-sensor-gateway/src/main/resources/db/ddl/zeroq_sensor_gateway_all.sql`

## 2.7 zeroq-front-service
- 역할: 일반 사용자(USER) 채널
- 현재 상태:
  - 로그인 페이지 + 토큰 저장/만료 처리
  - 기본 홈 페이지
- 로그인 흐름:
  - `${NEXT_PUBLIC_API_URL}/oauth2/authorize/naver` 호출
  - query `token` 수신 시 localStorage 저장
  - 만료 시 `/auth/refresh`
- 근거:
  - `zeroq-front-service/app/login/page.tsx`
  - `zeroq-front-service/app/lib/auth.ts`
  - `zeroq-front-service/app/hooks/useAuthSession.ts`

## 2.8 zeroq-front-admin
- 역할: 매장 관리자(MANAGER)/운영자(ADMIN) 채널
- 현재 상태:
  - 로그인/회원가입 동작 구현
  - 로그인 시 MANAGER/ADMIN만 허용
  - 회원가입 요청은 role 고정 `MANAGER`
- 근거:
  - `zeroq-front-admin/app/login/page.tsx`
  - `zeroq-front-admin/app/signup/page.tsx`
  - `zeroq-front-admin/app/lib/auth.ts`

---

## 3. 인증/권한 체인

1. `auth-back-server`가 JWT 발급 (claims: `userId`, `role`)
2. 클라이언트가 `Authorization: Bearer ...`로 Gateway 호출
3. `cloud-back-server`가 JWT 검증
4. Gateway가 `X-User-Id`, `X-User-Role`, `X-User-Name` 헤더 주입
5. 각 서비스가 헤더 기반으로 권한 처리
   - `zeroq-back-service`: `UserContext` resolver 방식
   - `zeroq-back-sensor`: `SensorRoleGuard` 직접 체크

---

## 4. Sensor 데이터 흐름 (운영 기준)

1. 센서/게이트웨이 로컬 API로 telemetry/heartbeat 입력
2. `zeroq-sensor-gateway` 로컬 DB(H2) 버퍼 저장
3. 동기화 스케줄러가 cloud API로 batch 전송 시도
4. 실패 시 단건 fallback + retry 증가
5. 성공 시 `SENT`, 실패 시 `FAILED`
6. `retryCount >= maxRetry`면 사실상 소진 상태
7. 클라우드(`zeroq-back-sensor`)는 수집 후 snapshot 집계

상태 모델:
- `PENDING`
- `FAILED`
- `SENT`

---

## 5. 현재 연결 상태 점검 결론

## 5.1 정상 연결 확인
- Gateway 라우팅:
  - `/api/zeroq/v1/sensor/** -> zeroq-back-sensor`
  - `/api/zeroq/v1/** -> zeroq-back-service`
  - `/auth/**`, `/oauth2/**`, `/api/users/** -> auth-back-server`
- `zeroq-sensor-gateway -> cloud-back-server -> zeroq-back-sensor` API 체인 정상 매칭
- JWT -> `X-User-*` 헤더 -> 서비스 소비 체인 정상

## 5.2 현재 구조 리스크/갭
1. OAuth 리다이렉트가 `3001` 기준으로 고정되어 있어 `zeroq-front-service(3000)` 소셜 로그인과 충돌 가능
2. `zeroq-back-sensor` 집계 스냅샷과 `zeroq-back-service` 점유 API가 직접 연결되지 않음
3. `zeroq-sensor-gateway`의 cloud 인증은 고정 bearer token 의존(만료 자동 갱신 없음)
4. `zeroq-front-admin` 가입 폼은 서버 검증 방식이며, 프론트에서 `1234` 정확 일치 강제 버튼 제어는 아직 없음
5. `zeroq-back-service`/`auth-back-server` `PubDataConfig`에서 master datasource 생성 시 slave properties 사용 코드가 보여 설정 실수 가능성 존재

---

## 6. 즉시 우선 조치 권고

1. OAuth redirect 정책 정리 (`front-service`/`front-admin` 분리)
2. 센서 snapshot -> 사용자 API 반영 경로 설계(조회 API 통합 또는 동기화 테이블)
3. gateway cloud auth 토큰 갱신 전략 추가
4. admin 회원가입 프론트 UX 정책 확정 (`1234` 강제 여부)
5. datasource 설정 검증 및 수정

---

## 7. 참고 문서

- `AGENTS_ZEROQ_DEVELOPMENT_ONLY.md`
- `AGENTS_ZEROQ_SENSOR_PROTOCOL.md`

