# AgroSmart V5 — Autorização end-to-end (Flutter + Firebase Auth + AWS API Gateway)

Este documento descreve **o que foi implementado**, **por que foi feito**, **como funciona** e **como testar** a camada de autorização do AgroSmart V5.  
A ideia é que você consiga explicar isso com segurança em uma entrevista — de forma técnica, mas clara.

---

## 1) Problema que estávamos resolvendo

O app Flutter consome endpoints na AWS (API Gateway) para:

- **Ler telemetria** (`GET /telemetry`)
- **Enviar comandos** para o dispositivo (ex.: ligar válvula) (`POST /command`)

Antes, o API Gateway aceitava chamadas sem uma validação forte do usuário. Ao mesmo tempo, o app já usava **Firebase Authentication** (login), então fazia sentido **reaproveitar o token do Firebase** para proteger a API na AWS.

### Objetivos de segurança

1. **Somente usuários autenticados** podem chamar `/telemetry` e `/command`.
2. O app deve enviar **Authorization: Bearer <Firebase ID Token>**.
3. A AWS deve **validar o token** (issuer + audience + assinatura) antes de permitir o acesso.
4. O app deve lidar bem com:
   - token expirado → **refresh automático** e retry
   - permissão negada → mensagem clara e comportamento consistente

---

## 2) Visão geral da arquitetura implementada

### Fluxo (alto nível)

1. Usuário faz login no app (Firebase Auth).
2. O app obtém um **Firebase ID Token**.
3. O app chama a AWS (API Gateway) enviando:
   - `Authorization: Bearer <ID_TOKEN>`
4. O API Gateway chama um **Lambda Authorizer (CUSTOM / TOKEN)**.
5. O Authorizer valida o token usando as chaves públicas do Google (JWKS).
6. Se válido, o Authorizer retorna uma policy **Allow** para aquele request.
7. A chamada segue para o backend (Lambda/integração) e retorna a resposta ao app.

---

## 3) O que foi implementado no Flutter (cliente)

### Arquivo principal
- `flutter-app/agrosmart_app_v5/lib/services/aws_service.dart`

### 3.1 Cabeçalho Bearer automaticamente

Implementamos helpers no `AwsService` para:

- pegar o usuário atual:
  - `FirebaseAuth.instance.currentUser`
- obter token:
  - `user.getIdToken(forceRefresh)`
- montar headers:
  - `Authorization: Bearer <token>`
  - `Content-Type: application/json`

Se não existe usuário logado → lança `UnauthorizedException`.

### 3.2 Retry automático em 401 (token expirado)

Se a AWS responder **401**, o app:

1. força refresh do token (`getIdToken(true)`)
2. tenta **mais 1x** a mesma chamada
3. se falhar de novo → trata como sessão inválida

### 3.3 Exceptions tipadas (UI mais limpa)

Criamos exceções para permitir tratamento claro na UI:

- `ApiException(statusCode, message)`
- `UnauthorizedException` (401)
- `ForbiddenException` (403)

Assim, telas como Dashboard/History conseguem redirecionar corretamente e mostrar mensagens coerentes.

---

## 4) O que foi implementado na AWS (servidor)

### 4.1 API Gateway (REST)

- Região: `us-east-2`
- `API_ID = r6rky7wzx6`
- Stage: `prod`
- Recursos:
  - `/telemetry` (GET)
  - `/command` (POST)

### 4.2 Lambda Authorizer (Firebase Bearer)

- Função: `AgroSmart_Firebase_Authorizer`
- Runtime: `nodejs20.x`
- Env var: `FIREBASE_PROJECT_ID=agrosmart-v5`

Validação do token:

- JWKS do Google:
  - `https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com`
- Verifica:
  - **issuer**: `https://securetoken.google.com/<PROJECT_ID>`
  - **audience**: `<PROJECT_ID>`
- Se ok → policy `Allow` para `event.methodArn`
- Se falhar → `"Unauthorized"` → **401** no API Gateway

### 4.3 IAM Role para o Lambda

