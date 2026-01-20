import json
import boto3
import datetime
import pytz
import urllib.request # Biblioteca nativa para fazer requisições HTTP
from google.oauth2 import service_account
from google.cloud import firestore
from boto3.dynamodb.conditions import Key
from decimal import Decimal

# ==============================================================================
# 1. CONFIGURAÇÕES GERAIS
# ==============================================================================
# ARN do segredo que contém as credenciais do Google Firebase
SECRET_ARN = "arn:aws:secretsmanager:us-east-2:851725302756:secret:agrosmart/gcp-credentials-G03K1Z"
REGION_NAME = "us-east-2"
IOT_TOPIC = "agrosmart/v5/command"
DYNAMO_TABLE = "AgroTelemetryData_V5"

# Configurações da Inteligência Meteorológica
OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"
FORECAST_WINDOW_HOURS = 6   # Olhar as próximas 6 horas
RAIN_PROB_THRESHOLD = 50    # Se chance de chuva > 50%
RAIN_AMOUNT_THRESHOLD = 1.0 # E volume > 1mm, então cancela

# Inicializa clientes AWS
secrets_client = boto3.client('secretsmanager', region_name=REGION_NAME)
iot_client = boto3.client('iot-data', region_name=REGION_NAME)
dynamodb = boto3.resource('dynamodb', region_name=REGION_NAME)
table = dynamodb.Table(DYNAMO_TABLE)

# Cache global da conexão Firestore
db = None

# ==============================================================================
# 2. FUNÇÕES AUXILIARES
# ==============================================================================

def get_firestore_client():
    """Conecta ao Firestore usando credenciais do Secrets Manager"""
    global db
    if db: return db

    print("🔄 Conectando ao Firestore...")
    try:
        response = secrets_client.get_secret_value(SecretId=SECRET_ARN)
        if 'SecretString' in response:
            secret_dict = json.loads(response['SecretString'])
            creds = service_account.Credentials.from_service_account_info(secret_dict)
            db = firestore.Client(credentials=creds)
            print("✅ Firestore Conectado!")
            return db
        else:
            raise Exception("Segredo inválido.")
    except Exception as e:
        print(f"❌ Erro Firestore: {e}")
        raise e

def get_latest_soil_moisture(device_id):
    """Busca a última leitura de umidade do solo no DynamoDB"""
    try:
        response = table.query(
            KeyConditionExpression=Key('device_id').eq(device_id),
            ScanIndexForward=False, # Do mais recente para o mais antigo
            Limit=1
        )
        items = response.get('Items', [])
        if items:
            latest = items[0]
            sensors = latest.get('sensors', {})
            soil = sensors.get('soil_moisture', 0)
            print(f"💧 Umidade Atual ({device_id}): {soil}%")
            return float(soil)
        return None 
    except Exception as e:
        print(f"⚠️ Erro ao ler DynamoDB: {e}")
        return None

def check_rain_forecast(latitude, longitude):
    """
    Consulta a API Open-Meteo para verificar previsão de chuva.
    Retorna: (bool: vai_chover, str: motivo)
    """
    if not latitude or not longitude:
        return False, "Sem coordenadas GPS"

    try:
        # Monta URL para pegar probabilidade e quantidade de chuva hora a hora
        url = f"{OPEN_METEO_URL}?latitude={latitude}&longitude={longitude}&hourly=precipitation_probability,precipitation&forecast_days=1&timezone=auto"
        print(f"🌦️ Consultando API: {url}")
        
        with urllib.request.urlopen(url, timeout=5) as response:
            data = json.loads(response.read().decode())
            
            hourly = data.get('hourly', {})
            probs = hourly.get('precipitation_probability', [])
            amounts = hourly.get('precipitation', [])
            
            # Pega a hora atual (index 0 até FORECAST_WINDOW_HOURS)
            # A API geralmente retorna começando da hora atual (00:00 ou hora corrente dependendo do param)
            # Aqui simplificamos pegando as primeiras N horas retornadas
            
            will_rain = False
            total_rain = 0.0
            max_prob = 0
            
            for i in range(min(len(probs), FORECAST_WINDOW_HOURS)):
                prob = probs[i]
                amount = amounts[i]
                
                total_rain += amount
                if prob > max_prob: max_prob = prob
                
                # Lógica de Decisão
                if prob >= RAIN_PROB_THRESHOLD and amount >= 0.5:
                    will_rain = True

            # Refinamento da decisão: Só cancela se o volume total for relevante
            if will_rain and total_rain >= RAIN_AMOUNT_THRESHOLD:
                msg = f"Chuva prevista: {total_rain:.1f}mm (Max Prob: {max_prob}%) nas próx {FORECAST_WINDOW_HOURS}h"
                return True, msg
            
            return False, f"Sem chuva relevante ({total_rain:.1f}mm)"

    except Exception as e:
        print(f"⚠️ Falha na API de Tempo: {e}")
        return False, "Erro API Meteorológica"

