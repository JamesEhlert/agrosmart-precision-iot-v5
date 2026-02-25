from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import time
import uuid
import boto3
import datetime
from typing import Any, Optional, Tuple

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
# IMPORT SEGURO (LAYER FIREBASE)
# =====================================================================================
try:
    import firebase_admin
    from firebase_admin import credentials, firestore
    try:
        from google.api_core.exceptions import AlreadyExists
    except ImportError:
        AlreadyExists = Exception
    FIREBASE_AVAILABLE = True
except ImportError:
    firebase_admin = None
    credentials = None
    firestore = None
    AlreadyExists = Exception
    FIREBASE_AVAILABLE = False
    _log("WARN", "firebase_layer_missing", message="Layer Firebase ausente. Firestore tracking desativado.")


# =====================================================================================
# CONFIG
# =====================================================================================
AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
IOT_TOPIC_PREFIX = os.getenv("IOT_TOPIC_PREFIX", "agrosmart/v5").strip().strip("/")
IOT_DATA_ENDPOINT_URL = os.getenv("IOT_DATA_ENDPOINT_URL")

MAX_DURATION_SECONDS = int(os.getenv("MAX_DURATION_SECONDS", "900"))
ALLOWED_ACTIONS = {"on", "off"}

# Segurança: defaults TRUE (produto)
REQUIRE_AUTH = os.getenv("REQUIRE_AUTH", "true").lower() == "true"
ENFORCE_DEVICE_OWNERSHIP = os.getenv("ENFORCE_DEVICE_OWNERSHIP", "true").lower() == "true"

DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9:_-]{1,80}$")
COMMAND_ID_RE = re.compile(r"^[A-Za-z0-9:_-]{1,120}$")

# =====================================================================================
# AWS CLIENTS
# =====================================================================================
if IOT_DATA_ENDPOINT_URL:
    iot_data = boto3.client("iot-data", region_name=AWS_REGION, endpoint_url=IOT_DATA_ENDPOINT_URL)
else:
    iot_data = boto3.client("iot-data", region_name=AWS_REGION)

secrets_client = boto3.client("secretsmanager", region_name=AWS_REGION)

_firestore_client: Optional[Any] = None


# =====================================================================================
# HELPERS: HTTP / CORS / PARSE
# =====================================================================================
def build_response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
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


def _get_http_method(event: dict[str, Any]) -> str:
    if isinstance(event, dict) and "httpMethod" in event:
        return event["httpMethod"] or ""
    rc = (event or {}).get("requestContext", {}) if isinstance(event, dict) else {}
    http = (rc.get("http", {}) if isinstance(rc, dict) else {}) or {}
    return http.get("method", "") or ""


def _get_headers(event: dict[str, Any]) -> dict[str, str]:
    headers = (event or {}).get("headers", {}) if isinstance(event, dict) else {}
    if not isinstance(headers, dict):
        return {}
    out = {}
    for k, v in headers.items():
        if isinstance(k, str) and isinstance(v, str):
            out[k.lower()] = v
    return out


