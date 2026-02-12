/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM (AgroSmart Precision IoT V5)
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: 11/02/2026
 * VERSÃO: 5.17.3 (SD crash-safe store-and-forward + debug profundo)
 * ===================================================================================
 *
 * MOTIVAÇÃO
 * - Corrigir perda de dados no flush do SD (reset/WDT ou falha de I/O no meio da compactação)
 * - Melhorar diagnósticos de MQTT publish falhando (buffer PubSubClient, estado MQTT/TLS)
 *
 * PRINCIPAIS MELHORIAS (RESUMO)
 *  1) Store-and-forward NDJSON append-only (cada amostra offline vira 1 linha)
 *  2) Flush com offset persistido em NVS (retoma após reboot; avança SOMENTE após publish OK)
 *  3) Compactação crash-safe (TMP + BAK + renames atômicos)
 *  4) SD protegido por mutex + loops com vTaskDelay/yield (mitiga WDT)
 *  5) PubSubClient com buffer maior + publish com length + logs detalhados (state, TLS, buffer)
 *  6) Telemetry_id estável (device_id + timestamp + seq) e seq persistida em NVS
 *
 * OBS IMPORTANTES
 * - A telemetria é publicada em MQTT (AWS IoT Core). Uma IoT Rule grava no DynamoDB.
 * - Para stress-test com 10s/20s, use build flag DEFAULT_TELEMETRY_INTERVAL_MS no platformio.ini.
 * - Se NVS já tiver um intervalo gravado, ele prevalece. Para forçar defaults: pio run -t erase.
 */

#include <Arduino.h>
#include <Wire.h>
#include <SPI.h>
#include <SD.h>
#include <RTClib.h>
#include <Adafruit_AHTX0.h>

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>

#include <ArduinoJson.h>
#include <Preferences.h>
#include <time.h>
#include <esp_system.h>

#include <type_traits>
#include <utility>

#if __has_include("secrets.h")
  #include "secrets.h"
#else
  #error "secrets.h não encontrado. Garanta que está em firmware/include/secrets.h"
#endif

// ===================================================================================
// BUILD FLAGS / DEFAULTS (definidos no platformio.ini via build_flags)
// ===================================================================================
#ifndef FW_VERSION
  #define FW_VERSION "5.17.3"
#endif

#ifndef DEFAULT_TELEMETRY_INTERVAL_MS
  #define DEFAULT_TELEMETRY_INTERVAL_MS 60000UL
#endif

#ifndef ENABLE_OLED
  #define ENABLE_OLED 1
#endif

#ifndef LOG_LEVEL
  // 0=quiet | 1=info | 2=debug
  #define LOG_LEVEL 2
#endif

#ifndef NVS_FORCE_CONFIG_DEFAULTS
  // 1 = ignora config gravada no NVS (tele_int/soil_*), usa build flags/defaults.
  //     Mantém seq/pend_off para não bagunçar o flush.
  #define NVS_FORCE_CONFIG_DEFAULTS 0
#endif

#ifndef TELEMETRY_SCHEMA_VERSION
  #define TELEMETRY_SCHEMA_VERSION 1
#endif

// ===================================================================================
// LOG HELPERS
// ===================================================================================
static inline uint32_t msNow() { return (uint32_t)millis(); }

static void logPrefix(const char* level) {
  Serial.printf("[%10lu][%s] ", (unsigned long)msNow(), level);
}

#define LOGE(fmt, ...) do { logPrefix("ERR"); Serial.printf((fmt), ##__VA_ARGS__); Serial.println(); } while(0)
#define LOGW(fmt, ...) do { if (LOG_LEVEL >= 1) { logPrefix("WRN"); Serial.printf((fmt), ##__VA_ARGS__); Serial.println(); } } while(0)
#define LOGI(fmt, ...) do { if (LOG_LEVEL >= 1) { logPrefix("INF"); Serial.printf((fmt), ##__VA_ARGS__); Serial.println(); } } while(0)
#define LOGD(fmt, ...) do { if (LOG_LEVEL >= 2) { logPrefix("DBG"); Serial.printf((fmt), ##__VA_ARGS__); Serial.println(); } } while(0)

// ===================================================================================
// 1) CONFIGURAÇÕES GERAIS
// ===================================================================================
static const long BRT_OFFSET_SEC = -10800; // -3h

// FAIL-SAFE VÁLVULA (SEGURANÇA FÍSICA)
static const uint32_t MAX_VALVE_DURATION_S = 900;  // 15 min
static const uint32_t VALVE_DEBUG_EVERY_MS = 5000;

// PINAGEM
#define SD_CS_PIN  5
#define PIN_SOLO   34
#define PIN_CHUVA  35
#define PIN_UV     32
#define PIN_LUZ    33
#define PIN_VALVE  2

// OLED (opcional)
#if ENABLE_OLED
  #include <Adafruit_GFX.h>
  #include <Adafruit_SSD1306.h>
  #define SCREEN_WIDTH 128
  #define SCREEN_HEIGHT 64
#endif
static const uint32_t OLED_SWITCH_MS = 2000;
static const uint32_t I2C_MUTEX_WAIT_MS = 200;

// Arquivos no SD
static const char* LOG_FILENAME          = "/telemetry_v5.csv";
static const char* PENDING_FILENAME      = "/pending_telemetry.ndjson";
static const char* PENDING_TMP_FILENAME  = "/pending_telemetry.tmp";
static const char* PENDING_BAK_FILENAME  = "/pending_telemetry.bak";

// NTP
static const char* NTP_SERVER = "pool.ntp.org";

// Store-and-forward limits
static const size_t   PENDING_LINE_MAX            = 1200;                // NDJSON line max (bytes)
static const uint32_t MAX_PENDING_BYTES           = 5UL * 1024UL * 1024UL; // 5MB
static const uint32_t COMPACT_THRESHOLD_BYTES     = 64UL * 1024UL;        // compacta se offset >= 64KB
static const uint32_t SD_REINIT_COOLDOWN_MS       = 30000;
static const uint32_t SD_SPI_FREQ_PRIMARY         = 4000000;
static const uint32_t SD_SPI_FREQ_FALLBACK        = 1000000;

// Flush limits (evitar WDT / travar sensores)
static const uint32_t PENDING_FLUSH_EVERY_MS_DEFAULT     = 15000;
static const uint32_t PENDING_FLUSH_MAX_ITEMS_DEFAULT    = 30;
static const uint32_t PENDING_FLUSH_MAX_MS_DEFAULT       = 8000;

// MQTT
static const uint16_t MQTT_PORT = 8883;
static const uint16_t MQTT_BUFFER_SIZE = 2048; // <<<<<< CORREÇÃO PRINCIPAL p/ publish falhando por payload > 256

// ACK de comandos (novo)
#ifndef AWS_IOT_ACK_TOPIC
  #define AWS_IOT_ACK_TOPIC "agrosmart/v5/ack"
#endif

// ===================================================================================
// 2) ESTRUTURAS
// ===================================================================================
struct TelemetryData {
  uint32_t timestamp; // epoch seconds
  uint32_t seq;       // sequência local
  float air_temp;
  float air_hum;
  int soil_moisture;
  int light_level;
  int rain_raw;
  float uv_index;
};

struct RuntimeConfig {
  uint32_t telemetry_interval_ms = DEFAULT_TELEMETRY_INTERVAL_MS;
  int soil_raw_dry = 3000;
  int soil_raw_wet = 1200;

