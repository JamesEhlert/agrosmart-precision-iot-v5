/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM (V5.0)
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: Dezembro/2025
 * VERSÃO: 5.5 (Multi-WiFi + User Config + Optimization)
 * ===================================================================================
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
#include "secrets.h" 

// ===================================================================================
// 1. USER SETTINGS (CONFIGURAÇÕES DO USUÁRIO)
// ===================================================================================

// Intervalo de envio para a Nuvem/SD (em milissegundos)
// 60000 ms = 1 minuto
const uint32_t TELEMETRY_INTERVAL_MS = 30000; 

// Velocidade de troca das telas do OLED (em milissegundos)
// 2000 ms = 2 segundos (Recomendado para dar tempo de ler)
const uint32_t OLED_SWITCH_MS = 1000; 

// Diferença de Fuso Horário para visualização (Brasil = -3h)
const long BRT_OFFSET_SEC = -10800; 

// ===================================================================================
// 2. HARDWARE PINS & CONSTANTS
// ===================================================================================
#define SD_CS_PIN  5
#define PIN_SOLO   34
#define PIN_CHUVA  35
#define PIN_UV     32
#define PIN_LUZ    33

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define I2C_MUTEX_WAIT_MS 200 

const char* LOG_FILENAME = "/telemetry_v5.csv";

// ===================================================================================
// 3. ESTRUTURAS & GLOBAIS
// ===================================================================================
struct TelemetryData {
    uint32_t timestamp;
    float air_temp;
    float air_hum;
    int soil_moisture;
    int light_level;
    int rain_raw;
    float uv_index;
};

// Objetos de Hardware
RTC_DS3231 rtc;
Adafruit_AHTX0 aht;
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

// Objetos de Rede
WiFiClientSecure net;
PubSubClient client(net);

// Variáveis de Estado (Protegidas)
bool g_wifiConnected = false;
bool g_mqttConnected = false;
bool g_sdOk = false;
bool g_timeSynced = false; 
char g_currentSSID[32] = "Searching..."; // Para mostrar no OLED qual rede conectou

// Memória Compartilhada e Handles do RTOS
TelemetryData g_latestData;
QueueHandle_t sensorQueue;   
SemaphoreHandle_t i2cMutex;  
SemaphoreHandle_t dataMutex;

// ===================================================================================
// 4. FUNÇÕES AUXILIARES
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
    Serial.println("[TIME] Sincronizando NTP...");
    configTime(0, 0, "pool.ntp.org"); // UTC
    
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
            Serial.println("[TIME] RTC Atualizado (UTC).");
        }
    } else {
        Serial.println("[TIME] Falha NTP.");
    }
}

// Lógica inteligente para conectar no melhor Wi-Fi disponível
void connectMultiWiFi() {
    // Lista de redes (Vindo do secrets.h)
    const char* ssids[] = {WIFI_SSID_1, WIFI_SSID_2};
    const char* passw[] = {WIFI_PASS_1, WIFI_PASS_2};
    int networks = 2;

    WiFi.mode(WIFI_STA);
    
    for (int i = 0; i < networks; i++) {
        Serial.printf("[NET] Tentando conectar em: %s\n", ssids[i]);
        WiFi.begin(ssids[i], passw[i]);
        
        // Tenta por 10 segundos
        int attempts = 0;
        while (WiFi.status() != WL_CONNECTED && attempts < 20) {
            vTaskDelay(pdMS_TO_TICKS(500));
            attempts++;
        }

        if (WiFi.status() == WL_CONNECTED) {
            Serial.printf("[NET] Conectado a %s!\n", ssids[i]);
            strncpy(g_currentSSID, ssids[i], 31); // Salva nome para o Display
            g_wifiConnected = true;
            return; // Sucesso, sai da função
        } else {
            Serial.println("[NET] Falha. Tentando próxima...");
        }
    }
    
    Serial.println("[NET] Nenhuma rede disponível.");
    strcpy(g_currentSSID, "No Network");
    g_wifiConnected = false;
}