def parse_json_body(event: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(event, dict):
        return {}

    if "body" not in event or event["body"] is None:
        return event

    raw = event["body"]
    if isinstance(raw, dict):
        return raw

    if not isinstance(raw, str) or not raw.strip():
        raise ValueError("Body vazio")

    if event.get("isBase64Encoded") is True:
        try:
            raw = base64.b64decode(raw).decode("utf-8", errors="replace")
        except Exception:
            raise ValueError("Falha ao decodificar Base64 do body")

    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise ValueError("Body não é um JSON válido")


def parse_int(value: Any, default: int = 0) -> int:
    if value is None:
        return default
    if isinstance(value, bool):
        raise ValueError("Valor inválido (bool não permitido para inteiros)")
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        v = value.strip()
        if v == "":
            return default
        try:
            return int(float(v))
        except ValueError:
            pass
    raise ValueError("Valor inválido para número inteiro")


# =====================================================================================
# TOPICS / IDEMPOTENCY
# =====================================================================================
def build_topics(device_id: str) -> dict[str, str]:
    base = IOT_TOPIC_PREFIX
    return {
        "command_topic": f"{base}/{device_id}/command",
        "ack_topic": f"{base}/{device_id}/ack",
    }


def _command_id_from_idempotency_key(device_id: str, key: str) -> str:
    raw = f"{device_id}:{key}".encode("utf-8")
    h = hashlib.sha1(raw).hexdigest()[:16]
    return f"man-{h}"


def _extract_user_context(event: dict[str, Any]) -> dict[str, str]:
    """
    Extrai UID vindo do Lambda Authorizer (Firebase).
    """
    out: dict[str, str] = {}
    if not isinstance(event, dict):
        return out

    rc = event.get("requestContext", {}) or {}
    auth = rc.get("authorizer", {}) or {}

    principal_id = auth.get("principalId") if isinstance(auth, dict) else None
    uid = None

    if isinstance(auth, dict):
        uid = auth.get("uid") or auth.get("user_id") or auth.get("sub")

    if not uid:
        uid = principal_id

    if isinstance(uid, str) and uid.strip():
        out["user_id"] = uid.strip()

    return out


# =====================================================================================
# FIRESTORE (SAFE)
# =====================================================================================
def _load_service_account_json() -> Optional[dict[str, Any]]:
    sa_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    if sa_json:
        try:
            return json.loads(sa_json)
        except Exception as e:
            _log("ERROR", "firebase_sa_json_invalid", error=str(e))
            return None

    secret_arn = (os.getenv("FIREBASE_SA_SECRET_ARN", "").strip() or os.getenv("GCP_SECRET_ARN", "").strip())
    if not secret_arn:
        return None

    try:
        resp = secrets_client.get_secret_value(SecretId=secret_arn)
        if "SecretString" in resp and resp["SecretString"]:
            return json.loads(resp["SecretString"])
        if "SecretBinary" in resp and resp["SecretBinary"]:
            decoded = base64.b64decode(resp["SecretBinary"]).decode("utf-8", errors="replace")
            return json.loads(decoded)
    except Exception as e:
        _log("ERROR", "secret_fetch_failed", secret_arn=secret_arn, error=str(e))

    return None


def _get_firestore() -> Optional[Any]:
    global _firestore_client

    if not FIREBASE_AVAILABLE:
        return None

    if _firestore_client is not None:
        return _firestore_client

    if getattr(firebase_admin, "_apps", None) and firebase_admin._apps:
        _firestore_client = firestore.client()
        return _firestore_client

    sa_obj = _load_service_account_json()
    if sa_obj:
        cred = credentials.Certificate(sa_obj)
        firebase_admin.initialize_app(cred)
        _log("INFO", "firebase_init_ok", mode="explicit_credentials")
    else:
        try:
            firebase_admin.initialize_app()
            _log("INFO", "firebase_init_ok", mode="default_credentials")
        except Exception:
            _log("WARN", "firebase_no_credentials", message="Sem credenciais Firebase. Firestore indisponível.")
            return None

    _firestore_client = firestore.client()
    return _firestore_client


def _firestore_create_or_get_command(
    device_id: str,
    command_id: str,
    action: str,
    duration: int,
    origin: str,
    user_id: Optional[str],
    topics: dict[str, str],
    request_id: str,
) -> Tuple[bool, Optional[str]]:
    db = _get_firestore()
    if db is None:
        # Tracking é opcional; ownership já foi checado antes.
        return (True, None)

    now_server = firestore.SERVER_TIMESTAMP if FIREBASE_AVAILABLE else None
    cmd_ref = db.collection("devices").document(device_id).collection("commands").document(command_id)

    doc_data = {
        "device_id": device_id,
        "command_id": command_id,
        "origin": origin,
        "requested_action": action,
        "requested_duration": duration,
        "action": action,
        "duration": duration,
        "status": "pending",
        "last_status": "pending",
        "created_at": now_server,
        "updated_at": now_server,
        "requested_by": {"user_id": user_id} if user_id else None,
        "mqtt": {"topic": topics["command_topic"], "qos": 1},
        "request": {"request_id": request_id},
        "schema_version": 1,
    }
    doc_data = {k: v for k, v in doc_data.items() if v is not None}

    try:
        cmd_ref.create(doc_data)
        return (True, None)
    except AlreadyExists:
        try:
            existing = cmd_ref.get()
            if existing.exists:
                data = existing.to_dict() or {}
                st = str(data.get("status") or "").strip().lower()
                return (False, st)
        except Exception as e:
            _log("WARN", "firestore_read_existing_failed", device_id=device_id, command_id=command_id, error=str(e))
        return (False, None)
    except Exception as e:
        _log("WARN", "firestore_create_failed_following_without_lock", device_id=device_id, command_id=command_id, error=str(e))
        return (True, None)


def _firestore_mark_publish_failed(device_id: str, command_id: str, message: str):
    db = _get_firestore()
    if db is None:
        return
    now_server = firestore.SERVER_TIMESTAMP if FIREBASE_AVAILABLE else None
    try:
        cmd_ref = db.collection("devices").document(device_id).collection("commands").document(command_id)
        cmd_ref.set(
            {
                "status": "publish_failed",
                "updated_at": now_server,
                "error": {"type": "iot_publish_error", "message": str(message)[:500]},
            },
            merge=True,
        )
    except Exception as e:
        _log("WARN", "firestore_mark_publish_failed_failed", device_id=device_id, command_id=command_id, error=str(e))


def _firestore_check_device_owner(device_id: str, user_id: str) -> bool:
    """
    FAIL-CLOSED:
    - Firestore indisponível => False
    - Device não existe => False
    - Owner != user => False
    """
    db = _get_firestore()
    if db is None:
        _log("WARN", "ownership_check_firestore_unavailable", device_id=device_id)
        return False

    try:
        doc = db.collection("devices").document(device_id).get()
        if not doc.exists:
            return False

        data = doc.to_dict() or {}
        owner = data.get("owner_uid") or data.get("ownerUid")
        return isinstance(owner, str) and owner == user_id

    except Exception as e:
        _log("WARN", "firestore_owner_check_failed", device_id=device_id, error=str(e))
        return False


# =====================================================================================
# VALIDAÇÃO E PAYLOAD
# =====================================================================================
def validate_and_build_command(body: dict[str, Any], event: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(body, dict):
        raise ValueError("JSON inválido")

    device_id = body.get("device_id")
    action = body.get("action")
    duration_raw = body.get("duration", 0)
    origin = body.get("origin", "manual")

    headers = _get_headers(event)
    idempotency_key = headers.get("idempotency-key") or headers.get("x-idempotency-key")
    command_id = body.get("command_id")

    if not isinstance(device_id, str) or not device_id.strip():
        raise ValueError("device_id é obrigatório")
    device_id = device_id.strip()

    if not DEVICE_ID_RE.match(device_id):
        raise ValueError("device_id inválido (use apenas letras, números, '-', '_', ':')")

    if not isinstance(action, str) or not action.strip():
        raise ValueError("action é obrigatório")
    action = action.strip().lower()

    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"action inválido. Permitidos: {sorted(ALLOWED_ACTIONS)}")

    duration = parse_int(duration_raw, default=0)
    if duration < 0:
        raise ValueError("duration não pode ser negativo")
    if duration > MAX_DURATION_SECONDS:
        raise ValueError(f"duration acima do máximo permitido ({MAX_DURATION_SECONDS}s)")
    if action == "off":
        duration = 0

    if not isinstance(origin, str):
        origin = "manual"
    origin = (origin.strip() or "manual")[:30]

    if isinstance(command_id, str) and command_id.strip():
        command_id = command_id.strip()
    else:
        command_id = None

    if command_id is None and isinstance(idempotency_key, str) and idempotency_key.strip():
        command_id = _command_id_from_idempotency_key(device_id, idempotency_key.strip())

    if command_id is None:
        command_id = str(uuid.uuid4())

    if not COMMAND_ID_RE.match(command_id):
        raise ValueError("command_id inválido (caracteres proibidos)")

    user_ctx = _extract_user_context(event)

    payload = {
        "device_id": device_id,
        "action": action,
        "duration": duration,
        "origin": origin,
        "command_id": command_id,
        "issued_at": int(time.time()),
        **user_ctx,
    }
    return payload


# =====================================================================================
# HANDLER
# =====================================================================================
def lambda_handler(event: Any, context: Any) -> dict[str, Any]:
    method = _get_http_method(event)
    if method.upper() == "OPTIONS":
        return build_response(200, {"ok": True})

    request_id = getattr(context, "aws_request_id", "n/a")

    try:
        body = parse_json_body(event)
        payload = validate_and_build_command(body, event)

        device_id = payload["device_id"]
        topics = build_topics(device_id)
        topic = topics["command_topic"]

        user_id = payload.get("user_id")

        # 1) Auth obrigatório (produto)
        if REQUIRE_AUTH and not user_id:
            return build_response(401, {"message": "Unauthorized"})

        # 2) Se ownership está ligado, mas não temos usuário -> também é Unauthorized
        if ENFORCE_DEVICE_OWNERSHIP and not user_id:
            return build_response(401, {"message": "Unauthorized"})

        # 3) Ownership FAIL-CLOSED + 403 genérico
        if ENFORCE_DEVICE_OWNERSHIP and user_id:
            if not _firestore_check_device_owner(device_id, user_id):
                _log("WARN", "forbidden_device_ownership", request_id=request_id, device_id=device_id)
                return build_response(403, {"message": "Forbidden"})

        created_new, existing_status = _firestore_create_or_get_command(
            device_id=device_id,
            command_id=payload["command_id"],
            action=payload["action"],
            duration=payload["duration"],
            origin=payload.get("origin", "manual"),
            user_id=user_id,
            topics=topics,
            request_id=request_id,
        )

        if created_new is False and (existing_status or "").lower() != "publish_failed":
            _log(
                "INFO",
                "command_idempotent_ignored",
                request_id=request_id,
                device_id=device_id,
                command_id=payload["command_id"],
                existing_status=existing_status,
                mqtt_topic=topic,
            )
            return build_response(200, {
                "message": "Comando já existente (idempotent). Não foi republicado.",
                "target": device_id,
                "command_id": payload["command_id"],
                "topics": {"command": topics["command_topic"], "ack": topics["ack_topic"]},
            })

        _log(
            "INFO",
            "command_publish_attempt",
            request_id=request_id,
            device_id=device_id,
            command_id=payload["command_id"],
            action=payload["action"],
            duration=payload["duration"],
            mqtt_topic=topic,
        )

        iot_data.publish(
            topic=topic,
            qos=1,
            payload=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        )

        _log(
            "INFO",
            "command_publish_ok",
            request_id=request_id,
            device_id=device_id,
            command_id=payload["command_id"],
            mqtt_topic=topic,
        )

        return build_response(200, {
            "message": "Comando enviado com sucesso",
            "target": device_id,
            "command_id": payload["command_id"],
            "topics": {"command": topics["command_topic"], "ack": topics["ack_topic"]},
        })

    except ValueError as e:
        return build_response(400, {"message": str(e)})

    except Exception as e:
        _log("ERROR", "send_command_internal_error", request_id=request_id, error=str(e))
        try:
            if "payload" in locals():
                _firestore_mark_publish_failed(payload["device_id"], payload["command_id"], str(e))
        except Exception:
            pass

        return build_response(500, {"message": "Erro interno na Lambda"})  # sem vazar detalhes
