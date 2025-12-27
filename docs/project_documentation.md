# Documentação Técnica - AgroSmart V5
## Histórico de Versões e Incidentes Técnicos (Dezembro/2025)

### Incidente: Instabilidade na Redundância de Wi-Fi (Versões 5.5 a 5.9)

**Objetivo:**
Implementar um sistema de alta disponibilidade que alternasse automaticamente entre 4 redes Wi-Fi e validasse a conexão com a internet antes de enviar dados.

**Tentativas Realizadas:**
1. **Ping HTTP (Google DNS):** Tentativa de verificar conexão pingando `8.8.8.8`.
2. **Contador de Falhas MQTT:** Troca de rede após X falhas de envio para AWS.

**Causa das Falhas:**
* **Flapping (Oscilação):** A verificação de conexão era muito sensível. Instabilidades normais da rede 2.4GHz eram interpretadas como "sem internet", forçando o ESP32 a desconectar e reiniciar todo o ciclo de conexão (Scan -> Auth -> DHCP -> SSL Handshake).
* **Blocking I/O:** O tempo gasto tentando conectar e validar 4 redes diferentes consumia todo o tempo da CPU, impedindo que o FreeRTOS executasse a tarefa de leitura de sensores e envio MQTT corretamente. O resultado foi a perda de pacotes e lags no sistema.

**Solução Aplicada (Rollback V5.10):**
Retornou-se à arquitetura de "Single Connection" (Conexão Única Estável). O sistema foca em manter a conexão atual sólida. A redundância manual (alterar variáveis e recompilar) mostrou-se mais confiável para este estágio do projeto.

**Recomendação Futura (Roadmap):**
Para implementar redundância real no futuro, será necessário utilizar a API de Eventos Assíncronos do ESP32 (`WiFi.onEvent`) e mover a lógica de conexão para um Core separado do processador, evitando que a busca por redes trave o envio de dados.