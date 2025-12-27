/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: Dezembro/2025
 * VERSÃO: 5.10 (Stable Rollback + Configurable Intervals)
 * ===================================================================================
 * DESCRIÇÃO:
 * Versão focada em ESTABILIDADE MÁXIMA.
 * Retornamos à lógica de conexão única (Single Wi-Fi) que provou ser confiável.
 * Adicionamos configurações fáceis para intervalos de leitura e display.
 * ===================================================================================
 */

#include <Arduino.h>
#include <Wire.h>               // Comunicação I2C (Display e Sensores)
#include <SPI.h>                // Comunicação SPI (Cartão SD)
#include <SD.h>                 // Biblioteca do Cartão SD
#include <RTClib.h>             // Relógio em Tempo Real (DS3231)
#include <Adafruit_AHTX0.h>     // Sensor Temperatura/Umidade
#include <Adafruit_GFX.h>       // Gráficos básicos
#include <Adafruit_SSD1306.h>   // Driver do OLED
#include <WiFiClientSecure.h>   // Conexão Segura (SSL)
#include <PubSubClient.h>       // Protocolo MQTT (AWS)
#include <ArduinoJson.h>        // Formatação de Dados JSON
#include "secrets.h"            // Suas senhas e chaves

// ===================================================================================
// 1. CONFIGURAÇÕES DO USUÁRIO (AJUSTE AQUI)
// ===================================================================================

// INTERVALO DE LEITURA E ENVIO (em milissegundos)
// Exemplo: 60000 = 1 minuto. 300000 = 5 minutos.
const uint32_t TELEMETRY_INTERVAL_MS = 60000; 

// VELOCIDADE DO CARROSSEL DO DISPLAY (em milissegundos)
// Tempo que cada tela fica visível antes de trocar.
const uint32_t OLED_SWITCH_MS = 3000; 

// FUSO HORÁRIO PARA VISUALIZAÇÃO (em segundos)
// -10800 segundos = -3 Horas (Horário de Brasília)
const long BRT_OFFSET_SEC = -10800; 

// ===================================================================================
// 2. HARDWARE E PINOS
// ===================================================================================
#define SD_CS_PIN  5   // Pino Chip Select do SD
#define PIN_SOLO   34  // Sensor Capacitivo Solo
#define PIN_CHUVA  35  // Sensor Chuva
#define PIN_UV     32  // Sensor UV
#define PIN_LUZ    33  // Sensor LDR

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define I2C_MUTEX_WAIT_MS 200 // Tempo limite para esperar o barramento I2C

// Configurações de Tempo (Servidor NTP)
const char* NTP_SERVER = "pool.ntp.org";
const long  GMT_OFFSET_SEC = 0; // O sistema roda sempre em UTC (Padrão Mundial)
const int   DAYLIGHT_OFFSET_SEC = 0;

// Nome do arquivo de log no cartão SD
const char* LOG_FILENAME = "/telemetry_v5.csv";

// ===================================================================================
// 3. ESTRUTURAS DE DADOS
// ===================================================================================
// Pacote que carrega todas as informações de uma leitura
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
// 4. OBJETOS GLOBAIS E CONTROLE DO SISTEMA
// ===================================================================================
RTC_DS3231 rtc;
Adafruit_AHTX0 aht;
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

WiFiClientSecure net;
PubSubClient client(net);

// Variáveis de Estado (Para saber o que mostrar no display)
bool g_wifiConnected = false;
bool g_mqttConnected = false;
bool g_sdOk = false;
bool g_timeSynced = false; 

// Memória Compartilhada (Para o display ler o dado mais recente)
TelemetryData g_latestData;

// Ferramentas do Sistema Operacional (FreeRTOS)
QueueHandle_t sensorQueue;   // Fila de mensagens
SemaphoreHandle_t i2cMutex;  // Proteção do Display/Sensor
SemaphoreHandle_t dataMutex; // Proteção da variável g_latestData