// ===================================================================================
// 5. TAREFAS (TASKS)
// ===================================================================================

// --- TAREFA 1: SENSORES (Produtor) ---
void taskSensors(void *pvParameters) {
    for (;;) {
        TelemetryData data;
        Serial.println("\n--- [LEITURA DE SENSORES] ---");

        // 1. Hora
        DateTime nowUTC = getSystemTime();
        data.timestamp = nowUTC.unixtime();

        // 2. I2C (AHT10)
        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            sensors_event_t h, t;
            if (aht.getEvent(&h, &t)) {
                data.air_temp = t.temperature;
                data.air_hum = h.relative_humidity;
            } else {
                data.air_temp = 0; data.air_hum = 0;
            }
            xSemaphoreGive(i2cMutex);
        }

        // 3. Analógicos
        data.soil_moisture = constrain(map(analogRead(PIN_SOLO), 3000, 1200, 0, 100), 0, 100);
        data.light_level = map(analogRead(PIN_LUZ), 0, 4095, 0, 100);
        data.rain_raw = analogRead(PIN_CHUVA);

        long somaUV = 0;
        for(int i=0; i<16; i++) { somaUV += analogRead(PIN_UV); vTaskDelay(pdMS_TO_TICKS(1)); }
        data.uv_index = (((somaUV/16)*3.3)/4095.0) / 0.1;
        if (data.uv_index < 0.2) data.uv_index = 0;

        // Atualiza Memória Global (Display)
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(100))) {
            g_latestData = data;
            xSemaphoreGive(dataMutex);
        }

        // Envia para Fila (AWS/SD)
        xQueueSend(sensorQueue, &data, 0);

        // DEBUG com Hora BRT
        DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
        Serial.printf("Time: %02d:%02d:%02d | Solo: %d%% | Luz: %d%%\n", 
                      nowBRT.hour(), nowBRT.minute(), nowBRT.second(), 
                      data.soil_moisture, data.light_level);

        // AGUARDA O TEMPO CONFIGURADO PELO USUÁRIO
        vTaskDelay(pdMS_TO_TICKS(TELEMETRY_INTERVAL_MS));
    }
}

