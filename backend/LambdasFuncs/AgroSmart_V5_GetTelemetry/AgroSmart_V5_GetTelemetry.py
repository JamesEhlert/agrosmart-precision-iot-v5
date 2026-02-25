from __future__ import annotations

import base64
import datetime
import json
import os
from decimal import Decimal
from typing import Any, Dict, Optional

import boto3
from boto3.dynamodb.conditions import Key

# =====================================================================================
# LOG ESTRUTURADO
# =====================================================================================

def _log(level: str, event_name: str, **fields):
    payload = {
        "level": level.upper(),
        "event_name": event_name,
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        **{k: v for k, v in fields.items() if v is not None},
    }
    print(json.dumps(payload, ensure_ascii=False, default=str))


# =====================================================================================
# CONFIG
# =====================================================================================

AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
TABLE_NAME = os.getenv("DYNAMODB_TABLE", "AgroTelemetryData_V5")

# Segurança via env vars (mesmo padrão do SendCommand)
REQUIRE_AUTH = os.getenv("REQUIRE_AUTH", "true").lower() == "true"
ENFORCE_DEVICE_OWNERSHIP = os.getenv("ENFORCE_DEVICE_OWNERSHIP", "true").lower() == "true"

# Proteção contra abuso
MAX_LIMIT = int(os.getenv("MAX_LIMIT", "200"))

# =====================================================================================
# AWS CLIENTS
# =====================================================================================

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table = dynamodb.Table(TABLE_NAME)

secrets_client = boto3.client("secretsmanager", region_name=AWS_REGION)

# =====================================================================================
# FIREBASE (SAFE IMPORT)
# =====================================================================================

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
    FIREBASE_AVAILABLE = True
except ImportError:
    firebase_admin = None
    credentials = None
    firestore = None
    FIREBASE_AVAILABLE = False
    _log("WARN", "firebase_layer_missing", message="Layer Firebase ausente. Ownership não pode ser verificado.")

_firestore_client: Optional[Any] = None

# Cache para evitar tentar inicializar Firestore repetidamente (e travar)
_firestore_init_attempted: bool = False
_firestore_init_failed: bool = False


# =====================================================================================
# JSON ENCODER (Decimal -> int/float)
# =====================================================================================

class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return int(obj) if obj % 1 == 0 else float(obj)
        return super().default(obj)


# =====================================================================================
# HTTP / CORS
# =====================================================================================

def build_response(status_code: int, body: Dict[str, Any]) -> Dict[str, Any]:
    """
    Nota:
    - Você já padronizou 403 para {"message":"Forbidden"}.
    - 400/500 ainda usam "error" aqui (polimento futuro).
    """
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Access-Control-Allow-Headers": "*",
        },
        "body": json.dumps(body, cls=DecimalEncoder, ensure_ascii=False),
    }


def _get_http_method(event: Dict[str, Any]) -> str:
    # REST API
    if isinstance(event, dict) and "httpMethod" in event:
        return (event.get("httpMethod") or "").upper()

    # HTTP API
    rc = event.get("requestContext", {}) if isinstance(event, dict) else {}
    http = (rc.get("http", {}) if isinstance(rc, dict) else {}) or {}
    return (http.get("method") or "").upper()


# =====================================================================================
# AUTH: extrair UID do Authorizer
# =====================================================================================

def _extract_user_uid(event: Dict[str, Any]) -> Optional[str]:
    """
    Extrai UID do usuário autenticado.

    Seu authorizer pode popular:
    - requestContext.authorizer.principalId
    - requestContext.authorizer.uid
    - requestContext.authorizer.jwt.claims.user_id / sub (HTTP API JWT style)
    """
    if not isinstance(event, dict):
        return None

    rc = event.get("requestContext", {}) or {}
    auth = rc.get("authorizer", {}) or {}

    uid = None

    if isinstance(auth, dict):
        # Custom Authorizer TOKEN: uid pode vir direto
        uid = auth.get("uid") or auth.get("user_id") or auth.get("sub")

        # principalId é muito comum
        if not uid:
            uid = auth.get("principalId")

        # HTTP API JWT authorizer pattern
        jwt = auth.get("jwt")
        if not uid and isinstance(jwt, dict):
            claims = jwt.get("claims", {}) or {}
            if isinstance(claims, dict):
                uid = claims.get("user_id") or claims.get("sub")

    if isinstance(uid, str) and uid.strip():
        return uid.strip()

    return None


