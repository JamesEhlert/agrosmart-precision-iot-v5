/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: 10/02/2026
 * VERSÃO: 5.16 (Store-and-forward no SD + flush de pendências)
 * ===================================================================================
 * OBJETIVO DESTA VERSÃO
 * - Quando o MQTT/AWS estiver OFF, salvar o payload de telemetria no SD (fila persistente).
 * - Quando a internet voltar, reenviar automaticamente os dados pendentes (em lotes).
 * - Manter também o CSV histórico com status SENT/PENDING (útil para auditoria).
 *
 * OBS:
 * - Para testes, o intervalo de telemetria foi ajustado para 1 minuto.
 * - O OLED segue habilitado (protótipo). Para economizar energia no futuro,
 *   basta desabilitar a task do display (ver ENABLE_OLED).
 */

#include <Arduino.h>
#include <Wire.h>               // Comunicação I2C
#include <SPI.h>                // Comunicação SPI
#include <SD.h>                 // Cartão SD
#include <RTClib.h>             // Relógio RTC
#include <Adafruit_AHTX0.h>     // Sensor AHT10
#include <Adafruit_GFX.h>       // Gráficos OLED
#include <Adafruit_SSD1306.h>   // Driver OLED
#include <WiFiClientSecure.h>   // Wi-Fi Seguro
#include <PubSubClient.h>       // MQTT
#include <ArduinoJson.h>        // JSON Parsing
#include "secrets.h"            // Credenciais (Não comitadas)

// ===================================================================================
// 1. CONFIGURAÇÕES GERAIS
// ===================================================================================

// --- AJUSTE PARA TESTES ---
// 60000 ms = 1 minuto (para validar a fila offline sem esperar 10/30 min)
const uint32_t TELEMETRY_INTERVAL_MS = 20000;

// OLED: protótipo. Quando for para campo e economia de energia, coloque 0.
#define ENABLE_OLED 1

const uint32_t OLED_SWITCH_MS = 2000;          // Tempo de troca de tela (2s)
const long BRT_OFFSET_SEC = -10800;            // Fuso horário (-3h)

// --- FAIL-SAFE DA VÁLVULA (SEGURANÇA FÍSICA) ---
const uint32_t MAX_VALVE_DURATION_S = 900;     // Hard cap no device (900s = 15 min)
const uint32_t VALVE_DEBUG_EVERY_MS = 5000;    // Debug periódico enquanto rega

// --- PINAGEM DE HARDWARE ---
#define SD_CS_PIN  5
#define PIN_SOLO   34
#define PIN_CHUVA  35
#define PIN_UV     32
#define PIN_LUZ    33
#define PIN_VALVE  2  // GPIO 2 (LED onboard em muitos ESP32)

// --- CONFIGURAÇÃO OLED ---
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define I2C_MUTEX_WAIT_MS 200 // Tempo máximo de espera pelo barramento

// --- ARQUIVOS E SERVIÇOS ---
const char* LOG_FILENAME = "/telemetry_v5.csv";                 // histórico + status
const char* PENDING_FILENAME = "/pending_telemetry.ndjson";     // fila persistente (offline)
const char* PENDING_TMP_FILENAME = "/pending_telemetry.tmp";    // arquivo temporário de compactação

const char* NTP_SERVER = "pool.ntp.org";

// --- STORE-AND-FORWARD (FILA OFFLINE) ---
// Tamanho máximo do payload por linha (NDJSON). Ajuste se aumentar o JSON.
static const size_t PENDING_LINE_MAX = 512;

// Limites para não travar o device nem gastar bateria reenviando tudo de uma vez.
const uint32_t PENDING_FLUSH_MAX_ITEMS = 30;     // max itens reenviados por flush
const uint32_t PENDING_FLUSH_MAX_MS = 8000;      // max tempo em ms por flush
const uint32_t PENDING_FLUSH_EVERY_MS = 15000;   // roda flush no máximo a cada 15s

// Proteção simples para não lotar cartão. Em produção, evoluir para ring-buffer.
const uint32_t MAX_PENDING_BYTES = 5UL * 1024UL * 1024UL; // 5MB

