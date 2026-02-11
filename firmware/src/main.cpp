/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: 11/02/2026
 * VERSÃO: 5.17.2 (crash-safe SD store-and-forward)
 * ===================================================================================
 *
 * OBJETIVO DESTA REVISÃO
 * - Evitar perda de dados no flush do SD quando:
 *    1) houver reset/Watchdog no meio do flush/compactação
 *    2) ocorrer instabilidade de SD (I/O error)
 *
 * PRINCIPAIS MELHORIAS
 *  1) Store-and-forward em NDJSON (append-only) com flush seguro
 *     - Cada amostra offline vira 1 linha NDJSON
 *     - Escrita sempre com flush() + close() (reduz risco de perda)
 *
 *  2) Flush robusto com OFFSET persistido (NVS/Preferences)
 *     - Avança o offset SOMENTE após publish OK
 *     - Se resetar no meio, retoma do último offset persistido
 *
 *  3) Compactação crash-safe (TMP + BAK + rename)
 *     - Copia “restante” para TMP
 *     - Renomeia original -> BAK
 *     - Renomeia TMP -> original
 *     - Só então remove BAK
 *     - Boot faz recuperação se sobrar BAK/TMP
 *
 *  4) Mitigação de WDT: loops com yield/delay e limites de tempo/itens
 *
 *  5) Re-init de SD em caso de falha (tenta frequência SPI menor)
 *
 * OBS:
 * - Mantém FAIL-SAFE da válvula e mutex.
 * - Mantém OLED (protótipo). Pode desativar via build flag ENABLE_OLED=0.
 */

#include <Arduino.h>
#include <time.h>
#include <cstring>
#include <esp_system.h>
#include <Wire.h>
#include <SPI.h>
#include <SD.h>
#include <RTClib.h>
#include <Adafruit_AHTX0.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include "secrets.h"

// ===================================================================================
// BUILD FLAGS / DEFAULTS (podem vir do platformio.ini)
// ===================================================================================
#ifndef FW_VERSION
#define FW_VERSION "5.17.2"
#endif

#ifndef DEFAULT_TELEMETRY_INTERVAL_MS
#define DEFAULT_TELEMETRY_INTERVAL_MS 60000
#endif

#ifndef ENABLE_OLED
#define ENABLE_OLED 1
#endif

// ===================================================================================
// CONFIGURAÇÕES GERAIS
// ===================================================================================

const long BRT_OFFSET_SEC = -10800; // -3h

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
const uint32_t OLED_SWITCH_MS = 2000;

// SD arquivos
static const char* LOG_FILENAME          = "/telemetry_v5.csv";
static const char* PENDING_FILENAME      = "/pending_telemetry.ndjson";
static const char* PENDING_TMP_FILENAME  = "/pending_telemetry.tmp";
static const char* PENDING_BAK_FILENAME  = "/pending_telemetry.bak";

// NTP
static const char* NTP_SERVER = "pool.ntp.org";

// Store-and-forward (limites)
static const size_t  PENDING_LINE_MAX          = 768;               // tamanho máximo de uma linha NDJSON
static const uint32_t MAX_PENDING_BYTES        = 5UL * 1024UL * 1024UL; // 5MB
static const uint32_t COMPACT_THRESHOLD_BYTES  = 64UL * 1024UL;     // compacta quando offset passar disso

// Flush: limites para evitar WDT / travar appends
static const uint32_t PENDING_FLUSH_EVERY_MS_DEFAULT = 15000;
static const uint32_t PENDING_FLUSH_MAX_ITEMS_DEFAULT = 30;
static const uint32_t PENDING_FLUSH_MAX_MS_DEFAULT = 8000;

// SD init: tenta frequências (módulo SD ruim costuma precisar baixo clock)
static const uint32_t SD_SPI_FREQ_PRIMARY = 4000000;
static const uint32_t SD_SPI_FREQ_FALLBACK = 1000000;
static const uint32_t SD_REINIT_COOLDOWN_MS = 30000;

// ===================================================================================
// CONFIG PERSISTENTE (NVS)
// ===================================================================================
struct RuntimeConfig {
  uint32_t telemetry_interval_ms = DEFAULT_TELEMETRY_INTERVAL_MS;
  int soil_raw_dry = 3000;
  int soil_raw_wet = 1200;

  uint32_t pending_flush_every_ms = PENDING_FLUSH_EVERY_MS_DEFAULT;
  uint32_t pending_flush_max_items = PENDING_FLUSH_MAX_ITEMS_DEFAULT;
  uint32_t pending_flush_max_ms = PENDING_FLUSH_MAX_MS_DEFAULT;
};

static RuntimeConfig g_cfg;
static SemaphoreHandle_t cfgMutex;

static const char* NVS_NS = "agrosmart";
static const char* K_TELE_INT = "tele_int";
static const char* K_SOIL_DRY = "soil_dry";
static const char* K_SOIL_WET = "soil_wet";
static const char* K_SEQ      = "tele_seq";
static const char* K_PEND_OFF = "pend_off";

static Preferences prefs;

