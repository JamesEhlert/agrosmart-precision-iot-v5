/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: Janeiro/2026
 * VERSÃO: 5.14 (Atualizado com Filtro de Device ID)
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
const uint32_t TELEMETRY_INTERVAL_MS = 60000; // Tempo entre envios (1 min)
const uint32_t OLED_SWITCH_MS = 2000;         // Tempo de troca de tela (3s)
const long BRT_OFFSET_SEC = -10800;           // Fuso horário (-3h)

// --- PINAGEM DE HARDWARE ---
#define SD_CS_PIN  5
#define PIN_SOLO   34
#define PIN_CHUVA  35
#define PIN_UV     32
#define PIN_LUZ    33
#define PIN_VALVE  2  // ALTERADO: Pino 2 (Geralmente LED Onboard no ESP32)

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
bool g_valveState = false;        // Estado atual (Ligado/Desligado)
unsigned long g_valveOffTime = 0; // Timestamp futuro para desligar

// --- RECURSOS DO FREERTOS ---
TelemetryData g_latestData;  // Dados compartilhados para o Display
QueueHandle_t sensorQueue;   // Fila de mensagens (Sensores -> Rede)
SemaphoreHandle_t i2cMutex;  // Proteção do barramento I2C
SemaphoreHandle_t dataMutex; // Proteção da memória g_latestData

// ===================================================================================
// 4. CALLBACK MQTT (Ouvindo Comandos - ATUALIZADO)
// ===================================================================================
/**
 * Esta função é chamada automaticamente quando chega uma mensagem no tópico subscrito.
 * Tópico: agrosmart/v5/command
 * Payload Esperado: {"device_id": "...", "action": "on", "duration": 10}
 */
void mqttCallback(char* topic, byte* payload, unsigned int length) {
    Serial.println("\n>>> [MQTT] MENSAGEM RECEBIDA! <<<");
    Serial.printf("Tópico: %s\n", topic);
    
    // Buffer aumentado para garantir parsing seguro
    StaticJsonDocument<512> doc;
    DeserializationError error = deserializeJson(doc, payload, length);

    if (error) {
        Serial.print("[ERRO] JSON Inválido: ");
        Serial.println(error.c_str());
        return;
    }

    // --- NOVA LÓGICA DE FILTRO DE DISPOSITIVO ---
    const char* targetDevice = doc["device_id"];
    
    // Se o comando tem um destinatário E não sou eu (THINGNAME), ignoro.
    if (targetDevice != nullptr && strcmp(targetDevice, THINGNAME) != 0) {
        Serial.printf("[IGNORADO] Comando direcionado para: %s (Eu sou: %s)\n", targetDevice, THINGNAME);
        return;
    }

    // Se chegou aqui, o comando é para mim (ou é broadcast)
    const char* action = doc["action"];
    int duration = doc["duration"];

    // Verifica comando "on"
    if (strcmp(action, "on") == 0) {
        if (duration > 0) {
            Serial.printf("[COMANDO] ✅ LIGAR Válvula por %d segundos.\n", duration);
            digitalWrite(PIN_VALVE, HIGH); // Ativa pino físico
            g_valveState = true;
            g_valveOffTime = millis() + (duration * 1000); // Calcula hora de desligar
            Serial.println("[VALVULA] Estado: LIGADO (ON)");
        } else {
            // Se duração for 0, é comando de parada imediata
            Serial.println("[COMANDO] ⏹️ PARAR Válvula imediatamente.");
            digitalWrite(PIN_VALVE, LOW);
            g_valveState = false;
            g_valveOffTime = 0;
            Serial.println("[VALVULA] Estado: DESLIGADO (OFF)");
        }
    } else {
        Serial.println("[AVISO] Ação desconhecida recebida via MQTT.");
    }
}

// ===================================================================================
// 5. FUNÇÕES AUXILIARES
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
            Serial.println("[TIME] Sucesso! Relógio DS3231 atualizado com a internet.");
        }
    } else {
        Serial.println("[TIME] Falha no NTP. Usando horário interno do RTC.");
    }
}

// ===================================================================================
// 6. TAREFAS DO SISTEMA (RTOS TASKS)
// ===================================================================================

/**
 * TAREFA 1: LEITURA DE SENSORES
 * Lê todos os sensores, empacota os dados e envia para a fila de processamento.
 * Roda a cada 60 segundos (configurável).
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
        Serial.printf("[DEBUG] Hora: %02d:%02d:%02d\n", nowBRT.hour(), nowBRT.minute(), nowBRT.second());
        Serial.printf("[DEBUG] Ar: %.2fC | %.2f%%\n", data.air_temp, data.air_hum);
        Serial.printf("[DEBUG] Solo (Raw: %d): %d%%\n", rawSolo, data.soil_moisture);
        Serial.printf("[DEBUG] Luz (Raw: %d): %d%%\n", rawLuz, data.light_level);
        Serial.printf("[DEBUG] Chuva Raw: %d\n", data.rain_raw);
        Serial.printf("[DEBUG] Status Válvula: %s\n", g_valveState ? "LIGADA" : "DESLIGADA");

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
 * Gerencia Wi-Fi, MQTT (AWS) e escrita no Cartão SD.
 * Também verifica o temporizador da válvula.
 */
