# ZeroQ Seat Sensor Hardware Recommendation

Last updated: 2026-03-11

## 목적

이 문서는 ZeroQ 좌석 점유 센서를 `ICBANQ` 부품 위주로 조합하는 최종 권장안을 정리한다.

전제:
- 목표는 정밀 무게 측정이 아니라 `occupied / vacant` 판정이다.
- `1 seat = 1 sensor node` 구조를 따른다.
- `sensorId` 기준으로 `ZEROQ_ADMIN`에서 공간/게이트웨이/센서 매핑을 관리한다.
- 센서 패드만 좌석 쪽에 두고, 보드와 배터리는 의자 다리 하우징으로 분리한다.

## 최종 권장안

가장 추천하는 조합:
- 압력센서 `RA30P` 2개
- `Seeed XIAO BLE nRF52840` 1개
- `LiPo 2500mAh` 1개 또는 `18650` 1개
- `FB32` 케이스 1개
- 전원 스위치/연장 케이블 1개

추천 이유:
- `RA30P` 1개보다 2개가 좌석 편중 하중에 더 안정적이다.
- `XIAO BLE nRF52840`는 소형, BLE 지원, 저전력 운용에 적합하다.
- 배터리와 보드를 의자 다리 쪽으로 모으면 유지보수와 교체가 쉽다.

## BOM

### 필수 부품

| 구분 | 제품 | 가격 | 수량 | 용도 | 링크 |
|---|---|---:|---:|---|---|
| 센서 | 압력센서 FSR, RA30P | 12,000원 | 2 | 좌석 압력 감지 | https://www.icbanq.com/P012003223 |
| BLE 보드 | Seeed XIAO BLE nRF52840 | 15,000원 | 1 | BLE 송신, 상태 판정 | https://www.icbanq.com/P013158938 |
| 배터리 | 리튬폴리머 3.7V 2500mAh KC 인증 | 9,500원 | 1 | 기본 전원 | https://www.icbanq.com/P012000458 |
| 전원 스위치 | JST PH2 ON/OFF 스위치 연장 케이블 | 5,000원 | 1 | 전원 차단 | https://www.icbanq.com/P007412320 |
| 케이스 | 다목적 핸디 박스 FB32 | 4,000원 | 1 | 의자 다리 하우징 | https://www.icbanq.com/P014162017 |

### 교체형 배터리 대안

| 구분 | 제품 | 가격 | 수량 | 용도 | 링크 |
|---|---|---:|---:|---|---|
| 배터리 | 18650 3500mAh 보호회로 내장 | 16,200원 | 1 | 교체형 전원 | https://www.icbanq.com/P015535293 |
| 홀더 | BH18650-1P 전지홀더 리드선 타입 | 1,100원 | 1 | 18650 장착 | https://www.icbanq.com/P013989686 |

### 테스트/조립 보조

| 구분 | 제품 | 가격 | 수량 | 용도 | 링크 |
|---|---|---:|---:|---|---|
| 테스트 배선 | 악어 클립 테스트 케이블 10pcs | 5,770원 | 1 | 프로토타입 점검 | https://www.icbanq.com/P005672334 |
| 케이블 정리 | 접착식 케이블타이 마운트 | 1,500원 | 1세트 | 좌석 하부 배선 고정 | https://www.icbanq.com/P016911255 |

## 예상 비용

LiPo 기준:
- `RA30P x2`: 24,000원
- `XIAO`: 15,000원
- `LiPo`: 9,500원
- `JST ON/OFF`: 5,000원
- `FB32`: 4,000원

합계:
- 기본 조립 부품 기준 `57,500원`
- 소모품과 배선 정리 부품 포함 시 대략 `6만 원대 초반`

18650 기준:
- `RA30P x2`: 24,000원
- `XIAO`: 15,000원
- `18650`: 16,200원
- `홀더`: 1,100원
- `FB32`: 4,000원

합계:
- 기본 조립 부품 기준 `60,300원`

## 기구 배치

권장 배치:
- 좌석/방석 아래: `RA30P` 2개
- 의자 다리 하우징: `XIAO`, 배터리, 전원 스위치
- 센서선 길이: `30~50cm`

배치 개념:

```text
[방석]
  ├─ RA30P (좌)
  └─ RA30P (우)

     30~50cm 센서선

[의자 다리 하우징]
  - XIAO BLE nRF52840
  - 배터리
  - 전원 스위치
```