  uint32_t pending_flush_every_ms = PENDING_FLUSH_EVERY_MS_DEFAULT;
  uint32_t pending_flush_max_items = PENDING_FLUSH_MAX_ITEMS_DEFAULT;
  uint32_t pending_flush_max_ms = PENDING_FLUSH_MAX_MS_DEFAULT;
};

// ===================================================================================
// 3) GLOBAIS
// ===================================================================================
RTC_DS3231 rtc;
Adafruit_AHTX0 aht;

#if ENABLE_OLED
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
#endif

WiFiClientSecure net;
PubSubClient client(net);

static bool g_wifiConnected = false;
static bool g_mqttConnected = false;
static bool g_sdOk = false;
static bool g_timeSynced = false;

static bool g_valveState = false;
static uint32_t g_valveOffTimeMs = 0;
static uint32_t g_valveLastDebugMs = 0;
static char g_lastCommandId[48] = {0};
static char g_activeCommandId[48] = {0}; // command_id do comando atualmente em execução (válvula ON)

// FreeRTOS
static QueueHandle_t sensorQueue;
static SemaphoreHandle_t i2cMutex;
static SemaphoreHandle_t dataMutex;
static SemaphoreHandle_t valveMutex;
static SemaphoreHandle_t sdMutex;
static SemaphoreHandle_t cfgMutex;

static TelemetryData g_latestData;

// NVS
static const char* NVS_NS = "agrosmart";
static const char* K_TELE_INT = "tele_int";
static const char* K_SOIL_DRY = "soil_dry";
static const char* K_SOIL_WET = "soil_wet";
static const char* K_SEQ      = "tele_seq";
static const char* K_PEND_OFF = "pend_off";

static RuntimeConfig g_cfg;
static uint32_t g_telemetrySeq = 0;
static uint32_t g_pendingOffset = 0;
static uint32_t g_seqDirty = 0;
static uint32_t g_offDirty = 0;
static const uint32_t SEQ_PERSIST_EVERY = 10;
static const uint32_t OFF_PERSIST_EVERY = 5;

// SD reinit
static uint32_t g_sdLastReinitMs = 0;

// ===================================================================================
// 4) HELPERS (tempo wrap-safe / mutex)
// ===================================================================================
static inline bool timeReached(uint32_t now, uint32_t deadline) {
  return (int32_t)(now - deadline) >= 0;
}

static bool lockSem(SemaphoreHandle_t sem, uint32_t waitMs) {
  return xSemaphoreTake(sem, pdMS_TO_TICKS(waitMs)) == pdTRUE;
}

static void unlockSem(SemaphoreHandle_t sem) {
  xSemaphoreGive(sem);
}

// ===================================================================================
// 5) CONFIG / NVS
// ===================================================================================
static RuntimeConfig cfgGet() {
  RuntimeConfig c;
  if (lockSem(cfgMutex, 50)) {
    c = g_cfg;
    unlockSem(cfgMutex);
  } else {
    c = g_cfg;
  }
  return c;
}

static void cfgSet(const RuntimeConfig& c) {
  if (lockSem(cfgMutex, 50)) {
    g_cfg = c;
    unlockSem(cfgMutex);
  }
}

static void printConfig() {
  RuntimeConfig c = cfgGet();
  LOGI("FW=%s | THING=%s | schema=%d", FW_VERSION, THINGNAME, TELEMETRY_SCHEMA_VERSION);
  LOGI("[NVS] tele_int=%lu ms, soil(dry=%d wet=%d), seq=%lu, pend_off=%lu",
       (unsigned long)c.telemetry_interval_ms, c.soil_raw_dry, c.soil_raw_wet,
       (unsigned long)g_telemetrySeq, (unsigned long)g_pendingOffset);
}

static void loadFromNVS() {
  Preferences p;
  if (!p.begin(NVS_NS, true)) {
    LOGW("[NVS] Falha ao abrir (read). Usando defaults.");
    return;
  }

  RuntimeConfig c;
  if (!NVS_FORCE_CONFIG_DEFAULTS) {
    c.telemetry_interval_ms = p.getUInt(K_TELE_INT, c.telemetry_interval_ms);
    c.soil_raw_dry = p.getInt(K_SOIL_DRY, c.soil_raw_dry);
    c.soil_raw_wet = p.getInt(K_SOIL_WET, c.soil_raw_wet);
  } else {
    LOGW("[NVS] FORCANDO DEFAULTS (ignora tele_int/soil_* do NVS)");
  }

  if (c.soil_raw_wet >= c.soil_raw_dry) {
    LOGW("[NVS] soil_raw_wet >= soil_raw_dry. Revertendo defaults.");
    c.soil_raw_dry = 3000;
    c.soil_raw_wet = 1200;
  }
  if (c.telemetry_interval_ms < 10000) {
    LOGW("[NVS] telemetry_interval_ms muito baixo. Ajustando para 10s.");
    c.telemetry_interval_ms = 10000;
  }

  g_telemetrySeq  = p.getUInt(K_SEQ, 0);
  g_pendingOffset = p.getUInt(K_PEND_OFF, 0);

  p.end();
  cfgSet(c);
  printConfig();
}

static void persistSeqIfNeeded(bool force=false) {
  if (!force && g_seqDirty < SEQ_PERSIST_EVERY) return;

  Preferences p;
  if (!p.begin(NVS_NS, false)) return;
  p.putUInt(K_SEQ, g_telemetrySeq);
  p.end();
  g_seqDirty = 0;
  LOGD("[NVS] telemetry_seq persistido: %lu", (unsigned long)g_telemetrySeq);
}

static void persistOffsetIfNeeded(bool force=false) {
  if (!force && g_offDirty < OFF_PERSIST_EVERY) return;

  Preferences p;
  if (!p.begin(NVS_NS, false)) return;
  p.putUInt(K_PEND_OFF, g_pendingOffset);
  p.end();
  g_offDirty = 0;
  LOGD("[NVS] pending_offset persistido: %lu", (unsigned long)g_pendingOffset);
}

// ===================================================================================
// 6) SD HELPERS (init / recovery / stats)
// ===================================================================================
static bool sdBeginWithFreq(uint32_t freqHz) {
  SPI.begin(18, 19, 23, SD_CS_PIN);
  bool ok = SD.begin(SD_CS_PIN, SPI, freqHz);
  if (ok) {
    LOGI("[SD] OK (SPI=%lu Hz) type=%d", (unsigned long)freqHz, (int)SD.cardType());
  } else {
    LOGW("[SD] FAIL (SPI=%lu Hz)", (unsigned long)freqHz);
  }
  return ok;
}

static bool sdInit() {
  if (lockSem(sdMutex, 2000)) {
    bool ok = sdBeginWithFreq(SD_SPI_FREQ_PRIMARY);
    if (!ok) ok = sdBeginWithFreq(SD_SPI_FREQ_FALLBACK);
    g_sdOk = ok;

    // cria CSV com header se não existe
    if (ok) {
      if (!SD.exists(LOG_FILENAME)) {
        File f = SD.open(LOG_FILENAME, FILE_WRITE);
        if (f) {
          f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status_Envio,telemetry_id,seq");
          f.close();
        }
      }
    }
    unlockSem(sdMutex);
  } else {
    LOGW("[SD] Mutex ocupado na init.");
    g_sdOk = false;
  }
  return g_sdOk;
}

