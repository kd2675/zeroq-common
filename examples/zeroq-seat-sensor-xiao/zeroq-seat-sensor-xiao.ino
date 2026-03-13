#include <ArduinoBLE.h>

namespace {

constexpr int LEFT_SENSOR_PIN = A0;
constexpr int RIGHT_SENSOR_PIN = A1;
constexpr int BATTERY_PIN = A2;
constexpr int SAMPLE_INTERVAL_MS = 100;
constexpr int HEARTBEAT_INTERVAL_MS = 60000;
constexpr int OCCUPIED_HOLD_MS = 2000;
constexpr int VACANT_HOLD_MS = 5000;
constexpr int ADC_THRESHOLD_LEFT = 620;
constexpr int ADC_THRESHOLD_RIGHT = 620;
constexpr int BATTERY_MIN_ADC = 550;
constexpr int BATTERY_MAX_ADC = 820;

constexpr uint16_t MANUFACTURER_ID = 0x5A51;
constexpr uint8_t PROTOCOL_VERSION = 0x01;
constexpr uint8_t FLAG_OCCUPIED = 0x01;
constexpr uint8_t FLAG_HEARTBEAT = 0x02;
constexpr uint8_t FLAG_LOW_BATTERY = 0x04;

const char SENSOR_ID[] = "SEAT-014";

bool occupied = false;
bool lastStableOccupied = false;
unsigned long occupiedCandidateSince = 0;
unsigned long vacantCandidateSince = 0;
unsigned long lastSampleAt = 0;
unsigned long lastHeartbeatAt = 0;
uint32_t sequenceNo = 1;

BLEService sensorService("19B10000-E8F2-537E-4F6C-D104768A1214");
BLECharacteristic sensorStateCharacteristic(
    "19B10001-E8F2-537E-4F6C-D104768A1214",
    BLERead | BLENotify,
    20
);

uint8_t clampBatteryPercent(int adcValue) {
  if (adcValue <= BATTERY_MIN_ADC) {
    return 0;
  }
  if (adcValue >= BATTERY_MAX_ADC) {
    return 100;
  }

  const int span = BATTERY_MAX_ADC - BATTERY_MIN_ADC;
  return static_cast<uint8_t>(((adcValue - BATTERY_MIN_ADC) * 100) / span);
}

bool isOccupiedRaw(int leftValue, int rightValue) {
  return leftValue >= ADC_THRESHOLD_LEFT || rightValue >= ADC_THRESHOLD_RIGHT;
}

void writeUint32(uint8_t* target, uint32_t value) {
  target[0] = static_cast<uint8_t>(value & 0xFF);
  target[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
  target[2] = static_cast<uint8_t>((value >> 16) & 0xFF);
  target[3] = static_cast<uint8_t>((value >> 24) & 0xFF);
}

void encodeSensorId(uint8_t* target) {
  for (size_t i = 0; i < 8; ++i) {
    target[i] = i < sizeof(SENSOR_ID) - 1 ? static_cast<uint8_t>(SENSOR_ID[i]) : 0;
  }
}

void updateAdvertising(bool heartbeat, int leftValue, int rightValue, uint8_t batteryPercent) {
  uint8_t payload[22] = {};
  payload[0] = PROTOCOL_VERSION;
  payload[1] = 0;
  if (occupied) {
    payload[1] |= FLAG_OCCUPIED;
  }
  if (heartbeat) {
    payload[1] |= FLAG_HEARTBEAT;
  }
  if (batteryPercent <= 20) {
    payload[1] |= FLAG_LOW_BATTERY;
  }

  encodeSensorId(&payload[2]);
  payload[10] = static_cast<uint8_t>(leftValue >> 2);
  payload[11] = static_cast<uint8_t>(rightValue >> 2);
  payload[12] = batteryPercent;
  writeUint32(&payload[13], sequenceNo);
  writeUint32(&payload[17], millis() / 1000UL);
  payload[21] = 0;

  BLE.stopAdvertise();
  BLE.setManufacturerData(payload, sizeof(payload));
  sensorStateCharacteristic.writeValue(payload, sizeof(payload));
  BLE.advertise();
}

void evaluateOccupancy(bool occupiedRaw) {
  const unsigned long now = millis();

  if (occupiedRaw) {
    vacantCandidateSince = 0;
    if (occupied) {
      return;
    }
    if (occupiedCandidateSince == 0) {
      occupiedCandidateSince = now;
      return;
    }
    if (now - occupiedCandidateSince >= OCCUPIED_HOLD_MS) {
      occupied = true;
      occupiedCandidateSince = 0;
    }
    return;
  }

  occupiedCandidateSince = 0;
  if (!occupied) {
    return;
  }
  if (vacantCandidateSince == 0) {
    vacantCandidateSince = now;
    return;
  }
  if (now - vacantCandidateSince >= VACANT_HOLD_MS) {
    occupied = false;
    vacantCandidateSince = 0;
  }
}

}  // namespace

void setup() {
  analogReadResolution(10);
  pinMode(LEFT_SENSOR_PIN, INPUT);
  pinMode(RIGHT_SENSOR_PIN, INPUT);
  pinMode(BATTERY_PIN, INPUT);

  BLE.begin();
  BLE.setLocalName("ZeroQSeat");
  BLE.setAdvertisedService(sensorService);
  sensorService.addCharacteristic(sensorStateCharacteristic);
  BLE.addService(sensorService);

  const uint8_t initialValue[20] = {};
  sensorStateCharacteristic.writeValue(initialValue, sizeof(initialValue));
  BLE.advertise();
}

void loop() {
  BLE.poll();

  const unsigned long now = millis();
  if (now - lastSampleAt < SAMPLE_INTERVAL_MS) {
    return;
  }
  lastSampleAt = now;

  const int leftValue = analogRead(LEFT_SENSOR_PIN);
  const int rightValue = analogRead(RIGHT_SENSOR_PIN);
  const int batteryAdc = analogRead(BATTERY_PIN);
  const uint8_t batteryPercent = clampBatteryPercent(batteryAdc);

  evaluateOccupancy(isOccupiedRaw(leftValue, rightValue));

  if (occupied != lastStableOccupied) {
    lastStableOccupied = occupied;
    updateAdvertising(false, leftValue, rightValue, batteryPercent);
    ++sequenceNo;
    lastHeartbeatAt = now;
    return;
  }

  if (now - lastHeartbeatAt >= HEARTBEAT_INTERVAL_MS) {
    updateAdvertising(true, leftValue, rightValue, batteryPercent);
    ++sequenceNo;
    lastHeartbeatAt = now;
  }
}