// seq persistida (telemetry_id)
static uint32_t g_telemetrySeq = 0;
static uint32_t g_seqDirty = 0;
static const uint32_t SEQ_PERSIST_EVERY = 10;

// offset persistido (onde já foi enviado no arquivo pending)
static uint32_t g_pendingOffset = 0;
static uint32_t g_offDirty = 0;
static const uint32_t OFF_PERSIST_EVERY = 5;

// ===================================================================================
// OBJETOS GLOBAIS
// ===================================================================================
RTC_DS3231 rtc;
Adafruit_AHTX0 aht;

#if ENABLE_OLED
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
#endif

WiFiClientSecure net;
PubSubClient client(net);

// flags
static bool g_wifiConnected = false;
static bool g_mqttConnected = false;
static bool g_sdOk = false;
static bool g_timeSynced = false;

// Válvula
static bool g_valveState = false;
static uint32_t g_valveOffTimeMs = 0;
static uint32_t g_valveLastDebugMs = 0;
static char g_lastCommandId[48] = {0};

// RTOS
static SemaphoreHandle_t i2cMutex;
static SemaphoreHandle_t dataMutex;
static SemaphoreHandle_t valveMutex;
static SemaphoreHandle_t sdMutex;
static QueueHandle_t sensorQueue;

// ===================================================================================
// DADOS
// ===================================================================================
struct TelemetryData {
  uint32_t timestamp; // epoch (s)
  uint32_t seq;       // sequência local
  float air_temp;
  float air_hum;
  int soil_moisture;
  int light_level;
  int rain_raw;
  float uv_index;
};

static TelemetryData g_latestData;

// ===================================================================================
// HELPERS
// ===================================================================================
static inline bool timeReached(uint32_t now, uint32_t deadline) {
  return (int32_t)(now - deadline) >= 0;
}

static inline uint32_t clampValveDurationS(int32_t requestedS) {
  if (requestedS <= 0) return 0;
  if ((uint32_t)requestedS > MAX_VALVE_DURATION_S) return MAX_VALVE_DURATION_S;
  return (uint32_t)requestedS;
}

static RuntimeConfig cfgGetCopy() {
  RuntimeConfig c;
  if (xSemaphoreTake(cfgMutex, pdMS_TO_TICKS(20))) {
    c = g_cfg;
    xSemaphoreGive(cfgMutex);
  } else {
    c = g_cfg;
  }
  return c;
}

// ===================================================================================
// VÁLVULA (FAIL-SAFE)
// ===================================================================================
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
  uint32_t durationMs = durationS * 1000UL;
  g_valveOffTimeMs = now + durationMs; // wrap-safe
  g_valveLastDebugMs = now;

  Serial.printf("[VALVULA] ✅ LIGADA por %lu s (hard cap=%lu s)\n",
                (unsigned long)durationS, (unsigned long)MAX_VALVE_DURATION_S);
}

static void valveApplyCommand(bool turnOn, int32_t durationS) {
  if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(50))) {
    if (!turnOn) {
      Serial.println("[VALVULA] ⏹️ DESLIGAR imediato.");
      valveSetOffLocked();
    } else {
      uint32_t safeS = clampValveDurationS(durationS);
      if ((uint32_t)durationS > safeS) {
        Serial.printf("[FAIL-SAFE] duration %ld s excede máximo; clamp para %lu s\n",
                      (long)durationS, (unsigned long)safeS);
      }
      valveSetOnForLocked(safeS);
    }
    xSemaphoreGive(valveMutex);
  } else {
    Serial.println("[FAIL-SAFE] Mutex da válvula ocupado. Forçando OFF por segurança.");
    digitalWrite(PIN_VALVE, LOW);
    g_valveState = false;
    g_valveOffTimeMs = 0;
    g_valveLastDebugMs = 0;
  }
}

// ===================================================================================
// CONFIG/NVS
// ===================================================================================
static void nvsLoad() {
  prefs.begin(NVS_NS, false);

  g_cfg.telemetry_interval_ms = prefs.getUInt(K_TELE_INT, DEFAULT_TELEMETRY_INTERVAL_MS);
  g_cfg.soil_raw_dry = (int)prefs.getInt(K_SOIL_DRY, 3000);
  g_cfg.soil_raw_wet = (int)prefs.getInt(K_SOIL_WET, 1200);

  g_telemetrySeq = prefs.getUInt(K_SEQ, 0);
  g_pendingOffset = prefs.getUInt(K_PEND_OFF, 0);

  prefs.end();

  // validações
  if (g_cfg.telemetry_interval_ms < 10000) {
    // abaixo de 10s tende a gerar muita coisa e pode dificultar debug
    g_cfg.telemetry_interval_ms = 10000;
  }
  if (g_cfg.soil_raw_wet >= g_cfg.soil_raw_dry) {
    // evita map invertido
    g_cfg.soil_raw_wet = 1200;
    g_cfg.soil_raw_dry = 3000;
  }

  Serial.printf("[NVS] tele_int=%lu ms, soil(dry=%d wet=%d), seq=%lu, pend_off=%lu\n",
                (unsigned long)g_cfg.telemetry_interval_ms,
                g_cfg.soil_raw_dry, g_cfg.soil_raw_wet,
                (unsigned long)g_telemetrySeq,
                (unsigned long)g_pendingOffset);
}