// Recovery simples se existir .bak/.tmp após queda
static void sdRecoverPendingIfNeeded() {
  if (!g_sdOk) return;

  if (!lockSem(sdMutex, 2000)) return;

  bool hasBak = SD.exists(PENDING_BAK_FILENAME);
  bool hasTmp = SD.exists(PENDING_TMP_FILENAME);
  bool hasMain = SD.exists(PENDING_FILENAME);

  if (hasBak) {
    LOGW("[SD][RECOVERY] Encontrado .bak. hasMain=%d hasTmp=%d", (int)hasMain, (int)hasTmp);

    // Se main não existe, restaura bak -> main
    if (!hasMain) {
      if (SD.rename(PENDING_BAK_FILENAME, PENDING_FILENAME)) {
        LOGW("[SD][RECOVERY] Restaurado BAK -> MAIN");
        g_pendingOffset = 0;
        g_offDirty++;
        persistOffsetIfNeeded(true);
      } else {
        LOGE("[SD][RECOVERY] Falha ao renomear BAK->MAIN");
      }
    } else {
      // main existe: mantém main e remove bak (ou poderia manter para debug)
      SD.remove(PENDING_BAK_FILENAME);
      LOGW("[SD][RECOVERY] MAIN existe. Removendo BAK antigo.");
    }
  }

  if (hasTmp) {
    // tmp nunca deve sobreviver; se existe, é resíduo de compactação interrompida
    LOGW("[SD][RECOVERY] Encontrado .tmp. Removendo para evitar confusão.");
    SD.remove(PENDING_TMP_FILENAME);
  }

  unlockSem(sdMutex);
}

static uint32_t sdFileSize(const char* path) {
  if (!g_sdOk) return 0;
  uint32_t s = 0;
  if (!lockSem(sdMutex, 500)) return 0;
  File f = SD.open(path, FILE_READ);
  if (f) { s = (uint32_t)f.size(); f.close(); }
  unlockSem(sdMutex);
  return s;
}

// Reinit do SD (cooldown)
static void sdTryReinit() {
  uint32_t now = msNow();
  if (g_sdOk) return;
  if (!timeReached(now, g_sdLastReinitMs + SD_REINIT_COOLDOWN_MS)) return;

  LOGW("[SD] Tentando reinit...");
  g_sdLastReinitMs = now;
  sdInit();
  if (g_sdOk) sdRecoverPendingIfNeeded();
}

// ===================================================================================
// 7) MQTT HELPERS (state + publish debug)
// ===================================================================================
static const char* mqttStateName(int st) {
  switch (st) {
    case MQTT_CONNECTION_TIMEOUT: return "TIMEOUT";
    case MQTT_CONNECTION_LOST: return "CONNECTION_LOST";
    case MQTT_CONNECT_FAILED: return "CONNECT_FAILED";
    case MQTT_DISCONNECTED: return "DISCONNECTED";
    case MQTT_CONNECTED: return "CONNECTED";
    case MQTT_CONNECT_BAD_PROTOCOL: return "BAD_PROTOCOL";
    case MQTT_CONNECT_BAD_CLIENT_ID: return "BAD_CLIENT_ID";
    case MQTT_CONNECT_UNAVAILABLE: return "UNAVAILABLE";
    case MQTT_CONNECT_BAD_CREDENTIALS: return "BAD_CREDENTIALS";
    case MQTT_CONNECT_UNAUTHORIZED: return "UNAUTHORIZED";
    default: return "UNKNOWN";
  }
}

template <typename T>
struct has_lastError {
  template <typename U>
  static auto test(int) -> decltype(std::declval<U&>().lastError((char*)nullptr, size_t(0)), std::true_type{});
  template <typename>
  static std::false_type test(...);
  static constexpr bool value = decltype(test<T>(0))::value;
};

template <typename ClientT>
static void logTlsLastError_impl(ClientT& c, std::true_type) {
  // arduino-esp32 expõe lastError(buf, size) (mbedTLS) — diferente de getLastSSLError (BearSSL/Arduino-Pico/ESP8266)
  char buf[256] = {0};
  int err = c.lastError(buf, sizeof(buf));
  if (err != 0 || buf[0] != '\0') {
    LOGW("[TLS] lastError=%d msg=%s", err, buf);
  } else {
    LOGD("[TLS] lastError=0");
  }

  int we = c.getWriteError();
  if (we != 0) {
    LOGW("[TLS] writeError=%d", we);
  }
}

template <typename ClientT>
static void logTlsLastError_impl(ClientT& c, std::false_type) {
  // Core/versão sem API pública para o erro TLS
  int we = c.getWriteError();
  LOGW("[TLS] API lastError() indisponível neste core. writeError=%d", we);
}

static void logTlsLastError() {
  logTlsLastError_impl(net, std::integral_constant<bool, has_lastError<WiFiClientSecure>::value>{});
}


static bool mqttPublish(const char* topic, const uint8_t* payload, uint32_t len, bool retained=false) {
  if (!g_mqttConnected || !client.connected()) {
    LOGW("[AWS] publish skip (mqttConnected=%d client.connected=%d)", (int)g_mqttConnected, (int)client.connected());
    return false;
  }

  uint16_t bufSz = client.getBufferSize();
  if (len + 10 > bufSz) { // folga
    LOGE("[AWS] payload len=%lu > PubSubClient buffer=%u. AUMENTE MQTT_BUFFER_SIZE!", (unsigned long)len, (unsigned)bufSz);
    return false;
  }

  bool ok = client.publish(topic, payload, len, retained);
  if (!ok) {
    int st = client.state();
    LOGE("[AWS] publish FAIL: state=%d(%s) connected=%d len=%lu buf=%u topic=%s",
         st, mqttStateName(st), (int)client.connected(), (unsigned long)len, (unsigned)bufSz, topic);
    logTlsLastError();
  } else {
    LOGD("[AWS] publish OK len=%lu topic=%s", (unsigned long)len, topic);
  }
  return ok;
}

// ===================================================================================
// 7.1) ACK DE COMANDOS (command_id + status)
// ===================================================================================
static DateTime getSystemTime(); // forward declaration (definido na seção TIME)

static uint32_t epochNow() {
  // Usa RTC (atualizado por NTP quando possível). Best-effort: se RTC falhar, cai para 0.
  DateTime nowUTC = getSystemTime();
  return nowUTC.unixtime();
}

static void safeCopy(char* dst, size_t dstSz, const char* src) {
  if (!dst || dstSz == 0) return;
  if (!src) { dst[0] = '\0'; return; }
  strncpy(dst, src, dstSz - 1);
  dst[dstSz - 1] = '\0';
}

