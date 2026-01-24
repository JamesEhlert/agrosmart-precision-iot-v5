import json
import boto3

# Configuração
client = boto3.client('iot-data', region_name='us-east-2') # Confirme sua região
TOPIC = "agrosmart/v5/command"

def lambda_handler(event, context):
    try:
        # Debug: Ver o que chegou do Flutter
        print("Evento recebido:", event)
        
        # 1. Extrair dados do corpo da requisição (HTTP POST)
        # O Flutter manda o body como string dentro de 'body', ou direto no event dependendo da config
        body = json.loads(event['body']) if 'body' in event else event
        
        device_id = body.get('device_id')
        action = body.get('action')
        duration = body.get('duration', 0)
        
        if not device_id or not action:
            return {
                'statusCode': 400,
                'body': json.dumps({'message': 'Erro: device_id e action são obrigatórios'})
            }

        # 2. Montar o Payload MQTT com o device_id (Unicast)
        mqtt_payload = {
            "device_id": device_id,  # <--- O SEGREDO ESTÁ AQUI
            "action": action,
            "duration": duration
        }
        
        # 3. Publicar no Tópico
        print(f"Publicando no tópico {TOPIC}: {mqtt_payload}")
        
        client.publish(
            topic=TOPIC,
            qos=1,
            payload=json.dumps(mqtt_payload)
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'Comando enviado com sucesso', 'target': device_id})
        }
        
    except Exception as e:
        print("Erro:", str(e))
        return {
            'statusCode': 500,
            'body': json.dumps({'message': 'Erro interno na Lambda', 'error': str(e)})
        }