// "Soft format" (apaga apenas os arquivos do app). Útil para testes.
// Ative digitando "FORMAT" no Serial Monitor nos primeiros segundos do boot.
const uint32_t SD_FORMAT_WINDOW_MS = 8000;

// ===================================================================================
// 2. ESTRUTURA DE DADOS (Payload Interno)
// ===================================================================================
struct TelemetryData {
    uint32_t timestamp; // Data/Hora UNIX
    float air_temp;
    float air_hum;
    int soil_moisture;
    int light_level;
    int rain_raw;
    float uv_index;
    // Nota: Status da válvula não é salvo no histórico, apenas exibido em tempo real.
};

// ===================================================================================
// 3. OBJETOS GLOBAIS
// ===================================================================================
RTC_DS3231 rtc;
Adafruit_AHTX0 aht;
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

WiFiClientSecure net;
PubSubClient client(net);

// --- ESTADOS GLOBAIS (Flags) ---
bool g_wifiConnected = false;
bool g_mqttConnected = false;
bool g_sdOk = false;
bool g_timeSynced = false;

// --- CONTROLE DE VÁLVULA ---
bool g_valveState = false;          // Estado atual (Ligado/Desligado)
uint32_t g_valveOffTimeMs = 0;      // "deadline" em millis() para desligar (wrap-safe)
uint32_t g_valveLastDebugMs = 0;    // para debug periódico durante irrigação

// (Bônus) armazenar último command_id para log (e no futuro ACK)
char g_lastCommandId[48] = {0};

// --- RECURSOS DO FREERTOS ---
TelemetryData g_latestData;   // Dados compartilhados para o Display
QueueHandle_t sensorQueue;    // Fila de mensagens (Sensores -> Rede)
SemaphoreHandle_t i2cMutex;   // Proteção do barramento I2C
SemaphoreHandle_t dataMutex;  // Proteção da memória g_latestData
SemaphoreHandle_t valveMutex; // Proteção do estado da válvula (lido por múltiplas tasks)

// ===================================================================================
// 4. HELPERS (TEMPO WRAP-SAFE / VÁLVULA)
// ===================================================================================

/**
 * millis() no ESP32 é uint32_t e "vira" (overflow) com o tempo.
 * Para comparar corretamente, usamos diferença com cast para signed:
 *   se (now - deadline) >= 0, então já passou do prazo.
 */
static inline bool timeReached(uint32_t now, uint32_t deadline) {
    return (int32_t)(now - deadline) >= 0;
}

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
    // durationS já deve estar clampado
    if (durationS == 0) {
        valveSetOffLocked();
        return;
    }

    digitalWrite(PIN_VALVE, HIGH);
    g_valveState = true;

    uint32_t now = (uint32_t)millis();
    uint32_t durationMs = durationS * 1000UL;
    g_valveOffTimeMs = now + durationMs;  // overflow aqui é OK (comparação wrap-safe)
    g_valveLastDebugMs = now;

    Serial.printf("[VALVULA] ✅ LIGADA por %lu s (hard cap=%lu s)\n",
                  (unsigned long)durationS, (unsigned long)MAX_VALVE_DURATION_S);
}

/**
 * Wrapper thread-safe para ligar/desligar a válvula.
 */
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
            if (safeS == 0) {
                Serial.println("[VALVULA] ⏹️ STOP (duration=0)");
            }
            valveSetOnForLocked(safeS);
        }
        xSemaphoreGive(valveMutex);
    } else {
        // Se por algum motivo não conseguir pegar o mutex, preferimos segurança:
        Serial.println("[FAIL-SAFE] Mutex da válvula ocupado. Forçando OFF por segurança.");
        digitalWrite(PIN_VALVE, LOW);
        g_valveState = false;
        g_valveOffTimeMs = 0;
        g_valveLastDebugMs = 0;
    }
}

