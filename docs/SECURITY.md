# Security — AgroSmart Precision IoT V5

Este documento descreve:
- estado atual de segurança (AS-IS)
- riscos e impactos
- plano de hardening (TO-BE) por fases
- checklist para tornar o projeto “publicável” no futuro (portfolio)

> Referências:
- `docs/ARCHITECTURE.md`
- `docs/DATA_MODEL.md`
- `docs/API_CONTRACT.md`

---

## 1) Assets (o que precisa ser protegido)

### 1.1 Dispositivo (ESP32)
- Wi-Fi SSID/password
- Private key + certificate (AWS IoT)
- Device identity (`device_id` / ThingName)

### 1.2 APIs e comandos
- Endpoints HTTP do API Gateway (telemetry + command)
- Possibilidade de acionar irrigação (risco físico)

### 1.3 Dados
- Telemetria em DynamoDB (sensor readings / histórico)
- Schedules e logs em Firestore (histórico de execução, decisões do scheduler)
- Identidade do usuário (Firebase Auth)

---

## 2) Estado atual (AS-IS)

### 2.1 AWS IoT Core (MQTT)
- Conexão: MQTT over TLS (8883), endpoint ATS
- Tópicos:
  - Publish: `agrosmart/v5/telemetry`
  - Subscribe/Receive: `agrosmart/v5/command`
- Policy (AgroSmart-V5-Policy):
  - iot:Connect -> `client/${iot:ClientId}`
  - iot:Publish -> `topic/agrosmart/v5/telemetry`
  - iot:Subscribe -> `topicfilter/agrosmart/v5/command`
  - iot:Receive -> `topic/agrosmart/v5/command`

**Observação**
- Como o comando usa um tópico compartilhado (`agrosmart/v5/command`), qualquer dispositivo autorizado pode receber mensagens.
- O firmware mitiga usando `device_id` dentro do payload (unicast), mas o tópico ainda é compartilhado.

### 2.2 API Gateway (HTTP)
- Base: `https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod`
- Endpoints:
  - `GET /telemetry`
  - `POST /command`
- Segurança atual:
  - Authorization: NONE
  - API Key required: false
- CORS:
  - `OPTIONS /command` existe (Mock integration)
  - `POST /command` usa Lambda Proxy integration
  - (Para browser, pode exigir headers no POST; para Flutter Android normalmente não bloqueia.)

### 2.3 Firestore (Regras)
- Regra atual (modo desenvolvimento):
  - Qualquer usuário autenticado pode ler/escrever em qualquer documento:
    - `allow read, write: if request.auth != null;`

### 2.4 DynamoDB
- Acesso ocorre via Lambdas (GetTelemetry/Scheduler)
- Configs (observabilidade e proteção):
  - Streams: off
  - TTL: off
  - PITR: off
  - Sem índices secundários
- (Detalhes IAM: TODO)

---

## 3) Principais riscos (AS-IS)

### 3.1 API pública (risco crítico)
**Impacto**
- Qualquer pessoa com a URL consegue:
  - consultar telemetria (exposição de dados)
  - enviar comandos e acionar irrigação (risco físico + custos)

**Causas**
- API Gateway sem auth e sem API key
- Sem validação de ownership do device

### 3.2 Firestore permissivo (risco crítico)
**Impacto**
- Qualquer usuário autenticado pode:
  - ler schedules e histórico de outros devices
  - escrever/alterar schedules e settings (potencial para comandos indiretos via scheduler)

### 3.3 Tópico de comando compartilhado (risco médio)
**Impacto**
- Devices recebem mensagens de comando do mesmo tópico
- Mitigação atual é por payload `device_id` (no firmware), mas é melhor isolar por tópico

### 3.4 Segredos em arquivos de código (risco alto)
**Impacto**
- Se `secrets.h` vazar por engano, expõe:
  - Wi-Fi credentials
  - certificados e private key do IoT

---

## 4) Plano de hardening (TO-BE) — por fases

### Fase 0 (rápida, baixo esforço)
1) **Throttling no API Gateway**
   - limitar taxa por IP (evita abuso/custos)
