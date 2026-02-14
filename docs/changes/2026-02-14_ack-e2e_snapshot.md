# ACK E2E Snapshot (2026-02-14)

Commit: 2a74b88  
Branch: feature/multi-tenant-topics-ack-e2e

## Summary

Este snapshot consolida a implementação do **ACK ponta-a-ponta (E2E)** para comandos, junto com a migração para **tópicos MQTT por dispositivo** (“device-scoped topics”).

**Objetivos atingidos no código do repositório:**
- Firmware (ESP32) passou a publicar **telemetria, comandos e ACK** em tópicos **isolados por device**.
- Firmware publica ACK em fases (ex.: `received`, `done`, `error`) e reforça segurança para ignorar comandos fora do tópico correto.
- App Flutter ganhou base para:
  - enviar comando com `command_id` (compatível com UI antiga)
  - acompanhar ACK via Firestore (stream) e aguardar finalização com timeout
- HistoryService do Flutter foi reforçado para paginação compatível com versões antigas e futuras.

> Observação: alterações na AWS (IoT Rule, Lambda(s), policies, authorizer etc.) **não aparecem neste commit** porque parte foi feita no console/infra. Isso será documentado em um snapshot de infra separado via AWS CLI.

---

## What changed (by file)

### 1) `.gitignore`
**Mudança**
- Ignora artefatos locais do firmware:
  - `firmware/.vscode/`
  - `firmware/compile_commands.json`

**Impacto**
- Evita commitar arquivos gerados por editor/IDE/build, mantendo o repositório limpo e reduzindo conflitos.

---

### 2) `firmware/src/main.cpp`

#### 2.1 Versão do firmware
- Atualizado para `FW_VERSION 5.17.4`
- Comentários/cabeçalho indicam foco em:
  - device-scoped topics
  - ACK ponta-a-ponta
  - SD crash-safe

#### 2.2 Device-scoped topics (arquitetura “produto”)
Foi introduzido um padrão de tópicos por dispositivo com base no `THINGNAME`:

- `agrosmart/v5/<THINGNAME>/telemetry`
- `agrosmart/v5/<THINGNAME>/command`
- `agrosmart/v5/<THINGNAME>/ack`

Implementação:
- Macro `AGROSMART_TOPIC_PREFIX` (default `"agrosmart/v5"`, podendo ser definido via `secrets.h`)
- Buffers globais:
  - `g_topicTelemetry`
  - `g_topicCommand`
  - `g_topicAck`
- Função `buildMqttTopics()` monta as strings com `snprintf()`

**Impacto**
- Isolamento por dispositivo (melhor para multi-tenant)
- Facilita enforcement por policy no AWS IoT
- Reduz risco de “misturar” eventos de devices diferentes

#### 2.3 Inicialização correta no `setup()`
- `buildMqttTopics()` é chamado no início do `setup()` antes da rede/MQTT

**Impacto**
- Garante tópicos válidos antes de subscribe/publish.

#### 2.4 Publish telemetria (online e flush do SD) no tópico por device
Mudanças principais:
- Publish de telemetria online: agora usa `g_topicTelemetry`
- Flush do SD (store-and-forward): agora usa `g_topicTelemetry`

**Impacto**
- Todo fluxo de telemetria (online/offline) fica consistente e isolado por device.

#### 2.5 Subscribe no tópico de comando por device
- Subscribe mudou para `client.subscribe(g_topicCommand)`

**Impacto**
- Device escuta somente comandos do seu tópico.

#### 2.6 Segurança extra no callback de MQTT
No callback:
- Se a mensagem não chegou em `g_topicCommand`, ela é ignorada com warning.

**Impacto**
- Proteção adicional contra configurações erradas e ruídos de tópico.
- Reduz risco em cenário multi-tenant.

#### 2.7 ACK por device (mudança crítica)
A publicação do ACK passou a usar:
- `mqttPublish(g_topicAck, ...)`

E o log do ACK passou a incluir o tópico.

**Impacto**
- ACK publicado em `agrosmart/v5/<THINGNAME>/ack`
- Permite regra IoT/Lambda atuar por device com maior precisão.

#### 2.8 Fail-safe + ACK de término
Há reforço no loop de rede para “fail-safe válvula” gerando ACK final (`done`/`error`) quando necessário.

**Impacto**
- Segurança operacional + auditabilidade (o motivo aparece no ACK e pode virar evento no Firestore).

---

