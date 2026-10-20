Markdown
# 🌱 AgroSmart Precision IoT V5

**Sistema Industrial de Irrigação Inteligente e Monitoramento Agrometeorológico em Nuvem Híbrida (ESP32 FreeRTOS + AWS Serverless + Google Cloud/Firebase + Flutter)**

[![Firmware](https://img.shields.io/badge/Firmware-ESP32%20v5.19.0%20(FreeRTOS)-blue)](#1-engenharia-de-firmware-embarcado-esp32---v5190)
[![AWS](https://img.shields.io/badge/Cloud-AWS%20IoT%20%7C%20Lambda%20%7C%20DynamoDB-orange)](#2-arquitetura-multi-cloud-h%C3%ADbrida-aws--google-cloud)
[![Firebase](https://img.shields.io/badge/Realtime-Firebase%20Auth%20%26%20Firestore-yellow)](#2-arquitetura-multi-cloud-h%C3%ADbrida-aws--google-cloud)
[![Flutter](https://img.shields.io/badge/Mobile-Flutter%203%20(Android)-02569B)](#3-aplicativo-m%C3%B3vel-flutter)

---

## 📌 Visão Geral do Projeto

O **AgroSmart Precision IoT V5** é uma solução ponta a ponta (*End-to-End*) de Internet das Coisas (IoT) projetada com padrões de confiabilidade industrial para automação de irrigação e telemetria ambiental de precisão.

Diferente de protótipos convencionais baseados em loops bloqueantes, o sistema implementa **tolerância a falhas de borda (*Edge Computing*)**, armazenamento offline em fila **Write-Ahead Log (WAL)** segmentada em cartão MicroSD, segurança **mTLS X.509**, controle de concorrência distribuído e observabilidade em tempo real da saúde física do hardware diretamente no aplicativo móvel.

---

## 🏗️ Arquitetura Multi-Cloud Híbrida (AWS + Google Cloud)

O projeto combina os pontos fortes da **Amazon Web Services (AWS)** (ingestão massiva de telemetria IoT e processamento Serverless) e do **Google Cloud / Firebase** (autenticação social e sincronização de estado em tempo real com baixa latência no cliente móvel):

```text
+-----------------------------------------------------------------------------------+
|                        ESTAÇÃO DE BORDA (ESP32 - FreeRTOS)                        |
|  Sensores (AHT20, Solo, Luz, Chuva, UV) + RTC DS3231 + Fila WAL SD + Relé Válvula |
+-----------------------------------------+-----------------------------------------+
                                          |
                              MQTT sobre TLS 1.2 (mTLS X.509)
                                    Porta 8883 (QoS 0 / 1)
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                              AWS CLOUD (us-east-2)                                |
|                                                                                   |
|  [AWS IoT Core]                                                                   |
|    ├── Tópico: agrosmart/v5/+/telemetry ──> [IoT Rule] ──> [Amazon DynamoDB]      |
|    ├── Tópico: agrosmart/v5/+/ack       ──> [IoT Rule] ──> [Lambda AckToFirestore]|
|    ├── Tópico: agrosmart/v5/+/presence  ──> [IoT Rule] ──> [Lambda Presence]      |
|    └── Tópico: agrosmart/v5/+/command   <── [Lambda SendCommand / Scheduler]      |
|                                                                                   |
|  [Amazon EventBridge (Cron 1 min)]                                                |
|    └── Aciona ──> [Lambda Scheduler_Logic] ──> Consulta DynamoDB + Open-Meteo API |
|                                                                                   |
|  [Amazon API Gateway (REST API)]                                                  |
|    ├── Custom Authorizer: [Lambda Firebase_Authorizer (Node.js JWKS)]             |
|    ├── GET  /telemetry ──> [Lambda GetTelemetry] ( Paginação Base64 + Ownership ) |
|    └── POST /command   ──> [Lambda SendCommand]  ( Trava HTTP 409 + Idempotência )|
+-----------------------------------------+-----------------------------------------+
                                          |
                         Credenciais via AWS Secrets Manager
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                         GOOGLE CLOUD / FIREBASE (agrosmart-v5)                    |
|                                                                                   |
|  [Firebase Authentication] (E-mail/Senha & Google Sign-In)                        |
|  [Cloud Firestore] (Single Source of Truth de Estado, Presença LWT e Histórico)   |
+-----------------------------------------+-----------------------------------------+
                                          |
                          Streams Reativos + HTTPS Bearer JWT
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                           APLICATIVO MOBILE (FLUTTER)                             |
|   Monitoramento em Tempo Real, Diagnóstico de Hardware, Gráficos e Agendamentos   |
+-----------------------------------------------------------------------------------+
⚙️ Principais Diferenciais de Engenharia
1. Engenharia de Firmware Embarcado (ESP32 - v5.19.0)
Arquitetura Multitarefa em Tempo Real (FreeRTOS): Divisão estrita de responsabilidades em 4 tasks independentes sincronizadas por 5 Mutexes e 2 Filas:

taskValveControl (Prioridade Máxima 4 - ciclo de 100ms): Garante o desligamento determinístico da válvula solenoide independente da rede.

taskSensors (Prioridade 3): Aquisição de dados com Filtro Digital de Mediana + Média Aparada (9 amostras ADC) e detecção de falha no solo (soil_fault).

taskNetworkStorage (Prioridade 2): Gerenciamento de Wi-Fi, mTLS com AWS IoT Core, NTP assíncrono e persistência no SD.

taskDisplay (Prioridade 1): Atualização local do display OLED SSD1306.

Alocação Estática em BSS (Prevenção de Stack Overflow): Buffers JSON e de arquivos alocados estaticamente para zerar fragmentação de Heap e erros de Panic.

Fila Offline Store-and-Forward Segmentada (WAL no MicroSD): Segmentos de 256 KB (/queue/q_XXXXXXXX.ndjson) com ponteiros salvos no NVS. Sincronização em Burst Flush ao reconectar.

Segurança de Borda (Edge Computing):

Interlock Local de Chuva: Aborto imediato de rega caso comece a chover (rain_detected == true).

Crash Recovery via NVS: Recuperação de estado e envio de aviso (power_loss_reset) caso falte energia no meio de uma irrigação.

Idempotência de Comandos MQTT: Deduplicação baseada em cache circular de command_id.

2. Backend Serverless e Segurança Multi-Tenant (AWS + Firebase)
Autenticação Criptográfica Zero-Trust: Custom Authorizer em Node.js (AgroSmart_Firebase_Authorizer.mjs) validando tokens JWT via JWKS do Google.

Isolamento Multi-Tenant e Controle de Concorrência:

Restrição de tópicos X.509 no AWS IoT Core por ClientId.

Validação de owner_uid no Firestore pelas Lambdas (403 Forbidden).

Trava de concorrência com HTTP 409 Conflict caso a válvula já esteja em uso.

Automação Inteligente Fail-Closed: Validação de telemetria recente (<= 180s), verificação de sensores físicos e consulta à API Open-Meteo antes de acionar regas agendadas.

3. Aplicativo Móvel (Flutter)
Monitoramento e Previsão Climática: Exibição de 6 grandezas ambientais (Temperatura, Umidade do Ar/Solo, Luminosidade, UV e Chuva) integradas por geolocalização.

Painel de Observabilidade e Integridade Física: Leitura do bloco sys (Firmware, RSSI, Uptime, Fila WAL, contagem de boots e status de periféricos: SD, RTC, AHT e Solo).

Cronômetro Global Sincronizado: Contagem regressiva baseada no timestamp state.valve_ends_at do Firestore.

📂 Estrutura do Repositório
Plaintext
├── backend/
│   └── LambdasFuncs/
│       ├── AgroSmart_Firebase_Authorizer/   # Custom Authorizer JWT (Node.js)
│       ├── AgroSmart_Scheduler_Logic/       # Motor de agendamento (Python)
│       ├── AgroSmart_V5_AckToFirestore/     # Processador de ACKs (Python)
│       ├── AgroSmart_V5_GetTelemetry/       # Leitura paginada do DynamoDB (Python)
│       ├── AgroSmart_V5_PresenceToFirestore/# Rastreador Online/Offline LWT (Python)
│       └── AgroSmart_V5_SendCommand/        # Disparo de comandos com trava 409 (Python)
├── docs/                                    # Documentação técnica e Guia de Entrevista (STAR)
├── firmware/                                # Projeto PlatformIO do ESP32 (C++ / FreeRTOS)
│   ├── include/
│   │   └── secrets.example.h                # Template de configuração (Wi-Fi e Certs X.509)
│   ├── src/
│   │   └── main.cpp                         # Firmware v5.19.0
│   └── platformio.ini                       # Configuração de build
└── flutter-app/
    └── agrosmart_app_v5/                    # App Mobile (Flutter / Dart)
        ├── lib/
        │   ├── core/                        # Configurações e temas
        │   ├── features/                    # Módulos de telas (Auth, Monitor, Schedules, History)
        │   ├── models/                      # Modelos de domínio Schema V2
        │   └── services/                    # Integração AWS REST e Firebase Streams
        └── test/                            # Testes unitários automatizados (flutter test)
👨‍💻 Autor
Desenvolvido por James Rafael Ehlert — Projeto de Engenharia de Software, IoT e Computação em Nuvem.