2) **Logs e retenção**
   - garantir CloudWatch Logs para Lambdas
   - definir retenção (ex.: 14 ou 30 dias)
3) **Revisar payload do comando**
   - exigir `device_id` sempre (evitar “broadcast”)

### Fase 1 (recomendada) — proteger a API com Firebase Auth
Objetivo: permitir que somente usuário autenticado e dono do device acione endpoints.

**Opção recomendada**
- Implementar **Lambda Authorizer** (ou JWT authorizer) validando **Firebase ID Token**
- Regras:
  - Requisitar `Authorization: Bearer <firebase_id_token>` nas chamadas
  - Validar token e obter `uid`
  - Checar ownership do device:
    - `devices/{deviceId}.owner_uid == uid` (Firestore) ou
    - `users/{uid}.my_devices contains deviceId`

**Resultado**
- API deixa de ser pública
- Command/telemetry só funcionam para dono do device

### Fase 2 — Firestore rules por ownership (essencial)
Substituir regras abertas por regras de dono do device.

Exemplo (modelo alvo — ajustar ao seu schema final):
- users: apenas o próprio usuário
- devices: apenas se owner_uid == request.auth.uid
- schedules/history: apenas sob device que o usuário possui

> (Implementaremos o arquivo final de rules quando entrarmos na fase de melhorias de segurança.)

### Fase 3 — Tópicos por device (melhor prática IoT)
Trocar de:
- `agrosmart/v5/telemetry`
- `agrosmart/v5/command`

Para algo como:
- `agrosmart/v5/{clientId}/telemetry`
- `agrosmart/v5/{clientId}/command`

E ajustar:
- firmware (publish/subscribe)
- IoT policy para restringir tópico do próprio clientId
- IoT Rule (pode usar wildcard + extrair clientId)

**Benefício**
- isolamento real por device, reduz risco de cross-device.

### Fase 4 — Segredos e publicação futura (portfolio)
- Manter segredos fora do git:
  - `secrets.h` fora do repositório (gitignored)
  - `secrets.example.h` com placeholders
- Rotação:
  - plano simples de troca de certificado IoT se necessário
- Checklist antes de publicar:
  - remover invoke URL real (ou mascarar)
  - garantir rules/authorizer ativados
  - remover qualquer chave/cert

---
#################################################################################################################################################



# Security — AgroSmart Precision IoT V5

Este documento registra o **estado atual de segurança (AS-IS)** do projeto AgroSmart V5 e um **plano de hardening (TO-BE)** por fases.  
Objetivo: servir como **referência completa** dentro do projeto (não necessariamente para publicação).

> Documentos relacionados:
- `docs/ARCHITECTURE.md`
- `docs/DATA_MODEL.md`
- `docs/API_CONTRACT.md`

---

## 1) Escopo e ativos críticos

### 1.1 Ativos que precisam ser protegidos
| Ativo | Por que é crítico | Exemplos |
|------|--------------------|---------|
| **Controle físico** | Pode acionar irrigação indevidamente | Válvula/relé GPIO2 |
| **Credenciais do dispositivo** | Permite conexão no IoT e rede local | SSID/senha Wi-Fi, cert/key IoT |
| **Telemetria** | Pode expor padrão de uso/ambiente | umidade/chuva/luz/temperatura |
| **Agendamentos** | Pode causar irrigação indevida | schedules no Firestore |
| **Histórico (logs)** | Auditoria e rastreio | history no Firestore |
| **API pública** | Permite abuso/custos/ataques | GET /telemetry, POST /command |
| **Permissões IAM** | “Blast radius” de comprometimento | role das Lambdas |

### 1.2 Componentes no escopo
- **ESP32** (firmware + secrets)
- **AWS IoT Core** (MQTT TLS + policy)
- **DynamoDB** (telemetria)
- **API Gateway** (HTTP)
- **Lambda** (GetTelemetry, SendCommand, Scheduler)
- **Firebase Auth + Firestore**
- **CloudWatch Logs**

---

## 2) Estado atual (AS-IS)