static bool publishCommandAck(const char* commandId,
                              const char* status,
                              const char* action = nullptr,
                              int32_t durationS = -1,
                              const char* reason = nullptr,
                              const char* error = nullptr) {
  if (!commandId || commandId[0] == '\0') {
    LOGW("[ACK] command_id vazio. Skip.");
    return false;
  }
  if (!status || status[0] == '\0') status = "unknown";

  StaticJsonDocument<384> doc;
  doc["device_id"] = THINGNAME;
  doc["command_id"] = commandId;
  doc["status"] = status;
  doc["ts"] = epochNow();

  JsonObject sys = doc.createNestedObject("sys");
  sys["fw"] = FW_VERSION;
  sys["uptime_s"] = (uint32_t)(msNow()/1000UL);
  if (g_wifiConnected) sys["rssi"] = WiFi.RSSI();

  if (action) doc["action"] = action;
  if (durationS >= 0) doc["duration"] = durationS;
  if (reason) doc["reason"] = reason;
  if (error) doc["error"] = error;

  char out[512];
  size_t outLen = serializeJson(doc, out, sizeof(out));
  if (outLen == 0) {
    LOGE("[ACK] serializeJson falhou");
    return false;
  }

  // ArduinoJson pode adicionar  ao final do buffer; evitar enviar bytes nulos no MQTT
  if (outLen > 0 && out[outLen - 1] == '\0') {
    outLen--;
  }

  bool ok = mqttPublish(AWS_IOT_ACK_TOPIC, (const uint8_t*)out, (uint32_t)outLen, false);
  LOGI("[ACK] status=%s cmd=%s ok=%d", status, commandId, (int)ok);
  return ok;
}

// ===================================================================================
// 8) TELEMETRY PAYLOAD (JSON)
// ===================================================================================
static void makeTelemetryId(char* out, size_t outSz, uint32_t ts, uint32_t seq) {
  // Ex: ESP32-AgroSmart-Station-V5:1700000000:42
  snprintf(out, outSz, "%s:%lu:%lu", THINGNAME, (unsigned long)ts, (unsigned long)seq);
}

static bool buildTelemetryJson(const TelemetryData& d, char* out, size_t outSz, uint32_t& outLen) {
  // Doc maior (por causa de sys.*)
  StaticJsonDocument<1024> doc;

  doc["device_id"] = THINGNAME;
  doc["timestamp"] = d.timestamp;
  doc["telemetry_seq"] = d.seq;

  char tid[80];
  makeTelemetryId(tid, sizeof(tid), d.timestamp, d.seq);
  doc["telemetry_id"] = tid;

  JsonObject s = doc.createNestedObject("sensors");
  s["air_temp"] = d.air_temp;
  s["air_humidity"] = d.air_hum;
  s["soil_moisture"] = d.soil_moisture;
  s["light_level"] = d.light_level;
  s["rain_raw"] = d.rain_raw;
  s["uv_index"] = d.uv_index;

  JsonObject sys = doc.createNestedObject("sys");
  sys["fw"] = FW_VERSION;
  sys["schema"] = TELEMETRY_SCHEMA_VERSION;
  sys["uptime_s"] = (uint32_t)(msNow()/1000UL);
  sys["heap"] = (uint32_t)esp_get_free_heap_size();
  if (g_wifiConnected) sys["rssi"] = WiFi.RSSI();

  // stats da fila pendente (best effort)
  uint32_t pendSz = sdFileSize(PENDING_FILENAME);
  sys["pending_bytes"] = pendSz;
  sys["pending_off"] = g_pendingOffset;

  size_t needed = measureJson(doc) + 1;
  if (needed > outSz) {
    LOGE("[JSON] buffer pequeno: needed=%u outSz=%u", (unsigned)needed, (unsigned)outSz);
    return false;
  }

  outLen = serializeJson(doc, out, outSz);
  return outLen > 0;
}

// ===================================================================================
// 9) PENDING NDJSON (append / read / flush / compact)
// ===================================================================================
static bool sdAppendPendingLine(const char* line, uint32_t len) {
  if (!g_sdOk) return false;
  if (len == 0 || len > PENDING_LINE_MAX) {
    LOGE("[SD][PENDING] len inválido=%lu", (unsigned long)len);
    return false;
  }

  if (!lockSem(sdMutex, 1500)) {
    LOGW("[SD][PENDING] mutex ocupado (append).");
    return false;
  }

  // limite de tamanho antes de escrever
  uint32_t sizeBefore = 0;
  File s = SD.open(PENDING_FILENAME, FILE_READ);
  if (s) { sizeBefore = (uint32_t)s.size(); s.close(); }

  if (sizeBefore > MAX_PENDING_BYTES) {
    LOGW("[SD][PENDING] arquivo muito grande (%lu). NÃO gravando mais (proteção).", (unsigned long)sizeBefore);
    unlockSem(sdMutex);
    return false;
  }

  File f = SD.open(PENDING_FILENAME, FILE_APPEND);
  if (!f) {
    LOGE("[SD][PENDING] open append falhou.");
    unlockSem(sdMutex);
    return false;
  }

  size_t w = f.write((const uint8_t*)line, len);
  f.write('\n');
  f.flush();
  f.close();

  unlockSem(sdMutex);

  if (w != len) {
    LOGE("[SD][PENDING] write parcial (%u/%lu).", (unsigned)w, (unsigned long)len);
    return false;
  }

  LOGD("[SD][PENDING] append=OK bytes=%lu (sizeBefore=%lu)", (unsigned long)len, (unsigned long)sizeBefore);
  return true;
}

// Lê 1 linha a partir de offset. Retorna nextOffset e fileSize. Abre/fecha o arquivo para manter SD thread-safe.
static bool sdReadPendingLine(uint32_t offset, String& outLine, uint32_t& nextOffset, uint32_t& fileSize) {
  outLine = "";
  nextOffset = offset;
  fileSize = 0;

  if (!g_sdOk) return false;

  if (!lockSem(sdMutex, 1500)) return false;

  File f = SD.open(PENDING_FILENAME, FILE_READ);
  if (!f) {
    unlockSem(sdMutex);
    return false;
  }

  fileSize = (uint32_t)f.size();
  if (offset >= fileSize) {
    f.close();
    unlockSem(sdMutex);
    return false;
  }

  if (!f.seek(offset)) {
    LOGE("[SD][READ] seek(%lu) falhou (size=%lu)", (unsigned long)offset, (unsigned long)fileSize);
    f.close();
    unlockSem(sdMutex);
    return false;
  }

  outLine = f.readStringUntil('\n');
  uint32_t posAfter = (uint32_t)f.position();
  f.close();
  unlockSem(sdMutex);

  // remove \r
  outLine.trim(); // remove espaços e \r
  nextOffset = posAfter;

  if (outLine.length() == 0) {
    return false;
  }
  if (outLine.length() > PENDING_LINE_MAX) {
    LOGE("[SD][READ] linha grande demais (%u)", (unsigned)outLine.length());
    return false;
  }

  return true;
}