설치 원칙:
- 센서 2개는 좌우 하중 위치에 분산 배치한다.
- 센서 면은 직접 꺾이지 않게 평평하게 부착한다.
- 하우징은 사용자 발에 걸리지 않는 다리 안쪽 면에 고정한다.
- 센서선은 의자 하부를 따라 클립으로 고정한다.

## 회로 연결

이 구성은 `switch-type occupancy pad`가 아니라 `FSR/박막 압력센서` 기반이므로 `GPIO 직결`이 아니라 `ADC 판독`이 필요하다.

권장 연결:

```text
RA30P(좌) -> 분압 회로 -> XIAO A0
RA30P(우) -> 분압 회로 -> XIAO A1
BATTERY + -> XIAO BAT
BATTERY - -> XIAO GND
```

실제 회로 개념:

```text
3V3
 |
[Rfixed 10k]
 |
 +-----> A0
 |
[RA30P-left]
 |
GND

3V3
 |
[Rfixed 10k]
 |
 +-----> A1
 |
[RA30P-right]
 |
GND
```

설명:
- 각 센서는 고정 저항과 함께 전압 분배 회로를 만든다.
- XIAO는 `A0`, `A1`로 두 센서를 읽는다.
- 둘 중 하나라도 임계치 이상이면 `occupied`로 판정한다.

권장 저항값:
- `10kΩ` 시작
- 필요 시 `4.7kΩ` 또는 `22kΩ`로 재조정

실제 핀 기준:

| 기능 | XIAO 핀 | 연결 대상 |
|---|---|---|
| 좌측 센서 ADC | `A0` | 좌측 `RA30P` 분압 출력 |
| 우측 센서 ADC | `A1` | 우측 `RA30P` 분압 출력 |
| 배터리 측정 | `A2` | 배터리 전압 분배 출력 |
| 센서 기준 전압 | `3V3` | 분압 상단 |
| 공통 접지 | `GND` | 센서 하단, 배터리 음극 |
| 배터리 입력 | `BAT` | LiPo 양극 |

권장 실제 회로도:

```text
좌측 센서
3V3 ---[10k]---+--- A0
               |
            [RA30P-L]
               |
              GND

우측 센서
3V3 ---[10k]---+--- A1
               |
            [RA30P-R]
               |
              GND

배터리
LiPo + ------------------------ BAT
LiPo - ------------------------ GND

선택: 배터리 전압 측정
BAT ----[100k]----+---- A2
                  |
               [100k]
                  |
                 GND
```

배선 원칙:
- 센서선은 `30~50cm`까지 허용
- 센서선은 가능하면 꼬아서 배치
- 센서선과 전원선은 평행 장거리 배치를 피함
- 의자 하부에서 케이블 클립으로 고정

## 판정 로직

권장 로직:
- `A0` 또는 `A1`이 임계치 초과 상태로 `2초` 이상 유지 -> `OCCUPIED`
- 두 센서 모두 임계치 미만 상태로 `5초` 이상 유지 -> `VACANT`
- 상태 변화 시 즉시 BLE 송신
- 변화가 없어도 `60~300초` heartbeat 송신

권장 추가 처리:
- 이동 평균 3~5샘플 적용
- 센서별 개별 보정값 저장
- 저배터리 임계치 예: `20%`

권장 수치 예시:

| 항목 | 권장값 |
|---|---:|
| 샘플링 주기 | `100ms` |
| Occupied hold | `2000ms` |
| Vacant hold | `5000ms` |
| Heartbeat 주기 | `60000ms` |
| 저배터리 기준 | `20%` |

현장 보정 절차:
1. 아무도 앉지 않은 상태에서 `A0`, `A1` 100회 측정
2. 평균값과 최대값 기록
3. 성인 1명이 정상 착석한 상태에서 100회 측정
4. 평균값과 최소값 기록
5. 각 센서 threshold는 `빈 상태 최대값`과 `착석 상태 평균값`의 중간값으로 시작
6. 오탐/미탐 비율을 보고 `±5~10%` 조정

## ZeroQ BLE 패킷

권장 payload:

```json
{
  "version": 1,
  "sensorId": "SEAT-014",
  "occupied": true,
  "batteryPercent": 82,
  "seq": 1204,
  "measuredAt": "2026-03-11T12:10:00Z"
}
```

선택 확장 필드:
- `leftValue`
- `rightValue`
- `rssi`
- `heartbeat`

gateway 업로드 예시:

```json
{
  "sensorId": "SEAT-014",
  "gatewayId": "GW-STORE-001",
  "occupied": true,
  "batteryPercent": 82,
  "seq": 1204,
  "measuredAt": "2026-03-11T12:10:00Z",
  "leftValue": 712,
  "rightValue": 655
}
```

