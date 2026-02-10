/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: 10/02/2026
 * VERSÃO: 5.17.0
 * ===================================================================================
 *
 * MELHORIAS NESTA VERSÃO:
 *  1) Backoff exponencial + jitter para reconexão Wi-Fi e MQTT
 *  2) Config persistente via NVS (Preferences): intervalo de telemetria + calibração solo
 *  3) telemetry_id estável por amostra: THINGNAME-timestamp-seq (seq persistente)
 *
 * Mantém:
 *  - Fail-safe de válvula + millis wrap-safe + mutex
 *  - Store-and-forward no SD (NDJSON) + flush automático quando internet volta
 *
 * OBS:
 *  - OLED é só protótipo. Pode desligar via build flag ENABLE_OLED=0.
 */

#include <Arduino.h>
#include <Wire.h>
#include <SPI.h>
#include <SD.h>
#include <RTClib.h>
#include <Adafruit_AHTX0.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include "secrets.h"

// ===================================================================================
// BUILD FLAGS / DEFAULTS
// ===================================================================================
#ifndef FW_VERSION
#define FW_VERSION "5.17.0"
#endif

#ifndef DEFAULT_TELEMETRY_INTERVAL_MS
#define DEFAULT_TELEMETRY_INTERVAL_MS 60000
#endif

#ifndef ENABLE_OLED
#define ENABLE_OLED 1
#endif

// ===================================================================================
// 1) CONFIGURAÇÕES GERAIS
// ===================================================================================

const long BRT_OFFSET_SEC = -10800;        // -3h
const uint32_t OLED_SWITCH_MS = 2000;      // troca de tela (protótipo)

// FAIL-SAFE VÁLVULA
const uint32_t MAX_VALVE_DURATION_S = 900; // 15 min
const uint32_t VALVE_DEBUG_EVERY_MS = 5000;

// PINAGEM
#define SD_CS_PIN  5
#define PIN_SOLO   34
#define PIN_CHUVA  35
#define PIN_UV     32
#define PIN_LUZ    33
#define PIN_VALVE  2

// OLED
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define I2C_MUTEX_WAIT_MS 200

// SD arquivos
const char* LOG_FILENAME = "/telemetry_v5.csv";
const char* PENDING_FILENAME = "/pending_telemetry.ndjson";
const char* PENDING_TMP_FILENAME = "/pending_telemetry.tmp";

// NTP
const char* NTP_SERVER = "pool.ntp.org";

// Store-and-forward
static const size_t PENDING_LINE_MAX = 640;
const uint32_t MAX_PENDING_BYTES = 5UL * 1024UL * 1024UL; // 5MB (simples)
const uint32_t PENDING_FLUSH_MAX_ITEMS_DEFAULT = 30;
const uint32_t PENDING_FLUSH_MAX_MS_DEFAULT = 8000;
const uint32_t PENDING_FLUSH_EVERY_MS_DEFAULT = 15000;

// Soft format SD (apaga arquivos do app)
const uint32_t SD_FORMAT_WINDOW_MS = 8000;

// ===================================================================================
// 2) CONFIG PERSISTENTE (NVS)
// ===================================================================================
/**
 * A ideia aqui é: você consegue ajustar parâmetros SEM recompilar e eles persistem
 * entre reboots. (Excelente para protótipo e para produto.)
 *
 * Config que vamos persistir agora:
 * - telemetry_interval_ms (intervalo de telemetria)
 * - soil_raw_dry / soil_raw_wet (calibração do sensor de solo)
 *
 * Futuro: dá para persistir thresholds, modo de operação, etc.
 */
struct RuntimeConfig {
  uint32_t telemetry_interval_ms = DEFAULT_TELEMETRY_INTERVAL_MS;

  // calibração do solo (valores padrão seus)
  int soil_raw_dry = 3000;
  int soil_raw_wet = 1200;

  // parâmetros do flush (mantidos configuráveis)
  uint32_t pending_flush_max_items = PENDING_FLUSH_MAX_ITEMS_DEFAULT;
  uint32_t pending_flush_max_ms = PENDING_FLUSH_MAX_MS_DEFAULT;
  uint32_t pending_flush_every_ms = PENDING_FLUSH_EVERY_MS_DEFAULT;
};

RuntimeConfig g_cfg;
SemaphoreHandle_t cfgMutex;

// NVS keys
static const char* NVS_NS = "agrosmart";
static const char* K_TELE_INT = "tele_int";
static const char* K_SOIL_DRY = "soil_dry";
static const char* K_SOIL_WET = "soil_wet";
static const char* K_SEQ      = "tele_seq";