- Role: `AgroSmartFirebaseAuthorizerRole`
- Policy:
  - `AWSLambdaBasicExecutionRole` (logs no CloudWatch)

### 4.4 Permissão para API Gateway invocar o Lambda

- Principal: `apigateway.amazonaws.com`
- Source ARN:
  - `arn:aws:execute-api:us-east-2:<ACCOUNT_ID>:r6rky7wzx6/authorizers/*`

### 4.5 Criando o Authorizer no API Gateway

- Nome: `FirebaseBearer`
- Tipo: `TOKEN`
- `identitySource`: `method.request.header.Authorization`
- TTL: `0` (valida sempre; mais seguro)

### 4.6 Aplicando o Authorizer nos métodos

- `/telemetry` **GET** → `authorizationType=CUSTOM` + `authorizerId=...`
- `/command` **POST** → `authorizationType=CUSTOM` + `authorizerId=...`
- Deployment no stage `prod`

---

## 5) Firestore: regras e “history”

Descobrimos que o **app não escreve** em `devices/{deviceId}/history`.  
Quem escreve é o backend:

- `backend/lambda/aws_lambda_scheduler/AgroSmart_Scheduler_Logic.py`
- função `save_activity_log(...)` → grava em:
  - `devices/{device_id}/history/{logId}`

Logo, a regra segura é:

- owner pode **ler** `history`
- client **não pode escrever** `history`

---

## 6) Como testamos (e o que os testes provaram)

### 6.1 Testes no API Gateway (curl)

- Sem token → **401**
- Token inválido → **401**

✅ Prova que a API está protegida.

### 6.2 Teste real via Flutter

Logs mostram:

- header Bearer sendo setado
- telemetria carregando
- comando enviando com sucesso

✅ Prova o fluxo end-to-end.

### 6.3 Firestore Rules — unit tests (Emulator)

Validamos:

- owner lê seus docs
- outros usuários são bloqueados
- schedules ok
- history write bloqueado
- history read ok

Resultado final:
- **7 passing**

---

## 7) Como explicar isso em entrevista (resposta modelo)

> “Eu uso Firebase Authentication no app. Depois do login, eu envio o Firebase ID Token no header `Authorization: Bearer` para a AWS.  
> No API Gateway eu configurei um Lambda Authorizer que valida o JWT usando as chaves públicas do Google (JWKS) e confere issuer/audience do projeto.  
> Se o token é válido, o Authorizer retorna uma policy Allow; se não, retorna 401.  
> No app eu implementei retry automático em 401 com refresh do token, e tratei 401/403 com exceptions tipadas.  
> No Firestore, as rules garantem que cada device pertence a um owner e que a subcoleção history só pode ser lida pelo owner, não escrita pelo cliente.”

---

## 8) Padrões profissionais aplicados

- **Single source of identity** (Firebase Auth)
- **Zero secrets no app**
- **Validação JWT correta** (assinatura + issuer + audience)
- **Retry em token expirado**
- **Least privilege** (history read-only)

---

## 9) Melhorias futuras (opcional)

1. TTL do Authorizer > 0 (ex.: 60s) para reduzir latência/custo
2. Verificação de autorização por `device_id` no Authorizer (fine-grained)
3. Cancelar listeners/streams do Firestore no logout (reduzir warnings)

---

## 10) Referências do ambiente

- AWS Account: `851725302756`
- Region: `us-east-2`
- API Gateway: `r6rky7wzx6`
- Stage: `prod`
- Lambda: `AgroSmart_Firebase_Authorizer`
- IAM Role: `AgroSmartFirebaseAuthorizerRole`
- Authorizer: `FirebaseBearer`
- Firebase Project ID: `agrosmart-v5`

---

## 11) Checklist rápido

- [ ] App carrega telemetry logado ✅
- [ ] App envia command logado ✅
- [ ] Curl sem token → 401 ✅
- [ ] Curl token inválido → 401 ✅
- [ ] Rules tests: “history write denied” ✅

**Status:** Implementação concluída e validada.
