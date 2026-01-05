# Arquivo: backend/aws_lambda_scheduler/lambda_function.py

import json
import boto3
import datetime
import pytz
from google.oauth2 import service_account
from google.cloud import firestore

# --- CONFIGURAÇÕES ---
# Substitua pelo ARN do seu segredo na AWS se mudar
SECRET_ARN = "arn:aws:secretsmanager:us-east-2:851725302756:secret:agrosmart/gcp-credentials-G03K1Z"
REGION_NAME = "us-east-2"

# Tópico MQTT exato que o ESP32 escuta (conforme firmware C++)
IOT_TOPIC = "agrosmart/v5/command" 

# Inicializa clientes AWS
secrets_client = boto3.client('secretsmanager', region_name=REGION_NAME)
iot_client = boto3.client('iot-data', region_name=REGION_NAME)

# Variável global para cache da conexão (Reutiliza conexão entre execuções quentes)
db = None

def get_firestore_client():
    global db
    if db: return db

    print("🔄 Buscando credenciais no Secrets Manager...")
    try:
        response = secrets_client.get_secret_value(SecretId=SECRET_ARN)
        if 'SecretString' in response:
            secret_dict = json.loads(response['SecretString'])
            creds = service_account.Credentials.from_service_account_info(secret_dict)
            db = firestore.Client(credentials=creds)
            print("✅ Conectado ao Firestore com sucesso!")
            return db
        else:
            raise Exception("Segredo não está em formato texto (SecretString).")
    except Exception as e:
        print(f"❌ Erro ao conectar no Firestore: {e}")
        raise e

def lambda_handler(event, context):
    try:
        # 1. Definir Hora Atual (Fuso Horário São Paulo)
        tz = pytz.timezone('America/Sao_Paulo') 
        now = datetime.datetime.now(tz)
        
        # Ajuste: Python weekday (0=Seg) -> App Flutter (1=Seg)
        current_day_flutter = now.weekday() + 1 
        current_time_str = now.strftime('%H:%M')
        
        print(f"🕒 Verificando agendamentos para: Dia {current_day_flutter} às {current_time_str}")

        firestore_db = get_firestore_client()

        # 2. Busca Agendamentos Ativos (Query Collection Group)
        docs_stream = firestore_db.collection_group('schedules')\
            .where('enabled', '==', True)\
            .where('days', 'array_contains', current_day_flutter)\
            .where('time', '==', current_time_str)\
            .stream()

        count = 0
        executed_list = []

        for doc in docs_stream:
            schedule = doc.to_dict()
            
            # Navegação: schedule -> parent -> device
            device_ref = doc.reference.parent.parent
            device_id = device_ref.id
            
            duration = schedule.get('duration_minutes', 5) * 60 # Converte p/ segundos
            label = schedule.get('label', 'Agendamento')
            
            print(f"🚀 EXECUTANDO: '{label}' no device {device_id} por {duration}s")
            
            # 3. Monta o Payload
            payload = {
                "device_id": device_id,
                "action": "on",
                "duration": duration,
                "origin": "schedule"
            }
            
            # 4. Envia para o Tópico Global de Comandos
            print(f"📡 Publicando no tópico: {IOT_TOPIC}")
            
            iot_client.publish(
                topic=IOT_TOPIC,
                qos=1,
                payload=json.dumps(payload)
            )
            
            count += 1
            executed_list.append(f"{device_id}: {label}")

        result_msg = f'Processamento concluído. {count} agendamentos executados: {executed_list}'
        print(result_msg)
        
        return {
            'statusCode': 200,
            'body': json.dumps(result_msg)
        }

    except Exception as e:
        print(f"❌ ERRO CRÍTICO NA LAMBDA: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Erro: {str(e)}")
        }