// ===================================================================================
// 5. CALLBACK MQTT (Ouvindo Comandos - FAIL-SAFE)
// ===================================================================================
/**
 * Esta função é chamada automaticamente quando chega uma mensagem no tópico subscrito.
 * Payload esperado:
 *  {
 *    "device_id": "...",
 *    "action": "on",
 *    "duration": 10,
 *    "command_id": "uuid-opcional"
 *  }
 */
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

    // --- FILTRO DE DISPOSITIVO ---
    const char* targetDevice = doc["device_id"];
    if (targetDevice != nullptr && strcmp(targetDevice, THINGNAME) != 0) {
        Serial.printf("[IGNORADO] Para: %s (Eu sou: %s)\n", targetDevice, THINGNAME);
        return;
    }

    // Captura command_id (se vier)
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

    // duration pode vir ausente (default 0)
    int32_t duration = doc["duration"] | 0;

    if (strcmp(action, "on") == 0) {
        // Seu padrão: duration > 0 liga por X segundos; duration == 0 = STOP imediato
        if (duration > 0) {
            Serial.printf("[COMANDO] LIGAR por %ld segundos.\n", (long)duration);
            valveApplyCommand(true, duration);
        } else {
            Serial.println("[COMANDO] STOP imediato (duration=0).");
            valveApplyCommand(false, 0);
        }
    } else {
        Serial.printf("[AVISO] Ação desconhecida recebida: %s\n", action);
    }
}

// ===================================================================================
// 6. FUNÇÕES AUXILIARES (TEMPO)
// ===================================================================================

/**
 * Obtém a hora atual do RTC de forma segura (Thread-Safe).
 * Se o I2C estiver ocupado, retorna epoch 0 (para não travar o sistema).
 */
DateTime getSystemTime() {
    if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
        DateTime now = rtc.now();
        xSemaphoreGive(i2cMutex);
        return now;
    }
    return DateTime((uint32_t)0);
}

/**
 * Conecta ao servidor NTP para ajustar o relógio RTC.
 * Tenta 5 vezes antes de desistir.
 */
void syncTimeWithNTP() {
    Serial.println("[TIME] Iniciando sincronização NTP...");
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
            Serial.println("[TIME] Sucesso! RTC atualizado com a internet.");
        }
    } else {
        Serial.println("[TIME] Falha no NTP. Usando horário interno do RTC.");
    }
}

// ===================================================================================
// 7. SD: STORE-AND-FORWARD (FILA OFFLINE)
// ===================================================================================

/**
 * Lê uma linha do arquivo (até '\n') em buffer fixo.
 * - Remove '\r'.
 * - Retorna true se leu alguma coisa.
 * - Se a linha exceder o tamanho do buffer, descarta o resto da linha e retorna false.
 */
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
            // Linha maior que o buffer: descarta até o fim da linha
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

/**
 * Checa se o arquivo de pendências está "grande demais".
 */
static bool pendingTooLarge() {
    if (!SD.exists(PENDING_FILENAME)) return false;

    File f = SD.open(PENDING_FILENAME, FILE_READ);
    if (!f) return false;

    uint32_t sz = (uint32_t)f.size();
    f.close();

    return sz >= MAX_PENDING_BYTES;
}

/**
 * Adiciona um evento na fila persistente (NDJSON = 1 JSON por linha).
 * Usado quando:
 * - MQTT está offline
 * - publish falhou
 */
