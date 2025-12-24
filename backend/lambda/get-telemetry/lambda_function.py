import json
import boto3
import base64
from decimal import Decimal

# Inicializa conexão com DynamoDB
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('AgroTelemetryData_V5') # Nossa tabela V5

# Helper para converter Decimal do DynamoDB para JSON
class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super(DecimalEncoder, self).default(obj)

def lambda_handler(event, context):
    """
    API Endpoint para buscar histórico de telemetria.
    Parâmetros (QueryString):
    - device_id: ID do dispositivo (Obrigatório)
    - limit: Quantidade de registros (Opcional, default 50)
    - next_token: Paginação (Opcional)
    """
    try:
        params = event.get('queryStringParameters', {})
        device_id = params.get('device_id')
        limit = int(params.get('limit', 50))
        
        if not device_id:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Missing device_id'})
            }

        # Configura a query
        query_kwargs = {
            'KeyConditionExpression': boto3.dynamodb.conditions.Key('device_id').eq(device_id),
            'ScanIndexForward': False, # Do mais recente para o antigo
            'Limit': limit
        }

        # Paginação (Decodifica o token se existir)
        if params.get('next_token'):
            last_key_json = base64.b64decode(params['next_token']).decode('utf-8')
            query_kwargs['ExclusiveStartKey'] = json.loads(last_key_json, parse_float=Decimal)

        # Executa a busca
        response = table.query(**query_kwargs)
        items = response.get('Items', [])

        # Prepara resposta
        result = {
            'data': items,
            'count': len(items)
        }

        # Se tiver mais páginas, gera o token
        if 'LastEvaluatedKey' in response:
            last_key = json.dumps(response['LastEvaluatedKey'], cls=DecimalEncoder)
            result['next_token'] = base64.b64encode(last_key.encode('utf-8')).decode('utf-8')

        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*' # CORS liberado para o App
            },
            'body': json.dumps(result, cls=DecimalEncoder)
        }

    except Exception as e:
        print(f"Erro: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Internal Server Error'})
        }