static bool sdCompactPendingFile(uint32_t keepFromOffset) {
  if (!g_sdOk) return false;

  LOGW("[SD][COMPACT] Iniciando compactação (keepFrom=%lu)", (unsigned long)keepFromOffset);

  if (!lockSem(sdMutex, 5000)) {
    LOGW("[SD][COMPACT] mutex ocupado.");
    return false;
  }

  File src = SD.open(PENDING_FILENAME, FILE_READ);
  if (!src) {
    unlockSem(sdMutex);
    return false;
  }

  uint32_t size = (uint32_t)src.size();
  if (keepFromOffset >= size) {
    // nada a manter => remove arquivo
    src.close();
    SD.remove(PENDING_FILENAME);
    unlockSem(sdMutex);
    LOGW("[SD][COMPACT] Nada a manter. Arquivo removido.");
    return true;
  }

  if (!src.seek(keepFromOffset)) {
    LOGE("[SD][COMPACT] seek falhou.");
    src.close();
    unlockSem(sdMutex);
    return false;
  }

  SD.remove(PENDING_TMP_FILENAME);
  File tmp = SD.open(PENDING_TMP_FILENAME, FILE_WRITE);
  if (!tmp) {
    LOGE("[SD][COMPACT] open tmp falhou.");
    src.close();
    unlockSem(sdMutex);
    return false;
  }

  uint8_t buf[256];
  while (src.available()) {
    int r = src.read(buf, sizeof(buf));
    if (r > 0) tmp.write(buf, r);
    vTaskDelay(1); // mitiga WDT
  }

  tmp.flush();
  tmp.close();
  src.close();

  // TMP + BAK + rename (crash-safe)
  SD.remove(PENDING_BAK_FILENAME);
  bool ok1 = SD.rename(PENDING_FILENAME, PENDING_BAK_FILENAME);
  bool ok2 = SD.rename(PENDING_TMP_FILENAME, PENDING_FILENAME);

  if (!ok1 || !ok2) {
    LOGE("[SD][COMPACT] rename falhou (ok1=%d ok2=%d). Tentando recovery...", (int)ok1, (int)ok2);
    // tentar reverter
    if (SD.exists(PENDING_BAK_FILENAME) && !SD.exists(PENDING_FILENAME)) {
      SD.rename(PENDING_BAK_FILENAME, PENDING_FILENAME);
    }
    SD.remove(PENDING_TMP_FILENAME);
    unlockSem(sdMutex);
    return false;
  }

  SD.remove(PENDING_BAK_FILENAME);
  unlockSem(sdMutex);

  LOGW("[SD][COMPACT] Compactação OK.");
  return true;
}

static void pendingFlushTick() {
  RuntimeConfig c = cfgGet();
  static uint32_t lastFlushMs = 0;
  uint32_t now = msNow();

  if (!g_sdOk) return;
  if (!g_mqttConnected || !client.connected()) return;

  if (!timeReached(now, lastFlushMs + c.pending_flush_every_ms)) return;
  lastFlushMs = now;

  // nada pendente?
  uint32_t fileSize = sdFileSize(PENDING_FILENAME);
  if (fileSize == 0 || g_pendingOffset >= fileSize) return;

  LOGI("[SD][FLUSH] Iniciando (off=%lu size=%lu maxItems=%lu maxMs=%lu)",
       (unsigned long)g_pendingOffset, (unsigned long)fileSize,
       (unsigned long)c.pending_flush_max_items, (unsigned long)c.pending_flush_max_ms);

  uint32_t start = msNow();
  uint32_t sent = 0;
  uint32_t failures = 0;

  while (sent < c.pending_flush_max_items && (msNow() - start) < c.pending_flush_max_ms) {
    String line;
    uint32_t nextOff = g_pendingOffset;
    uint32_t sz = 0;

    bool okRead = sdReadPendingLine(g_pendingOffset, line, nextOff, sz);
    if (!okRead) break;

    // publish fora do mutex do SD
    const uint8_t* p = (const uint8_t*)line.c_str();
    uint32_t len = (uint32_t)line.length();

    bool okPub = mqttPublish(AWS_IOT_PUBLISH_TOPIC, p, len, false);
    if (!okPub) {
      failures++;
      LOGW("[SD][FLUSH] publish falhou. Parando flush para tentar mais tarde.");
      break;
    }

    // Avança offset SOMENTE após publish OK
    g_pendingOffset = nextOff;
    g_offDirty++;
    if (g_offDirty >= OFF_PERSIST_EVERY) persistOffsetIfNeeded(false);

    sent++;
    vTaskDelay(1); // mitiga WDT e dá chance ao WiFi stack
  }

  persistOffsetIfNeeded(true);

  uint32_t sizeAfter = sdFileSize(PENDING_FILENAME);
  LOGI("[SD][FLUSH] fim: sent=%lu fail=%lu off=%lu size=%lu took=%lums",
       (unsigned long)sent, (unsigned long)failures,
       (unsigned long)g_pendingOffset, (unsigned long)sizeAfter,
       (unsigned long)(msNow() - start));

  // Compactação quando offset cresce
  if (g_pendingOffset >= COMPACT_THRESHOLD_BYTES) {
    // Recheca size
    uint32_t sz = sdFileSize(PENDING_FILENAME);
    if (sz > 0 && g_pendingOffset < sz) {
      bool okComp = sdCompactPendingFile(g_pendingOffset);
      if (okComp) {
        g_pendingOffset = 0;
        g_offDirty++;
        persistOffsetIfNeeded(true);
      }
    } else if (sz > 0 && g_pendingOffset >= sz) {
      // tudo enviado -> remove
      if (lockSem(sdMutex, 1500)) {
        SD.remove(PENDING_FILENAME);
        unlockSem(sdMutex);
      }
      g_pendingOffset = 0;
      g_offDirty++;
      persistOffsetIfNeeded(true);
    }
  }
}

// ===================================================================================
// 10) VÁLVULA (fail-safe + mutex)
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
  if (durationS == 0) { valveSetOffLocked(); return; }
  digitalWrite(PIN_VALVE, HIGH);
  g_valveState = true;
  uint32_t now = msNow();
  g_valveOffTimeMs = now + durationS * 1000UL;
  g_valveLastDebugMs = now;
  LOGI("[VALVULA] ON por %lus (cap=%lus)", (unsigned long)durationS, (unsigned long)MAX_VALVE_DURATION_S);
}

static void valveApplyCommand(bool turnOn, int32_t durationS) {
  if (lockSem(valveMutex, 50)) {
    if (!turnOn) {
      LOGI("[VALVULA] OFF imediato.");
      valveSetOffLocked();
    } else {
      uint32_t safeS = clampValveDurationS(durationS);
      if ((uint32_t)durationS > safeS) {
        LOGW("[FAIL-SAFE] duration %lds > max. clamp -> %lus", (long)durationS, (unsigned long)safeS);
      }
      valveSetOnForLocked(safeS);
    }
    unlockSem(valveMutex);
  } else {
    LOGE("[FAIL-SAFE] Mutex da válvula ocupado. Forçando OFF (GPIO).");
    digitalWrite(PIN_VALVE, LOW);
    g_valveState = false;
    g_valveOffTimeMs = 0;
    g_valveLastDebugMs = 0;
  }
}