static void appendPendingNdjson(const char* jsonLine) {
    if (!g_sdOk || !jsonLine || jsonLine[0] == '\0') return;

    if (pendingTooLarge()) {
        Serial.println("[SD][WARN] pending_telemetry.ndjson atingiu o limite. Novo evento NÃO será enfileirado.");
        Serial.println("[SD][WARN] (Em produto: evoluir para ring-buffer/rotacionamento.)");
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

    Serial.println("[SD] Evento enfileirado (NDJSON)."
                  " (será reenviado assim que a internet voltar)");
}

/**
 * "Soft format" do SD: apaga apenas arquivos do AgroSmart.
 * (Não formata FAT32/exFAT; isso você faz no PC. Aqui é só reset do app.)
 */
static void sdSoftFormatAppFiles() {
    if (!g_sdOk) return;

    Serial.println("[SD] Soft format: removendo arquivos do app...");

    if (SD.exists(LOG_FILENAME)) SD.remove(LOG_FILENAME);
    if (SD.exists(PENDING_FILENAME)) SD.remove(PENDING_FILENAME);
    if (SD.exists(PENDING_TMP_FILENAME)) SD.remove(PENDING_TMP_FILENAME);

    // Recria CSV com header
    File f = SD.open(LOG_FILENAME, FILE_WRITE);
    if (f) {
        f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status_Envio");
        f.close();
        Serial.println("[SD] CSV recriado com header.");
    } else {
        Serial.println("[SD] Falha ao recriar CSV.");
    }

    Serial.println("[SD] Soft format concluído.");
}

/**
 * Reenvia eventos pendentes quando MQTT estiver conectado.
 * Estratégia:
 *  - Lê pending_telemetry.ndjson
 *  - Tenta publicar linha por linha
 *  - Se falhar, mantém a linha em pending_telemetry.tmp
 *  - Ao final, substitui o arquivo original pelo tmp
 */
static void flushPending(uint32_t maxItems, uint32_t maxMs) {
    if (!g_sdOk || !g_mqttConnected) return;
    if (!SD.exists(PENDING_FILENAME)) return; // nada pendente

    File in = SD.open(PENDING_FILENAME, FILE_READ);
    if (!in) {
        Serial.println("[SD] Falha ao abrir pending_telemetry.ndjson para leitura.");
        return;
    }

    File out = SD.open(PENDING_TMP_FILENAME, FILE_WRITE);
    if (!out) {
        Serial.println("[SD] Falha ao abrir pending_telemetry.tmp para escrita.");
        in.close();
        return;
    }

    Serial.println("[SD] Iniciando flush de pendências...");

    uint32_t start = (uint32_t)millis();
    uint32_t sentCount = 0;
    uint32_t keptCount = 0;

    char line[PENDING_LINE_MAX];

    while (in.available()) {
        if (sentCount >= maxItems) break;
        if (timeReached((uint32_t)millis(), start + maxMs)) break;

        bool okLine = readLineToBuffer(in, line, sizeof(line));
        if (!okLine) {
            // Linha vazia ou grande demais: pula
            continue;
        }

        bool ok = client.publish(AWS_IOT_PUBLISH_TOPIC, line);
        if (ok) {
            sentCount++;
        } else {
            out.println(line);
            keptCount++;
        }

        // manter MQTT vivo
        client.loop();
        vTaskDelay(pdMS_TO_TICKS(10));
    }

    // Copia o restante sem tentar enviar (caso paramos por limite)
    while (in.available()) {
        bool okLine = readLineToBuffer(in, line, sizeof(line));
        if (!okLine) continue;
        out.println(line);
        keptCount++;
    }

    in.close();
    out.flush();
    out.close();

    // Troca arquivos: tmp vira o novo pending
    SD.remove(PENDING_FILENAME);
    SD.rename(PENDING_TMP_FILENAME, PENDING_FILENAME);

    Serial.printf("[SD] Flush concluído. Enviados=%lu | Mantidos=%lu\n",
                  (unsigned long)sentCount, (unsigned long)keptCount);
}

// ===================================================================================
// 8. TAREFAS DO SISTEMA (RTOS TASKS)
// ===================================================================================

/**
 * TAREFA 1: LEITURA DE SENSORES
 */
void taskSensors(void *pvParameters) {
    for (;;) {
        TelemetryData data;

        Serial.println("\n========================================");
        Serial.println("[SENSOR TASK] Iniciando ciclo de leitura...");

        // 1. Pega Data/Hora
        DateTime nowUTC = getSystemTime();
        data.timestamp = nowUTC.unixtime();

        // 2. Lê Sensor Digital AHT10
        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            sensors_event_t h, t;
            if (aht.getEvent(&h, &t)) {
                data.air_temp = t.temperature;
                data.air_hum = h.relative_humidity;
            } else {
                Serial.println("[ERRO] Falha leitura AHT10");
                data.air_temp = 0; data.air_hum = 0;
            }
            xSemaphoreGive(i2cMutex);
        }

        // 3. Lê Sensores Analógicos
        int rawSolo = analogRead(PIN_SOLO);
        data.soil_moisture = constrain(map(rawSolo, 3000, 1200, 0, 100), 0, 100);

        int rawLuz = analogRead(PIN_LUZ);
        data.light_level = map(rawLuz, 0, 4095, 0, 100);

        data.rain_raw = analogRead(PIN_CHUVA);

        // 4. Leitura UV (Média de amostras)
        long somaUV = 0;
        for(int i=0; i<16; i++) { somaUV += analogRead(PIN_UV); vTaskDelay(pdMS_TO_TICKS(1)); }
        data.uv_index = (((somaUV / 16) * 3.3) / 4095.0) / 0.1;
        if (data.uv_index < 0.2) data.uv_index = 0.0;

        // --- DEBUG DETALHADO NO TERMINAL ---
        DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);

        bool valveOn = false;
        if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(10))) {
            valveOn = g_valveState;
            xSemaphoreGive(valveMutex);
        }

        Serial.printf("[DEBUG] Hora: %02d:%02d:%02d\n", nowBRT.hour(), nowBRT.minute(), nowBRT.second());
        Serial.printf("[DEBUG] Ar: %.2fC | %.2f%%\n", data.air_temp, data.air_hum);
        Serial.printf("[DEBUG] Solo (Raw: %d): %d%%\n", rawSolo, data.soil_moisture);
        Serial.printf("[DEBUG] Luz (Raw: %d): %d%%\n", rawLuz, data.light_level);
        Serial.printf("[DEBUG] Chuva Raw: %d\n", data.rain_raw);
        Serial.printf("[DEBUG] Status Válvula: %s\n", valveOn ? "LIGADA" : "DESLIGADA");

        // Atualiza dado para o display
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(100))) {
            g_latestData = data;
            xSemaphoreGive(dataMutex);
        }

        // Envia para a fila
        if(xQueueSend(sensorQueue, &data, 0) == pdPASS) {
            Serial.println("[SENSOR TASK] Dados enviados para a fila.");
        } else {
            Serial.println("[ERRO] Fila cheia! Dados perdidos.");
        }

        vTaskDelay(pdMS_TO_TICKS(TELEMETRY_INTERVAL_MS));
    }
}