// sequência para telemetry_id (persistida “economicamente”)
uint32_t g_telemetrySeq = 0;
uint32_t g_seqDirty = 0;           // conta quantos increments sem persistir
const uint32_t SEQ_PERSIST_EVERY = 10; // grava no flash a cada 10 amostras (reduz desgaste)

// ===================================================================================
// 3) OBJETOS GLOBAIS
// ===================================================================================
RTC_DS3231 rtc;
Adafruit_AHTX0 aht;

#if ENABLE_OLED
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
#endif

WiFiClientSecure net;
PubSubClient client(net);

bool g_wifiConnected = false;
bool g_mqttConnected = false;
bool g_sdOk = false;
bool g_timeSynced = false;

// Válvula
bool g_valveState = false;
uint32_t g_valveOffTimeMs = 0;
uint32_t g_valveLastDebugMs = 0;
char g_lastCommandId[48] = {0};

// RTOS
SemaphoreHandle_t i2cMutex;
SemaphoreHandle_t dataMutex;
SemaphoreHandle_t valveMutex;
QueueHandle_t sensorQueue;

// ===================================================================================
// 4) ESTRUTURA DE DADOS
// ===================================================================================
struct TelemetryData {
  uint32_t timestamp;      // epoch (s)
  uint32_t seq;            // sequência local para telemetry_id
  float air_temp;
  float air_hum;
  int soil_moisture;
  int light_level;
  int rain_raw;
  float uv_index;
};

TelemetryData g_latestData;

// ===================================================================================
// 5) HELPERS (tempo wrap-safe)
// ===================================================================================
static inline bool timeReached(uint32_t now, uint32_t deadline) {
  return (int32_t)(now - deadline) >= 0;
}

// ===================================================================================
// 6) HELPERS CONFIG (mutex)
// ===================================================================================
static RuntimeConfig cfgGetCopy() {
  RuntimeConfig c;
  if (xSemaphoreTake(cfgMutex, pdMS_TO_TICKS(20))) {
    c = g_cfg;
    xSemaphoreGive(cfgMutex);
  } else {
    c = g_cfg; // melhor esforço
  }
  return c;
}

static void cfgSet(const RuntimeConfig& c) {
  if (xSemaphoreTake(cfgMutex, pdMS_TO_TICKS(50))) {
    g_cfg = c;
    xSemaphoreGive(cfgMutex);
  }
}

// ===================================================================================
// 7) NVS (Preferences)
// ===================================================================================
static void printConfig(const RuntimeConfig& c) {
  Serial.println("\n[CFG] ===== CONFIG ATUAL =====");
  Serial.printf("[CFG] FW_VERSION: %s\n", FW_VERSION);
  Serial.printf("[CFG] telemetry_interval_ms: %lu\n", (unsigned long)c.telemetry_interval_ms);
  Serial.printf("[CFG] soil_raw_dry: %d\n", c.soil_raw_dry);
  Serial.printf("[CFG] soil_raw_wet: %d\n", c.soil_raw_wet);
  Serial.printf("[CFG] pending_flush_max_items: %lu\n", (unsigned long)c.pending_flush_max_items);
  Serial.printf("[CFG] pending_flush_max_ms: %lu\n", (unsigned long)c.pending_flush_max_ms);
  Serial.printf("[CFG] pending_flush_every_ms: %lu\n", (unsigned long)c.pending_flush_every_ms);
  Serial.printf("[CFG] telemetry_seq (RAM): %lu\n", (unsigned long)g_telemetrySeq);
  Serial.println("[CFG] ========================\n");
}

static void loadConfigFromNVS() {
  Preferences prefs;
  if (!prefs.begin(NVS_NS, true)) {
    Serial.println("[NVS] Falha ao abrir namespace. Usando defaults.");
    return;
  }

  RuntimeConfig c; // defaults já no struct
  c.telemetry_interval_ms = prefs.getUInt(K_TELE_INT, c.telemetry_interval_ms);
  c.soil_raw_dry = prefs.getInt(K_SOIL_DRY, c.soil_raw_dry);
  c.soil_raw_wet = prefs.getInt(K_SOIL_WET, c.soil_raw_wet);

  // validação simples
  if (c.soil_raw_wet >= c.soil_raw_dry) {
    Serial.println("[NVS][WARN] soil_raw_wet >= soil_raw_dry. Revertendo para defaults.");
    c.soil_raw_dry = 3000;
    c.soil_raw_wet = 1200;
  }
  if (c.telemetry_interval_ms < 10000) {
    Serial.println("[NVS][WARN] interval muito baixo. Ajustando para 10s mínimo.");
    c.telemetry_interval_ms = 10000;
  }

  g_telemetrySeq = prefs.getUInt(K_SEQ, 0);

  prefs.end();
  cfgSet(c);
  printConfig(c);
}

