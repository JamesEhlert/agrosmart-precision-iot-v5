# AgroSmart Precision IoT V5 — Architecture

## 1) Purpose
AgroSmart V5 is a smart irrigation IoT system that:
- Collects soil and environmental sensor data using an ESP32 device
- Stores telemetry in AWS DynamoDB via AWS IoT Core rules
- Allows users to monitor telemetry in a Flutter mobile app
- Allows manual irrigation (command) via the mobile app
- Supports scheduling-based irrigation using Firestore + AWS Lambda (scheduler)
- Logs automation actions and decisions to Firestore for audit/history

---

## 2) Tech stack (high level)

### Device (Firmware)
- MCU/Board: ESP32 DevKit V1 (esp32doit-devkit-v1) / Arduino framework via PlatformIO
- Connectivity: Wi-Fi + MQTT over TLS to AWS IoT Core
- Sensors:
  - AHT10: air temperature + air humidity
  - Soil moisture: analog input
  - Rain (raw): analog input
  - Light (raw): analog input
  - UV (raw): analog input (averaged)
- Output:
  - Valve/relay control (timed)
  - OLED display (SSD1306) — planned to be removed in a future low-power version
- Local persistence: SD card (CSV log)

### Cloud (AWS)
- AWS IoT Core (MQTT TLS)
- IoT Rule: forwards telemetry to DynamoDB
- DynamoDB table: AgroTelemetryData_V5
- Lambda functions:
  - AgroSmart_V5_GetTelemetry (reads telemetry from DynamoDB)
  - AgroSmart_V5_SendCommand (publishes commands to IoT topic)
  - AgroSmart_Scheduler_Logic (reads schedules & decides irrigation)
- API Gateway:
  - GET /telemetry
  - POST /command
- Region: us-east-2

### Cloud (Firebase / Google)
- Firebase Authentication (email/password + Google Sign-In)
- Cloud Firestore (users/devices/schedules/history)
- Weather provider used by scheduler: Open-Meteo (HTTP)

### Mobile (Flutter)
- Flutter app (Android-focused)
- Telemetry: reads via AWS API Gateway
- Settings/Schedules/History: stored in Firestore
- Auth: Firebase Auth

---

## 3) Identifiers, endpoints, and topics

### AWS IoT Core
- IoT endpoint:
  - a39ub0vpt280b2-ats.iot.us-east-2.amazonaws.com
- Thing name (device_id):
  - ESP32-AgroSmart-Station-V5
- MQTT topics:
  - Telemetry publish: agrosmart/v5/telemetry
  - Command subscribe: agrosmart/v5/command

### API Gateway
- Stage: prod
- Invoke URL:
  - https://frk7y7wxz6.execute-api.us-east-2.amazonaws.com/prod
- Endpoints:
  - GET /telemetry
  - POST /command
- Current authentication:
  - None (public). Security hardening planned.

### Firebase / Firestore
- Firebase project id:
  - agrosmart-v5

---

## 4) Firmware architecture (ESP32)

### Responsibilities
- Read sensors periodically
- Publish telemetry to AWS IoT via MQTT TLS
- Subscribe for commands and drive the valve output for a configured duration
- Show status/values in OLED
- Log telemetry to SD card in CSV format (SENT/PENDING)

### Telemetry interval (current)
- Production device: 10 minutes (TELEMETRY_INTERVAL_MS = 600000)
- Planned future: 30 minutes + OLED removal for battery operation

### Key pins
- Soil moisture (ADC): GPIO 34
- Rain raw (ADC): GPIO 35
- UV (ADC): GPIO 32
- Light (ADC): GPIO 33
- Valve/relay output: GPIO 2
  - Logic: HIGH = ON, LOW = OFF

### Buses
- I2C: SDA=21, SCL=22
  - OLED + RTC + AHT10
- SPI (SD card): SCK=18, MISO=19, MOSI=23, CS=5

### Local log file
- SD path: /telemetry_v5.csv
- Status marker: SENT | PENDING

### Libraries (PlatformIO lib_deps)
- Adafruit AHTX0, Adafruit Unified Sensor, Adafruit BusIO
- RTClib (DS3231)
- Adafruit GFX + Adafruit SSD1306
- PubSubClient (MQTT)
- ArduinoJson v6

---

