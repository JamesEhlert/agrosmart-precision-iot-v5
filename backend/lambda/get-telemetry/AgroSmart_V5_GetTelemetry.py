import json
import boto3
import base64
from decimal import Decimal
from boto3.dynamodb.conditions import Key

TABLE_NAME = 'AgroTelemetryData_V5'
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(TABLE_NAME)

class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return int(obj) if obj % 1 == 0 else float(obj)
        return super(DecimalEncoder, self).default(obj)

def lambda_handler(event, context):
    """
    Parâmetros (QueryString):
    - device_id (Obrigatório)
    - limit (Opcional, default 50)
    - next_token (Opcional, paginação)
    - start_time (Opcional, Unix Timestamp) -> NOVO
    - end_time (Opcional, Unix Timestamp)   -> NOVO
    """
    print(f"Evento: {event}")

    try:
        params = event.get('queryStringParameters', {}) or {}
        device_id = params.get('device_id')
        limit = int(params.get('limit', 50))
        next_token = params.get('next_token')
        
        # Novos parâmetros de filtro temporal
        start_time = params.get('start_time')
        end_time = params.get('end_time')

        if not device_id:
            return build_response(400, {'error': 'device_id obrigatorio'})

        # Construção da Query Base
        key_condition = Key('device_id').eq(device_id)

        # Se enviou datas, adiciona o filtro "BETWEEN"
        if start_time and end_time:
            # DynamoDB espera Decimal ou int para números
            t_start = int(start_time)
            t_end = int(end_time)
            key_condition = key_condition & Key('timestamp').between(t_start, t_end)
            print(f"Filtrando datas: {t_start} até {t_end}")

        query_params = {
            'KeyConditionExpression': key_condition,
            'ScanIndexForward': False, # False = Mais recentes primeiro
            'Limit': limit
        }

        if next_token:
            try:
                decoded_key = json.loads(base64.b64decode(next_token).decode('utf-8'), parse_float=Decimal)
                query_params['ExclusiveStartKey'] = decoded_key
            except Exception:
                return build_response(400, {'error': 'Token invalido'})

        response = table.query(**query_params)
        items = response.get('Items', [])

        result = {
            'data': items,
            'count': len(items)
        }

        if 'LastEvaluatedKey' in response:
            last_key_json = json.dumps(response['LastEvaluatedKey'], cls=DecimalEncoder)
            result['next_token'] = base64.b64encode(last_key_json.encode('utf-8')).decode('utf-8')
        else:
            result['next_token'] = None

        return build_response(200, result)

    except Exception as e:
        print(f"ERRO: {str(e)}")
        return build_response(500, {'error': str(e)})

def build_response(status_code, body):
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, OPTIONS',
            'Access-Control-Allow-Headers': '*'
        },
        'body': json.dumps(body, cls=DecimalEncoder)
    }