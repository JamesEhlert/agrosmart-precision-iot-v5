import json
import boto3

# ==============================================================================
# CONFIGURAÇÕES
# ==============================================================================
# Cliente para publicar mensagens no IoT Core
iot_client = boto3.client('iot-data')

# Tópico MQTT onde o ESP32 está ouvindo
TOPIC = 'agrosmart/v5/command'

def lambda_handler(event, context):
    """
    Função Lambda para enviar comandos (Downlink) para o ESP32.
    Recebe POST request com JSON: {"action": "on", "duration": 10}
    """
    print(f"Evento Recebido: {event}")

    try:
        # Tenta ler o corpo da requisição (Body)
        # Se vier vazio, assume objeto vazio para não quebrar
        body_str = event.get('body', '{}')
        body = json.loads(body_str) if body_str else {}
        
        # Extração dos parâmetros
        action = body.get('action')
        duration = body.get('duration')

        # Validação Rigorosa
        # Agora o comando esperado é "on", não mais "water"
        if action != 'on' or duration is None:
            return build_response(400, {
                'error': 'Comando invalido.', 
                'expected_format': {'action': 'on', 'duration': 10} # Exemplo em segundos
            })

        # Monta o pacote MQTT para o ESP32
        payload = {
            'action': 'on',
            'duration': int(duration)
        }

        # Publica no Tópico
        print(f"Publicando no tópico {TOPIC}: {payload}")
        iot_client.publish(
            topic=TOPIC,
            qos=1, # Qualidade de Serviço 1 (Garante entrega pelo menos uma vez)
            payload=json.dumps(payload)
        )

        return build_response(200, {
            'message': 'Comando enviado para a fila MQTT com sucesso!',
            'sent_payload': payload
        })

    except Exception as e:
        print(f"ERRO: {str(e)}")
        return build_response(500, {'error': 'Erro interno', 'details': str(e)})

def build_response(status, body):
    """Auxiliar para resposta HTTP com CORS"""
    return {
        'statusCode': status,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*', # Importante para o App funcionar
            'Access-Control-Allow-Methods': 'POST, OPTIONS'
        },
        'body': json.dumps(body)
    }