/**
 * TAREFA 2: REDE E ARMAZENAMENTO
 * - Gerencia Wi-Fi/MQTT/SD
 * - Verifica temporizador da válvula (wrap-safe)
 * - Implementa store-and-forward com fila NDJSON no SD
 */
void taskNetworkStorage(void *pvParameters) {
    // Configura SSL da AWS
    net.setCACert(AWS_CERT_CA);
    net.setCertificate(AWS_CERT_CRT);
    net.setPrivateKey(AWS_CERT_PRIVATE);

    client.setServer(AWS_IOT_ENDPOINT, 8883);
    client.setCallback(mqttCallback);

    // Se o payload crescer no futuro, pode aumentar (PubSubClient default ~256)
    client.setBufferSize(1024);

    TelemetryData receivedData;
    uint32_t lastNtpAttempt = 0;
    uint32_t lastFlushAttempt = 0;

    for (;;) {
        // --- 1. FAIL-SAFE: TEMPORIZADOR DA VÁLVULA (wrap-safe) ---
        if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(10))) {
            if (g_valveState) {
                uint32_t now = (uint32_t)millis();

                // Se por algum bug o estado estiver ON sem deadline, desligar por segurança
                if (g_valveOffTimeMs == 0) {
                    Serial.println("[FAIL-SAFE] Válvula ON sem deadline. Forçando OFF.");
                    valveSetOffLocked();
                } else if (timeReached(now, g_valveOffTimeMs)) {
                    Serial.println("[VALVULA] Tempo esgotado! Desligando.");
                    valveSetOffLocked();
                } else {
                    // Debug periódico
                    if (timeReached(now, g_valveLastDebugMs + VALVE_DEBUG_EVERY_MS)) {
                        uint32_t remaining = (uint32_t)(g_valveOffTimeMs - now); // ok em uint32 com wrap
                        Serial.printf("[VALVULA] Regando... Falta ~%lu ms\n", (unsigned long)remaining);
                        g_valveLastDebugMs = now;
                    }
                }
            }
            xSemaphoreGive(valveMutex);
        }

        // --- 2. GERENCIAMENTO DE CONEXÃO ---
        if (WiFi.status() != WL_CONNECTED) {
            if (g_wifiConnected) {
                Serial.println("[NET] Wi-Fi caiu! Tentando reconectar...");
            }
            g_wifiConnected = false;
            g_mqttConnected = false;

            WiFi.disconnect();
            WiFi.reconnect();
            vTaskDelay(pdMS_TO_TICKS(2000));
        } else {
            if (!g_wifiConnected) {
                g_wifiConnected = true;
                Serial.println("[NET] Wi-Fi Conectado!");
                syncTimeWithNTP();
                lastNtpAttempt = (uint32_t)millis();
            }

            if (!g_timeSynced && timeReached((uint32_t)millis(), lastNtpAttempt + 60000)) {
                syncTimeWithNTP();
                lastNtpAttempt = (uint32_t)millis();
            }
        }

        // --- 3. CONEXÃO MQTT (AWS) ---
        if (g_wifiConnected) {
            if (!client.connected()) {
                Serial.print("[AWS] Conectando MQTT... ");
                if (client.connect(THINGNAME)) {
                    Serial.println("SUCESSO!");
                    g_mqttConnected = true;

                    client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
                    Serial.printf("[AWS] Inscrito no tópico: %s\n", AWS_IOT_SUBSCRIBE_TOPIC);

                    // flush logo após reconectar
                    lastFlushAttempt = 0;
                } else {
                    Serial.printf("FALHA (rc=%d)\n", client.state());
                    g_mqttConnected = false;
                    vTaskDelay(pdMS_TO_TICKS(1000));
                }
            } else {
                client.loop();
            }
        }

        // --- 4. FLUSH DA FILA OFFLINE (a cada X segundos enquanto MQTT ON) ---
        if (g_mqttConnected) {
            uint32_t now = (uint32_t)millis();
            if (lastFlushAttempt == 0 || timeReached(now, lastFlushAttempt + PENDING_FLUSH_EVERY_MS)) {
                flushPending(PENDING_FLUSH_MAX_ITEMS, PENDING_FLUSH_MAX_MS);
                lastFlushAttempt = now;
            }
        }

        // --- 5. PROCESSAMENTO DE DADOS (ENVIO) ---
        if (xQueueReceive(sensorQueue, &receivedData, pdMS_TO_TICKS(100)) == pdPASS) {
            Serial.println("[NET TASK] Processando pacote da fila...");

            // Monta JSON SEMPRE (mesmo offline), para poder enfileirar.
            StaticJsonDocument<512> doc;
            doc["device_id"] = THINGNAME;
            doc["timestamp"] = receivedData.timestamp;

            JsonObject s = doc.createNestedObject("sensors");
            s["air_temp"] = receivedData.air_temp;
            s["air_humidity"] = receivedData.air_hum;
            s["soil_moisture"] = receivedData.soil_moisture;
            s["light_level"] = receivedData.light_level;
            s["rain_raw"] = receivedData.rain_raw;
            s["uv_index"] = receivedData.uv_index;

            char buf[512];
            size_t n = serializeJson(doc, buf, sizeof(buf));
            if (n == 0 || n >= sizeof(buf)) {
                Serial.println("[ERRO] JSON muito grande para o buffer. Ajuste PENDING_LINE_MAX/bufferSize.");
                // Ainda grava no CSV como PENDING para não perder registro
            }

            bool sent = false;

            // Envio AWS
            if (g_mqttConnected && n > 0 && n < sizeof(buf)) {
                if (client.publish(AWS_IOT_PUBLISH_TOPIC, buf)) {
                    Serial.println("[AWS] JSON Publicado com sucesso.");
                    sent = true;
                } else {
                    Serial.println("[AWS] Falha na publicação. Enfileirando no SD...");
                    appendPendingNdjson(buf);
                }
            } else {
                Serial.println("[AWS] Offline. Enfileirando no SD...");
                if (n > 0 && n < sizeof(buf)) {
                    appendPendingNdjson(buf);
                }
            }

            // Envio SD (histórico CSV)
            if (g_sdOk) {
                File file = SD.open(LOG_FILENAME, FILE_APPEND);
                if (file) {
                    file.printf("%lu,%.1f,%.0f,%d,%d,%d,%.2f,%s\n",
                                receivedData.timestamp,
                                receivedData.air_temp, receivedData.air_hum,
                                receivedData.soil_moisture, receivedData.light_level,
                                receivedData.rain_raw, receivedData.uv_index,
                                sent ? "SENT" : "PENDING");
                    file.close();
                    Serial.println("[SD] Linha adicionada ao CSV.");
                } else {
                    Serial.println("[SD] Erro crítico de escrita no CSV.");
                }
            }
        }

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