static void saveConfigToNVS(const RuntimeConfig& c) {
  Preferences prefs;
  if (!prefs.begin(NVS_NS, false)) {
    Serial.println("[NVS] Falha ao abrir para escrita.");
    return;
  }
  prefs.putUInt(K_TELE_INT, c.telemetry_interval_ms);
  prefs.putInt(K_SOIL_DRY, c.soil_raw_dry);
  prefs.putInt(K_SOIL_WET, c.soil_raw_wet);
  prefs.end();
  Serial.println("[NVS] Config salva com sucesso.");
}

static void persistSeqIfNeeded(bool force = false) {
  if (!force && g_seqDirty < SEQ_PERSIST_EVERY) return;

  Preferences prefs;
  if (!prefs.begin(NVS_NS, false)) return;
  prefs.putUInt(K_SEQ, g_telemetrySeq);
  prefs.end();

  g_seqDirty = 0;
  Serial.printf("[NVS] telemetry_seq persistido: %lu\n", (unsigned long)g_telemetrySeq);
}

// ===================================================================================
// 8) BACKOFF EXPONENCIAL (Wi-Fi e MQTT)
// ===================================================================================
struct BackoffState {
  uint32_t attempt = 0;
  uint32_t nextTryMs = 0;
};

static uint32_t randJitterPercent(uint32_t baseMs) {
  // jitter 75% a 125%
  uint32_t r = (uint32_t)esp_random();
  uint32_t pct = 75 + (r % 51); // 75..125
  return (baseMs * pct) / 100;
}

static uint32_t backoffDelayMs(uint32_t baseMs, uint32_t maxMs, uint32_t attempt) {
  // base * 2^attempt (cap em maxMs)
  // limita attempt pra não estourar shift
  uint32_t a = attempt > 10 ? 10 : attempt; // 2^10=1024
  uint64_t delay = (uint64_t)baseMs * (1ULL << a);
  if (delay > maxMs) delay = maxMs;
  return randJitterPercent((uint32_t)delay);
}

static void backoffReset(BackoffState& b) {
  b.attempt = 0;
  b.nextTryMs = 0;
}

static bool backoffCanTry(BackoffState& b) {
  uint32_t now = (uint32_t)millis();
  if (b.nextTryMs == 0) return true;
  return timeReached(now, b.nextTryMs);
}

static void backoffOnFail(BackoffState& b, uint32_t baseMs, uint32_t maxMs) {
  uint32_t now = (uint32_t)millis();
  uint32_t d = backoffDelayMs(baseMs, maxMs, b.attempt);
  b.attempt++;
  b.nextTryMs = now + d;
  Serial.printf("[BACKOFF] próxima tentativa em %lu ms (attempt=%lu)\n",
                (unsigned long)d, (unsigned long)b.attempt);
}

// ===================================================================================
// 9) VÁLVULA (fail-safe + mutex)
// ===================================================================================
static inline uint32_t clampValveDurationS(int32_t requestedS) {
  if (requestedS <= 0) return 0;
  if ((uint32_t)requestedS > MAX_VALVE_DURATION_S) return MAX_VALVE_DURATION_S;
  return (uint32_t)requestedS;
}

static void valveSetOffLocked() {
  digitalWrite(PIN_VALVE, LOW);
  g_valveState = false;
  g_valveOffTimeMs = 0;
  g_valveLastDebugMs = 0;
}

static void valveSetOnForLocked(uint32_t durationS) {
  if (durationS == 0) {
    valveSetOffLocked();
    return;
  }
  digitalWrite(PIN_VALVE, HIGH);
  g_valveState = true;

  uint32_t now = (uint32_t)millis();
  g_valveOffTimeMs = now + (durationS * 1000UL);
  g_valveLastDebugMs = now;

  Serial.printf("[VALVULA] ✅ LIGADA por %lu s (cap=%lu s)\n",
                (unsigned long)durationS, (unsigned long)MAX_VALVE_DURATION_S);
}