static void nvsPersistSeqIfNeeded() {
  if (g_seqDirty >= SEQ_PERSIST_EVERY) {
    prefs.begin(NVS_NS, false);
    prefs.putUInt(K_SEQ, g_telemetrySeq);
    prefs.end();
    g_seqDirty = 0;
  }
}

static void nvsPersistOffsetIfNeeded(bool force) {
  if (force || g_offDirty >= OFF_PERSIST_EVERY) {
    prefs.begin(NVS_NS, false);
    prefs.putUInt(K_PEND_OFF, g_pendingOffset);
    prefs.end();
    g_offDirty = 0;
  }
}

// ===================================================================================
// TIME/NTP
// ===================================================================================
static DateTime getSystemTime() {
  if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
    DateTime now = rtc.now();
    xSemaphoreGive(i2cMutex);
    return now;
  }
  return DateTime((uint32_t)0);
}

static void syncTimeWithNTP() {
  Serial.println("[TIME] Iniciando sincronização NTP...");
  configTime(0, 0, NTP_SERVER);

  struct tm timeinfo;
  int retry = 0;
  while (!getLocalTime(&timeinfo, 1000) && retry < 5) {
    Serial.print('.');
    retry++;
    vTaskDelay(pdMS_TO_TICKS(10));
  }
  Serial.println();

  if (retry < 5) {
    if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
      rtc.adjust(DateTime(timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
                          timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec));
      xSemaphoreGive(i2cMutex);
      g_timeSynced = true;
      Serial.println("[TIME] Sucesso! RTC atualizado.");
    }
  } else {
    Serial.println("[TIME] Falha no NTP. Usando RTC.");
  }
}

// ===================================================================================
// SD HELPERS (mutex)
// ===================================================================================
static bool sdLock(uint32_t waitMs = 200) {
  return xSemaphoreTake(sdMutex, pdMS_TO_TICKS(waitMs)) == pdTRUE;
}
static void sdUnlock() { xSemaphoreGive(sdMutex); }

static bool sdReinit(uint32_t spiFreqHz);

static bool sdInit() {
  SPI.begin(18, 19, 23, SD_CS_PIN);

  Serial.println("[SD] Iniciando cartão...");
  if (SD.begin(SD_CS_PIN, SPI, SD_SPI_FREQ_PRIMARY)) {
    Serial.printf("[SD] OK (SPI=%lu Hz)\n", (unsigned long)SD_SPI_FREQ_PRIMARY);
    return true;
  }

  Serial.printf("[SD] Falhou em %lu Hz. Tentando fallback %lu Hz...\n",
                (unsigned long)SD_SPI_FREQ_PRIMARY, (unsigned long)SD_SPI_FREQ_FALLBACK);
  if (SD.begin(SD_CS_PIN, SPI, SD_SPI_FREQ_FALLBACK)) {
    Serial.printf("[SD] OK (SPI=%lu Hz)\n", (unsigned long)SD_SPI_FREQ_FALLBACK);
    return true;
  }

  Serial.println("[SD] Falha ao iniciar cartão SD.");
  return false;
}

static bool sdEnsureCsvHeader() {
  if (!SD.exists(LOG_FILENAME)) {
    File f = SD.open(LOG_FILENAME, FILE_WRITE);
    if (!f) return false;
    f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status_Envio");
    f.flush();
    f.close();
  }
  return true;
}

static void sdRecoverPendingFiles() {
  // Recuperação simples para casos de crash no meio do rename
  // Cenários possíveis:
  // - pending ausente + bak presente  => restaurar bak -> pending
  // - tmp presente                   => se pending ausente, tmp -> pending; senão remove tmp

  bool hasPending = SD.exists(PENDING_FILENAME);
  bool hasBak = SD.exists(PENDING_BAK_FILENAME);
  bool hasTmp = SD.exists(PENDING_TMP_FILENAME);

  if (!hasPending && hasBak) {
    Serial.println("[SD][RECOVERY] pending ausente e bak presente. Restaurando...");
    SD.rename(PENDING_BAK_FILENAME, PENDING_FILENAME);
    g_pendingOffset = 0;
    g_offDirty++;
    nvsPersistOffsetIfNeeded(true);
    hasPending = SD.exists(PENDING_FILENAME);
    hasBak = SD.exists(PENDING_BAK_FILENAME);
  }

  if (hasTmp) {
    if (!hasPending) {
      Serial.println("[SD][RECOVERY] tmp presente e pending ausente. Promovendo tmp -> pending...");
      SD.rename(PENDING_TMP_FILENAME, PENDING_FILENAME);
      g_pendingOffset = 0;
      g_offDirty++;
      nvsPersistOffsetIfNeeded(true);
    } else {
      Serial.println("[SD][RECOVERY] tmp sobrando. Removendo tmp...");
      SD.remove(PENDING_TMP_FILENAME);
    }
  }

  // Se sobrou bak e pending existe, decidimos manter apenas um:
  // Regra simples: se pending existe, bak é lixo (de uma compactação concluída)
  if (SD.exists(PENDING_FILENAME) && SD.exists(PENDING_BAK_FILENAME)) {
    Serial.println("[SD][RECOVERY] bak sobrando. Removendo bak...");
    SD.remove(PENDING_BAK_FILENAME);
  }
}

