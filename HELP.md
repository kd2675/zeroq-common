# zeroq-common Help

루트에서 자주 쓰는 실행과 검증 명령 모음입니다.

## Aggregate Build

```bash
./gradlew clean build
./gradlew clean build -x test
./gradlew test
```

## Backend Run

```bash
./gradlew eureka-back-server:bootRun
./gradlew auth-back-server:bootRun
./gradlew cloud-back-server:bootRun
./gradlew zeroq-back-service:bootRun
./gradlew zeroq-back-sensor:bootRun
./gradlew zeroq-sensor-gateway:bootRun
./gradlew muse-back-service:bootRun
./gradlew semo-back-service:bootRun
./gradlew image-back-server:bootRun
./gradlew stock-back-service:bootRun
./gradlew stock-batch-service:bootRun
```

## Backend Compile and Test

```bash
./gradlew :web-common-core:compileJava
./gradlew :auth-common-core:compileJava
./gradlew :auth-back-server:test
./gradlew :cloud-back-server:test
./gradlew :zeroq-back-service:test
./gradlew :zeroq-back-sensor:test
./gradlew :zeroq-sensor-gateway:test
./gradlew :muse-back-service:test
./gradlew :semo-back-service:test
./gradlew :image-back-server:test
./gradlew :stock-back-service:test
./gradlew :stock-batch-service:test
```

## Stock Smoke Checks

```bash
cp .env.example .env
scripts/stock-smoke.sh
scripts/stock-h2-smoke.sh
STOCK_SMOKE_RUN_BATCH_JOBS=true scripts/stock-smoke.sh
STOCK_BATCH_INTERNAL_TOKEN=<token> STOCK_SMOKE_RUN_BATCH_JOBS=true scripts/stock-smoke.sh
```

## Frontend Run

```bash
cd muse-front-service && npm install && npm run dev
cd zeroq-front-service && npm install && npm run dev
cd zeroq-front-admin && npm install && npm run dev
cd semo-front-service && npm install && npm run dev
cd sbng-front-service && npm install && npm run dev
cd stock-front-service && npm install && npm run dev
```

## ZeroQ BLE Spot Scanner

```bash
cd zeroq-sensor-gateway/tools/ble-seat-scanner
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
python seat_ble_scanner.py
```

## Frontend Quality

```bash
cd muse-front-service && npm run lint
cd zeroq-front-service && npm run lint
cd zeroq-front-admin && npm run lint
cd semo-front-service && npm run lint
cd sbng-front-service && npm run lint
cd stock-front-service && npm run lint
```

## Notes

- 프론트 앱은 각각 독립 실행합니다.
- 기본 Gateway 진입점은 `http://localhost:8080`입니다.
- 서비스별 포트와 환경 변수는 각 프로젝트 문서를 우선으로 확인합니다.