static void valveApplyCommand(bool turnOn, int32_t durationS) {
  if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(50))) {
    if (!turnOn) {
      Serial.println("[VALVULA] ⏹️ OFF imediato.");
      valveSetOffLocked();
    } else {
      uint32_t safeS = clampValveDurationS(durationS);
      if ((uint32_t)durationS > safeS) {
        Serial.printf("[FAIL-SAFE] duration %ld s > max. clamp para %lu s\n",
                      (long)durationS, (unsigned long)safeS);
      }
      valveSetOnForLocked(safeS);
    }
    xSemaphoreGive(valveMutex);
  } else {
    Serial.println("[FAIL-SAFE] Mutex da válvula ocupado. Forçando OFF.");
    digitalWrite(PIN_VALVE, LOW);
    g_valveState = false;
    g_valveOffTimeMs = 0;
    g_valveLastDebugMs = 0;
  }
}

// ===================================================================================
// 10) MQTT CALLBACK (comandos)
// ===================================================================================
void mqttCallback(char* topic, byte* payload, unsigned int length) {
  Serial.println("\n>>> [MQTT] MENSAGEM RECEBIDA <<<");
  Serial.printf("Tópico: %s\n", topic);

  StaticJsonDocument<512> doc;
  DeserializationError error = deserializeJson(doc, payload, length);
  if (error) {
    Serial.print("[ERRO] JSON inválido: ");
    Serial.println(error.c_str());
    return;
  }

  const char* targetDevice = doc["device_id"];
  if (targetDevice != nullptr && strcmp(targetDevice, THINGNAME) != 0) {
    Serial.printf("[IGNORADO] Para %s (eu sou %s)\n", targetDevice, THINGNAME);
    return;
  }

  const char* cmdId = doc["command_id"];
  if (cmdId && cmdId[0] != '\0') {
    strncpy(g_lastCommandId, cmdId, sizeof(g_lastCommandId) - 1);
    g_lastCommandId[sizeof(g_lastCommandId) - 1] = '\0';
    Serial.printf("[CMD] command_id=%s\n", g_lastCommandId);
  }

  const char* action = doc["action"];
  if (!action) {
    Serial.println("[ERRO] Campo action ausente.");
    return;
  }

  int32_t duration = doc["duration"] | 0;

  if (strcmp(action, "on") == 0) {
    if (duration > 0) {
      Serial.printf("[COMANDO] LIGAR por %ld s\n", (long)duration);
      valveApplyCommand(true, duration);
    } else {
      Serial.println("[COMANDO] STOP (duration=0)");
      valveApplyCommand(false, 0);
    }
  } else {
    Serial.printf("[WARN] action desconhecida: %s\n", action);
  }
}

// ===================================================================================
// 11) TEMPO (RTC + NTP)
// ===================================================================================
DateTime getSystemTime() {
  if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
    DateTime now = rtc.now();
    xSemaphoreGive(i2cMutex);
    return now;
  }
  return DateTime((uint32_t)0);
}

void syncTimeWithNTP() {
  Serial.println("[TIME] Sincronizando via NTP...");
  configTime(0, 0, NTP_SERVER);

  struct tm timeinfo;
  int retry = 0;
  while (!getLocalTime(&timeinfo, 1000) && retry < 5) {
    Serial.print(".");
    retry++;
  }
  Serial.println();

  if (retry < 5) {
    if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
      rtc.adjust(DateTime(timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
                          timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec));
      xSemaphoreGive(i2cMutex);
      g_timeSynced = true;
      Serial.println("[TIME] RTC ajustado com sucesso.");
    }
  } else {
    Serial.println("[TIME] Falha NTP. Usando RTC local.");
  }
}

// ===================================================================================
// 12) SD STORE-AND-FORWARD (NDJSON + flush)
// ===================================================================================
static bool readLineToBuffer(File &f, char* out, size_t outSize) {
  if (!out || outSize < 2) return false;
  size_t idx = 0;
  bool gotAny = false;

  while (f.available()) {
    char c = (char)f.read();
    gotAny = true;

    if (c == '\r') continue;
    if (c == '\n') break;

    if (idx + 1 < outSize) {
      out[idx++] = c;
    } else {
      // descarta o resto da linha
      while (f.available()) {
        char d = (char)f.read();
        if (d == '\n') break;
      }
      out[0] = '\0';
      return false;
    }
  }

  out[idx] = '\0';
  return gotAny && idx > 0;
}

static bool pendingTooLarge() {
  if (!SD.exists(PENDING_FILENAME)) return false;
  File f = SD.open(PENDING_FILENAME, FILE_READ);
  if (!f) return false;
  uint32_t sz = (uint32_t)f.size();
  f.close();
  return sz >= MAX_PENDING_BYTES;
}

