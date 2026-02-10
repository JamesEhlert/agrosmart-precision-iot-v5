# Firestore — Estrutura (schema) + plano de testes de Rules

## 1) Estrutura atual (baseado nos prints do Console)

### Coleção `users`
**Path:** `users/{uid}`  
**DocId:** normalmente o próprio `uid` do Firebase Auth (ex.: `cB2t...`)

**Campos (exemplos):**
- `created_at` *(timestamp)*
- `email` *(string)*
- `name` *(string)*
- `role` *(string)* — ex.: `"customer"`
- `uid` *(string)* — redundante (igual ao docId)
- `my_devices` *(array<string>)* — lista de `deviceId` vinculados ao usuário

**Exemplo (sanitizado):**
```json
{
  "created_at": "2025-12-30T19:16:03Z",
  "email": "user@example.com",
  "name": "Nome do Usuário",
  "role": "customer",
  "uid": "<uid>",
  "my_devices": ["ESP32-AgroSmart-Station-V5", "ESP32C3-AgroSmart-Sensor-01"]
}
```

---

### Coleção `devices`
**Path:** `devices/{deviceId}`  
**DocId:** o `deviceId` (ex.: `ESP32-AgroSmart-Station-V5`)

**Campos (exemplos):**
- `created_at` *(timestamp)*
- `device_id` *(string)* — geralmente igual ao docId
- `online` *(bool)*
- `owner_uid` *(string)* — dono do dispositivo (uid do Firebase Auth)
- `settings` *(map)*:
  - `capabilities` *(array<string>)* — ex.: `["air","soil","light","rain","uv"]`
  - `device_name` *(string)*
  - `enable_weather_control` *(bool)*
  - `latitude` *(number)*
  - `longitude` *(number)*
  - `manual_valve_duration` *(number)* — minutos
  - `target_soil_moisture` *(number)* — %
  - `timezone_offset` *(number)* — ex.: `-3`

**Exemplo (sanitizado):**
```json
{
  "created_at": "2025-12-31T03:28:50Z",
  "device_id": "ESP32-AgroSmart-Station-V5",
  "online": false,
  "owner_uid": "<uid>",
  "settings": {
    "capabilities": ["air", "soil", "light", "rain", "uv"],
    "device_name": "Jardim",
    "enable_weather_control": true,
    "latitude": -30.8651058,
    "longitude": -51.8191699,
    "manual_valve_duration": 2,
    "target_soil_moisture": 62,
    "timezone_offset": -3
  }
}
```

---

### Subcoleção `devices/{deviceId}/schedules`
**Path:** `devices/{deviceId}/schedules/{scheduleId}`

**Campos (exemplo observado):**
- `days` *(array<number>)* — 1..7 (Seg..Dom)
- `duration_minutes` *(number)*
- `enabled` *(bool)*
- `label` *(string)*
- `time` *(string)* — `"HH:mm"`

**Exemplo (sanitizado):**
```json
{
  "days": [1, 4, 6, 7],
  "duration_minutes": 16,
  "enabled": true,
  "label": "Rega da madrugada",
  "time": "00:15"
}
```

---

### Subcoleção `devices/{deviceId}/history`
**Path:** `devices/{deviceId}/history/{historyId}`  
> Nos prints só aparece como subcoleção (não deu para ver o formato do documento).  
Sugestão comum: `timestamp`, `type`, `message`, `source`, `command_id`, etc.

---

## 2) O que suas rules atuais fazem (importante)

Pelo print de Rules, você está em modo **DEV**:

- `allow read, write: if request.auth != null;`

Isso significa: **qualquer usuário logado pode ler/escrever em qualquer coleção**.  
Então, “testar rules” agora só vai provar que **logado funciona** e **deslogado dá PERMISSION_DENIED** — mas **não testa ownership**.

---

## 3) Como testar Firestore Rules (3 jeitos)

### A) Teste mais fácil (Console): “Laboratório de testes de regras”
1. Vá em **Firestore → Regras → Desenvolver e testar**.
2. Em **Simular**, escolha a operação:
   - `get` (ler 1 doc),
   - `list` (consulta),
   - `create`, `update`, `delete`.