#if ENABLE_OLED
/**
 * TAREFA 3: INTERFACE DE USUÁRIO (OLED)
 */
void taskDisplay(void *pvParameters) {
    int screen = 0;

    for (;;) {
        TelemetryData localData;
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
            localData = g_latestData;
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

            // HEADER
            display.setTextSize(1);
            display.setCursor(0, 0);
            display.printf("%02d:%02d", nowBRT.hour(), nowBRT.minute());

            display.setCursor(40, 0);
            if (valveOn) {
                display.print("REGANDO!");
            } else {
                display.print("W:");
                display.print(g_wifiConnected ? "OK" : "X");
            }

            display.drawLine(0, 9, 128, 9, WHITE);

            // CARROSSEL
            display.setCursor(0, 15);
            switch (screen) {
                case 0:
                    display.println("SISTEMA V5:");
                    display.printf("AWS MQTT: %s\n", g_mqttConnected ? "ON" : "OFF");
                    display.printf("SD CARD:  %s\n", g_sdOk ? "OK" : "ERRO");
                    display.printf("VALVULA:  %s", valveOn ? "ATIVO" : "OFF");
                    break;

                case 1:
                    display.setTextSize(2);
                    display.printf("%.1f C\n", localData.air_temp);
                    display.setTextSize(1);
                    display.printf("Um: %.0f%% UV: %.1f", localData.air_hum, localData.uv_index);
                    break;

                case 2:
                    display.setTextSize(1);
                    display.println("SOLO / LUZ:");
                    display.setTextSize(2);
                    display.printf("%d%%\n", localData.soil_moisture);
                    display.setTextSize(1);
                    display.printf("Lz:%d%% Ch:%d", localData.light_level, localData.rain_raw);
                    break;
            }

            display.display();
            xSemaphoreGive(i2cMutex);
        }

        vTaskDelay(pdMS_TO_TICKS(OLED_SWITCH_MS));
        screen++;
        if (screen > 2) screen = 0;
    }
}
#endif