static void appendPendingNdjson(const char* jsonLine) {
  if (!g_sdOk || !jsonLine || jsonLine[0] == '\0') return;

  if (pendingTooLarge()) {
    Serial.println("[SD][WARN] pendências atingiram limite. Evento NÃO será enfileirado.");
    return;
  }

  File f = SD.open(PENDING_FILENAME, FILE_APPEND);
  if (!f) {
    Serial.println("[SD] Falha ao abrir pending_telemetry.ndjson para append.");
    return;
  }
  f.println(jsonLine);
  f.flush();
  f.close();
}

static void flushPending(uint32_t maxItems, uint32_t maxMs) {
  if (!g_sdOk || !g_mqttConnected) return;
  if (!SD.exists(PENDING_FILENAME)) return;

  File in = SD.open(PENDING_FILENAME, FILE_READ);
  if (!in) return;

  File out = SD.open(PENDING_TMP_FILENAME, FILE_WRITE);
  if (!out) { in.close(); return; }

  Serial.println("[SD] Flush pendências...");

  uint32_t start = (uint32_t)millis();
  uint32_t sentCount = 0;
  uint32_t keptCount = 0;

  char line[PENDING_LINE_MAX];

  while (in.available()) {
    if (sentCount >= maxItems) break;
    if (timeReached((uint32_t)millis(), start + maxMs)) break;

    bool okLine = readLineToBuffer(in, line, sizeof(line));
    if (!okLine) continue;

    bool ok = client.publish(AWS_IOT_PUBLISH_TOPIC, line);
    if (ok) {
      sentCount++;
    } else {
      out.println(line);
      keptCount++;
    }
    client.loop();
    vTaskDelay(pdMS_TO_TICKS(10));
  }

  while (in.available()) {
    bool okLine = readLineToBuffer(in, line, sizeof(line));
    if (!okLine) continue;
    out.println(line);
    keptCount++;
  }

  in.close();
  out.flush();
  out.close();

  SD.remove(PENDING_FILENAME);
  SD.rename(PENDING_TMP_FILENAME, PENDING_FILENAME);

  Serial.printf("[SD] Flush OK. Enviados=%lu Mantidos=%lu\n",
                (unsigned long)sentCount, (unsigned long)keptCount);
}

static void sdSoftFormatAppFiles() {
  if (!g_sdOk) return;

  Serial.println("[SD] Soft format (apaga arquivos do app)...");

  if (SD.exists(LOG_FILENAME)) SD.remove(LOG_FILENAME);
  if (SD.exists(PENDING_FILENAME)) SD.remove(PENDING_FILENAME);
  if (SD.exists(PENDING_TMP_FILENAME)) SD.remove(PENDING_TMP_FILENAME);

  File f = SD.open(LOG_FILENAME, FILE_WRITE);
  if (f) {
    f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status_Envio");
    f.close();
  }
  Serial.println("[SD] Soft format concluído.");
}

// ===================================================================================
// 13) TELEMETRY ID (estável)
// ===================================================================================
static void makeTelemetryId(char* out, size_t outSize, uint32_t timestamp, uint32_t seq) {
  // Ex: ESP32-AgroSmart-Station-V5-1766805062-1234
  snprintf(out, outSize, "%s-%lu-%lu",
           THINGNAME, (unsigned long)timestamp, (unsigned long)seq);
}