// --- TAREFA 2: REDE E STORAGE (Consumidor) ---
void taskNetworkStorage(void *pvParameters) {
    net.setCACert(AWS_CERT_CA);
    net.setCertificate(AWS_CERT_CRT);
    net.setPrivateKey(AWS_CERT_PRIVATE);
    client.setServer(AWS_IOT_ENDPOINT, 8883);

    TelemetryData receivedData;
    unsigned long lastNtpAttempt = 0;

    for (;;) {
        // 1. Gerenciamento de Conexão (Redundância)
        if (WiFi.status() != WL_CONNECTED) {
            g_wifiConnected = false;
            g_mqttConnected = false;
            connectMultiWiFi(); // Tenta conectar em alguma das redes
        } else {
            // Se está conectado no Wi-Fi, verifica NTP e MQTT
            if (!g_timeSynced && (millis() - lastNtpAttempt > 60000)) {
                syncTimeWithNTP();
                lastNtpAttempt = millis();
            }

            if (!client.connected()) {
                if (client.connect(THINGNAME)) {
                    g_mqttConnected = true;
                    client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
                    Serial.println("[AWS] Conectado!");
                } else {
                    g_mqttConnected = false;
                    vTaskDelay(pdMS_TO_TICKS(1000));
                }
            } else {
                client.loop();
            }
        }

        // 2. Processamento da Fila
        if (xQueueReceive(sensorQueue, &receivedData, pdMS_TO_TICKS(100)) == pdPASS) {
            bool sent = false;
            
            // AWS
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
                    Serial.println("[AWS] Pacote enviado.");
                    sent = true;
                }
            }

            // SD
            if (g_sdOk) {
                File f = SD.open(LOG_FILENAME, FILE_APPEND);
                if (f) {
                    f.printf("%lu,%.1f,%.0f,%d,%d,%d,%.2f,%s\n",
                             receivedData.timestamp, receivedData.air_temp, receivedData.air_hum,
                             receivedData.soil_moisture, receivedData.light_level, receivedData.rain_raw,
                             receivedData.uv_index, sent ? "SENT" : "PENDING");
                    f.close();
                    Serial.println("[SD] Backup salvo.");
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

// --- TAREFA 3: DISPLAY (Visualizador) ---
void taskDisplay(void *pvParameters) {
    int screen = 0;
    
    for (;;) {
        TelemetryData d;
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
            d = g_latestData;
            xSemaphoreGive(dataMutex);
        }

        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            display.clearDisplay();
            display.setTextColor(WHITE);
            
            // Top Bar
            DateTime nowUTC = rtc.now();
            DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
            display.setTextSize(1);
            display.setCursor(0,0); 
            display.printf("%02d:%02d", nowBRT.hour(), nowBRT.minute());
            
            // Icons
            display.setCursor(40,0); display.printf(g_wifiConnected ? "Wi:OK" : "Wi:--");
            display.setCursor(85,0); display.printf(g_sdOk ? "SD:OK" : "SD:X");
            display.drawLine(0,9,128,9,WHITE);

            // Carousel
            display.setCursor(0,15);
            switch(screen) {
                case 0: // INFO REDE
                    display.println("REDE:");
                    display.printf("SSID: %s\n", g_currentSSID);
                    display.printf("AWS: %s", g_mqttConnected ? "ON" : "OFF");
                    break;
                case 1: // INFO AR
                    display.setTextSize(2); display.printf("%.1f C\n", d.air_temp);
                    display.setTextSize(1); display.printf("Umid: %.0f%%\n", d.air_hum);
                    display.printf("UV: %.1f", d.uv_index);
                    break;
                case 2: // INFO SOLO/LUZ
                    display.println("AMBIENTE:");
                    display.setTextSize(2); display.printf("S:%d%%\n", d.soil_moisture);
                    display.setTextSize(1); display.printf("Luz: %d%% Chv:%d", d.light_level, d.rain_raw);
                    break;
            }
            
            display.display();
            xSemaphoreGive(i2cMutex);
        }

        // AGUARDA O TEMPO CONFIGURADO PELO USUÁRIO (VELOCIDADE CARROSSEL)
        vTaskDelay(pdMS_TO_TICKS(OLED_SWITCH_MS));
        
        screen++;
        if (screen > 2) screen = 0;
    }
}

// ===================================================================================
// 6. SETUP
// ===================================================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n=== AGROSMART V5.5 BOOTING (Multi-WiFi + Config) ===");

    i2cMutex = xSemaphoreCreateMutex();
    dataMutex = xSemaphoreCreateMutex();

    pinMode(PIN_SOLO, INPUT);
    pinMode(PIN_CHUVA, INPUT);
    pinMode(PIN_LUZ, INPUT);
    pinMode(PIN_UV, INPUT);
    analogReadResolution(12);

    Wire.begin(21, 22);

    if(!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) Serial.println("Err OLED");
    else { display.clearDisplay(); display.display(); }
    if(!rtc.begin()) Serial.println("Err RTC");
    if(!aht.begin()) Serial.println("Err AHT10");

    SPI.begin(18, 19, 23, 5);
    if (SD.begin(SD_CS_PIN, SPI, 4000000)) {
        g_sdOk = true;
        if (!SD.exists(LOG_FILENAME)) {
            File f = SD.open(LOG_FILENAME, FILE_WRITE);
            if(f) {
                f.println("Timestamp,Temp,Umid,Solo,Luz,Chuva,UV,Status");
                f.close();
            }
        }
    }

    sensorQueue = xQueueCreate(10, sizeof(TelemetryData));

    // Inicia Tasks
    xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
    xTaskCreate(taskNetworkStorage, "Net", 8192, NULL, 2, NULL);
    xTaskCreate(taskSensors, "Sensors", 4096, NULL, 3, NULL);
    
    Serial.println("Tasks Started.");
}

void loop() { vTaskDelete(NULL); }