실제 펌웨어 예제:
- `examples/zeroq-seat-sensor-xiao/zeroq-seat-sensor-xiao.ino`
- 설명: `examples/zeroq-seat-sensor-xiao/README.md`

광고 전략:
- 상태 변화 시 즉시 advertising 갱신
- 같은 상태는 heartbeat 주기만 유지
- sequence 번호는 단조 증가

권장 BLE 수신 흐름:
1. 좌석 센서가 manufacturer data advertising 송신
2. `zeroq-sensor-gateway`가 로컬 BLE 스캔
3. gateway가 `sensorId`, `occupied`, `batteryPercent`, `seq`, `measuredAt` 파싱
4. gateway가 `zeroq-back-sensor` ingest API로 업로드

## 설치 방법

### 1. 센서 부착

1. 방석을 들어 좌석면을 노출한다.
2. `RA30P` 2개를 좌우 하중 위치에 맞춰 평평하게 부착한다.
3. 센서 필름은 접거나 강하게 비틀지 않는다.
4. 센서선은 좌석 후면 또는 하부 쪽으로 빼낸다.

### 2. 하우징 설치

1. `XIAO`, 배터리, 스위치를 `FB32` 케이스에 넣는다.
2. 케이스를 의자 다리 안쪽에 고정한다.
3. 전원 스위치는 손이 닿지만 외부 충격이 적은 면으로 둔다.
4. 센서선은 하우징으로 넣고 스트레인 릴리프를 준다.

### 3. 배선 고정

1. 센서선은 좌석 하부를 따라 클립으로 고정한다.
2. 여분 케이블은 루프를 크게 만들어 꺾임을 줄인다.
3. 사용자의 발이나 청소 도구에 걸리지 않게 다리 안쪽으로 정리한다.

## 운영 과정

### 센서 동작 흐름

1. 부팅
2. 센서 baseline 읽기
3. `100ms` 주기로 `A0`, `A1` 샘플링
4. threshold 및 debounce 로직 적용
5. 상태 변화 시 BLE 송신
6. 일정 주기 heartbeat 송신

### gateway 동작 흐름

1. BLE scan으로 광고 수집
2. 센서 payload 파싱
3. 로컬 버퍼 저장
4. `cloud-back-server` 내부 경로로 업로드
5. 실패 시 재시도

### 백엔드 동작 흐름

1. `zeroq-back-sensor` raw telemetry 저장
2. `sensorId -> gateway -> space` 매핑 해석
3. 관리자 화면에서 좌석 상태 집계

## 장애 대응

증상별 우선 점검:

| 증상 | 우선 확인 |
|---|---|
| 항상 occupied | threshold 과도하게 낮음, 방석 압박, 센서 굽힘 |
| 항상 vacant | threshold 높음, 센서 배선 단선, ADC 핀 오배선 |
| 상태 튐 | debounce 부족, 센서선 노이즈, 케이블 고정 불량 |
| 배터리 빨리 소모 | heartbeat 과도, advertising 빈도 과다 |
| gateway 미수신 | BLE 스캔 로직, 광고 형식, 배터리 전압 확인 |

## 펌웨어/운영 파일

- 하드웨어 권장안: `AGENTS_ZEROQ_SEAT_SENSOR_HARDWARE.md`
- 센서 예제 코드: `examples/zeroq-seat-sensor-xiao/zeroq-seat-sensor-xiao.ino`
- 예제 설명: `examples/zeroq-seat-sensor-xiao/README.md`

## 왜 이 구성이 최종 추천인가

- `ICBANQ`에서 조달 가능한 부품만으로 조합 가능하다.
- 좌석 점유 여부만 볼 때 정밀 로드셀보다 구현이 단순하다.
- 배터리/보드를 의자 다리로 내리면 유지보수성이 좋다.
- ZeroQ의 `sensorId -> gateway -> space` 구조와 바로 맞는다.

## 주의점

- `RA30P`는 본질적으로 아날로그 센서라 임계치 보정이 필요하다.
- 완성형 `switch-type pad`보다 펌웨어가 조금 더 복잡하다.
- 좌석 재질, 방석 두께, 사용자 체형에 따라 캘리브레이션이 필요하다.

## 다음 단계

1. 실제 `RA30P 2개` 기준 테스트 지그 제작
2. `occupied / vacant` 임계치 측정
3. XIAO BLE 펌웨어 작성
4. `zeroq-sensor-gateway` BLE 수집 규격 확정