// ===================================================================================
// PENDING QUEUE (append-only + offset)
// ===================================================================================
static bool appendPendingLine(const char* line) {
  if (!g_sdOk) return false;

  if (!sdLock(500)) return false;

  // Tamanho (para limitar crescimento)
  if (SD.exists(PENDING_FILENAME)) {
    File f = SD.open(PENDING_FILENAME, FILE_READ);
    if (f) {
      uint32_t sz = (uint32_t)f.size();
      f.close();
      if (sz >= MAX_PENDING_BYTES) {
        Serial.println("[SD][PENDING] Limite MAX_PENDING_BYTES atingido. Não salvando nova linha.");
        sdUnlock();
        return false;
      }
    }
  }

  File file = SD.open(PENDING_FILENAME, FILE_APPEND);
  if (!file) {
    Serial.println("[SD][PENDING] Falha ao abrir pending para append.");
    sdUnlock();
    return false;
  }

  // garante newline
  file.print(line);
  size_t L = strlen(line);
  if (L == 0 || line[L - 1] != '\n') file.print('\n');

  file.flush();
  file.close();

  sdUnlock();
  return true;
}

static bool readPendingLineAt(uint32_t offset, char* out, size_t outLen, uint32_t* outNewOffset) {
  out[0] = '\0';
  *outNewOffset = offset;

  if (!SD.exists(PENDING_FILENAME)) return false;

  File f = SD.open(PENDING_FILENAME, FILE_READ);
  if (!f) return false;

  uint32_t sz = (uint32_t)f.size();
  if (offset >= sz) {
    f.close();
    return false;
  }

  if (!f.seek(offset)) {
    f.close();
    return false;
  }

  size_t idx = 0;
  while (f.available()) {
    int c = f.read();
    if (c < 0) break;
    if (c == '\n') break;
    if (c == '\r') continue;

    if (idx + 1 < outLen) {
      out[idx++] = (char)c;
    } else {
      // linha maior que buffer: descartamos até o fim da linha
      // (evita corromper publish)
    }
  }

  out[idx] = '\0';
  *outNewOffset = (uint32_t)f.position();
  f.close();

  // linha vazia (ex.: newline), tratamos como “não tem nada útil”, mas avançamos offset pelo chamador
  return true;
}

static bool compactPendingFromOffset(uint32_t offset) {
  // Copia o “restante” (offset -> EOF) para tmp e faz troca crash-safe com bak
  if (!SD.exists(PENDING_FILENAME)) return true;

  // remove tmp anterior
  if (SD.exists(PENDING_TMP_FILENAME)) SD.remove(PENDING_TMP_FILENAME);

  File in = SD.open(PENDING_FILENAME, FILE_READ);
  if (!in) return false;

  uint32_t sz = (uint32_t)in.size();
  if (offset >= sz) {
    in.close();
    // nada restante -> podemos remover pending de forma segura
    if (SD.exists(PENDING_BAK_FILENAME)) SD.remove(PENDING_BAK_FILENAME);
    SD.rename(PENDING_FILENAME, PENDING_BAK_FILENAME);
    SD.remove(PENDING_BAK_FILENAME);
    return true;
  }

  if (!in.seek(offset)) {
    in.close();
    return false;
  }

  File out = SD.open(PENDING_TMP_FILENAME, FILE_WRITE);
  if (!out) {
    in.close();
    return false;
  }

  uint8_t buf[512];
  while (in.available()) {
    int n = in.read(buf, sizeof(buf));
    if (n <= 0) break;
    if (out.write(buf, (size_t)n) != (size_t)n) {
      out.close();
      in.close();
      return false;
    }
    // cooperar com scheduler/WDT
    vTaskDelay(1);
  }

  out.flush();
  out.close();
  in.close();

  // Swap crash-safe
  if (SD.exists(PENDING_BAK_FILENAME)) SD.remove(PENDING_BAK_FILENAME);

  if (!SD.rename(PENDING_FILENAME, PENDING_BAK_FILENAME)) {
    // não conseguiu renomear original; não mexe mais
    return false;
  }

  if (!SD.rename(PENDING_TMP_FILENAME, PENDING_FILENAME)) {
    // falhou em promover tmp -> pending. Tenta restaurar bak.
    SD.rename(PENDING_BAK_FILENAME, PENDING_FILENAME);
    return false;
  }

  // Agora é seguro remover bak
  SD.remove(PENDING_BAK_FILENAME);
  return true;
}

