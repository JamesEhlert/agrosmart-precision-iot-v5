/**
 * ===================================================================================
 * NOME DO PROJETO: AGROSMART PRECISION SYSTEM (V5.0)
 * ===================================================================================
 * AUTOR: James Rafael Ehlert
 * DATA: Dezembro/2025
 * HARDWARE: ESP32-WROOM-32 + AHT10 + Capacitivo + Chuva + LDR + UV + RTC + SD
 * * DESCRIÇÃO:
 * Firmware base V5. Responsável pela leitura dos sensores ambientais,
 * exibição no OLED e datalogging local no Cartão SD (CSV).
 * * NOTA:
 * Esta versão foca na integração de hardware (Offline).
 * Conectividade AWS/MQTT será adicionada na próxima etapa.
 * ===================================================================================
 */

#include <Arduino.h>
#include <Wire.h>               // Comunicação I2C
#include <SPI.h>                // Comunicação SPI (para SD Card)
#include <SD.h>                 // Biblioteca do Sistema de Arquivos SD
#include <RTClib.h>             // Biblioteca do Relógio (DS3231)
#include <Adafruit_AHTX0.h>     // Sensor de Temp/Umid (AHT10)
#include <Adafruit_GFX.h>       // Biblioteca Gráfica Base
#include <Adafruit_SSD1306.h>   // Driver do Display OLED

// ===================================================================================
// 1. DEFINIÇÃO DE HARDWARE E PINOS
// ===================================================================================

// Pino Chip Select (CS) do módulo SD Card
#define SD_CS_PIN  5

// Entradas Analógicas (ADC1 - Seguras para usar com Wi-Fi)
#define PIN_SOLO   34  // Sensor Capacitivo
#define PIN_CHUVA  35  // Sensor Resistivo Chuva
#define PIN_UV     32  // Sensor UV GUVA-S12SD
#define PIN_LUZ    33  // Sensor LDR Luz

// Configurações do Display OLED
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET    -1 
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

// ===================================================================================
// 2. PARÂMETROS E OBJETOS
// ===================================================================================

// Calibração do Sensor de Solo (Experimental)
const int SOLO_SECO = 3000; 
const int SOLO_AGUA = 1200; 

// Arquivo de Log Local
const char* LOG_FILENAME = "/telemetry_v5.csv"; 

bool g_sdCardOk = false;

RTC_DS3231 rtc;
Adafruit_AHTX0 aht;

// ===================================================================================
// 3. SETUP
// ===================================================================================
void setup() {
  Serial.begin(115200);
  
  // Configuração ADC (ESP32)
  analogReadResolution(12);       
  analogSetAttenuation(ADC_11db); 
  
  pinMode(PIN_SOLO, INPUT);
  pinMode(PIN_CHUVA, INPUT);
  pinMode(PIN_LUZ, INPUT);
  pinMode(PIN_UV, INPUT);

  delay(1000);
  Serial.println("\n=== AGROSMART V5 SYSTEM STARTING ===");

  // Inicializa OLED
  if(!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) { 
    Serial.println("[ERROR] OLED Display not found!");
  } else {
    display.clearDisplay();
    display.setTextColor(WHITE);
    display.setTextSize(1);
    display.setCursor(10,20);
    display.println("Booting V5...");
    display.display();
  }

  // Inicializa Sensores I2C
  if (!rtc.begin()) Serial.println("[ERROR] RTC DS3231 not found.");
  if (!aht.begin()) Serial.println("[ERROR] AHT10 Sensor not found.");

  // Inicializa SD Card
  SPI.begin(18, 19, 23, 5); // SCK, MISO, MOSI, CS
  if (!SD.begin(SD_CS_PIN, SPI, 4000000)) { 
    Serial.println("[WARN] SD Card mount failed.");
    g_sdCardOk = false;
  } else {
    Serial.println("[OK] SD Card mounted.");
    g_sdCardOk = true;
    
    // Cria cabeçalho CSV se não existir
    if (!SD.exists(LOG_FILENAME)) {
      File file = SD.open(LOG_FILENAME, FILE_WRITE);
      if (file) {
        file.println("Data,Hora,Temp_Ar,Umid_Ar,Solo_Porc,Luz_Porc,UV_Index,Status_Chuva");
        file.close();
      }
    }
  }
  
  delay(1000);
}

// ===================================================================================
// 4. LOOP
// ===================================================================================
void loop() {
  DateTime now = rtc.now();
  
  // --- Leitura de Sensores ---
  sensors_event_t humidity, temp;
  aht.getEvent(&humidity, &temp);
  float tempAr = temp.temperature;
  float umidAr = humidity.relative_humidity;

  int rawSolo = analogRead(PIN_SOLO);
  int porcSolo = map(rawSolo, SOLO_SECO, SOLO_AGUA, 0, 100);
  porcSolo = constrain(porcSolo, 0, 100);
  
  int rawLuz = analogRead(PIN_LUZ);
  int porcLuz = map(rawLuz, 0, 4095, 0, 100);

  int rawChuva = analogRead(PIN_CHUVA);
  String statusChuva = (rawChuva < 3800) ? "RAINING" : "DRY";

  // Média simples para UV
  long somaUV = 0;
  for(int i=0; i<16; i++) {
    somaUV += analogRead(PIN_UV);
    delay(1);
  }
  float voltagemUV = ((somaUV / 16) * 3.3) / 4095.0;
  float indiceUV = voltagemUV / 0.1;
  if(indiceUV < 0.2) indiceUV = 0.0;

  // --- Serial Debug ---
  Serial.printf("[%02d:%02d:%02d] T:%.1fC H:%.0f%% Soil:%d%% UV:%.1f Rain:%s\n", 
                now.hour(), now.minute(), now.second(), 
                tempAr, umidAr, porcSolo, indiceUV, statusChuva.c_str());

  // --- OLED Update ---
  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0,0);
  display.printf("%02d:%02d V5", now.hour(), now.minute());
  display.setCursor(100,0);
  display.print(g_sdCardOk ? "SD" : "!");
  display.drawLine(0, 9, 128, 9, WHITE);

  display.setCursor(0, 15);
  display.setTextSize(2);
  display.printf("%.1fC", tempAr);
  
  display.setTextSize(1);
  display.setCursor(80, 15);
  display.printf("Soil");
  display.setCursor(80, 25);
  display.printf("%d%%", porcSolo);

  display.setCursor(0, 45);
  display.printf("UV:%.1f  %s", indiceUV, statusChuva.c_str());
  
  display.display();

  // --- Datalogging (SD) ---
  if (g_sdCardOk) {
    File file = SD.open(LOG_FILENAME, FILE_APPEND);
    if (file) {
      file.printf("%02d/%02d/%04d,%02d:%02d:%02d,%.1f,%.0f,%d,%d,%.2f,%s\n",
                  now.day(), now.month(), now.year(),
                  now.hour(), now.minute(), now.second(),
                  tempAr, umidAr, porcSolo, porcLuz, indiceUV, statusChuva.c_str());
      file.close();
    }
  }

  delay(2000); 
}