// ===================================================================================
// 14) TASK SENSORES
// ===================================================================================
void taskSensors(void* pv) {
  for (;;) {
    RuntimeConfig c = cfgGetCopy();
    TelemetryData data;

    DateTime nowUTC = getSystemTime();
    data.timestamp = nowUTC.unixtime();

    // seq para telemetry_id
    data.seq = g_telemetrySeq++;
    g_seqDirty++;
    persistSeqIfNeeded(false);

    // AHT10
    if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
      sensors_event_t h, t;
      if (aht.getEvent(&h, &t)) {
        data.air_temp = t.temperature;
        data.air_hum = h.relative_humidity;
      } else {
        data.air_temp = 0; data.air_hum = 0;
      }
      xSemaphoreGive(i2cMutex);
    } else {
      data.air_temp = 0; data.air_hum = 0;
    }

    // Analógicos
    int rawSolo = analogRead(PIN_SOLO);
    data.soil_moisture = constrain(map(rawSolo, c.soil_raw_dry, c.soil_raw_wet, 0, 100), 0, 100);

    int rawLuz = analogRead(PIN_LUZ);
    data.light_level = map(rawLuz, 0, 4095, 0, 100);

    data.rain_raw = analogRead(PIN_CHUVA);

    long somaUV = 0;
    for (int i = 0; i < 16; i++) { somaUV += analogRead(PIN_UV); vTaskDelay(pdMS_TO_TICKS(1)); }
    data.uv_index = (((somaUV / 16) * 3.3) / 4095.0) / 0.1;
    if (data.uv_index < 0.2) data.uv_index = 0.0;

    // debug
    DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
    Serial.printf("\n[SENSORS] %02d:%02d:%02d | T=%.1fC H=%.0f%% Solo=%d%% Luz=%d%% Ch=%d UV=%.1f seq=%lu\n",
                  nowBRT.hour(), nowBRT.minute(), nowBRT.second(),
                  data.air_temp, data.air_hum, data.soil_moisture, data.light_level,
                  data.rain_raw, data.uv_index, (unsigned long)data.seq);

    if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
      g_latestData = data;
      xSemaphoreGive(dataMutex);
    }

    if (xQueueSend(sensorQueue, &data, 0) != pdPASS) {
      Serial.println("[SENSORS][WARN] fila cheia, dado perdido.");
    }

    vTaskDelay(pdMS_TO_TICKS(c.telemetry_interval_ms));
  }
}

