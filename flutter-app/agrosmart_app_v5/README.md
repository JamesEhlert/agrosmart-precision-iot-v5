# agrosmart_app_v5

A new Flutter project.

📝 2. Atualização da Documentação Técnica

Como descobrimos que a Lambda é rigorosa com o formato do JSON, é crucial documentar isso para não esquecermos no futuro (por exemplo, quando formos fazer a automação).

Eu gerei abaixo um texto técnico. Sugiro que você copie e cole isso no seu arquivo de anotações do projeto (ex: README.md ou docs/API_REFERENCE.md), na seção de Integração AWS.
📄 Registro de Alteração: Controle Manual de Irrigação

Data: 03/01/2026 Status: Funcional (Testado via Postman e App Mobile)

Endpoint de Comando:

    URL: https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/command

    Método: POST

Estrutura do Payload (JSON Obrigatório): Diferente da documentação inicial, a Lambda não aceita chaves arbitrárias. O formato estrito exigido é:
JSON

{
  "device_id": "ESP32-AgroSmart-Station-V5", 
  "action": "on",       
  "duration": 300       
}

    device_id: String. O ID exato registrado no DynamoDB/IoT Core.

    action: String. Deve ser estritamente "on" (minúsculo). O valor "OPEN_VALVE" falha.

    duration: Inteiro. Tempo em segundos para manter a válvula aberta.

🚀 Próximo Passo: Agendamentos

Agora que temos:

    Monitoramento (GET): ✅ Funcionando.

    Controle Manual (POST): ✅ Funcionando.






    📚 2. Documentação Técnica: Módulo de Agendamentos

Copie o conteúdo abaixo para o seu arquivo de documentação técnica. Isso será essencial para manutenção futura e para entender como o App conversa com o Banco de Dados.
📄 Módulo: Gestão de Agendamentos (Schedules)

Versão: 1.0 Status: Implementado e Testado Tecnologia: Flutter + Firebase Firestore

1. Visão Geral Permite que o usuário crie regras de automação para seus dispositivos. O App atua como interface de gestão, salvando as regras na nuvem. A execução (o ato de ligar a válvula) é delegada ao Backend (AWS Lambda).

2. Arquitetura de Dados (NoSQL) Os agendamentos são armazenados como uma sub-coleção dentro do documento do dispositivo, garantindo escalabilidade e organização.

    Caminho: devices/{deviceID}/schedules/{scheduleID}

    Modelo JSON:
    JSON

    {
      "label": "Rega da Manhã",   // String: Nome amigável
      "time": "08:00",            // String: Formato HH:mm
      "days": [1, 3, 5],          // Array<Int>: 1=Segunda ... 7=Domingo
      "duration_minutes": 10,     // Int: Tempo de rega
      "enabled": true             // Bool: Ativo/Inativo
    }

3. Funcionalidades do App

    Listagem em Tempo Real: Uso de StreamBuilder para refletir mudanças instantaneamente (ex: se outro administrador alterar, atualiza na hora).

    Criação/Edição Unificada: Reutilização da tela ScheduleFormScreen. Se receber um objeto, entra em modo de edição; caso contrário, criação.

    Controle Rápido: Switch (Toggle) na listagem para ativar/desativar sem abrir o formulário.

    Validações:

        Obrigatório selecionar ao menos 1 dia da semana.

        Limite lógico de 100 agendamentos por dispositivo (controlado no SchedulesService).

4. Segurança (Firestore Rules) As regras de segurança foram atualizadas para permitir leitura/escrita para usuários autenticados (Auth != null). Nota: Futuramente, restringiremos apenas ao owner_uid do dispositivo.