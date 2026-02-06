import os
import json
import time
import uuid
import boto3

# =========================
# Config (via env vars)
# =========================
AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
TOPIC = os.getenv("IOT_COMMAND_TOPIC", "agrosmart/v5/command")

# (Opcional) endpoint do IoT Data Plane (se você quiser fixar explicitamente)
# Ex.: https://a39ub0vpt280b2-ats.iot.us-east-2.amazonaws.com
IOT_DATA_ENDPOINT_URL = os.getenv("IOT_DATA_ENDPOINT_URL")

MAX_DURATION_SECONDS = int(os.getenv("MAX_DURATION_SECONDS", "900"))  # 15 min (segurança)
ALLOWED_ACTIONS = {"on"}  # de acordo com seu firmware/contrato atual

# Cliente IoT Data
if IOT_DATA_ENDPOINT_URL:
    client = boto3.client("iot-data", region_name=AWS_REGION, endpoint_url=IOT_DATA_ENDPOINT_URL)
else:
    client = boto3.client("iot-data", region_name=AWS_REGION)


# =========================
# Helpers
# =========================
def build_response(status_code: int, body: dict):
    """Resposta padrão com CORS (igual seu GetTelemetry)."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "*",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _get_http_method(event: dict) -> str:
    """Compatível com API Gateway REST (v1) e HTTP API (v2)."""
    if "httpMethod" in event:
        return event["httpMethod"]
    rc = event.get("requestContext", {})
    http = rc.get("http", {})
    return http.get("method", "")


def parse_json_body(event: dict) -> dict:
    """Extrai e converte body JSON (considera base64)."""
    if "body" not in event or event["body"] is None:
        # Algumas configurações podem mandar o JSON direto no event (não recomendado, mas suportamos)
        return event if isinstance(event, dict) else {}

    raw = event["body"]
    if isinstance(raw, dict):
        return raw

    if not isinstance(raw, str) or not raw.strip():
        raise ValueError("Body vazio")

    # base64?
    if event.get("isBase64Encoded") is True:
        import base64
        raw = base64.b64decode(raw).decode("utf-8")

    return json.loads(raw)


def parse_int(value, default=0) -> int:
    if value is None:
        return default
    if isinstance(value, bool):
        # evita True/False virar 1/0 sem querer
        raise ValueError("duration inválido (bool não permitido)")
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        value = value.strip()
        if value == "":
            return default
        return int(float(value))
    raise ValueError("duration inválido")


def validate_payload(body: dict) -> dict:
    """
    Valida e normaliza o payload do comando.
    Retorna payload normalizado pronto para publicar.
    """
    device_id = body.get("device_id")
    action = body.get("action")
    duration_raw = body.get("duration", 0)
    origin = body.get("origin", "manual")
    command_id = body.get("command_id") or str(uuid.uuid4())

    if not isinstance(device_id, str) or not device_id.strip():
        raise ValueError("device_id é obrigatório")
    device_id = device_id.strip()

    # guardrail simples para evitar payloads abusivos
    if len(device_id) > 80:
        raise ValueError("device_id muito longo")

    if not isinstance(action, str) or not action.strip():
        raise ValueError("action é obrigatório")
    action = action.strip().lower()

    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"action inválido. Permitidos: {sorted(ALLOWED_ACTIONS)}")

    duration = parse_int(duration_raw, default=0)
    if duration < 0:
        raise ValueError("duration não pode ser negativo")

    # segurança: não aceitar duration gigante
    if duration > MAX_DURATION_SECONDS:
        raise ValueError(f"duration acima do máximo permitido ({MAX_DURATION_SECONDS}s)")

    if not isinstance(origin, str):
        origin = "manual"
    origin = origin.strip() or "manual"
    if len(origin) > 30:
        origin = origin[:30]

    return {
        "device_id": device_id,
        "action": action,
        "duration": duration,
        "origin": origin,
        "command_id": command_id,
        "issued_at": int(time.time()),
    }


def lambda_handler(event, context):
    # Preflight (caso OPTIONS bata na Lambda por algum motivo)
    method = _get_http_method(event)
    if method.upper() == "OPTIONS":
        return build_response(200, {"ok": True})

    try:
        print("Evento recebido:", json.dumps(event)[:1500])  # limita log para não poluir

        body = parse_json_body(event)
        payload = validate_payload(body)

        print(f"Publicando no tópico {TOPIC}: {payload}")

        client.publish(
            topic=TOPIC,
            qos=1,
            payload=json.dumps(payload),
        )

        # Compatível com seu app atual + adiciona command_id
        return build_response(200, {
            "message": "Comando enviado com sucesso",
            "target": payload["device_id"],
            "command_id": payload["command_id"],
        })

    except ValueError as e:
        # Erros de validação
        return build_response(400, {"message": str(e)})

    except Exception as e:
        print("Erro interno:", str(e))
        return build_response(500, {
            "message": "Erro interno na Lambda",
            "error": str(e),
        })