void taskNetworkStorage(void *pvParameters) {
    // Configura SSL da AWS
    net.setCACert(AWS_CERT_CA);
    net.setCertificate(AWS_CERT_CRT);
    net.setPrivateKey(AWS_CERT_PRIVATE);
    client.setServer(AWS_IOT_ENDPOINT, 8883);
    client.setCallback(mqttCallback); // Define quem trata as mensagens recebidas

    TelemetryData receivedData;
    unsigned long lastNtpAttempt = 0;

    for (;;) {
        // --- 1. LÓGICA DE TEMPORIZADOR DA VÁLVULA ---
        if (g_valveState) {
            unsigned long agora = millis();
            if (agora >= g_valveOffTime) {
                Serial.println("[VALVULA] Tempo esgotado! Desligando pino 2.");
                digitalWrite(PIN_VALVE, LOW);
                g_valveState = false;
            } else {
                // Debug periódico se estiver regando
                if (agora % 5000 < 20) { 
                    Serial.printf("[VALVULA] Regando... Falta %lu ms\n", g_valveOffTime - agora);
                }
            }
        }

        // --- 2. GERENCIAMENTO DE CONEXÃO ---
        if (WiFi.status() != WL_CONNECTED) {
            Serial.println("[NET] Wi-Fi caiu! Tentando reconectar...");
            g_wifiConnected = false;
            g_mqttConnected = false;
            WiFi.disconnect(); WiFi.reconnect();
            vTaskDelay(pdMS_TO_TICKS(2000)); 
        } else {
            if (!g_wifiConnected) {
                g_wifiConnected = true;
                Serial.println("[NET] Wi-Fi Conectado!");
                syncTimeWithNTP();
                lastNtpAttempt = millis();
            }
            // Verifica NTP periodicamente
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
                    // Inscreve no tópico para receber comandos
                    client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
                    Serial.printf("[AWS] Inscrito no tópico: %s\n", AWS_IOT_SUBSCRIBE_TOPIC);
                } else {
                    Serial.printf("FALHA (rc=%d)\n", client.state());
                    g_mqttConnected = false;
                    vTaskDelay(pdMS_TO_TICKS(1000)); 
                }
            } else {
                client.loop(); // Mantém a comunicação viva
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
 * Mostra dados em carrossel.
 * Prioridade: Mostrar estado da Válvula se estiver ligada.
 */
void taskDisplay(void *pvParameters) {
    int screen = 0;
    for (;;) {
        TelemetryData localData;
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
            localData = g_latestData;
            xSemaphoreGive(dataMutex);
        }

        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            display.clearDisplay();
            display.setTextColor(WHITE);
            
            DateTime nowUTC = rtc.now();
            DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
            
            // HEADER (Barra Superior)
            display.setTextSize(1);
            display.setCursor(0, 0);
            display.printf("%02d:%02d", nowBRT.hour(), nowBRT.minute());
            
            // INDICADOR DE VÁLVULA (Prioridade Máxima)
            display.setCursor(40, 0);
            if (g_valveState) {
                // Se estiver regando, mostra aviso piscante/claro
                display.print("REGANDO!"); 
            } else {
                display.print("W:");
                display.print(g_wifiConnected ? "OK" : "X");
            }
            
            display.drawLine(0, 9, 128, 9, WHITE);
            
            // CARROSSEL DE TELAS
            display.setCursor(0, 15);
            switch (screen) {
                case 0: // STATUS
                    display.println("SISTEMA V5:");
                    display.printf("AWS MQTT: %s\n", g_mqttConnected ? "ON" : "OFF");
                    display.printf("SD CARD:  %s\n", g_sdOk ? "OK" : "ERRO");
                    display.printf("VALVULA:  %s", g_valveState ? "ATIVO" : "OFF");
                    break;
                case 1: // AR
                    display.setTextSize(2); display.printf("%.1f C\n", localData.air_temp);
                    display.setTextSize(1); display.printf("Um: %.0f%% UV: %.1f", localData.air_hum, localData.uv_index);
                    break;
                case 2: // SOLO
                    display.setTextSize(1); display.println("SOLO / LUZ:");
                    display.setTextSize(2); display.printf("%d%%\n", localData.soil_moisture);
                    display.setTextSize(1); display.printf("Lz:%d%% Ch:%d", localData.light_level, localData.rain_raw);
                    break;
            }
            display.display();
            xSemaphoreGive(i2cMutex);
        }
        vTaskDelay(pdMS_TO_TICKS(OLED_SWITCH_MS));
        screen++; if (screen > 2) screen = 0;
    }
}

// ===================================================================================
// 7. SETUP
// ===================================================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n\n=== AGROSMART V5.14 INICIANDO ===");
    Serial.println("Configuração: PINO VALVULA = GPIO 2 | FILTRO = DEVICE_ID");

    // Inicializa Semáforos
    i2cMutex = xSemaphoreCreateMutex();
    dataMutex = xSemaphoreCreateMutex(); 

    // Configura Pinos
    analogReadResolution(12);       
    pinMode(PIN_SOLO, INPUT);
    pinMode(PIN_CHUVA, INPUT);
    pinMode(PIN_LUZ, INPUT);
    pinMode(PIN_UV, INPUT);
    
    // Configura Válvula
    pinMode(PIN_VALVE, OUTPUT);
    digitalWrite(PIN_VALVE, LOW); // Começa desligado
    Serial.println("[IO] Pinos configurados.");

    // Configura Periféricos
    Wire.begin(21, 22);
    if(!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) Serial.println("[ERRO] OLED Falhou");
    else { display.clearDisplay(); display.display(); }
    
    if(!rtc.begin()) Serial.println("[ERRO] RTC Falhou");
    if(!aht.begin()) Serial.println("[ERRO] AHT10 Falhou");

    // Configura SD
    SPI.begin(18, 19, 23, 5);
    if (SD.begin(5, SPI, 4000000)) {
        g_sdOk = true;
        Serial.println("[SD] Cartão Iniciado.");
        if (!SD.exists(LOG_FILENAME)) {
            File f = SD.open(LOG_FILENAME, FILE_WRITE);
            if(f) {
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