// ===================================================================================
// 9. SETUP
// ===================================================================================

static bool waitSerialForWord(const char* word, uint32_t timeoutMs) {
    // Lê algo do serial no boot (para soft format). Simples e robusto.
    // Digite: FORMAT + ENTER
    // (evitamos String para reduzir fragmentação de heap)

    auto equalsIgnoreCase = [](const char* a, const char* b) -> bool {
        if (!a || !b) return false;
        while (*a && *b) {
            char ca = *a;
            char cb = *b;
            if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
            if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
            if (ca != cb) return false;
            a++; b++;
        }
        return (*a == '\0' && *b == '\0');
    };

    char buf[16] = {0};
    size_t idx = 0;

    uint32_t start = (uint32_t)millis();
    while (!timeReached((uint32_t)millis(), start + timeoutMs)) {
        while (Serial.available()) {
            char c = (char)Serial.read();
            if (c == '\r' || c == '\n') {
                buf[idx] = '\0';
                if (equalsIgnoreCase(buf, word)) {
                    return true;
                }
                // reseta buffer se digitou outra coisa
                idx = 0;
                memset(buf, 0, sizeof(buf));
            } else {
                if (idx + 1 < sizeof(buf)) {
                    buf[idx++] = c;
                }
            }
        }
        delay(10);
    }
    return false;
}