### 2.1 ESP32 (device)
- Conecta via Wi-Fi e publica MQTT TLS (porta 8883).
- **Segredos locais** (no ambiente de desenvolvimento):
  - SSID/senha Wi-Fi
  - Certificado + private key do AWS IoT (TLS)
- Recomendações de higiene:
  - manter `secrets.h` fora de repositório público
  - evitar copiar private keys para documentos que possam ser compartilhados sem querer

---

### 2.2 AWS IoT Core (MQTT)
**Endpoint (ATS):**
- `a39ub0vpt280b2-ats.iot.us-east-2.amazonaws.com`

**Tópicos:**
- Publish telemetria: `agrosmart/v5/telemetry`
- Subscribe/Receive comandos: `agrosmart/v5/command`

**Policy do certificado (AgroSmart-V5-Policy):**
- `iot:Connect` em `client/${iot:ClientId}`
- `iot:Publish` em `topic/agrosmart/v5/telemetry`
- `iot:Subscribe` em `topicfilter/agrosmart/v5/command`
- `iot:Receive` em `topic/agrosmart/v5/command`

**Observação importante (AS-IS):**
- O tópico de comando é **compartilhado** (`agrosmart/v5/command`).  
  Mitigação atual: o firmware usa `device_id` no payload e ignora comandos destinados a outro device.  
  Ainda assim, do ponto de vista de segurança, **o isolamento por tópico não é total**.

---

### 2.3 API Gateway (HTTP)
**Base URL (prod):**
- `https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod`

**Rotas:**
- `GET /telemetry`
- `POST /command`
- `OPTIONS /telemetry`
- `OPTIONS /command`

**Autorização:**
- Authorization: **NONE**
- API key required: **False**

**Resource policy do API:**
- **Nenhuma** (API sem restrições por IP/VPC/origem)

**CORS / Preflight:**
- `OPTIONS /command`: **Mock integration** (preflight configurado)
- `POST /command`: **Lambda Proxy integration**

**Consequência (AS-IS):**
- A API é efetivamente **pública** (qualquer um com a URL pode consultar telemetria e enviar comando).

---

### 2.4 DynamoDB (telemetria)
**Tabela:** `AgroTelemetryData_V5`
- Partition key: `device_id` (String)
- Sort key: `timestamp` (Number)

**Configurações:**
- Capacity mode: **On-demand**
- Indexes: **0 GSI / 0 LSI**
- TTL: **Off**
- Streams: **Off**
- PITR: **Off**
- Encryption: **AWS owned key**
- Deletion protection: **Off**

---

### 2.5 Firebase / Firestore
**Auth:**
- Firebase Authentication (usuários logados)

**Rules atuais (modo dev):**
- Qualquer usuário autenticado pode ler/escrever em qualquer lugar:
  - `allow read, write: if request.auth != null;`

**Consequência (AS-IS):**
- Se o usuário A e B estiverem autenticados no seu projeto Firebase, **ambos podem ler/escrever** dados de qualquer device (schedules/history/settings).

---

### 2.6 AWS Lambda (permissions / IAM)
**Role usada por todas as Lambdas:**
- `AgroSmart_V5_Lambda_Role`

**Policies anexadas (AWS managed):**
- `AmazonDynamoDBFullAccess`  ⚠️ (muito permissivo)
- `AmazonDynamoDBReadOnlyAccess` (redundante se FullAccess existir)
- `AWSIoTDataAccess`
- `AWSLambdaBasicExecutionRole`

**Permissions boundary:**
- Not set

**Consequência (AS-IS):**
- Se uma Lambda for explorada (ou se vazar credencial/permissão), o impacto pode ser grande:
  - DynamoDB full access (leitura e escrita ampla)
  - IoT Data access (publish/subscribe/receive dependendo da policy da role)
  - Logs (padrão)

---

### 2.7 CloudWatch Logs (observabilidade)
Exemplo observado:
- Log group: `/aws/lambda/AgroSmart_V5_GetTelemetry`
- Retention: **Never expire**
- Metric filters: 0
- Subscription filters: 0
- Deletion protection: Off