// ===================================================================================
// 5. FUNÇÕES AUXILIARES
// ===================================================================================

// Obtém a hora atual do RTC de forma segura
DateTime getSystemTime() {
    if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
        DateTime now = rtc.now();
        xSemaphoreGive(i2cMutex);
        return now;
    }
    return DateTime((uint32_t)0); 
}

// Sincroniza o relógio com a internet (NTP)
void syncTimeWithNTP() {
    Serial.println("[TIME] Buscando hora na internet...");
    configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);
    
    struct tm timeinfo;
    int retry = 0;
    // Tenta por 5 segundos
    while (!getLocalTime(&timeinfo, 1000) && retry < 5) {
        Serial.print(".");
        retry++;
    }
    Serial.println();

    if (retry < 5) { 
        // Se conseguiu, atualiza o módulo RTC físico
        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            rtc.adjust(DateTime(timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
                                timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec));
            xSemaphoreGive(i2cMutex);
            g_timeSynced = true;
            Serial.println("[TIME] Sucesso! Relógio Sincronizado.");
        }
    } else {
        Serial.println("[TIME] Falha no NTP. Usando horário interno do RTC.");
    }
}

// ===================================================================================
// 6. TAREFAS (O CORAÇÃO DO SISTEMA)
// ===================================================================================

// --- TAREFA 1: LEITURA DE SENSORES ---
// Roda periodicamente baseada na variável TELEMETRY_INTERVAL_MS
void taskSensors(void *pvParameters) {
    for (;;) {
        TelemetryData data;
        
        Serial.println("\n--------------------------------");
        Serial.println("[SENSORS] Iniciando leitura...");

        // 1. Pega Hora UTC
        DateTime nowUTC = getSystemTime();
        data.timestamp = nowUTC.unixtime();

        // 2. Lê AHT10 (Protegido por Mutex)
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

        // 3. Lê Sensores Analógicos
        // Mapeia de 3000(seco)-1200(molhado) para 0-100%
        int rawSolo = analogRead(PIN_SOLO);
        data.soil_moisture = constrain(map(rawSolo, 3000, 1200, 0, 100), 0, 100);

        int rawLuz = analogRead(PIN_LUZ);
        data.light_level = map(rawLuz, 0, 4095, 0, 100);

        data.rain_raw = analogRead(PIN_CHUVA);

        // 4. Média do UV (para estabilidade)
        long somaUV = 0;
        for(int i=0; i<16; i++) { somaUV += analogRead(PIN_UV); vTaskDelay(pdMS_TO_TICKS(1)); }
        float voltagemUV = ((somaUV / 16) * 3.3) / 4095.0;
        float idx = voltagemUV / 0.1;
        data.uv_index = (idx < 0.2) ? 0.0 : idx;

        // 5. Debug no Terminal (Mostra hora Brasil)
        DateTime nowBRT = DateTime(nowUTC.unixtime() + BRT_OFFSET_SEC);
        Serial.printf("[LEITURA BRT] %02d:%02d:%02d\n", nowBRT.hour(), nowBRT.minute(), nowBRT.second());
        Serial.printf("Dados: Temp:%.1f Solo:%d Luz:%d\n", data.air_temp, data.soil_moisture, data.light_level);

        // 6. Atualiza variável para o Display
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(100))) {
            g_latestData = data;
            xSemaphoreGive(dataMutex);
        }

        // 7. Envia para a Fila (Para ser salvo/enviado)
        xQueueSend(sensorQueue, &data, 0);

        // Aguarda o tempo definido pelo usuário
        vTaskDelay(pdMS_TO_TICKS(TELEMETRY_INTERVAL_MS));
    }
}