static void flushPendingBatch() {
  if (!g_sdOk || !g_mqttConnected) return;

  RuntimeConfig c = cfgGetCopy();
  const uint32_t maxItems = c.pending_flush_max_items;
  const uint32_t maxMs = c.pending_flush_max_ms;

  const uint32_t startMs = (uint32_t)millis();
  uint32_t sent = 0;

  while (sent < maxItems && !timeReached((uint32_t)millis(), startMs + maxMs)) {
    char line[PENDING_LINE_MAX];
    uint32_t newOffset = g_pendingOffset;

    // Leitura do SD deve ser protegida
    if (!sdLock(500)) break;

    // Revalida offset se arquivo mudou
    if (SD.exists(PENDING_FILENAME)) {
      File fsz = SD.open(PENDING_FILENAME, FILE_READ);
      if (fsz) {
        uint32_t sz = (uint32_t)fsz.size();
        fsz.close();
        if (g_pendingOffset > sz) {
          Serial.println("[SD][PENDING] Offset > tamanho. Resetando offset.");
          g_pendingOffset = 0;
          g_offDirty++;
          nvsPersistOffsetIfNeeded(true);
        }
      }
    }

    bool okRead = readPendingLineAt(g_pendingOffset, line, sizeof(line), &newOffset);
    sdUnlock();

    if (!okRead) {
      // acabou arquivo (ou não existe). Se offset era >0, compacta/zera para limpar.
      if (g_pendingOffset != 0 && g_sdOk) {
        if (sdLock(1000)) {
          // compacta a partir do offset atual (normalmente EOF) => remove
          (void)compactPendingFromOffset(g_pendingOffset);
          sdUnlock();
          g_pendingOffset = 0;
          g_offDirty++;
          nvsPersistOffsetIfNeeded(true);
        }
      }
      break;
    }

    // Linha vazia? Avança e continua
    if (line[0] == '\0') {
      g_pendingOffset = newOffset;
      g_offDirty++;
      nvsPersistOffsetIfNeeded(false);
      vTaskDelay(1);
      continue;
    }

    // Publish fora do lock do SD
    bool ok = client.publish(AWS_IOT_PUBLISH_TOPIC, line);

    if (!ok) {
      Serial.println("[SD][FLUSH] publish falhou. Parando flush para tentar mais tarde.");
      break;
    }

    sent++;
    g_pendingOffset = newOffset;
    g_offDirty++;
    nvsPersistOffsetIfNeeded(false);

    // yield para não estourar WDT
    vTaskDelay(1);
  }

  // persistência final
  nvsPersistOffsetIfNeeded(true);

  // Compacta se offset ficou grande (reduz tamanho e acelera próximos flushes)
  if (g_pendingOffset >= COMPACT_THRESHOLD_BYTES) {
    if (sdLock(1500)) {
      bool ok = compactPendingFromOffset(g_pendingOffset);
      sdUnlock();
      if (ok) {
        Serial.println("[SD][PENDING] Compactação concluída. Resetando offset.");
        g_pendingOffset = 0;
        g_offDirty++;
        nvsPersistOffsetIfNeeded(true);
      } else {
        Serial.println("[SD][PENDING] Compactação falhou. Mantendo offset (tenta depois)." );
      }
    }
  }

  if (sent > 0) {
    Serial.printf("[SD][FLUSH] Enviados %lu registros do pending.\n", (unsigned long)sent);
  }
}

// ===================================================================================
// MQTT callback (comandos)
// ===================================================================================
void mqttCallback(char* topic, byte* payload, unsigned int length) {
  Serial.println("\n>>> [MQTT] MENSAGEM RECEBIDA! <<<");
  Serial.printf("Tópico: %s\n", topic);

  StaticJsonDocument<512> doc;
  DeserializationError error = deserializeJson(doc, payload, length);
  if (error) {
    Serial.print("[ERRO] JSON Inválido: ");
    Serial.println(error.c_str());
    return;
  }

  const char* targetDevice = doc["device_id"];
  if (targetDevice != nullptr && strcmp(targetDevice, THINGNAME) != 0) {
    Serial.printf("[IGNORADO] Para: %s (Eu sou: %s)\n", targetDevice, THINGNAME);
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
    Serial.println("[ERRO] Campo 'action' ausente.");
    return;
  }

  int32_t duration = doc["duration"] | 0;

  if (strcmp(action, "on") == 0) {
    if (duration > 0) {
      Serial.printf("[COMANDO] LIGAR por %ld segundos.\n", (long)duration);
      valveApplyCommand(true, duration);
    } else {
      Serial.println("[COMANDO] STOP imediato (duration=0).");
      valveApplyCommand(false, 0);
    }
  } else {
    Serial.printf("[AVISO] Ação desconhecida: %s\n", action);
  }
}

// ===================================================================================
// BACKOFF (WiFi/MQTT)
// ===================================================================================
struct Backoff {
  uint8_t attempts = 0;
  uint32_t nextAttemptMs = 0;
};

