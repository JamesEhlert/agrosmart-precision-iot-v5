# AgroSmart Precision System V5

## Overview
Versão 5.0 do sistema de irrigação inteligente e monitoramento agrometeorológico.
Projeto focado em robustez, expansibilidade e operação offline.

## Hardware Architecture
- **MCU:** ESP32-WROOM-32 (DevKit V1)
- **Sensors:**
  - AHT10 (Air Temp/Humidity) - I2C
  - Capacitive Soil Moisture - Analog
  - Rain Sensor (Resistive) - Analog
  - LDR (Light) - Analog
  - GUVA-S12SD (UV Index) - Analog
- **Modules:**
  - DS3231 RTC (Precision Time) - I2C
  - OLED Display 0.96" - I2C
  - SD Card Module - SPI

## Connectivity
- **Primary:** AWS IoT Core (MQTT/TLS)
- **Database:** DynamoDB (NoSQL)
- **App Backend:** Google Firebase

## Author
James Rafael Ehlert