// ===================================================================================
// 11) MQTT CALLBACK (comandos)
// ===================================================================================
static void mqttCallback(char* topic, byte* payload, unsigned int length) {
  LOGI("[MQTT] msg topic=%s len=%u", topic, length);

  StaticJsonDocument<512> doc;
  DeserializationError err = deserializeJson(doc, payload, length);
  if (err) {
    LOGE("[MQTT] JSON inválido: %s", err.c_str());
    return;
  }

  // 1) valida device alvo (se vier no payload)
  const char* targetDevice = doc["device_id"];
  if (targetDevice && strcmp(targetDevice, THINGNAME) != 0) {
    LOGD("[MQTT] Ignorado (target=%s eu=%s)", targetDevice, THINGNAME);
    return;
  }

  // 2) command_id + action: copiar campos ANTES de publicar ACK (PubSubClient reutiliza buffer RX)
  char cmdLocal[48] = {0};
  char actionLocal[24] = {0};

  const char* cmdIdRaw = doc["command_id"];
  if (cmdIdRaw && cmdIdRaw[0] != '\0') {
    safeCopy(g_lastCommandId, sizeof(g_lastCommandId), cmdIdRaw);
  } else {
    // fallback (não deveria ocorrer, pois a Lambda já gera command_id)
    snprintf(cmdLocal, sizeof(cmdLocal), "local-%lu", (unsigned long)msNow());
    safeCopy(g_lastCommandId, sizeof(g_lastCommandId), cmdLocal);
    LOGW("[MQTT] command_id ausente. Usando fallback=%s", g_lastCommandId);
  }
  const char* cmdId = g_lastCommandId; // estável

  const char* actionRaw = doc["action"];
  if (actionRaw && actionRaw[0] != '\0') {
    safeCopy(actionLocal, sizeof(actionLocal), actionRaw);
  }

  int32_t duration = doc["duration"] | 0;

  LOGI("[MQTT] command_id=%s action=%s duration=%ld", cmdId,
       actionLocal[0] ? actionLocal : "(null)", (long)duration);

  if (!actionLocal[0]) {
    LOGE("[MQTT] Campo 'action' ausente.");
    publishCommandAck(cmdId, "error", nullptr, -1, "invalid_payload", "missing_action");
    return;
  }

  const char* action = actionLocal;

  // 3) ACK imediato: recebemos e validamos o comando
  publishCommandAck(cmdId, "received", action, duration, nullptr, nullptr);

  // 4) aplica comando
  bool wasOn = false;
  if (lockSem(valveMutex, 10)) { wasOn = g_valveState; unlockSem(valveMutex); }

  if (strcmp(action, "on") == 0) {
    if (duration > 0) {
      LOGI("[COMANDO] LIGAR por %lds", (long)duration);
      valveApplyCommand(true, duration);

      bool nowOn = false;
      if (lockSem(valveMutex, 50)) {
        nowOn = g_valveState;
        if (nowOn) {
          safeCopy(g_activeCommandId, sizeof(g_activeCommandId), cmdId);
        }
        unlockSem(valveMutex);
      }

      if (nowOn) {
        publishCommandAck(cmdId, "started", action, duration, nullptr, nullptr);
      } else {
        publishCommandAck(cmdId, "error", action, duration, "valve_not_on", "valve_failed_to_start");
      }
    } else {
      // compat: seu firmware tratava "on" com duration=0 como STOP
      LOGI("[COMANDO] STOP imediato (duration=0)");
      valveApplyCommand(false, 0);

      char doneCmd[48] = {0};
      if (lockSem(valveMutex, 50)) {
        if (g_activeCommandId[0] != '\0') {
          safeCopy(doneCmd, sizeof(doneCmd), g_activeCommandId);
        } else {
          safeCopy(doneCmd, sizeof(doneCmd), cmdId);
        }
        g_activeCommandId[0] = '\0';
        unlockSem(valveMutex);
      } else {
        safeCopy(doneCmd, sizeof(doneCmd), cmdId);
      }

      publishCommandAck(doneCmd, "done", "off", 0, "manual_stop", nullptr);
    }
  } else if (strcmp(action, "off") == 0) {
    LOGI("[COMANDO] OFF");
    valveApplyCommand(false, 0);

    char doneCmd[48] = {0};
    if (lockSem(valveMutex, 50)) {
      if (g_activeCommandId[0] != '\0') {
        safeCopy(doneCmd, sizeof(doneCmd), g_activeCommandId);
      } else {
        safeCopy(doneCmd, sizeof(doneCmd), cmdId);
      }
      g_activeCommandId[0] = '\0';
      unlockSem(valveMutex);
    } else {
      safeCopy(doneCmd, sizeof(doneCmd), cmdId);
    }

    publishCommandAck(doneCmd, "done", "off", 0, wasOn ? "manual_off" : "already_off", nullptr);
  } else {
    LOGW("[COMANDO] ação desconhecida: %s", action);
    publishCommandAck(cmdId, "error", action, duration, "unknown_action", "unsupported_action");
  }
}

// ===================================================================================
// 12) TIME (RTC + NTP)
// ===================================================================================
static DateTime getSystemTime() {
  if (lockSem(i2cMutex, I2C_MUTEX_WAIT_MS)) {
    DateTime now = rtc.now();
    unlockSem(i2cMutex);
    return now;
  }
  return DateTime((uint32_t)0);
}

static void syncTimeWithNTP() {
  LOGI("[TIME] Iniciando sincronização NTP...");
  configTime(0, 0, NTP_SERVER);

  struct tm timeinfo;
  int retry = 0;
  while (!getLocalTime(&timeinfo, 1000) && retry < 8) {
    Serial.print(".");
    retry++;
    vTaskDelay(1);
  }
  Serial.println();

  if (retry < 8) {
    if (lockSem(i2cMutex, I2C_MUTEX_WAIT_MS)) {
      rtc.adjust(DateTime(timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
                          timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec));
      unlockSem(i2cMutex);
      g_timeSynced = true;
      LOGI("[TIME] Sucesso! RTC atualizado.");
    }
  } else {
    LOGW("[TIME] Falha no NTP. Mantendo RTC local.");
  }
}

// ===================================================================================
// 13) BACKOFF (Wi-Fi / MQTT)
// ===================================================================================
struct BackoffState {
  uint32_t attempt = 0;
  uint32_t nextTryMs = 0;
};

static uint32_t jitter(uint32_t baseMs) {
  uint32_t r = (uint32_t)esp_random();
  uint32_t pct = 75 + (r % 51); // 75..125
  return (baseMs * pct) / 100;
}

static uint32_t backoffDelay(uint32_t baseMs, uint32_t maxMs, uint32_t attempt) {
  uint32_t a = attempt > 10 ? 10 : attempt;
  uint64_t d = (uint64_t)baseMs * (1ULL << a);
  if (d > maxMs) d = maxMs;
  return jitter((uint32_t)d);
}

static bool backoffCanTry(const BackoffState& b) {
  if (b.nextTryMs == 0) return true;
  return timeReached(msNow(), b.nextTryMs);
}

static void backoffOnFail(BackoffState& b, uint32_t baseMs, uint32_t maxMs) {
  uint32_t d = backoffDelay(baseMs, maxMs, b.attempt);
  b.attempt++;
  b.nextTryMs = msNow() + d;
  LOGW("[BACKOFF] próxima tentativa em %lums (attempt=%lu)", (unsigned long)d, (unsigned long)b.attempt);
}

static void backoffReset(BackoffState& b) {
  b.attempt = 0;
  b.nextTryMs = 0;
}

