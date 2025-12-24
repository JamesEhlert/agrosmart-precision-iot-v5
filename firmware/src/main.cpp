/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM (V5.0)
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: Dezembro/2025
 * VERSÃO: 5.4 (CSV Headers Fix & Full Monitoring)
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
// 1. CONFIGURAÇÕES & HARDWARE
// ===================================================================================
#define SD_CS_PIN  5
#define PIN_SOLO   34
#define PIN_CHUVA  35
#define PIN_UV     32
#define PIN_LUZ    33

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define I2C_MUTEX_WAIT_MS 200 

// Configurações de Tempo
const char* NTP_SERVER = "pool.ntp.org";
const long  GMT_OFFSET_SEC = 0; // UTC no Backend
const int   DAYLIGHT_OFFSET_SEC = 0;
const long  BRT_OFFSET_SEC = -10800; // -3 Horas (Apenas visualização)

// Nome do arquivo de log
const char* LOG_FILENAME = "/telemetry_v5.csv";

// ===================================================================================
// 2. ESTRUTURA DE DADOS
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

// ===================================================================================
// 3. OBJETOS GLOBAIS & RTOS HANDLERS
// ===================================================================================
RTC_DS3231 rtc;
Adafruit_AHTX0 aht;
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

WiFiClientSecure net;
PubSubClient client(net);

// Estado Global (Protegido)
bool g_wifiConnected = false;
bool g_mqttConnected = false;
bool g_sdOk = false;
bool g_timeSynced = false; 

// Dados mais recentes para o Display (Memória Compartilhada)
TelemetryData g_latestData;

// RTOS Handles
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
    Serial.println("[TIME] Tentando NTP...");
    configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);
    
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
            Serial.println("[TIME] SUCESSO! RTC Sincronizado (UTC).");
        }
    } else {
        Serial.println("[TIME] Timeout NTP. Usando RTC.");
    }
}

// ===================================================================================
// 5. TAREFAS (TASKS)
// ===================================================================================

// --- TAREFA 1: LEITURA DE SENSORES ---
void taskSensors(void *pvParameters) {
    for (;;) {
        TelemetryData data;
        
        Serial.println("\n--------------------------------");
        Serial.println("[SENSORS] Lendo sensores...");

        // 1. Hora
        DateTime nowUTC = getSystemTime();
        data.timestamp = nowUTC.unixtime();

        // 2. I2C (AHT10)
        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            sensors_event_t humidity, temp;
            if (aht.getEvent(&humidity, &temp)) {
                data.air_temp = temp.temperature;
                data.air_hum = humidity.relative_humidity;
            } else {
                data.air_temp = 0.0; data.air_hum = 0.0;
            }
            xSemaphoreGive(i2cMutex);
        }

        // 3. Analógicos
        int rawSolo = analogRead(PIN_SOLO);
        data.soil_moisture = constrain(map(rawSolo, 3000, 1200, 0, 100), 0, 100);

        int rawLuz = analogRead(PIN_LUZ);
        data.light_level = map(rawLuz, 0, 4095, 0, 100);

        data.rain_raw = analogRead(PIN_CHUVA);

        // UV
        long somaUV = 0;
        for(int i=0; i<16; i++) { somaUV += analogRead(PIN_UV); vTaskDelay(pdMS_TO_TICKS(1)); }
        float voltagemUV = ((somaUV / 16) * 3.3) / 4095.0;
        float idx = voltagemUV / 0.1;
        data.uv_index = (idx < 0.2) ? 0.0 : idx;

        // --- DEBUG (BRT) ---
        DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
        Serial.printf("[TIME BRT] %02d/%02d/%04d %02d:%02d:%02d\n", 
                      nowBRT.day(), nowBRT.month(), nowBRT.year(), 
                      nowBRT.hour(), nowBRT.minute(), nowBRT.second());
                      
        Serial.printf("[DATA] Ar: %.1fC / %.0f%% | Solo: %d%%\n", 
                      data.air_temp, data.air_hum, data.soil_moisture);
        Serial.printf("[DATA] Luz: %d%% | UV: %.1f | Chuva: %d\n", 
                      data.light_level, data.uv_index, data.rain_raw);

        // Atualiza Memória Compartilhada
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(100))) {
            g_latestData = data;
            xSemaphoreGive(dataMutex);
        }

        // Envia para Fila
        xQueueSend(sensorQueue, &data, 0);

        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}