void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n\n=== AGROSMART V5.16 INICIANDO ===");
    Serial.println("Configuração: SD store-and-forward + FAIL-SAFE + WRAP-SAFE + MUTEX DA VALVULA");

    // Inicializa Semáforos
    i2cMutex = xSemaphoreCreateMutex();
    dataMutex = xSemaphoreCreateMutex();
    valveMutex = xSemaphoreCreateMutex();

    // Configura Pinos
    analogReadResolution(12);
    pinMode(PIN_SOLO, INPUT);
    pinMode(PIN_CHUVA, INPUT);
    pinMode(PIN_LUZ, INPUT);
    pinMode(PIN_UV, INPUT);

    // Configura Válvula (BOOT SEGURO)
    pinMode(PIN_VALVE, OUTPUT);
    digitalWrite(PIN_VALVE, LOW); // Começa desligado

    // Estado interno também começa zerado (segurança)
    if (xSemaphoreTake(valveMutex, pdMS_TO_TICKS(50))) {
        g_valveState = false;
        g_valveOffTimeMs = 0;
        g_valveLastDebugMs = 0;
        g_lastCommandId[0] = '\0';
        xSemaphoreGive(valveMutex);
    } else {
        g_valveState = false;
        g_valveOffTimeMs = 0;
        g_valveLastDebugMs = 0;
        g_lastCommandId[0] = '\0';
    }

    Serial.println("[IO] Pinos configurados.");

    // Configura Periféricos
    Wire.begin(21, 22);

#if ENABLE_OLED
    if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) Serial.println("[ERRO] OLED Falhou");
    else { display.clearDisplay(); display.display(); }
#endif

    if (!rtc.begin()) Serial.println("[ERRO] RTC Falhou");
    if (!aht.begin()) Serial.println("[ERRO] AHT10 Falhou");

    // Configura SD
    SPI.begin(18, 19, 23, SD_CS_PIN);
    if (SD.begin(SD_CS_PIN, SPI, 4000000)) {
        g_sdOk = true;
        Serial.println("[SD] Cartão Iniciado.");

        Serial.printf("[SD] Para resetar os arquivos do app, digite 'FORMAT' e ENTER em até %lu ms...\n",
                      (unsigned long)SD_FORMAT_WINDOW_MS);
        if (waitSerialForWord("FORMAT", SD_FORMAT_WINDOW_MS)) {
            sdSoftFormatAppFiles();
        }

        // Cria CSV se não existir
        if (!SD.exists(LOG_FILENAME)) {
            File f = SD.open(LOG_FILENAME, FILE_WRITE);
            if (f) {
                f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status_Envio");
                f.close();
                Serial.println("[SD] CSV criado com header.");
            }
        }

        // Garante que tmp não ficou de uma execução anterior
        if (SD.exists(PENDING_TMP_FILENAME)) {
            SD.remove(PENDING_TMP_FILENAME);
        }

    } else {
        Serial.println("[ERRO] Cartão SD não detectado.");
    }

    // Configura Wi-Fi
    WiFi.persistent(false);       // evita escrever flash toda hora
    WiFi.setAutoReconnect(true);
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    // Cria Fila
    sensorQueue = xQueueCreate(10, sizeof(TelemetryData));

    // Inicia Tarefas
#if ENABLE_OLED
    xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
#endif
    xTaskCreate(taskNetworkStorage, "Net", 8192, NULL, 2, NULL);
    xTaskCreate(taskSensors, "Sensors", 4096, NULL, 3, NULL);

    Serial.println("[BOOT] Sistema Operacional Iniciado. Tarefas rodando.");
}

void loop() { vTaskDelete(NULL); }