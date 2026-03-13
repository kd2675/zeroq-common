# ZeroQ Seat Sensor XIAO Example

이 예제는 `AGENTS_ZEROQ_SEAT_SENSOR_HARDWARE.md`에 정의한 `RA30P x 2 + XIAO BLE nRF52840` 구성을 기준으로 한 Arduino 스케치다.

## 목적

- 좌석 점유 여부를 `occupied / vacant`로 판정
- BLE manufacturer data advertising 전송
- 상태 변화 시 즉시 송신
- 변화가 없으면 heartbeat 송신

## 핀 매핑

- `A0`: 좌측 RA30P 분압 출력
- `A1`: 우측 RA30P 분압 출력
- `A2`: 배터리 전압 측정

## 조정이 필요한 상수

- `ADC_THRESHOLD_LEFT`
- `ADC_THRESHOLD_RIGHT`
- `BATTERY_MIN_ADC`
- `BATTERY_MAX_ADC`
- `OCCUPIED_HOLD_MS`
- `VACANT_HOLD_MS`

## 주의

- 이 예제는 구조 설명용 기준 코드다.
- 실제 운용 전에는 현장 의자, 방석, 패드 위치 기준으로 threshold를 다시 측정해야 한다.
- gateway 수집기는 이 manufacturer data 형식을 해석하도록 별도 구현이 필요하다.