// --- TAREFA 2: REDE E ARMAZENAMENTO ---
void taskNetworkStorage(void *pvParameters) {
    // Configura AWS
    net.setCACert(AWS_CERT_CA);
    net.setCertificate(AWS_CERT_CRT);
    net.setPrivateKey(AWS_CERT_PRIVATE);
    client.setServer(AWS_IOT_ENDPOINT, 8883);

    TelemetryData receivedData;
    unsigned long lastNtpAttempt = 0;

    for (;;) {
        // Gestão Wi-Fi
        if (WiFi.status() != WL_CONNECTED) {
            g_wifiConnected = false;
            g_mqttConnected = false;
            WiFi.disconnect();
            WiFi.reconnect();
            vTaskDelay(pdMS_TO_TICKS(2000)); 
        } else {
            if (!g_wifiConnected) {
                g_wifiConnected = true;
                syncTimeWithNTP(); 
                lastNtpAttempt = millis();
            }
            if (!g_timeSynced && (millis() - lastNtpAttempt > 60000)) {
                syncTimeWithNTP();
                lastNtpAttempt = millis();
            }
        }

        // Gestão MQTT
        if (g_wifiConnected) {
            if (!client.connected()) {
                if (client.connect(THINGNAME)) {
                    g_mqttConnected = true;
                    client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
                } else {
                    g_mqttConnected = false;
                    vTaskDelay(pdMS_TO_TICKS(1000)); 
                }
            } else {
                client.loop(); 
            }
        }

        // Processamento de Dados
        if (xQueueReceive(sensorQueue, &receivedData, pdMS_TO_TICKS(100)) == pdPASS) {
            bool sentToAws = false;
            
            // AWS Envio
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

                char jsonBuffer[512];
                serializeJson(doc, jsonBuffer);
                
                if (client.publish(AWS_IOT_PUBLISH_TOPIC, jsonBuffer)) {
                    Serial.println("[AWS] >> Enviado.");
                    sentToAws = true;
                }
            } else {
                Serial.println("[AWS] -- Offline.");
            }

            // SD Backup (Datalogging)
            if (g_sdOk) {
                File file = SD.open(LOG_FILENAME, FILE_APPEND);
                if (file) {
                    // Formato: UNIX, Temp, Umid, Solo, Luz, Chuva, UV, Status
                    file.printf("%lu,%.1f,%.0f,%d,%d,%d,%.2f,%s\n",
                                receivedData.timestamp,
                                receivedData.air_temp, receivedData.air_hum,
                                receivedData.soil_moisture, receivedData.light_level,
                                receivedData.rain_raw, receivedData.uv_index,
                                sentToAws ? "SENT" : "PENDING"); 
                    file.close();
                    Serial.println("[SD] Log salvo.");
                } else {
                    Serial.println("[SD] Erro escrita.");
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

// --- TAREFA 3: DISPLAY OLED (CARROSSEL) ---
void taskDisplay(void *pvParameters) {
    int screenState = 0; 
    
    for (;;) {
        TelemetryData localData;
        bool hasData = false;
        
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
            localData = g_latestData;
            hasData = true;
            xSemaphoreGive(dataMutex);
        }

        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            display.clearDisplay();
            display.setTextColor(WHITE);
            
            // Status Bar
            DateTime nowUTC = rtc.now();
            DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
            
            display.setTextSize(1);
            display.setCursor(0, 0);
            display.printf("%02d:%02d", nowBRT.hour(), nowBRT.minute());
            
            display.setCursor(45, 0);
            display.printf("W:%s", g_wifiConnected ? "OK" : ".");
            display.setCursor(85, 0);
            display.printf("SD:%s", g_sdOk ? "OK" : "X");
            display.drawLine(0, 9, 128, 9, WHITE);

            // Carrossel
            display.setCursor(0, 15);
            switch (screenState) {
                case 0: 
                    display.println("STATUS:");
                    display.printf("AWS: %s\n", g_mqttConnected ? "CONECTADO" : "OFFLINE");
                    display.printf("NTP: %s\n", g_timeSynced ? "SINC" : "RTC");
                    break;
                case 1: 
                    display.setTextSize(2);
                    display.printf("%.1f C\n", localData.air_temp);
                    display.setTextSize(1);
                    display.printf("Umid Ar: %.0f%%\n", localData.air_hum);
                    display.printf("UV Index: %.1f", localData.uv_index);
                    break;
                case 2: 
                    display.setTextSize(1);
                    display.println("SOLO / LUZ:");
                    display.setTextSize(2);
                    display.printf("%d%%\n", localData.soil_moisture);
                    display.setTextSize(1);
                    display.printf("Luz Amb: %d%%\n", localData.light_level);
                    display.printf("Chuva: %d", localData.rain_raw);
                    break;
            }
            display.setCursor(110, 55);
            display.printf("%d/3", screenState + 1);
            display.display();
            xSemaphoreGive(i2cMutex);
        }
        vTaskDelay(pdMS_TO_TICKS(3000));
        screenState++;
        if (screenState > 2) screenState = 0;
    }
}

// ===================================================================================
// 6. SETUP & MAIN
// ===================================================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n\n=== AGROSMART V5.4 BOOTING ===");

    i2cMutex = xSemaphoreCreateMutex();
    dataMutex = xSemaphoreCreateMutex(); 

    analogReadResolution(12);       
    pinMode(PIN_SOLO, INPUT);
    pinMode(PIN_CHUVA, INPUT);
    pinMode(PIN_LUZ, INPUT);
    pinMode(PIN_UV, INPUT);

    Wire.begin(21, 22);

    if(!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) Serial.println("[ERR] OLED");
    else { display.clearDisplay(); display.display(); }
    
    if(!rtc.begin()) Serial.println("[ERR] RTC");
    if(!aht.begin()) Serial.println("[ERR] AHT10");

    SPI.begin(18, 19, 23, 5);
    if (SD.begin(SD_CS_PIN, SPI, 4000000)) {
        g_sdOk = true;
        
        // --- CORREÇÃO DO CSV AQUI ---
        // Se o arquivo não existir, cria e escreve o cabeçalho.
        if (!SD.exists(LOG_FILENAME)) {
            File file = SD.open(LOG_FILENAME, FILE_WRITE);
            if (file) {
                // Escreve os nomes das colunas para facilitar leitura no Excel/LibreOffice
                file.println("Timestamp_Unix,Temp_Ar_C,Umid_Ar_%,Solo_%,Luz_%,Chuva_Raw,UV_Index,Status_Envio");
                file.close();
                Serial.println("[SD] Novo arquivo criado com cabeçalhos.");
            } else {
                Serial.println("[SD] Erro ao criar arquivo.");
            }
        }
    } else {
        Serial.println("[ERR] SD Card");
    }

    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    sensorQueue = xQueueCreate(10, sizeof(TelemetryData));

    xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
    xTaskCreate(taskNetworkStorage, "Net", 8192, NULL, 2, NULL);
    xTaskCreate(taskSensors, "Sensors", 4096, NULL, 3, NULL);

    Serial.println("[BOOT] Sistema Iniciado.");
}

void loop() {
    vTaskDelete(NULL);
}