static uint32_t computeBackoffMs(uint8_t attempts, uint32_t baseMs, uint32_t maxMs) {
  uint32_t exp = baseMs;
  // exp = base * 2^attempts (cap)
  for (uint8_t i = 0; i < attempts; i++) {
    if (exp > maxMs / 2) { exp = maxMs; break; }
    exp *= 2;
  }
  if (exp > maxMs) exp = maxMs;

  // jitter 0..(exp/4)
  uint32_t jitter = (exp / 4) ? (uint32_t)random(0, exp / 4) : 0;
  uint32_t out = exp + jitter;
  if (out > maxMs) out = maxMs;
  return out;
}

// ===================================================================================
// TASKS
// ===================================================================================

// TAREFA 1: Sensores
void taskSensors(void* pvParameters) {
  for (;;) {
    TelemetryData data;

    DateTime nowUTC = getSystemTime();
    data.timestamp = nowUTC.unixtime();

    // seq estável
    data.seq = ++g_telemetrySeq;
    g_seqDirty++;
    nvsPersistSeqIfNeeded();

    // AHT10
    if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
      sensors_event_t h, t;
      if (aht.getEvent(&h, &t)) {
        data.air_temp = t.temperature;
        data.air_hum = h.relative_humidity;
      } else {
        data.air_temp = 0;
        data.air_hum = 0;
      }
      xSemaphoreGive(i2cMutex);
    } else {
      data.air_temp = 0;
      data.air_hum = 0;
    }

    RuntimeConfig c = cfgGetCopy();

    // Analógicos
    int rawSolo = analogRead(PIN_SOLO);
    data.soil_moisture = constrain(map(rawSolo, c.soil_raw_dry, c.soil_raw_wet, 0, 100), 0, 100);

    int rawLuz = analogRead(PIN_LUZ);
    data.light_level = map(rawLuz, 0, 4095, 0, 100);

    data.rain_raw = analogRead(PIN_CHUVA);

    long somaUV = 0;
    for (int i = 0; i < 16; i++) {
      somaUV += analogRead(PIN_UV);
      vTaskDelay(pdMS_TO_TICKS(1));
    }
    data.uv_index = (((somaUV / 16) * 3.3) / 4095.0) / 0.1;
    if (data.uv_index < 0.2) data.uv_index = 0.0;

    // Atualiza display
    if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
      g_latestData = data;
      xSemaphoreGive(dataMutex);
    }

    // Enfileira
    if (xQueueSend(sensorQueue, &data, 0) != pdPASS) {
      Serial.println("[SENSOR] Fila cheia! Amostra perdida.");
    }

    vTaskDelay(pdMS_TO_TICKS(c.telemetry_interval_ms));
  }
}