// ===================================================================================
// 14) TASKS
// ===================================================================================
static void taskSensors(void *pvParameters) {
  (void)pvParameters;

  for (;;) {
    RuntimeConfig c = cfgGet();
    TelemetryData data{};

    LOGD("========================================");
    LOGD("[SENSORS] ciclo leitura");

    DateTime nowUTC = getSystemTime();
    data.timestamp = nowUTC.unixtime();

    // seq e telemetry_id
    data.seq = ++g_telemetrySeq;
    g_seqDirty++;
    persistSeqIfNeeded(false);

    // AHT10 (I2C protegido)
    if (lockSem(i2cMutex, I2C_MUTEX_WAIT_MS)) {
      sensors_event_t h, t;
      if (aht.getEvent(&h, &t)) {
        data.air_temp = t.temperature;
        data.air_hum = h.relative_humidity;
      } else {
        LOGW("[AHT] Falha leitura");
        data.air_temp = 0; data.air_hum = 0;
      }
      unlockSem(i2cMutex);
    }

    // analógicos
    int rawSolo = analogRead(PIN_SOLO);
    data.soil_moisture = constrain(map(rawSolo, c.soil_raw_dry, c.soil_raw_wet, 0, 100), 0, 100);

    int rawLuz = analogRead(PIN_LUZ);
    data.light_level = map(rawLuz, 0, 4095, 0, 100);

    data.rain_raw = analogRead(PIN_CHUVA);

    long somaUV = 0;
    for (int i = 0; i < 16; i++) { somaUV += analogRead(PIN_UV); vTaskDelay(1); }
    data.uv_index = (((somaUV / 16) * 3.3) / 4095.0) / 0.1;
    if (data.uv_index < 0.2) data.uv_index = 0.0;

    // Debug detalhado
    DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
    bool valveOn = false;
    if (lockSem(valveMutex, 10)) { valveOn = g_valveState; unlockSem(valveMutex); }

    LOGD("[SENSORS] Hora: %02d:%02d:%02d", nowBRT.hour(), nowBRT.minute(), nowBRT.second());
    LOGD("[SENSORS] Ar: %.2fC | %.2f%%", data.air_temp, data.air_hum);
    LOGD("[SENSORS] Solo raw=%d -> %d%%", rawSolo, data.soil_moisture);
    LOGD("[SENSORS] Luz raw=%d -> %d%%", rawLuz, data.light_level);
    LOGD("[SENSORS] Chuva raw=%d", data.rain_raw);
    LOGD("[SENSORS] UV=%.2f", data.uv_index);
    LOGD("[SENSORS] Válvula=%s", valveOn ? "ON" : "OFF");

    // Atualiza display data
    if (lockSem(dataMutex, 100)) { g_latestData = data; unlockSem(dataMutex); }

    if (xQueueSend(sensorQueue, &data, 0) != pdPASS) {
      LOGW("[SENSORS] Fila cheia! Dado perdido.");
    } else {
      LOGD("[SENSORS] Enviado para fila.");
    }

    vTaskDelay(pdMS_TO_TICKS(c.telemetry_interval_ms));
  }
}

static void taskNetworkStorage(void *pvParameters) {
  (void)pvParameters;

  // TLS/AWS
  net.setCACert(AWS_CERT_CA);
  net.setCertificate(AWS_CERT_CRT);
  net.setPrivateKey(AWS_CERT_PRIVATE);
  net.setHandshakeTimeout(30);

  client.setServer(AWS_IOT_ENDPOINT, MQTT_PORT);
  client.setCallback(mqttCallback);
  client.setBufferSize(MQTT_BUFFER_SIZE);
  client.setKeepAlive(60);
  client.setSocketTimeout(10);

  LOGI("[AWS] PUB=%s | SUB=%s | ACK=%s | endpoint=%s:%u | buf=%u",
       AWS_IOT_PUBLISH_TOPIC, AWS_IOT_SUBSCRIBE_TOPIC, AWS_IOT_ACK_TOPIC, AWS_IOT_ENDPOINT, MQTT_PORT, (unsigned)client.getBufferSize());

  BackoffState wifiB, mqttB;
  uint32_t lastNtpAttempt = 0;

  TelemetryData received{};

  for (;;) {
    // 1) FAIL-SAFE válvula (wrap-safe) + ACK de término (timeout/failsafe)
    bool doAck = false;
    bool ackIsError = false;
    char ackCmd[48] = {0};
    const char* ackReason = nullptr;

    if (lockSem(valveMutex, 10)) {
      if (g_valveState) {
        uint32_t now = msNow();

        if (g_valveOffTimeMs == 0) {
          LOGE("[FAIL-SAFE] Válvula ON sem deadline. Forçando OFF.");
          valveSetOffLocked();
          if (g_activeCommandId[0] != '\0') {
            safeCopy(ackCmd, sizeof(ackCmd), g_activeCommandId);
            g_activeCommandId[0] = '\0';
            doAck = true;
            ackIsError = true;
            ackReason = "failsafe_no_deadline";
          }
        } else if (timeReached(now, g_valveOffTimeMs)) {
          LOGI("[VALVULA] Tempo esgotado! OFF.");
          valveSetOffLocked();
          if (g_activeCommandId[0] != '\0') {
            safeCopy(ackCmd, sizeof(ackCmd), g_activeCommandId);
            g_activeCommandId[0] = '\0';
            doAck = true;
            ackIsError = false;
            ackReason = "timeout";
          }
        } else if (timeReached(now, g_valveLastDebugMs + VALVE_DEBUG_EVERY_MS)) {
          uint32_t remaining = (uint32_t)(g_valveOffTimeMs - now);
          LOGI("[VALVULA] Regando... falta ~%lums", (unsigned long)remaining);
          g_valveLastDebugMs = now;
        }
      }
      unlockSem(valveMutex);
    }

    // publica ACK fora do mutex
    if (doAck && ackCmd[0] != '\0') {
      if (ackIsError) {
        publishCommandAck(ackCmd, "error", "off", 0, ackReason, "failsafe");
      } else {
        publishCommandAck(ackCmd, "done", "off", 0, ackReason, nullptr);
      }
    }


    // 2) Wi-Fi
    if (WiFi.status() != WL_CONNECTED) {
      if (g_wifiConnected) LOGW("[NET] Wi-Fi caiu.");
      g_wifiConnected = false;
      g_mqttConnected = false;

      if (backoffCanTry(wifiB)) {
        uint32_t d = backoffDelay(1000, 30000, wifiB.attempt);
        LOGI("[NET] Tentando Wi-Fi (backoff=%lums)", (unsigned long)d);
        WiFi.disconnect(true);
        WiFi.mode(WIFI_STA);
        WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
        backoffOnFail(wifiB, 1000, 30000);
      }
    } else {
      if (!g_wifiConnected) {
        backoffReset(wifiB);
        g_wifiConnected = true;
        LOGI("[NET] Wi-Fi OK. IP=%s RSSI=%d", WiFi.localIP().toString().c_str(), WiFi.RSSI());
        syncTimeWithNTP();
        lastNtpAttempt = msNow();
      }
      if (!g_timeSynced && timeReached(msNow(), lastNtpAttempt + 60000)) {
        syncTimeWithNTP();
        lastNtpAttempt = msNow();
      }
    }

    // 3) SD reinit se caiu
    sdTryReinit();

    // 4) MQTT
    if (g_wifiConnected) {
      if (!client.connected()) {
        g_mqttConnected = false;
        if (backoffCanTry(mqttB)) {
          uint32_t d = backoffDelay(1000, 20000, mqttB.attempt);
          LOGI("[AWS] Conectando MQTT (backoff=%lums)...", (unsigned long)d);

          bool ok = client.connect(THINGNAME);
          if (ok) {
            backoffReset(mqttB);
            g_mqttConnected = true;
            LOGI("[AWS] MQTT conectado. state=%d(%s)", client.state(), mqttStateName(client.state()));
            bool subOk = client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
            LOGI("[AWS] Subscribed: %s (ok=%d)", AWS_IOT_SUBSCRIBE_TOPIC, (int)subOk);
          } else {
            int st = client.state();
            LOGE("[AWS] MQTT connect FAIL: state=%d(%s)", st, mqttStateName(st));
            logTlsLastError();
            backoffOnFail(mqttB, 1000, 20000);
          }
        }
      } else {
        g_mqttConnected = true;
        client.loop();
      }
    }

    // 5) Flush pendências (se conectado)
    pendingFlushTick();

    // 6) Processa fila sensores -> tenta publicar; se falhar, append no SD
    if (xQueueReceive(sensorQueue, &received, pdMS_TO_TICKS(50)) == pdPASS) {
      LOGD("[NET] Processando telemetria ts=%lu seq=%lu", (unsigned long)received.timestamp, (unsigned long)received.seq);

      // monta JSON
      char payload[1400];
      uint32_t payloadLen = 0;
      bool jsonOk = buildTelemetryJson(received, payload, sizeof(payload), payloadLen);

      bool sentCloud = false;

      if (jsonOk && g_mqttConnected) {
        sentCloud = mqttPublish(AWS_IOT_PUBLISH_TOPIC, (const uint8_t*)payload, payloadLen, false);
        if (!sentCloud) {
          LOGW("[AWS] publish falhou. Vai para pending.");
        }
      } else {
        if (!jsonOk) LOGW("[JSON] payload inválido. Vai para pending (se possível).");
        if (!g_mqttConnected) LOGW("[AWS] Offline. Vai para pending.");
      }

      // se não enviou, grava pending
      bool pendingOk = false;
      if (!sentCloud) {
        if (g_sdOk && jsonOk) pendingOk = sdAppendPendingLine(payload, payloadLen);
      }

      // log CSV (status)
      if (g_sdOk) {
        if (lockSem(sdMutex, 1500)) {
          File f = SD.open(LOG_FILENAME, FILE_APPEND);
          if (f) {
            char tid[80];
            makeTelemetryId(tid, sizeof(tid), received.timestamp, received.seq);
            f.printf("%lu,%.2f,%.2f,%d,%d,%d,%.2f,%s,%s,%lu\n",
                     (unsigned long)received.timestamp,
                     received.air_temp, received.air_hum,
                     received.soil_moisture, received.light_level,
                     received.rain_raw, received.uv_index,
                     sentCloud ? "SENT" : (pendingOk ? "PENDING" : "DROP"),
                     tid,
                     (unsigned long)received.seq);
            f.close();
          } else {
            LOGE("[SD] Falha ao abrir CSV para append.");
          }
          unlockSem(sdMutex);
        } else {
          LOGW("[SD] Mutex ocupado ao gravar CSV.");
        }
      }
    }

    vTaskDelay(10);
  }
}