# =====================================================================================
# FIRESTORE INIT (Secrets Manager)  ✅ FAIL-CLOSED RÁPIDO
# =====================================================================================

def _get_secret_arn() -> str:
    """
    Retorna o ARN configurado para o service account do Firebase.
    """
    return (os.getenv("FIREBASE_SA_SECRET_ARN", "").strip()
            or os.getenv("GCP_SECRET_ARN", "").strip())


def _load_service_account_json() -> Optional[Dict[str, Any]]:
    """
    Carrega o service account JSON do Firebase pelo Secrets Manager.
    """
    secret_arn = _get_secret_arn()
    if not secret_arn:
        return None

    try:
        resp = secrets_client.get_secret_value(SecretId=secret_arn)
        if resp.get("SecretString"):
            return json.loads(resp["SecretString"])
        if resp.get("SecretBinary"):
            decoded = base64.b64decode(resp["SecretBinary"]).decode("utf-8", errors="replace")
            return json.loads(decoded)
    except Exception as e:
        # Se o secret falhar, não deve travar a Lambda.
        _log("ERROR", "secret_fetch_failed", secret_arn=secret_arn, error=str(e))
        return None

    return None


def _get_firestore() -> Optional[Any]:
    """
    Inicializa Firestore como singleton (warm start friendly).

    CORREÇÃO "PRODUTO" (fail-closed rápido):
    - Se existe FIREBASE_SA_SECRET_ARN configurado e NÃO conseguimos carregar o JSON,
      NÃO tentamos default credentials.
      Retornamos None imediatamente para a API cair no 403 (ownership falha).
    """
    global _firestore_client, _firestore_init_attempted, _firestore_init_failed

    if not FIREBASE_AVAILABLE:
        return None

    if _firestore_client is not None:
        return _firestore_client

    # Se já falhou antes nesse container, não tente de novo (evita travar e evita 502)
    if _firestore_init_attempted and _firestore_init_failed:
        return None

    # Se já existe app inicializado, reaproveita
    if getattr(firebase_admin, "_apps", None) and firebase_admin._apps:
        _firestore_client = firestore.client()
        return _firestore_client

    _firestore_init_attempted = True

    secret_arn = _get_secret_arn()
    sa_obj = _load_service_account_json()

    # ✅ Caso PROD: secret configurado, mas não carregou -> NÃO tenta default credentials.
    if secret_arn and not sa_obj:
        _log("WARN", "firebase_init_blocked_missing_service_account",
             message="Service account não carregou do Secrets Manager. Fail-closed rápido ativado.",
             secret_arn=secret_arn)
        _firestore_init_failed = True
        return None

    try:
        if sa_obj:
            cred = credentials.Certificate(sa_obj)
            firebase_admin.initialize_app(cred)
            _log("INFO", "firebase_init_ok", mode="service_account_from_secrets")
        else:
            # Apenas para ambientes DEV/sem secret configurado:
            firebase_admin.initialize_app()
            _log("INFO", "firebase_init_ok", mode="default_credentials")

        _firestore_client = firestore.client()
        _firestore_init_failed = False
        return _firestore_client

    except Exception as e:
        _log("ERROR", "firebase_init_failed", error=str(e))
        _firestore_init_failed = True
        return None


# =====================================================================================
# OWNERSHIP CHECK (baseado no seu Firestore REAL: owner_uid)
# =====================================================================================