// ===================================================================================
// 15) TASK REDE + STORAGE (Wi-Fi/MQTT + flush)
// ===================================================================================
void taskNetworkStorage(void* pv) {
  net.setCACert(AWS_CERT_CA);
  net.setCertificate(AWS_CERT_CRT);
  net.setPrivateKey(AWS_CERT_PRIVATE);

  client.setServer(AWS_IOT_ENDPOINT, 8883);
  client.setCallback(mqttCallback);
  client.setBufferSize(1024);

  BackoffState wifiBackoff;
  BackoffState mqttBackoff;

  uint32_t lastNtpAttempt = 0;
  uint32_t lastFlushAttempt = 0;

  TelemetryData t;

  for (;;) {
    // FAIL-SAFE: válvula timeout
    if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(10))) {
      if (g_valveState) {
        uint32_t now = (uint32_t)millis();
        if (g_valveOffTimeMs == 0) {
          Serial.println("[FAIL-SAFE] Válvula ON sem deadline. OFF.");
          valveSetOffLocked();
        } else if (timeReached(now, g_valveOffTimeMs)) {
          Serial.println("[VALVULA] Tempo esgotado. OFF.");
          valveSetOffLocked();
        } else if (timeReached(now, g_valveLastDebugMs + VALVE_DEBUG_EVERY_MS)) {
          uint32_t remaining = (uint32_t)(g_valveOffTimeMs - now);
          Serial.printf("[VALVULA] Regando... faltam ~%lu ms\n", (unsigned long)remaining);
          g_valveLastDebugMs = now;
        }
      }
      xSemaphoreGive(valveMutex);
    }

    // ----------------------
    // Wi-Fi com backoff
    // ----------------------
    if (WiFi.status() != WL_CONNECTED) {
      if (g_wifiConnected) Serial.println("[NET] Wi-Fi caiu.");
      g_wifiConnected = false;
      g_mqttConnected = false;

      if (backoffCanTry(wifiBackoff)) {
        Serial.println("[NET] Tentando conectar Wi-Fi...");
        WiFi.disconnect();
        WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

        // se falhar, o status vai continuar != CONNECTED e o backoff entra
        backoffOnFail(wifiBackoff, 1000, 60000);
      }
    } else {
      if (!g_wifiConnected) {
        g_wifiConnected = true;
        Serial.println("[NET] Wi-Fi conectado!");
        backoffReset(wifiBackoff);

        syncTimeWithNTP();
        lastNtpAttempt = (uint32_t)millis();
      }

      if (!g_timeSynced && timeReached((uint32_t)millis(), lastNtpAttempt + 60000)) {
        syncTimeWithNTP();
        lastNtpAttempt = (uint32_t)millis();
      }
    }

    // ----------------------
    // MQTT com backoff
    // ----------------------
    if (g_wifiConnected) {
      if (!client.connected()) {
        g_mqttConnected = false;

        if (backoffCanTry(mqttBackoff)) {
          Serial.print("[AWS] Conectando MQTT... ");
          if (client.connect(THINGNAME)) {
            Serial.println("OK!");
            g_mqttConnected = true;
            backoffReset(mqttBackoff);

            client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
            Serial.printf("[AWS] Subscribed: %s\n", AWS_IOT_SUBSCRIBE_TOPIC);

            lastFlushAttempt = 0; // força flush assim que conectar
          } else {
            Serial.printf("FAIL rc=%d\n", client.state());
            backoffOnFail(mqttBackoff, 1000, 30000);
          }
        }
      } else {
        g_mqttConnected = true;
        client.loop();
      }
    }

    // Flush pendências (com limites e periodicidade configurável)
    if (g_mqttConnected) {
      RuntimeConfig c = cfgGetCopy();
      uint32_t now = (uint32_t)millis();
      if (lastFlushAttempt == 0 || timeReached(now, lastFlushAttempt + c.pending_flush_every_ms)) {
        flushPending(c.pending_flush_max_items, c.pending_flush_max_ms);
        lastFlushAttempt = now;
      }
    }

    // Processa fila de sensores (envio + SD)
    if (xQueueReceive(sensorQueue, &t, pdMS_TO_TICKS(100)) == pdPASS) {
      // JSON com telemetry_id estável
      StaticJsonDocument<640> doc;
      doc["device_id"] = THINGNAME;
      doc["timestamp"] = t.timestamp;
      doc["fw_version"] = FW_VERSION;
      doc["schema_version"] = 1;

      char telemetryId[96];
      makeTelemetryId(telemetryId, sizeof(telemetryId), t.timestamp, t.seq);
      doc["telemetry_id"] = telemetryId;

      JsonObject s = doc.createNestedObject("sensors");
      s["air_temp"] = t.air_temp;
      s["air_humidity"] = t.air_hum;
      s["soil_moisture"] = t.soil_moisture;
      s["light_level"] = t.light_level;
      s["rain_raw"] = t.rain_raw;
      s["uv_index"] = t.uv_index;

      char buf[640];
      size_t n = serializeJson(doc, buf, sizeof(buf));

      bool sent = false;

      if (g_mqttConnected && n > 0 && n < sizeof(buf)) {
        if (client.publish(AWS_IOT_PUBLISH_TOPIC, buf)) {
          sent = true;
          Serial.printf("[AWS] Telemetria enviada OK (telemetry_id=%s)\n", telemetryId);
        } else {
          Serial.printf("[AWS] Falha publish. Enfileirando (telemetry_id=%s)\n", telemetryId);
          appendPendingNdjson(buf);
        }
      } else {
        Serial.printf("[AWS] Offline. Enfileirando (telemetry_id=%s)\n", telemetryId);
        appendPendingNdjson(buf);
      }

      // CSV histórico (mantido compatível)
      if (g_sdOk) {
        File f = SD.open(LOG_FILENAME, FILE_APPEND);
        if (f) {
          f.printf("%lu,%.1f,%.0f,%d,%d,%d,%.2f,%s\n",
                   t.timestamp, t.air_temp, t.air_hum,
                   t.soil_moisture, t.light_level, t.rain_raw, t.uv_index,
                   sent ? "SENT" : "PENDING");
          f.close();
        }
      }
    }

    vTaskDelay(pdMS_TO_TICKS(20));
  }
}

#if ENABLE_OLED
// ===================================================================================
// 16) TASK OLED (protótipo)
// ===================================================================================
void taskDisplay(void* pv) {
  int screen = 0;

  for (;;) {
    TelemetryData d;
    if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(20))) {
      d = g_latestData;
      xSemaphoreGive(dataMutex);
    }

    bool valveOn = false;
    if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(10))) {
      valveOn = g_valveState;
      xSemaphoreGive(valveMutex);
    }

    if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
      display.clearDisplay();
      display.setTextColor(WHITE);
      display.setTextSize(1);

      DateTime nowUTC = rtc.now();
      DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);

      display.setCursor(0, 0);
      display.printf("%02d:%02d", nowBRT.hour(), nowBRT.minute());
      display.setCursor(40, 0);
      display.print(valveOn ? "REGANDO" : (g_wifiConnected ? "W:OK" : "W:X"));

      display.drawLine(0, 9, 128, 9, WHITE);
      display.setCursor(0, 15);

      switch (screen) {
        case 0:
          display.printf("FW: %s\n", FW_VERSION);
          display.printf("MQTT: %s\n", g_mqttConnected ? "ON" : "OFF");
          display.printf("SD:   %s\n", g_sdOk ? "OK" : "ERRO");
          display.printf("SEQ:  %lu\n", (unsigned long)g_telemetrySeq);
          break;
        case 1:
          display.setTextSize(2);
          display.printf("%.1fC\n", d.air_temp);
          display.setTextSize(1);
          display.printf("Um:%.0f%% UV:%.1f", d.air_hum, d.uv_index);
          break;
        case 2:
          display.printf("Solo: %d%%\n", d.soil_moisture);
          display.printf("Luz:  %d%%\n", d.light_level);
          display.printf("Chuva:%d\n", d.rain_raw);
          break;
      }

      display.display();
      xSemaphoreGive(i2cMutex);
    }

    vTaskDelay(pdMS_TO_TICKS(OLED_SWITCH_MS));
    screen = (screen + 1) % 3;
  }
}
#endif