// --- TAREFA 2: REDE E ARMAZENAMENTO ---
// Gerencia Wi-Fi, AWS IoT e Cartão SD
void taskNetworkStorage(void *pvParameters) {
    // Carrega certificados da AWS
    net.setCACert(AWS_CERT_CA);
    net.setCertificate(AWS_CERT_CRT);
    net.setPrivateKey(AWS_CERT_PRIVATE);
    client.setServer(AWS_IOT_ENDPOINT, 8883);

    TelemetryData receivedData;
    unsigned long lastNtpAttempt = 0;

    for (;;) {
        // A. Gerenciamento de Wi-Fi (Reconexão Simples)
        if (WiFi.status() != WL_CONNECTED) {
            g_wifiConnected = false;
            g_mqttConnected = false;
            
            // Tenta reconectar na rede configurada
            WiFi.disconnect();
            WiFi.reconnect();
            vTaskDelay(pdMS_TO_TICKS(2000)); 
        } else {
            // Wi-Fi está OK!
            if (!g_wifiConnected) {
                g_wifiConnected = true;
                syncTimeWithNTP(); // Sincroniza hora ao conectar
                lastNtpAttempt = millis();
            }
            
            // Verifica se precisa ressincronizar hora (a cada 1 minuto se estiver desatualizado)
            if (!g_timeSynced && (millis() - lastNtpAttempt > 60000)) {
                syncTimeWithNTP();
                lastNtpAttempt = millis();
            }
        }

        // B. Gerenciamento MQTT (AWS)
        if (g_wifiConnected) {
            if (!client.connected()) {
                // Tenta conectar na AWS
                if (client.connect(THINGNAME)) {
                    g_mqttConnected = true;
                    client.subscribe(AWS_IOT_SUBSCRIBE_TOPIC);
                    Serial.println("[AWS] Conectado!");
                } else {
                    g_mqttConnected = false;
                    vTaskDelay(pdMS_TO_TICKS(1000)); 
                }
            } else {
                client.loop(); // Mantém conexão viva
            }
        }

        // C. Processamento de Dados (Se houver algo na fila)
        if (xQueueReceive(sensorQueue, &receivedData, pdMS_TO_TICKS(100)) == pdPASS) {
            bool sentToAws = false;
            
            // 1. Tenta enviar para AWS
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
                    Serial.println("[AWS] >> Enviado com sucesso.");
                    sentToAws = true;
                }
            } else {
                Serial.println("[AWS] -- Offline. Salvando localmente.");
            }

            // 2. Salva no Cartão SD (Backup Garantido)
            if (g_sdOk) {
                File file = SD.open(LOG_FILENAME, FILE_APPEND);
                if (file) {
                    file.printf("%lu,%.1f,%.0f,%d,%d,%d,%.2f,%s\n",
                                receivedData.timestamp,
                                receivedData.air_temp, receivedData.air_hum,
                                receivedData.soil_moisture, receivedData.light_level,
                                receivedData.rain_raw, receivedData.uv_index,
                                sentToAws ? "SENT" : "PENDING"); 
                    file.close();
                    Serial.println("[SD] Log salvo.");
                } else {
                    Serial.println("[SD] Erro ao gravar no cartão.");
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(10)); // Pequena pausa para o Watchdog
    }
}