3. Informe o **path** (ex.: `devices/ESP32-AgroSmart-Station-V5`).
4. Em **Authentication**, marque como “authenticated” e coloque:
   - `uid = <uid do dono>` e rode → **esperado: ALLOW**
   - `uid = <outro uid>` e rode → **esperado: DENY** *(quando você fechar por ownership)*
5. Repita para:
   - `users/<uid>`
   - `devices/<deviceId>/schedules/<scheduleId>`
   - `devices/<deviceId>/history/<historyId>`

> Dica: primeiro você testa no laboratório **antes de publicar** as rules.

### B) Teste na prática (App)
- **Cenário 1 (OK):** logado como dono → abre Dashboard, Agenda, Logs.
- **Cenário 2 (NEGATIVO):** criar um segundo usuário (signup) → tentar acessar o device do primeiro:
  - se a app tentar “vincular” o mesmo `deviceId`, você deve receber erro de permissão.
- **Cenário 3:** deslogar → qualquer `StreamBuilder` do Firestore deve falhar com `PERMISSION_DENIED` e a UI deve mandar para login (ou mostrar mensagem).

### C) Teste “profissional” (Local): Firebase Emulator Suite
Isso é o melhor para validar rules sem mexer no ambiente real.

1. Instale o CLI:
   ```bash
   npm i -g firebase-tools
   ```
2. No root do projeto (onde você tem o `firebase.json` / `.firebaserc`), inicialize:
   ```bash
   firebase init emulators
   # selecione Firestore + Authentication (opcional, mas ajuda)
   ```
3. Rode:
   ```bash
   firebase emulators:start --only firestore,auth
   ```
4. No Flutter (modo debug), aponte o Firestore para o emulador (exemplo):
   ```dart
   FirebaseFirestore.instance.useFirestoreEmulator('10.0.2.2', 8080); // Android emulator
   // ou IP da sua máquina na rede quando é celular físico
   ```
5. Aí você testa flows reais sem quebrar o banco em produção.

---

## 4) Checklist de testes mínimos (o que você deve “ver”)

Quando as rules forem por ownership, o esperado é:

- ✅ `users/{uid}`: só o próprio usuário lê/escreve.
- ✅ `devices/{deviceId}`: só o `owner_uid` lê/escreve.
- ✅ `schedules`: só o dono do device.
- ✅ `history`: leitura só do dono; escrita **bloqueada** no client (ideal), e escrita só por backend (Admin SDK) fora das rules.

---

## 5) Template de rules por ownership (para você testar no laboratório)

> **Atenção:** cole no laboratório, rode os testes (A) e só publique quando os ALLOW/DENY estiverem batendo.

```js
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function signedIn() {
      return request.auth != null;
    }

    function isSelf(uid) {
      return signedIn() && request.auth.uid == uid;
    }

    function deviceOwner(deviceId) {
      return signedIn()
        && get(/databases/$(database)/documents/devices/$(deviceId)).data.owner_uid == request.auth.uid;
    }

    match /users/{uid} {
      allow read, write: if isSelf(uid);
    }

    match /devices/{deviceId} {
      // lê o doc do device
      allow read: if signedIn() && resource.data.owner_uid == request.auth.uid;

      // cria/atualiza/deleta só se for dono (e impede troca de owner)
      allow create: if signedIn() && request.resource.data.owner_uid == request.auth.uid;
      allow update, delete: if signedIn()
        && resource.data.owner_uid == request.auth.uid
        && request.resource.data.owner_uid == resource.data.owner_uid;

      match /schedules/{scheduleId} {
        allow read, write: if deviceOwner(deviceId);
      }

      match /history/{historyId} {
        allow read: if deviceOwner(deviceId);
        allow write: if false; // só backend (Admin SDK)
      }
    }
  }
}
```

Se você quiser permitir “compartilhar” device com mais usuários no futuro, a regra muda para checar também `users/{uid}.my_devices` (me fala e eu adapto).