### 3) `flutter-app/agrosmart_app_v5/lib/screens/dashboard_screen.dart`

**Mudanças**
- `print(...)` → `debugPrint(...)` para logs
- `withOpacity(0.2)` → `withAlpha(51)` (equivalente aproximado)

**Impacto**
- Logging mais adequado ao Flutter
- Reduz possíveis warnings/variações; deixa o alpha explícito

---

### 4) `flutter-app/agrosmart_app_v5/lib/services/aws_service.dart`

#### 4.1 Compatibilidade + E2E ACK no app
Foram adicionadas estruturas para suportar ACK ponta-a-ponta **sem quebrar a UI antiga**.

**Novos imports**
- `dart:async` (streams/timeouts)
- `dart:math` (geração de command_id)
- `cloud_firestore` (escutar ACK no Firestore)

#### 4.2 Token log crash-safe
- Log do token agora protege substring se token < 6 chars

**Impacto**
- Evita crash raro e mantém log “seguro” (sem expor token inteiro).

#### 4.3 `command_id` gerado no app
- `_generateCommandId()` cria `app-<ms>-<rand>`

**Impacto**
- Ajuda correlação E2E mesmo se a API não gerar um `command_id`.

#### 4.4 `sendCommand()` mantém retorno bool (UI antiga)
- `sendCommand(...)` agora chama internamente `sendCommandWithAck(...)`
- Continua retornando `bool` para não quebrar telas existentes.

#### 4.5 `sendCommandWithAck()` retorna `SendCommandResult`
- Envia body incluindo `"command_id": <id>`
- Tenta ler `command_id` e `message` da resposta da API (se existir)
- Retorna:
  - `ok`
  - `commandId`
  - `message`

**Impacto**
- UI pode guardar `commandId` e acompanhar o status no Firestore.

#### 4.6 Stream de ACK via Firestore History
- `watchAckForCommand(...)` escuta:
  - `devices/{deviceId}/history`
  - filtrando `command_id == <id>`
- Não usa `orderBy` para evitar índice composto
- Ordena localmente pelo timestamp (mais recente primeiro)

**Impacto**
- Facilita implementação sem mexer na infra (índices).
- Pode haver múltiplos docs para o mesmo `command_id`, então a UI deve considerar o mais recente.

#### 4.7 Helper `waitForFinalAck()`
- Aguarda até aparecer `done` ou `error`
- Timeout padrão: 20s

**Impacto**
- Permite UX: “enviando comando → aguardando conclusão”.

> Nota: no backend existe também o doc único `devices/{deviceId}/commands/{commandId}` com `last_status`. Em uma evolução futura, a UI pode escutar esse doc para atualizações mais em tempo real (received/started/done) sem depender do history.

---

### 5) `flutter-app/agrosmart_app_v5/lib/services/history_service.dart`

#### 5.1 Response mais completo para paginação
`ActivityLogsResponse` agora inclui:
- `lastDoc` (DocumentSnapshot)
- `nextCursor` (String docId)
- `hasMore` (bool)

**Impacto**
- Facilita UI “carregar mais”
- Cursor pode ser armazenado como string se necessário.

#### 5.2 `getActivityLogs()` compatível com 2 estilos
A função agora aceita:
- `lastDocument` (modo clássico Firestore)
- `cursor` (pode ser DocumentSnapshot ou String docId)

Prioridade:
1) usa `lastDocument` se existir
2) senão, resolve `cursor`:
   - se cursor é `DocumentSnapshot`, usa direto
   - se cursor é `String`, faz `.doc(cursor).get()` para obter snapshot e então `startAfterDocument`

**Impacto**
- Mantém compatibilidade com dashboard antigo
- Permite evoluir paginação/estado sem quebrar telas

---

## Known gaps / next steps

1) **Infra snapshot (AWS)**
Este commit não contém as alterações feitas na AWS (IoT Rule, Lambda(s), policies, authorizer).
Próximo passo: exportar configurações via AWS CLI e salvar em `docs/infra-snapshots/...`.

2) **Front-end ACK (UX)**
O service Flutter já tem base (`sendCommandWithAck`, `watchAckForCommand`, `waitForFinalAck`),
mas ainda falta integrar isso visualmente no dashboard (mostrar status do comando/ACK).

3) **Security P0**
Roadmap menciona: *Ownership enforcement* em endpoints críticos (GetTelemetry / SendCommand),
validando `owner_uid == uid` para evitar que um usuário autenticado acesse device que não é dele.
