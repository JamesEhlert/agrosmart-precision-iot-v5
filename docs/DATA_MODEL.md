# Data Model — AgroSmart Precision IoT V5

Este documento descreve o modelo de dados oficial do projeto (DynamoDB + Firestore),
com campos, tipos, unidades e exemplos práticos.

---

## 1) DynamoDB

### 1.1 Tabela
- **Table name:** `AgroTelemetryData_V5`
- **Partition key (PK):** `device_id` *(String)*
- **Sort key (SK):** `timestamp` *(Number — Unix epoch em segundos)*
- **Capacity mode:** On-demand
- **Indexes:** nenhum (0 GSI / 0 LSI)
- **TTL:** Off
- **Streams:** Off
- **PITR:** Off
- **Encryption:** AWS owned key

---

### 1.2 Esquema do Item (telemetria)
Campos principais:

| Campo | Tipo | Obrigatório | Observação |
|------|------|-------------|-----------|
| device_id | String | sim | ID do dispositivo / ThingName (ex.: `ESP32-AgroSmart-Station-V5`) |
| timestamp | Number | sim | Unix timestamp em **segundos** |
| sensors | Map | sim | Medidas do dispositivo |
| boot_count | Number | não | Usado no device de teste (bateria/deep sleep); pode ser nulo no device principal |

---

### 1.3 Campo `sensors` (campos e unidades)

O firmware publica sensores como números (JSON normal). No DynamoDB Console/CSV, eles aparecem tipados.

| Sensor | Tipo | Unidade | Range esperado / Observação |
|-------|------|---------|-----------------------------|
| air_temp | number | °C | vem do AHT10 |
| air_humidity | number | % | vem do AHT10 |
| soil_moisture | number | % | **0–100** (mapeado do ADC: `map(raw, 3000..1200 -> 0..100)`) |
| light_level | number | % | **0–100** (mapeado do ADC 0..4095) |
| rain_raw | number/int | ADC | **0–4095** (leitura crua) |
| uv_index | number | índice | estimado a partir do ADC (média amostras) |

---

### 1.4 Exemplo de item (visão export/console)
Export CSV/console (DynamoDB JSON tipado):

```json
{
  "device_id": "ESP32-AgroSmart-Station-V5",
  "timestamp": 1766805062,
  "boot_count": null,
  "sensors": {
    "air_temp": { "N": "22.08786011" },
    "air_humidity": { "N": "63.59348297" },
    "uv_index": { "N": "0" },
    "soil_moisture": { "N": "0" },
    "light_level": { "N": "0" },
    "rain_raw": { "N": "4095" }
  }
}

###############################################################

1.5 Padrões de consulta (API)

A API consulta o DynamoDB por device_id e ordena por timestamp (SK), com suporte a:

Latest: limit=1

Histórico paginado: limit + next_token

Filtro temporal: start_time e end_time (Unix seconds)

2) Firestore (Firebase)
2.1 Coleções e documentos
users/{uid}
Campo	Tipo	Observação
my_devices	array<string>	Lista de IDs de devices vinculados ao usuário
email / name	string	Podem existir dependendo do cadastro
devices/{deviceId}
Campo	Tipo	Observação
device_id	string	Repetição opcional do ID (o ID já existe no docId)
owner_uid	string	UID do dono
online	bool	Status
created_at	timestamp	serverTimestamp
settings	map	Configurações do device

settings (map):

Campo	Tipo	Default	Unidade / Observação
device_name	string	Dispositivo Sem Nome	Nome exibido no app
target_soil_moisture	number	60	% (0–100)
manual_valve_duration	int	5	minutos (no app vira segundos ao enviar comando)
timezone_offset	int	-3	offset de fuso
latitude	number	0.0	usado no weather
longitude	number	0.0	usado no weather
enable_weather_control	bool	false	habilita controle por clima
capabilities	array<string>	['air','soil','light','rain','uv']	sensores disponíveis
2.2 Subcoleções
devices/{deviceId}/schedules/{scheduleId}
Campo	Tipo	Observação
label	string	Nome do agendamento
time	string	Formato "HH:mm"
days	array<int>	1=Seg ... 7=Dom
duration_minutes	int	1..60
enabled	bool	ativo/inativo
devices/{deviceId}/history/{logId}
Campo	Tipo	Observação
timestamp	timestamp	quando ocorreu
type	string	ex.: execution, skipped, error
source	string	ex.: schedule, manual, system, weather_ai
message	string	mensagem descritiva
2.3 Índices

Necessário para o Scheduler (query em collection group de schedules):

Collection group: schedules

Campos: days (array), enabled, time, __name__

3) Conversões importantes (para não confundir)
MQTT Payload (ESP32 -> IoT)

O ESP32 publica JSON “normal”:

device_id (string)

timestamp (unix seconds)

sensors (números)

DynamoDB Export/Console

Mostra sensors em formato tipado (ex.: {"N":"22.0"}

, mas é algo que pode virar bug em testes.)