def _assert_device_ownership(device_id: str, user_uid: str) -> bool:
    """
    Confere se devices/{device_id}.owner_uid == user_uid

    Importante (segurança):
    - Se o device não existe => retorna False (e a API devolve 403 genérico)
    - Se Firestore indisponível => retorna False (fail-closed)
    """
    if not user_uid:
        return False

    db = _get_firestore()
    if db is None:
        return False

    try:
        doc = db.collection("devices").document(device_id).get()
        if not doc.exists:
            return False

        data = doc.to_dict() or {}

        # Campo REAL confirmado: owner_uid
        owner = data.get("owner_uid")

        # Compatibilidade caso você mude no futuro para ownerUid
        if owner is None:
            owner = data.get("ownerUid")

        return isinstance(owner, str) and owner == user_uid

    except Exception as e:
        _log("ERROR", "ownership_check_error", device_id=device_id, error=str(e))
        return False


# =====================================================================================
# UTILS
# =====================================================================================

def _parse_int(value: Any, default: int) -> int:
    if value is None:
        return default
    if isinstance(value, bool):
        raise ValueError("invalid int (bool)")
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str) and value.strip():
        return int(float(value.strip()))
    return default


def _decode_next_token(token: str) -> Dict[str, Any]:
    decoded = base64.b64decode(token).decode("utf-8", errors="replace")
    return json.loads(decoded, parse_float=Decimal)


def _encode_next_token(last_evaluated_key: Dict[str, Any]) -> str:
    last_key_json = json.dumps(last_evaluated_key, cls=DecimalEncoder, ensure_ascii=False)
    return base64.b64encode(last_key_json.encode("utf-8")).decode("utf-8")


# =====================================================================================
# HANDLER
# =====================================================================================

def lambda_handler(event: Any, context: Any):
    request_id = getattr(context, "aws_request_id", "n/a")

    method = _get_http_method(event or {})
    if method == "OPTIONS":
        return build_response(200, {"ok": True})

    params = (event or {}).get("queryStringParameters", {}) or {}

    # ---- parâmetros
    device_id = params.get("device_id")
    if not device_id or not isinstance(device_id, str) or not device_id.strip():
        return build_response(400, {"error": "device_id obrigatorio"})
    device_id = device_id.strip()

    try:
        limit = _parse_int(params.get("limit"), default=50)
        if limit < 1:
            limit = 1
        if limit > MAX_LIMIT:
            limit = MAX_LIMIT
    except Exception:
        return build_response(400, {"error": "limit invalido"})

    next_token = params.get("next_token")
    start_time = params.get("start_time")
    end_time = params.get("end_time")

    # ---- auth
    user_uid = _extract_user_uid(event or {})
    if REQUIRE_AUTH and not user_uid:
        _log("WARN", "unauthorized_no_uid", request_id=request_id)
        return build_response(401, {"message": "Unauthorized"})

    # ---- ownership (multi-tenant)
    if ENFORCE_DEVICE_OWNERSHIP:
        ok = _assert_device_ownership(device_id, user_uid or "")
        if not ok:
            # 403 genérico: não vaza se existe ou não
            _log("WARN", "forbidden_device_access", request_id=request_id, device_id=device_id)
            return build_response(403, {"message": "Forbidden"})

    # ---- query DynamoDB
    try:
        key_condition = Key("device_id").eq(device_id)

        # filtro temporal (só aplica se vierem os dois)
        if start_time and end_time:
            t_start = _parse_int(start_time, default=0)
            t_end = _parse_int(end_time, default=0)
            key_condition = key_condition & Key("timestamp").between(t_start, t_end)

        query_params: Dict[str, Any] = {
            "KeyConditionExpression": key_condition,
            "ScanIndexForward": False,  # mais recentes primeiro
            "Limit": limit,
        }

        if next_token:
            try:
                query_params["ExclusiveStartKey"] = _decode_next_token(next_token)
            except Exception:
                return build_response(400, {"error": "Token invalido"})

        response = table.query(**query_params)
        items = response.get("Items", []) or []

        result: Dict[str, Any] = {
            "data": items,
            "count": len(items),
            "next_token": None,
        }

        lek = response.get("LastEvaluatedKey")
        if lek:
            result["next_token"] = _encode_next_token(lek)

        return build_response(200, result)

    except Exception as e:
        _log("ERROR", "dynamo_query_failed", request_id=request_id, error=str(e))
        return build_response(500, {"error": "Internal Server Error"})