// ===================================================================================
// 17) BOOT HELPERS (Serial FORMAT)
// ===================================================================================
static bool waitSerialForWord(const char* word, uint32_t timeoutMs) {
  char buf[24] = {0};
  size_t idx = 0;
  uint32_t start = (uint32_t)millis();

  auto lower = [](char c) -> char { return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; };

  while (!timeReached((uint32_t)millis(), start + timeoutMs)) {
    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c == '\r' || c == '\n') {
        buf[idx] = '\0';

        // compara ignore-case
        bool eq = true;
        const char* a = buf;
        const char* b = word;
        while (*a && *b) {
          if (lower(*a) != lower(*b)) { eq = false; break; }
          a++; b++;
        }
        if (*a != '\0' || *b != '\0') eq = false;

        if (eq) return true;

        idx = 0;
        memset(buf, 0, sizeof(buf));
      } else {
        if (idx + 1 < sizeof(buf)) buf[idx++] = c;
      }
    }
    delay(10);
  }
  return false;
}

// ===================================================================================
// 18) SETUP
// ===================================================================================
void setup() {
  Serial.begin(115200);
  delay(600);

  Serial.println("\n=== AGROSMART BOOT ===");
  Serial.printf("FW_VERSION: %s\n", FW_VERSION);

  // mutexes
  i2cMutex = xSemaphoreCreateMutex();
  dataMutex = xSemaphoreCreateMutex();
  valveMutex = xSemaphoreCreateMutex();
  cfgMutex = xSemaphoreCreateMutex();

  // IO
  analogReadResolution(12);
  pinMode(PIN_SOLO, INPUT);
  pinMode(PIN_CHUVA, INPUT);
  pinMode(PIN_LUZ, INPUT);
  pinMode(PIN_UV, INPUT);

  pinMode(PIN_VALVE, OUTPUT);
  digitalWrite(PIN_VALVE, LOW);

  // periféricos
  Wire.begin(21, 22);

#if ENABLE_OLED
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) Serial.println("[OLED] Falhou init");
  else { display.clearDisplay(); display.display(); }
#endif

  if (!rtc.begin()) Serial.println("[RTC] Falhou init");
  if (!aht.begin()) Serial.println("[AHT10] Falhou init");

  // load config + seq
  loadConfigFromNVS();

  // SD
  SPI.begin(18, 19, 23, SD_CS_PIN);
  if (SD.begin(SD_CS_PIN, SPI, 4000000)) {
    g_sdOk = true;
    Serial.println("[SD] OK.");

    Serial.printf("[SD] Digite 'FORMAT' e ENTER em até %lu ms para resetar arquivos do app...\n",
                  (unsigned long)SD_FORMAT_WINDOW_MS);
    if (waitSerialForWord("FORMAT", SD_FORMAT_WINDOW_MS)) {
      sdSoftFormatAppFiles();
    }

    if (!SD.exists(LOG_FILENAME)) {
      File f = SD.open(LOG_FILENAME, FILE_WRITE);
      if (f) {
        f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status_Envio");
        f.close();
      }
    }
    if (SD.exists(PENDING_TMP_FILENAME)) SD.remove(PENDING_TMP_FILENAME);
  } else {
    Serial.println("[SD] ERRO: não detectado.");
  }

  // Wi-Fi
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  // Queue
  sensorQueue = xQueueCreate(10, sizeof(TelemetryData));

  // Tasks
#if ENABLE_OLED
  xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
#endif
  xTaskCreate(taskNetworkStorage, "Net", 8192, NULL, 2, NULL);
  xTaskCreate(taskSensors, "Sensors", 4096, NULL, 3, NULL);

  Serial.println("[BOOT] Tasks iniciadas.");
}

void loop() {
  // Não usamos loop no FreeRTOS
  vTaskDelete(NULL);
}