// --- TAREFA 3: DISPLAY OLED (CARROSSEL) ---
// Mostra informações rotativas para o usuário
void taskDisplay(void *pvParameters) {
    int screenState = 0; 
    
    for (;;) {
        TelemetryData localData;
        
        // Pega dados da memória compartilhada de forma segura
        if (xSemaphoreTake(dataMutex, pdMS_TO_TICKS(50))) {
            localData = g_latestData;
            xSemaphoreGive(dataMutex);
        }

        // Atualiza a tela (Protegido pelo Mutex I2C)
        if (xSemaphoreTake(i2cMutex, pdMS_TO_TICKS(I2C_MUTEX_WAIT_MS))) {
            display.clearDisplay();
            display.setTextColor(WHITE);
            
            // --- Barra de Status ---
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

            // --- Carrossel de Informações ---
            display.setCursor(0, 15);
            switch (screenState) {
                case 0: // TELA 1: Status Geral
                    display.println("STATUS:");
                    display.printf("AWS: %s\n", g_mqttConnected ? "CONECTADO" : "OFFLINE");
                    display.printf("NTP: %s\n", g_timeSynced ? "SINC" : "RTC");
                    break;

                case 1: // TELA 2: Clima (Ar)
                    display.setTextSize(2);
                    display.printf("%.1f C\n", localData.air_temp);
                    display.setTextSize(1);
                    display.printf("Umid Ar: %.0f%%\n", localData.air_hum);
                    display.printf("UV Index: %.1f", localData.uv_index);
                    break;

                case 2: // TELA 3: Solo e Luz
                    display.setTextSize(1);
                    display.println("SOLO / LUZ:");
                    display.setTextSize(2);
                    display.printf("%d%%\n", localData.soil_moisture);
                    display.setTextSize(1);
                    display.printf("Luz Amb: %d%%\n", localData.light_level);
                    display.printf("Chuva: %d", localData.rain_raw);
                    break;
            }

            // Paginação (1/3, 2/3...)
            display.setCursor(110, 55);
            display.printf("%d/3", screenState + 1);

            display.display();
            xSemaphoreGive(i2cMutex);
        }
        
        // Espera o tempo configurado antes de trocar de tela
        vTaskDelay(pdMS_TO_TICKS(OLED_SWITCH_MS));
        
        screenState++;
        if (screenState > 2) screenState = 0;
    }
}

// ===================================================================================
// 6. SETUP (INICIALIZAÇÃO)
// ===================================================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n\n=== AGROSMART V5.10 BOOTING (STABLE ROLLBACK) ===");

    // Cria os "Semáforos" para evitar conflitos entre tarefas
    i2cMutex = xSemaphoreCreateMutex();
    dataMutex = xSemaphoreCreateMutex(); 

    // Configura os pinos dos sensores
    analogReadResolution(12);       
    pinMode(PIN_SOLO, INPUT);
    pinMode(PIN_CHUVA, INPUT);
    pinMode(PIN_LUZ, INPUT);
    pinMode(PIN_UV, INPUT);

    Wire.begin(21, 22);

    // Inicializa Display e Sensores I2C
    if(!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) Serial.println("[ERR] OLED Falhou");
    else { display.clearDisplay(); display.display(); }
    
    if(!rtc.begin()) Serial.println("[ERR] RTC Falhou");
    if(!aht.begin()) Serial.println("[ERR] AHT10 Falhou");

    // Inicializa Cartão SD
    SPI.begin(18, 19, 23, 5);
    if (SD.begin(SD_CS_PIN, SPI, 4000000)) {
        g_sdOk = true;
        
        // Se o arquivo não existir, cria o cabeçalho CSV
        if (!SD.exists(LOG_FILENAME)) {
            File file = SD.open(LOG_FILENAME, FILE_WRITE);
            if (file) {
                file.println("Timestamp_Unix,Temp_Ar_C,Umid_Ar_%,Solo_%,Luz_%,Chuva_Raw,UV_Index,Status_Envio");
                file.close();
                Serial.println("[SD] Novo arquivo criado.");
            }
        }
    } else {
        Serial.println("[ERR] SD Card não detectado");
    }

    // Inicia conexão Wi-Fi
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    // Cria fila de mensagens (Buffer para 10 leituras)
    sensorQueue = xQueueCreate(10, sizeof(TelemetryData));

    // Inicia as Tarefas do Sistema
    xTaskCreate(taskDisplay, "Display", 4096, NULL, 1, NULL);
    xTaskCreate(taskNetworkStorage, "Net", 8192, NULL, 2, NULL);
    xTaskCreate(taskSensors, "Sensors", 4096, NULL, 3, NULL);

    Serial.println("[BOOT] Sistema Iniciado com Sucesso.");
}

void loop() {
    // O loop fica vazio pois usamos o FreeRTOS para gerenciar as tarefas
    vTaskDelete(NULL);
}