def save_activity_log(device_id, log_type, source, message):
    """Grava o log na sub-coleção 'history' do Firestore"""
    try:
        client = get_firestore_client()
        doc_ref = client.collection('devices').document(device_id).collection('history').document()
        
        doc_ref.set({
            'timestamp': datetime.datetime.now(pytz.utc),
            'type': log_type,   # execution, skipped, error
            'source': source,   # schedule, manual, system
            'message': message
        })
        print(f"📝 Log gravado: [{log_type}] {message}")
    except Exception as e:
        print(f"❌ Erro ao gravar log: {e}")

# ==============================================================================
# 3. LÓGICA PRINCIPAL (HANDLER)
# ==============================================================================

def lambda_handler(event, context):
    try:
        # 1. Hora Atual (Fuso SP)
        tz = pytz.timezone('America/Sao_Paulo')
        now = datetime.datetime.now(tz)
        current_day_flutter = now.weekday() + 1 # 1=Seg, 7=Dom
        current_time_str = now.strftime('%H:%M')
        
        print(f"🕒 Verificando: Dia {current_day_flutter} às {current_time_str}")
        
        firestore_db = get_firestore_client()
        
        # 2. Busca Agendamentos que batem com a hora atual
        # Necessário Índice Composto no Firestore: schedules (enabled ASC, days ARRAY, time ASC)
        docs_stream = firestore_db.collection_group('schedules')\
            .where('enabled', '==', True)\
            .where('days', 'array_contains', current_day_flutter)\
            .where('time', '==', current_time_str)\
            .stream()
            
        count = 0
        
        for doc in docs_stream:
            schedule = doc.to_dict()
            
            # Pega referência do Dispositivo Pai
            device_ref = doc.reference.parent.parent
            device_id = device_ref.id
            
            label = schedule.get('label', 'Agendamento')
            duration = schedule.get('duration_minutes', 5) * 60 # Segundos
            
            print(f"🔎 Analisando: '{label}' para {device_id}")
            
            # --- A. DADOS DO DISPOSITIVO ---
            device_doc = device_ref.get()
            if not device_doc.exists:
                print(f"⚠️ Dispositivo {device_id} não encontrado.")
                continue
                
            device_data = device_doc.to_dict()
            settings = device_data.get('settings', {})
            
            # Configurações
            target_moisture = float(settings.get('target_soil_moisture', 100))
            enable_weather = settings.get('enable_weather_control', False)
            lat = settings.get('latitude', 0.0)
            lon = settings.get('longitude', 0.0)
            
            # --- B. VERIFICAÇÃO DE SOLO ---
            current_moisture = get_latest_soil_moisture(device_id)
            
            if current_moisture is not None and current_moisture >= target_moisture:
                msg = f"Ignorado: Solo em {int(current_moisture)}% (Alvo: {int(target_moisture)}%)"
                save_activity_log(device_id, 'skipped', 'schedule', msg)
                continue

            # --- C. VERIFICAÇÃO METEOROLÓGICA (NOVO) ---
            if enable_weather:
                if lat != 0.0 and lon != 0.0:
                    should_skip, reason = check_rain_forecast(lat, lon)
                    if should_skip:
                        # Log de Pulo Inteligente
                        save_activity_log(device_id, 'skipped', 'weather_ai', f"Cancelado: {reason}")
                        print(f"⛔ {label} cancelado pela previsão do tempo.")
                        continue
                    else:
                        print(f"✅ Previsão limpa: {reason}")
                else:
                    print("⚠️ Clima ativado mas sem GPS configurado. Ignorando checagem.")

            # --- D. EXECUTAR IRRIGAÇÃO ---
            try:
                payload = {
                    "device_id": device_id,
                    "action": "on",
                    "duration": duration,
                    "origin": "schedule"
                }
                
                iot_client.publish(
                    topic=IOT_TOPIC,
                    qos=1,
                    payload=json.dumps(payload)
                )
                
                msg = f"Executado: {label} por {int(duration/60)} min"
                save_activity_log(device_id, 'execution', 'schedule', msg)
                count += 1
                
            except Exception as e:
                err_msg = f"Falha ao enviar comando: {str(e)}"
                save_activity_log(device_id, 'error', 'system', err_msg)
                
        return {
            'statusCode': 200,
            'body': json.dumps(f"Ciclo concluído. {count} execuções.")
        }
        
    except Exception as e:
        print(f"❌ ERRO CRÍTICO: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Erro: {str(e)}")
        }