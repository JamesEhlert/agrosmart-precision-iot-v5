/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: 05/02/2026
 * VERSÃO: 5.15 (Fail-safe de válvula + millis wrap-safe + mutex)
 * ===================================================================================
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

// OBS: 600000 ms = 10 minutos (o comentário antigo dizia 1 min, mas o valor era 10 min)
const uint32_t TELEMETRY_INTERVAL_MS = 600000; // Tempo entre envios (10 min)

// OBS: 2000 ms = 2s (o comentário antigo dizia 3s)
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
const char* LOG_FILENAME = "/telemetry_v5.csv";
const char* NTP_SERVER = "pool.ntp.org";

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
TelemetryData g_latestData;  // Dados compartilhados para o Display
QueueHandle_t sensorQueue;   // Fila de mensagens (Sensores -> Rede)
SemaphoreHandle_t i2cMutex;  // Proteção do barramento I2C
SemaphoreHandle_t dataMutex; // Proteção da memória g_latestData
SemaphoreHandle_t valveMutex; // Proteção do estado da válvula (lido por múltiplas tasks)

// ===================================================================================
// 4. HELPERS (FAIL-SAFE / TEMPO WRAP-SAFE / VÁLVULA)
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
// 6. FUNÇÕES AUXILIARES
// ===================================================================================

/**
 * Obtém a hora atual do RTC de forma segura (Thread-Safe).
 * Se o I2C estiver ocupado, retorna 0 para não travar o sistema.
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
// 7. TAREFAS DO SISTEMA (RTOS TASKS)
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
 */
void taskNetworkStorage(void *pvParameters) {
    // Configura SSL da AWS
    net.setCACert(AWS_CERT_CA);
    net.setCertificate(AWS_CERT_CRT);
    net.setPrivateKey(AWS_CERT_PRIVATE);
    client.setServer(AWS_IOT_ENDPOINT, 8883);
    client.setCallback(mqttCallback);

    TelemetryData receivedData;
    unsigned long lastNtpAttempt = 0;

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
            Serial.println("[NET] Wi-Fi caiu! Tentando reconectar...");
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
                lastNtpAttempt = millis();
            }
            if (!g_timeSynced && (millis() - lastNtpAttempt > 60000)) {
                syncTimeWithNTP();
                lastNtpAttempt = millis();
            }
        }

        // Conexão MQTT (AWS)
        if (g_wifiConnected) {
            if (!client.connected()) {
                Serial.print("[AWS] Conectando MQTT... ");
                if (client.connect(THINGNAME)) {
                    Serial.println("SUCESSO!");
                    g_mqttConnected = true;
                    client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
                    Serial.printf("[AWS] Inscrito no tópico: %s\n", AWS_IOT_SUBSCRIBE_TOPIC);
                } else {
                    Serial.printf("FALHA (rc=%d)\n", client.state());
                    g_mqttConnected = false;
                    vTaskDelay(pdMS_TO_TICKS(1000));
                }
            } else {
                client.loop();
            }
        }

        // --- 3. PROCESSAMENTO DE DADOS (ENVIO) ---
        if (xQueueReceive(sensorQueue, &receivedData, pdMS_TO_TICKS(100)) == pdPASS) {
            Serial.println("[NET TASK] Processando pacote da fila...");
            bool sent = false;

            // Envio AWS
            if (g_mqttConnected) {
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
                serializeJson(doc, buf);

                if (client.publish(AWS_IOT_PUBLISH_TOPIC, buf)) {
                    Serial.println("[AWS] JSON Publicado com sucesso.");
                    sent = true;
                } else {
                    Serial.println("[AWS] Falha na publicação.");
                }
            } else {
                Serial.println("[AWS] Offline. Pulando envio nuvem.");
            }

            // Envio SD
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
                    Serial.println("[SD] Erro crítico de escrita.");
                }
            }
        }

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

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

// ===================================================================================
// 8. SETUP
// ===================================================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n\n=== AGROSMART V5.15 INICIANDO ===");
    Serial.println("Configuração: FAIL-SAFE + WRAP-SAFE + MUTEX DA VALVULA");

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
    if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) Serial.println("[ERRO] OLED Falhou");
    else { display.clearDisplay(); display.display(); }

    if (!rtc.begin()) Serial.println("[ERRO] RTC Falhou");
    if (!aht.begin()) Serial.println("[ERRO] AHT10 Falhou");

    // Configura SD
    SPI.begin(18, 19, 23, 5);
    if (SD.begin(5, SPI, 4000000)) {
        g_sdOk = true;
        Serial.println("[SD] Cartão Iniciado.");
        if (!SD.exists(LOG_FILENAME)) {
            File f = SD.open(LOG_FILENAME, FILE_WRITE);
            if (f) {
                f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status_Envio");
                f.close();
            }
        }
    } else {
        Serial.println("[ERRO] Cartão SD não detectado.");
    }

    // Configura Wi-Fi
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    // Cria Fila
    sensorQueue = xQueueCreate(10, sizeof(TelemetryData));

    // Inicia Tarefas
    xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
    xTaskCreate(taskNetworkStorage, "Net", 8192, NULL, 2, NULL);
    xTaskCreate(taskSensors, "Sensors", 4096, NULL, 3, NULL);

    Serial.println("[BOOT] Sistema Operacional Iniciado. Tarefas rodando.");
}

void loop() { vTaskDelete(NULL); }