// TAREFA 2: Rede + SD
void taskNetworkStorage(void* pvParameters) {
  // TLS AWS
  net.setCACert(AWS_CERT_CA);
  net.setCertificate(AWS_CERT_CRT);
  net.setPrivateKey(AWS_CERT_PRIVATE);

  client.setServer(AWS_IOT_ENDPOINT, 8883);
  client.setCallback(mqttCallback);

  TelemetryData received;
  Backoff wifiBackoff;
  Backoff mqttBackoff;

  uint32_t lastNtpAttempt = 0;
  uint32_t lastFlushAttempt = 0;
  uint32_t lastSdReinitAttempt = 0;

  for (;;) {
    // 1) FAIL-SAFE válvula
    if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(10))) {
      if (g_valveState) {
        uint32_t now = (uint32_t)millis();
        if (g_valveOffTimeMs == 0) {
          Serial.println("[FAIL-SAFE] Válvula ON sem deadline. Forçando OFF.");
          valveSetOffLocked();
        } else if (timeReached(now, g_valveOffTimeMs)) {
          Serial.println("[VALVULA] Tempo esgotado. OFF.");
          valveSetOffLocked();
        } else {
          if (timeReached(now, g_valveLastDebugMs + VALVE_DEBUG_EVERY_MS)) {
            uint32_t remaining = (uint32_t)(g_valveOffTimeMs - now);
            Serial.printf("[VALVULA] Regando... falta ~%lu ms\n", (unsigned long)remaining);
            g_valveLastDebugMs = now;
          }
        }
      }
      xSemaphoreGive(valveMutex);
    }

    // 2) Wi-Fi com backoff
    if (WiFi.status() != WL_CONNECTED) {
      if (g_wifiConnected) {
        Serial.println("[NET] Wi-Fi caiu.");
      }
      g_wifiConnected = false;
      g_mqttConnected = false;

      uint32_t now = (uint32_t)millis();
      if (timeReached(now, wifiBackoff.nextAttemptMs)) {
        uint32_t delayMs = computeBackoffMs(wifiBackoff.attempts, 1000, 30000);
        wifiBackoff.attempts = (wifiBackoff.attempts < 10) ? wifiBackoff.attempts + 1 : 10;
        wifiBackoff.nextAttemptMs = now + delayMs;

        Serial.printf("[NET] Tentando Wi-Fi (backoff=%lu ms)\n", (unsigned long)delayMs);
        WiFi.disconnect(true);
        WiFi.mode(WIFI_STA);
        WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
      }
    } else {
      if (!g_wifiConnected) {
        g_wifiConnected = true;
        wifiBackoff.attempts = 0;
        wifiBackoff.nextAttemptMs = 0;
        Serial.printf("[NET] Wi-Fi OK. IP=%s RSSI=%d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
        syncTimeWithNTP();
        lastNtpAttempt = (uint32_t)millis();
      }

      // NTP retry
      if (!g_timeSynced && timeReached((uint32_t)millis(), lastNtpAttempt + 60000)) {
        syncTimeWithNTP();
        lastNtpAttempt = (uint32_t)millis();
      }

      // 3) MQTT com backoff
      if (!client.connected()) {
        g_mqttConnected = false;
        uint32_t now = (uint32_t)millis();
        if (timeReached(now, mqttBackoff.nextAttemptMs)) {
          uint32_t delayMs = computeBackoffMs(mqttBackoff.attempts, 1000, 30000);
          mqttBackoff.attempts = (mqttBackoff.attempts < 10) ? mqttBackoff.attempts + 1 : 10;
          mqttBackoff.nextAttemptMs = now + delayMs;

          Serial.printf("[AWS] Conectando MQTT (backoff=%lu ms)... ", (unsigned long)delayMs);
          if (client.connect(THINGNAME)) {
            Serial.println("OK!");
            g_mqttConnected = true;
            mqttBackoff.attempts = 0;
            mqttBackoff.nextAttemptMs = 0;
            client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
            Serial.printf("[AWS] Subscribed: %s\n", AWS_IOT_SUBSCRIBE_TOPIC);
          } else {
            Serial.printf("FALHA rc=%d\n", client.state());
          }
        }
      } else {
        g_mqttConnected = true;
        client.loop();
      }
    }

    // 4) Re-init de SD se falhar I/O
    if (!g_sdOk) {
      uint32_t now = (uint32_t)millis();
      if (timeReached(now, lastSdReinitAttempt + SD_REINIT_COOLDOWN_MS)) {
        lastSdReinitAttempt = now;
        Serial.println("[SD] Tentando reinit...");
        if (sdLock(1500)) {
          g_sdOk = sdInit();
          if (g_sdOk) {
            sdEnsureCsvHeader();
            sdRecoverPendingFiles();
          }
          sdUnlock();
        }
      }
    }

    // 5) Se reconectou MQTT, tenta flush periodicamente
    RuntimeConfig c = cfgGetCopy();
    if (g_mqttConnected && g_sdOk && timeReached((uint32_t)millis(), lastFlushAttempt + c.pending_flush_every_ms)) {
      lastFlushAttempt = (uint32_t)millis();
      flushPendingBatch();
    }

    // 6) Consome fila e envia
    if (xQueueReceive(sensorQueue, &received, pdMS_TO_TICKS(100)) == pdPASS) {
      bool sent = false;

      // Monta JSON
      StaticJsonDocument<768> doc;
      doc["device_id"] = THINGNAME;
      doc["timestamp"] = received.timestamp;
      doc["seq"] = received.seq;

      char telemetryId[64];
      snprintf(telemetryId, sizeof(telemetryId), "%s-%lu-%lu", THINGNAME,
               (unsigned long)received.timestamp, (unsigned long)received.seq);
      doc["telemetry_id"] = telemetryId;

      JsonObject s = doc.createNestedObject("sensors");
      s["air_temp"] = received.air_temp;
      s["air_humidity"] = received.air_hum;
      s["soil_moisture"] = received.soil_moisture;
      s["light_level"] = received.light_level;
      s["rain_raw"] = received.rain_raw;
      s["uv_index"] = received.uv_index;

      // sys telemetry (upgrade pequeno e útil)
      JsonObject sys = doc.createNestedObject("sys");
      sys["fw_version"] = FW_VERSION;
      sys["uptime_s"] = (uint32_t)(millis() / 1000UL);
      sys["wifi_rssi"] = g_wifiConnected ? WiFi.RSSI() : -127;
      sys["mqtt"] = g_mqttConnected;

      // bytes pendentes (melhor esforço)
      uint32_t pendBytes = 0;
      uint32_t pendUnsent = 0;
      if (g_sdOk && sdLock(200)) {
        if (SD.exists(PENDING_FILENAME)) {
          File f = SD.open(PENDING_FILENAME, FILE_READ);
          if (f) {
            pendBytes = (uint32_t)f.size();
            f.close();
          }
        }
        sdUnlock();
      }
      if (pendBytes > g_pendingOffset) pendUnsent = pendBytes - g_pendingOffset;
      sys["pending_bytes"] = pendBytes;
      sys["pending_unsent_bytes"] = pendUnsent;
      sys["pending_offset"] = g_pendingOffset;

      char out[768];
      size_t outLen = serializeJson(doc, out, sizeof(out));
      if (outLen == 0) {
        Serial.println("[JSON] Falha ao serializar.");
      } else {
        // Publica se conectado
        if (g_mqttConnected) {
          if (client.publish(AWS_IOT_PUBLISH_TOPIC, out)) {
            sent = true;
          } else {
            Serial.println("[AWS] publish falhou.");
          }
        }

        // Se não enviou, salva para retry
        if (!sent) {
          if (g_sdOk) {
            bool ok = appendPendingLine(out);
            Serial.printf("[SD][PENDING] append=%s\n", ok ? "OK" : "FAIL");
          }
        }

        // CSV local (sempre)
        if (g_sdOk) {
          if (sdLock(300)) {
            File file = SD.open(LOG_FILENAME, FILE_APPEND);
            if (file) {
              file.printf("%lu,%.1f,%.0f,%d,%d,%d,%.2f,%s\n",
                          (unsigned long)received.timestamp,
                          received.air_temp, received.air_hum,
                          received.soil_moisture, received.light_level,
                          received.rain_raw, received.uv_index,
                          sent ? "SENT" : "PENDING");
              file.flush();
              file.close();
            } else {
              Serial.println("[SD] Erro ao escrever CSV.");
              g_sdOk = false;
            }
            sdUnlock();
          }
        }
      }
    }

    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

// TAREFA 3: Display
void taskDisplay(void* pvParameters) {
#if ENABLE_OLED
  int screen = 0;
  for (;;) {
    TelemetryData local;
    if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
      local = g_latestData;
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

      DateTime nowUTC = rtc.now();
      DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);

      display.setTextSize(1);
      display.setCursor(0, 0);
      display.printf("%02d:%02d", nowBRT.hour(), nowBRT.minute());

      display.setCursor(40, 0);
      if (valveOn) {
        display.print("REGANDO!");
      } else {
        display.print("W:");
        display.print(g_wifiConnected ? "OK" : "X");
        display.print(" M:");
        display.print(g_mqttConnected ? "OK" : "X");
      }

      display.drawLine(0, 9, 128, 9, WHITE);
      display.setCursor(0, 15);

      switch (screen) {
        case 0:
          display.println("AGROSMART V5");
          display.printf("FW: %s\n", FW_VERSION);
          display.printf("SD: %s\n", g_sdOk ? "OK" : "ERR");
          display.printf("OFF: %lu\n", (unsigned long)g_pendingOffset);
          break;

        case 1:
          display.setTextSize(2);
          display.printf("%.1fC\n", local.air_temp);
          display.setTextSize(1);
          display.printf("Um:%.0f%% UV:%.1f\n", local.air_hum, local.uv_index);
          break;

        case 2:
          display.setTextSize(1);
          display.println("SOLO/LUZ");
          display.setTextSize(2);
          display.printf("%d%%\n", local.soil_moisture);
          display.setTextSize(1);
          display.printf("Lz:%d Ch:%d\n", local.light_level, local.rain_raw);
          break;
      }

      display.display();
      xSemaphoreGive(i2cMutex);
    }

    vTaskDelay(pdMS_TO_TICKS(OLED_SWITCH_MS));
    screen = (screen + 1) % 3;
  }