O log exportado indica:
- Runtime: Python 3.13
- Memory size: 128 MB
- Execuções rápidas (dezenas a centenas de ms)
- Requisições vindas do app (User-Agent Dart/Flutter)

---

## 3) Superfícies de ataque e riscos

### 3.1 Risco crítico — API pública (GET/POST sem auth)
**Impacto:**
- Qualquer pessoa pode:
  - consumir telemetria (vazamento)
  - enviar comando e acionar irrigação (risco físico + custo + abuso)

**Probabilidade:**
- Alta (basta conhecer a URL)

---

### 3.2 Risco crítico — Firestore rules abertas
**Impacto:**
- Qualquer usuário autenticado pode:
  - alterar schedules/settings de qualquer device
  - ler histórico de outros devices

**Probabilidade:**
- Alta (regra permite por design)

---

### 3.3 Risco alto — permissões IAM amplas (FullAccess)
**Impacto:**
- “Blast radius” maior do que o necessário
- Dificulta auditoria de “o que cada função realmente precisa”

---

### 3.4 Risco médio — tópico de comando compartilhado
**Impacto:**
- Devices recebem mensagens do mesmo tópico
- Mitigação via `device_id` existe, mas o melhor é isolar por tópico/policy

---

### 3.5 Risco médio — retenção infinita de logs
**Impacto:**
- Custo e acúmulo
- Possível retenção de dados sensíveis em logs por tempo indefinido

---

## 4) Plano de hardening (TO-BE) por fases

### Fase 0 — Rápida (baixo esforço, alta melhoria)
1) **Throttling no Stage do API Gateway**
   - Limitar burst/rate (reduz abuso e custos)
2) **Ajustar retenção do CloudWatch Logs**
   - Ex.: 14 ou 30 dias (ao invés de never expire)
3) **Evitar broadcast de comando**
   - Exigir `device_id` sempre no payload (HTTP e scheduler)
4) **Remover policy redundante**
   - Se mantiver FullAccess (temporariamente), remover ReadOnly (ou o contrário)
5) **Melhorar validação de entrada**
   - Validar `duration` (mín/max), `device_id` não vazio, etc.

---

### Fase 1 — Proteger a API (recomendado)
Objetivo: **somente usuários autenticados e donos do device** podem usar a API.

**Opção recomendada (compatível com Firebase):**
- Implementar **Authorizer** no API Gateway para validar **Firebase ID Token**
- Exigir header:
  - `Authorization: Bearer <firebase_id_token>`

**Regras alvo:**
- Após validar token, obter `uid`
- Checar ownership antes de responder:
  - `devices/{deviceId}.owner_uid == uid`
  - ou `users/{uid}.my_devices` contém `deviceId`

**Resultado:**
- API deixa de ser pública
- Evita que qualquer pessoa com URL acione irrigação

---

### Fase 2 — Firestore Rules por ownership (essencial)
Trocar regra “dev mode” por regras restritivas.

Modelo alvo (exemplo, ajustar conforme seu schema final):

```js
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    match /users/{uid} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }

    match /devices/{deviceId} {
      allow read, update, delete: if request.auth != null
        && resource.data.owner_uid == request.auth.uid;

      allow create: if request.auth != null
        && request.resource.data.owner_uid == request.auth.uid;

      match /schedules/{scheduleId} {
        allow read, write: if request.auth != null
          && get(/databases/$(database)/documents/devices/$(deviceId)).data.owner_uid == request.auth.uid;
      }

      match /history/{logId} {
        allow read: if request.auth != null
          && get(/databases/$(database)/documents/devices/$(deviceId)).data.owner_uid == request.auth.uid;

        // normalmente history é escrito só pelo backend, mas se o app escrever, ajuste:
        allow write: if false;
      }
    }
  }
}
####################################

Fase 3 — Isolamento por tópico (best practice IoT)

Trocar de tópico compartilhado para tópico por dispositivo.

Exemplo:

Telemetry: agrosmart/v5/{thingName}/telemetry

Command:

.