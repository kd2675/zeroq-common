# ZeroQ Sensor Protocol (Gateway First)

## 1. 목적
- 센서 데이터 유실 방지
- 중복 전송 안전 처리(idempotency)
- 오프라인 복구 후 순차 재전송
- 운영 모니터링 표준화

## 2. 권장 데이터 경로
1. `Sensor(ESP32)` 측정
2. `zeroq-sensor-gateway` 로컬 수집/버퍼 저장
3. `cloud-back-server` 경유 인증/라우팅
4. `zeroq-back-sensor` 저장/집계
5. `DB` 반영

## 3. MQTT 토픽 규격
- Telemetry: `zeroq/sensor/{sensorId}/telemetry`
- Heartbeat: `zeroq/sensor/{sensorId}/heartbeat`
- Command Ack: `zeroq/sensor/{sensorId}/command-ack`
- Command Downlink(서버 -> 센서): `zeroq/sensor/{sensorId}/command`

주의:
- `{sensorId}`는 장치 고유 ID와 1:1이어야 함
- topic의 `{sensorId}`와 payload `sensorId`가 다르면 reject 또는 DLQ 처리

## 4. Telemetry Payload
```json
{
  "sensorId": "SN-CAFE-001",
  "sequenceNo": 102345,
  "placeId": 101,
  "gatewayId": "GW-STORE-001",
  "measuredAt": "2026-03-05T10:30:12",
  "distanceCm": 84.3,
  "confidence": 0.93,
  "temperatureC": 23.1,
  "humidityPercent": 42.5,
  "batteryPercent": 78.0,
  "rssi": -62,
  "rawPayload": "..."
}
```

필수:
- `sensorId`, `measuredAt`, `distanceCm`

중복키(idempotency key):
- 우선: `(sensorId, sequenceNo, measuredAt)`
- 보조: `(sensorId, measuredAt)`

## 4-1. Seat Occupancy Telemetry Payload
좌석 센서는 거리값 대신 최종 점유 상태를 직접 전송할 수 있다.

```json
{
  "sensorId": "SEAT-014",
  "sequenceNo": 1204,
  "gatewayId": "GW-STORE-001",
  "measuredAt": "2026-03-11T12:10:00",
  "occupied": true,
  "padLeftValue": 640,
  "padRightValue": 618,
  "batteryPercent": 82.0,
  "rssi": -58,
  "rawPayload": "0103534541542D3031349B5A50B004000084CCA96700"
}
```

설명:
- `distanceCm`는 생략 가능
- `occupied`는 센서가 debounce 후 확정한 최종 상태
- `padLeftValue`, `padRightValue`는 threshold 조정과 디버깅용 원시값

gateway local 입력 경로:
- `POST /api/zeroq/gateway/v1/local/ingest/seat/advertisement`

## 5. Heartbeat Payload
```json
{
  "sensorId": "SN-CAFE-001",
  "placeId": 101,
  "gatewayId": "GW-STORE-001",
  "heartbeatAt": "2026-03-05T10:30:30",
  "firmwareVersion": "1.4.2",
  "batteryPercent": 77.9
}
```

중복키:
- `(sensorId, heartbeatAt)`

## 6. 게이트웨이 버퍼 상태 머신
공통 상태(`BufferSyncStatus`):
- `PENDING`: 로컬 저장 완료, cloud 전송 대기
- `FAILED`: cloud 전송 실패(재시도 가능/소진 포함)
- `SENT`: cloud 반영 완료

전이:
1. 로컬 ingest 성공 -> `PENDING`
2. sync 시도 성공 -> `SENT`
3. sync 시도 실패 -> `FAILED`, `retryCount++`
4. `retryCount >= maxRetry`인 `FAILED`는 더 이상 poll 대상 아님(소진)

운영 판별:
- `FAILED && retryCount < maxRetry`: 재시도 예정
- `FAILED && retryCount >= maxRetry`: 개입 필요(네트워크/인증/스키마 오류)

## 7. 이번 코드 반영 사항(2026-03-05)
- `zeroq-sensor-gateway` 로컬 ingest 중복 방지 추가
  - Telemetry: 중복 요청 무시
  - Heartbeat: 중복 요청 무시
- DB unique 제약 추가
  - telemetry: `(sensor_id, sequence_no, measured_at)`, `(sensor_id, measured_at)`
  - heartbeat: `(sensor_id, heartbeat_at)`
- 모니터링 확장
  - `telemetryExhausted`, `heartbeatExhausted`, `commandAckExhausted` 노출

## 8. 센서 펌웨어 구현 체크리스트
1. 측정마다 `sequenceNo` 단조 증가
2. QoS 1 이상 사용
3. 전송 실패 시 로컬 큐 저장
4. 재연결 시 sequence 순서대로 재전송
5. ACK 없는 경우 재시도(backoff)
6. RTC 없으면 `measuredAt`는 gateway에서 보정 가능

## 9. 운영 파라미터 권장값
- `gateway.sync.batch-size`: 100
- `gateway.sync.max-retry`: 10
- `gateway.sync.ingest-fixed-delay-ms`: 5000
- `sensor.ingestion.stale-threshold-seconds`: 180

## 10. 장애 대응 우선순위
1. Gateway -> Cloud 인증 토큰 만료 여부
2. MQTT broker 연결 상태
3. 중복키 충돌 비정상 증가(펌웨어 sequence 오류)
4. FAILED 소진 건의 공통 error_message 패턴 분석
