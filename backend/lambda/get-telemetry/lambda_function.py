import json
import boto3
import base64
from decimal import Decimal
from boto3.dynamodb.conditions import Key

# ==============================================================================
# CONFIGURAÇÕES GLOBAIS
# Nome da tabela definido como constante para facilitar manutenção
# ==============================================================================
TABLE_NAME = 'AgroTelemetryData_V5'
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(TABLE_NAME)

# ==============================================================================
# CLASSE AUXILIAR: DECIMAL ENCODER
# O DynamoDB retorna números como objetos "Decimal" que o JSON padrão não aceita.
# Esta classe converte tudo para Int ou Float automaticamente.
# ==============================================================================
class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            # Se for número redondo (ex: 25.0), vira Inteiro. Se não (25.3), vira Float.
            return int(obj) if obj % 1 == 0 else float(obj)
        return super(DecimalEncoder, self).default(obj)

# ==============================================================================
# FUNÇÃO PRINCIPAL (HANDLER)
# ==============================================================================
def lambda_handler(event, context):
    """
    Endpoint de Leitura de Telemetria.
    Recebe requisições GET do API Gateway.
    Parâmetros Suportados (QueryString):
      - device_id (Obrigatório): ID do dispositivo (ex: ESP32-AgroSmart-Station-V5)
      - limit (Opcional): Quantos registros retornar (Padrão: 20)
      - next_token (Opcional): Token para carregar a próxima página de dados
    """
    print(f"Evento Recebido: {event}") # Log no CloudWatch para debug

    try:
        # 1. Extração e Validação de Parâmetros
        # O API Gateway envia os parâmetros de URL dentro de 'queryStringParameters'
        params = event.get('queryStringParameters', {}) or {}
        
        device_id = params.get('device_id')
        limit = int(params.get('limit', 20)) 
        next_token = params.get('next_token')

        # Se não enviou o ID, retorna erro 400 (Bad Request)
        if not device_id:
            return build_response(400, {'error': 'Parametro obrigatorio ausente: device_id'})

        # 2. Configuração da Consulta (Query) ao DynamoDB
        query_params = {
            'KeyConditionExpression': Key('device_id').eq(device_id),
            'ScanIndexForward': False, # False = Ordenação Decrescente (Mais recente primeiro)
            'Limit': limit
        }

        # Lógica de Paginação (Se o app pediu a "próxima página")
        if next_token:
            try:
                # O token viaja codificado em Base64 para não quebrar a URL. Decodificamos aqui.
                decoded_key = json.loads(base64.b64decode(next_token).decode('utf-8'), parse_float=Decimal)
                query_params['ExclusiveStartKey'] = decoded_key
            except Exception:
                return build_response(400, {'error': 'Token de paginacao invalido'})

        # 3. Execução da Consulta
        response = table.query(**query_params)
        items = response.get('Items', [])
        
        # 4. Preparação da Resposta
        result = {
            'data': items,           # A lista de leituras dos sensores
            'count': len(items)      # Quantos itens vieram
        }

        # Verifica se sobrou dados no banco (Paginação)
        if 'LastEvaluatedKey' in response:
            # Se sobrou, criamos um token para o App pedir o resto depois
            last_key_json = json.dumps(response['LastEvaluatedKey'], cls=DecimalEncoder)
            result['next_token'] = base64.b64encode(last_key_json.encode('utf-8')).decode('utf-8')
        else:
            result['next_token'] = None

        return build_response(200, result)

    except Exception as e:
        print(f"ERRO CRITICO: {str(e)}")
        return build_response(500, {'error': 'Erro interno no servidor', 'details': str(e)})

# ==============================================================================
# FUNÇÃO AUXILIAR: RESPOSTA HTTP
# Constrói o pacote de resposta com cabeçalhos CORS (Cross-Origin Resource Sharing)
# Isso permite que seu App ou Site acessem essa API sem bloqueio de navegador.
# ==============================================================================
def build_response(status_code, body):
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',  # Libera acesso global (Crucial para Apps)
            'Access-Control-Allow-Methods': 'GET, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'
        },
        'body': json.dumps(body, cls=DecimalEncoder)
    }