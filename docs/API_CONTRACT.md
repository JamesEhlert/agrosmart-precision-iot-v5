# API Contract — AgroSmart Precision IoT V5

Este documento descreve os contratos (interfaces) entre os módulos do sistema:
- MQTT (ESP32 ↔ AWS IoT Core)
- HTTP (Flutter ↔ API Gateway + Lambdas)
- Integrações internas (Scheduler ↔ Firestore/DynamoDB/IoT)

> Referência do modelo de dados: ver `docs/DATA_MODEL.md`.

---

## 1) Environments & Base URLs

### 1.1 AWS Region
- `us-east-2`

### 1.2 MQTT (AWS IoT Core)
- Broker endpoint (ATS): `a39ub0vpt280b2-ats.iot.us-east-2.amazonaws.com`
- Port: `8883`
- TLS: obrigatório (CA + certificate + private key no device)


### 1.3 HTTP (API Gateway)
- Stage: `prod`
- Base URL: `https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod`


## 2) MQTT Contract (ESP32 ↔ AWS IoT Core)

### 2.1 Telemetry Publish
- Topic: `agrosmart/v5/telemetry`
- Publisher: ESP32 device
- QoS: 0 (firmware usa `client.publish(topic, payload)` sem QoS explícito)
- Payload format: JSON

#### 2.1.1 Payload schema
```json
{
  "device_id": "ESP32-AgroSmart-Station-V5",
  "timestamp": 1766805062,
  "sensors": {
    "air_temp": 22.08,
    "air_humidity": 63.59,
    "soil_moisture": 23,
    "light_level": 70,
    "rain_raw": 4095,
    "uv_index": 0.0
  }
}
####################################################################333




    device_id: string (ThingName)

    timestamp: number (Unix epoch em segundos)

    sensors: objeto com valores numéricos (ver unidades em DATA_MODEL.md)

    Campo opcional (device de teste):

    boot_count: number (usado para estimar ciclos em bateria / deep sleep)

2.2 Command Subscribe

    Topic: agrosmart/v5/command

    Subscriber: ESP32 device

    Publisher: Lambda (Scheduler e SendCommand)

    QoS: 1 (Lambdas publicam com qos=1)

2.2.1 Payload schema

{
  "device_id": "ESP32-AgroSmart-Station-V5",
  "action": "on",
  "duration": 300,
  "origin": "schedule"
}

    device_id (opcional): se presente, atua como unicast

        se device_id existir e for diferente do THINGNAME, o device ignora o comando

        se device_id estiver ausente/null, o comando vira broadcast (qualquer device aplica)

    action: string

        valores suportados no firmware: "on"

    duration: int (segundos)

        se duration > 0: liga válvula e agenda desligamento automático

        se duration == 0: desliga imediatamente (parada)

    origin: string (opcional)

        ex.: "schedule", "manual"

2.2.2 Comportamento do device ao receber comando

    Se ação for "on" e duration > 0: seta GPIO 2 = HIGH, mantém ligado até timeout

    Se ação for "on" e duration == 0: GPIO 2 = LOW (stop)

    Se ação for diferente de "on": firmware loga aviso e ignora

3) HTTP API Contract (Flutter ↔ API Gateway)
3.1 GET /telemetry

Descrição: Retorna lista de telemetrias do DynamoDB para um dispositivo, com paginação e filtro temporal.

    Method: GET

    Path: /telemetry

    Query params:

        device_id (obrigatório): string

        limit (opcional): int (default = 50)

        next_token (opcional): string (token base64 de paginação)

        start_time (opcional): int (Unix seconds)

        end_time (opcional): int (Unix seconds)

Regras do filtro de tempo:

    Só aplica filtro temporal se start_time e end_time vierem juntos.

3.1.1 Response 200 (success)

{
  "data": [
    {
      "device_id": "ESP32-AgroSmart-Station-V5",
      "timestamp": 1766805062,
      "boot_count": null,
      "sensors": {
        "air_temp": 22.08,
        "air_humidity": 63.59,
        "soil_moisture": 23,
        "light_level": 70,
        "rain_raw": 4095,
        "uv_index": 0.0
      }
    }
  ],
  "count": 1,
  "next_token": "BASE64..."
}

    data: lista de itens (ordenado do mais recente para o mais antigo)

    count: número de itens na resposta

    next_token: string base64 (ou null) para buscar a próxima página

3.1.2 Errors

    400 — device_id ausente

{ "error": "device_id obrigatorio" }

    400 — next_token inválido

{ "error": "Token invalido" }

    500 — erro interno

{ "error": "<mensagem>" }

3.1.3 CORS (atual)

A Lambda retorna headers:

    Access-Control-Allow-Origin: *

    Access-Control-Allow-Methods: GET, OPTIONS

    Access-Control-Allow-Headers: *

3.2 POST /command

Descrição: Envia comando manual para abrir a válvula via publish MQTT.

    Method: POST

    Path: /command

    Headers:

        Content-Type: application/json

    Body JSON:

        device_id (obrigatório): string

        action (obrigatório): string ("on")

        duration (opcional): int (segundos, default 0)

3.2.1 Request example

{
  "device_id": "ESP32-AgroSmart-Station-V5",
  "action": "on",
  "duration": 300
}

3.2.2 Response 200 (success)

{
  "message": "Comando enviado com sucesso",
  "target": "ESP32-AgroSmart-Station-V5"
}

3.2.3 Errors

    400 — body inválido / faltando campos

{ "message": "Erro: device_id e action são obrigatórios" }

    500 — erro interno

{ "message": "Erro interno na Lambda", "error": "<mensagem>" }

#### 3.2.4 CORS (confirmado)
- Existe `OPTIONS /command` configurado no API Gateway com **Mock integration** (preflight).
- O método `POST /command` usa **Lambda Proxy integration**.

Notas:
- Para clientes **browser**, o POST também precisa responder com `Access-Control-Allow-Origin`.
  - Se necessário, adicionar headers no retorno da Lambda **ou** configurar mapeamento no API Gateway.
- Para Flutter Android, CORS normalmente não bloqueia.


4) Scheduler Contract (interno)
4.1 Trigger

    EventBridge rule: AgroSmart_V5_Minute_Trigger

    Schedule: rate(1 minute)

4.2 Fonte de dados

    Firestore: collectionGroup('schedules') filtrando:

        enabled == true

        days array_contains (1..7, baseado em weekday+1)

        time == "HH:mm" (fuso America/Sao_Paulo)

    DynamoDB: busca último item por device_id (Limit 1, mais recente)

4.3 Comando emitido

Publica MQTT em agrosmart/v5/command com:

{
  "device_id": "<deviceId>",
  "action": "on",
  "duration": <duration_minutes * 60>,
  "origin": "schedule"
}

4.4 Weather intelligence (Open-Meteo)

    Endpoint: https://api.open-meteo.com/v1/forecast

    Params: latitude, longitude, hourly precipitation_probability/precipitation, timezone auto

    Janela: 6 horas

    Regra: cancela se

        prob >= 50% e amount >= 0.5 em alguma hora

        e total >= 1.0mm na janela

4.5 Logs

Escreve em: devices/{deviceId}/history/{logId}

    type: execution | skipped | error

    source: schedule | weather_ai | system | manual

    message: string

    timestamp: server time (UTC)

5) Versioning

    Versão atual: V5

    Recomendação: versionar contratos com:

        API Gateway base path /prod (stage)

        MQTT topics: agrosmart/v5/...