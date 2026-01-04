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