## 5) AWS IoT Core: policy + routing

### Device certificate policy
Policy name: AgroSmart-V5-Policy
- Allow iot:Connect on client/${iot:ClientId}
- Allow iot:Publish on topic agrosmart/v5/telemetry
- Allow iot:Subscribe on topicfilter agrosmart/v5/command
- Allow iot:Receive on topic agrosmart/v5/command

### IoT Rule -> DynamoDB
- Rule name: AgroSmart_V5_To_DynamoDB
- SQL: SELECT * FROM 'agrosmart/v5/telemetry'
- Action: write to DynamoDB table AgroTelemetryData_V5

---

## 6) DynamoDB data storage

### Table: AgroTelemetryData_V5
- Partition key: device_id (String)
- Sort key: timestamp (Number; Unix seconds)

### Primary attributes
- sensors: Map saved in DynamoDB AttributeValue-typed format (e.g. {"N": "24.6"})
- boot_* or boot_count (optional): used only by a battery-test device to estimate runtime

### Capacity and features (current)
- Capacity mode: On-demand
- TTL: disabled
- Streams: disabled
- PITR: disabled

---

## 7) API layer (API Gateway + Lambda)

### GET /telemetry (read)
- Input:
  - device_id (required)
  - limit (optional)
  - next_token (optional pagination)
  - start_time/end_time (optional range; Unix seconds)
- Behavior:
  - Query by device_id ordered newest-first
  - Pagination returns next_token

### POST /command (manual irrigation)
- Input body:
  - device_id (required)
  - action (required)
  - duration (optional, seconds)
- Behavior:
  - Publishes MQTT command payload to agrosmart/v5/command

---

## 8) Scheduler automation (Lambda)

### Trigger
- EventBridge rule: AgroSmart_V5_Minute_Trigger
- Schedule: rate(1 minute)

### Decision logic
- Reads enabled schedules in Firestore (collection group query for schedules)
  - enabled == true
  - days array contains today
  - time == current HH:mm (America/Sao_Paulo)
- Fetches latest soil moisture from DynamoDB
- Optional weather check (Open-Meteo) if enabled and lat/lon configured:
  - may skip irrigation on expected rain conditions
- If conditions allow:
  - publish command to agrosmart/v5/command (duration_minutes * 60)
- Writes activity logs to Firestore:
  - devices/{deviceId}/history

---

## 9) Firestore data model (summary)

### users/{uid}
- my_devices: [deviceId, ...]

### devices/{deviceId}
- owner_uid
- online
- settings:
  - device_name
  - target_soil_moisture
  - manual_valve_duration
  - timezone_offset
  - enable_weather_control
  - latitude / longitude
  - capabilities: ["air","soil","light","rain","uv"]

### devices/{deviceId}/schedules/{scheduleId}
- label
- time ("HH:mm")
- days [1..7] (1=Mon ... 7=Sun)
- duration_minutes
- enabled

### devices/{deviceId}/history/{logId}
- timestamp
- type (execution | skipped | error | ...)
- source (schedule | weather_ai | manual | ...)
- message

### Firestore index (required for scheduler)
- Composite index for collection group schedules:
  - days (array), enabled, time, __name__

### Firestore rules (current)
- Development mode: allow read/write for any authenticated user
- Hardening planned: enforce ownership (owner_uid == request.auth.uid)

---

## 10) Mobile app (Flutter)

### Main features
- Authentication: Firebase Auth (email/password + Google Sign-In)
- Device registry: Firestore users/{uid}.my_devices
- Monitor:
  - latest telemetry via AWS API
  - charts/history
- Schedules:
  - CRUD schedules in Firestore
  - enable/disable schedules
- Manual irrigation:
  - POST /command to AWS API
- Logs:
  - reads devices/{deviceId}/history from Firestore

---

## 11) Known future improvements (architecture-level)
- Power optimization:
  - remove OLED
  - increase telemetry interval (e.g. 30 minutes)
  - deep sleep strategy for battery
- Security hardening:
  - protect API Gateway with auth (e.g. Firebase token validation + ownership)
  - restrict Firestore rules to device ownership
- Data format:
  - store sensor values as native numbers in DynamoDB to simplify parsing
- Observability:
  - correlation ids in command/telemetry
  - structured logs in Lambdas