#if ENABLE_OLED
static void taskDisplay(void *pvParameters) {
  (void)pvParameters;
  int screen = 0;

  for (;;) {
    TelemetryData local{};
    if (lockSem(dataMutex, 50)) { local = g_latestData; unlockSem(dataMutex); }

    bool valveOn = false;
    if (lockSem(valveMutex, 10)) { valveOn = g_valveState; unlockSem(valveMutex); }

    if (lockSem(i2cMutex, I2C_MUTEX_WAIT_MS)) {
      display.clearDisplay();
      display.setTextColor(WHITE);

      DateTime nowUTC = rtc.now();
      DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);

      display.setTextSize(1);
      display.setCursor(0,0);
      display.printf("%02d:%02d", nowBRT.hour(), nowBRT.minute());
      display.setCursor(40,0);
      display.print(valveOn ? "REGANDO!" : (g_wifiConnected ? "W:OK" : "W:X"));
      display.drawLine(0, 9, 128, 9, WHITE);

      display.setCursor(0, 15);
      switch (screen) {
        case 0:
          display.println("SISTEMA V5:");
          display.printf("MQTT: %s\n", g_mqttConnected ? "ON" : "OFF");
          display.printf("SD:   %s\n", g_sdOk ? "OK" : "ERRO");
          display.printf("PEND:%lu\n", (unsigned long)sdFileSize(PENDING_FILENAME));
          display.printf("VALV:%s\n", valveOn ? "ON" : "OFF");
          break;
        case 1:
          display.setTextSize(2);
          display.printf("%.1fC\n", local.air_temp);
          display.setTextSize(1);
          display.printf("Um:%.0f%% UV:%.1f", local.air_hum, local.uv_index);
          break;
        case 2:
          display.setTextSize(1);
          display.println("SOLO/LUZ:");
          display.setTextSize(2);
          display.printf("%d%%\n", local.soil_moisture);
          display.setTextSize(1);
          display.printf("Lz:%d%% Ch:%d", local.light_level, local.rain_raw);
          break;
      }

      display.display();
      unlockSem(i2cMutex);
    }

    vTaskDelay(pdMS_TO_TICKS(OLED_SWITCH_MS));
    screen = (screen + 1) % 3;
  }
}
#endif

// ===================================================================================
// 15) SETUP
// ===================================================================================
void setup() {
  Serial.begin(115200);
  delay(800);

  Serial.println();
  Serial.println("=== AGROSMART V5 INICIANDO ===");

  // Mutexes
  i2cMutex  = xSemaphoreCreateMutex();
  dataMutex = xSemaphoreCreateMutex();
  valveMutex = xSemaphoreCreateMutex();
  sdMutex   = xSemaphoreCreateMutex();
  cfgMutex  = xSemaphoreCreateMutex();

  // Pinos
  analogReadResolution(12);
  pinMode(PIN_SOLO, INPUT);
  pinMode(PIN_CHUVA, INPUT);
  pinMode(PIN_LUZ, INPUT);
  pinMode(PIN_UV, INPUT);

  pinMode(PIN_VALVE, OUTPUT);
  digitalWrite(PIN_VALVE, LOW);

  // Boot state válvula
  if (lockSem(valveMutex, 50)) {
    g_valveState = false;
    g_valveOffTimeMs = 0;
    g_valveLastDebugMs = 0;
    g_lastCommandId[0] = '\0';
    unlockSem(valveMutex);
  }

  // I2C / sensores
  Wire.begin(21, 22);

#if ENABLE_OLED
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    LOGE("[OLED] Falhou iniciar");
  } else {
    display.clearDisplay();
    display.display();
  }
#else
  LOGI("[OLED] Desabilitado (ENABLE_OLED=0)");
#endif

  if (!rtc.begin()) LOGE("[RTC] Falhou iniciar");
  if (!aht.begin()) LOGE("[AHT] Falhou iniciar");

  // NVS
  loadFromNVS();

  // SD
  LOGI("[SD] Iniciando cartão...");
  sdInit();
  if (g_sdOk) sdRecoverPendingIfNeeded();

  // WiFi
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  // Queue
  sensorQueue = xQueueCreate(10, sizeof(TelemetryData));
  if (!sensorQueue) {
    LOGE("[BOOT] Falha ao criar queue!");
  }

  // Tasks
#if ENABLE_OLED
  xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
#endif
  xTaskCreate(taskNetworkStorage, "Net", 12288, NULL, 2, NULL);
  xTaskCreate(taskSensors, "Sensors", 6144, NULL, 3, NULL);

  LOGI("[BOOT] Tarefas iniciadas.");
}

void loop() {
  vTaskDelete(NULL);
}