#else
  // OLED desativado
  for (;;) vTaskDelay(pdMS_TO_TICKS(1000));
#endif
}

// ===================================================================================
// SETUP
// ===================================================================================
void setup() {
  Serial.begin(115200);
  delay(500);
  randomSeed((uint32_t)esp_random());

  Serial.println("\n\n=== AGROSMART V5 INICIANDO ===");
  Serial.printf("FW=%s | THING=%s\n", FW_VERSION, THINGNAME);

  // Mutex
  i2cMutex = xSemaphoreCreateMutex();
  dataMutex = xSemaphoreCreateMutex();
  valveMutex = xSemaphoreCreateMutex();
  cfgMutex = xSemaphoreCreateMutex();
  sdMutex = xSemaphoreCreateMutex();

  // IO
  analogReadResolution(12);
  pinMode(PIN_SOLO, INPUT);
  pinMode(PIN_CHUVA, INPUT);
  pinMode(PIN_LUZ, INPUT);
  pinMode(PIN_UV, INPUT);

  pinMode(PIN_VALVE, OUTPUT);
  digitalWrite(PIN_VALVE, LOW);
  g_valveState = false;
  g_valveOffTimeMs = 0;
  g_valveLastDebugMs = 0;
  g_lastCommandId[0] = '\0';

  // I2C
  Wire.begin(21, 22);

#if ENABLE_OLED
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("[OLED] Falhou");
  } else {
    display.clearDisplay();
    display.display();
  }
#endif

  // RTC / Sensor
  if (!rtc.begin()) Serial.println("[RTC] Falhou");
  if (!aht.begin()) Serial.println("[AHT10] Falhou");

  // NVS
  nvsLoad();

  // SD
  if (sdLock(1500)) {
    g_sdOk = sdInit();
    if (g_sdOk) {
      sdEnsureCsvHeader();
      sdRecoverPendingFiles();
    }
    sdUnlock();
  }

  // WiFi
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  // Queue
  sensorQueue = xQueueCreate(10, sizeof(TelemetryData));

  // Tasks
  xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
  xTaskCreate(taskNetworkStorage, "Net", 8192, NULL, 2, NULL);
  xTaskCreate(taskSensors, "Sensors", 4096, NULL, 3, NULL);

  Serial.println("[BOOT] Tarefas iniciadas.");
}

void loop() {
  vTaskDelete(NULL);
}