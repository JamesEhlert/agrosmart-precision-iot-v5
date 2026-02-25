# lambda_function.py
#
# AgroSmart_V5_AckToFirestore (Versão Híbrida Otimizada + Observabilidade)
# ======================================================
# Mantém parsing robusto.
# Mantém lógica timeout -> duration_elapsed.
# MELHORIA: logs estruturados (JSON) com:
#   - request_id
#   - device_id
#   - command_id
#   - status
#   - mqtt_topic (vindo da IoT Rule via: SELECT *, topic() as mqtt_topic ...)
#
# Assim você consegue filtrar fácil no CloudWatch.

import os
import json
import base64
import datetime
from typing import Any, Dict, Optional

import boto3

# =====================================================================================
# LOG ESTRUTURADO
# =====================================================================================

def _log(level: str, event_name: str, **fields):
    """
    Log estruturado em JSON para facilitar filtros no CloudWatch.
    """
    payload = {
        "level": level.upper(),
        "event_name": event_name,
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        **{k: v for k, v in fields.items() if v is not None},
    }
    print(json.dumps(payload, ensure_ascii=False, default=str))


# =====================================================================================
# CONFIGURAÇÃO DE IMPORTAÇÃO SEGURA (LAYER FIREBASE)
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
    _log("WARN", "firebase_layer_missing", message="Layer do Firebase não encontrada. Persistência DESATIVADA.")

# -----------------------------
# Firebase init (lazy / safe)
# -----------------------------
_firestore_client: Optional[Any] = None

def _get_firestore() -> Optional[Any]:
    """
    Inicializa e retorna o client Firestore de forma segura.
    """
    global _firestore_client

    if not FIREBASE_AVAILABLE:
        return None

    if _firestore_client is not None:
        return _firestore_client

    # Reuso se já inicializado em invocação "quente"
    if firebase_admin._apps:
        _firestore_client = firestore.client()
        return _firestore_client

    # Inicialização fria
    sa_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()

    if not sa_json:
        secret_arn = os.getenv("FIREBASE_SA_SECRET_ARN", "").strip()
        if secret_arn:
            region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "us-east-2"
            sm = boto3.client("secretsmanager", region_name=region)

            try:
                resp = sm.get_secret_value(SecretId=secret_arn)
                if "SecretString" in resp and resp["SecretString"]:
                    sa_json = resp["SecretString"].strip()
                elif "SecretBinary" in resp and resp["SecretBinary"]:
                    sa_json = base64.b64decode(resp["SecretBinary"]).decode("utf-8", errors="replace").strip()
            except Exception as e:
                _log("ERROR", "secret_fetch_failed", secret_arn=secret_arn, error=str(e))
                return None

    if sa_json:
        try:
            sa_obj = json.loads(sa_json)
            cred_obj = credentials.Certificate(sa_obj)
            firebase_admin.initialize_app(cred_obj)
            _log("INFO", "firebase_init_ok", mode="explicit_credentials")
        except Exception as e:
            _log("ERROR", "firebase_init_failed", mode="explicit_credentials", error=str(e))
            return None
    else:
        # Fallback: Default Credentials (geralmente NÃO funciona no seu caso)
        try:
            firebase_admin.initialize_app()
            _log("INFO", "firebase_init_ok", mode="default_credentials")
        except Exception:
            _log("WARN", "firebase_no_credentials", message="Sem credenciais. Firestore tracking desativado.")
            return None

    _firestore_client = firestore.client()
    return _firestore_client


# -----------------------------
# Helpers - datas e logs
# -----------------------------
def _utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _safe_get(d: Dict[str, Any], key: str, default=None):
    v = d.get(key, default)
    return v if v is not None else default


def _json_safe(obj: Any, limit: int = 5000) -> str:
    try:
        s = json.dumps(obj, default=str, ensure_ascii=False)
    except Exception:
        s = str(obj)
    return s[:limit]


# -----------------------------
# Helpers - Parsing ROBUSTO
# -----------------------------
def _try_json_loads(text: str) -> Optional[Dict[str, Any]]:
    try:
        v = json.loads(text)
        return v if isinstance(v, dict) else None
    except Exception:
        return None


def _try_base64_to_json(text: str) -> Optional[Dict[str, Any]]:
    try:
        decoded = base64.b64decode(text)
        decoded_text = decoded.decode("utf-8", errors="replace")
        return _try_json_loads(decoded_text)
    except Exception:
        return None


def _parse_iot_payload(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Garante que lê o JSON mesmo se vier como string, base64 ou dentro de 'message'.
    """
    # 1) Formato plano
    if isinstance(event, dict) and "device_id" in event and "status" in event and "command_id" in event:
        return event

    payload = event.get("payload")

    # 2) bytes -> str
    if isinstance(payload, (bytes, bytearray)):
        payload = payload.decode("utf-8", errors="replace")

    # 3) payload str -> json/base64(json)
    if isinstance(payload, str) and payload.strip():
        payload = payload.strip()
        as_json = _try_json_loads(payload)
        if as_json:
            return as_json

        as_b64_json = _try_base64_to_json(payload)
        if as_b64_json:
            return as_b64_json

    # 4) chaves alternativas comuns
    for k in ("message", "data", "body"):
        val = event.get(k)
        if isinstance(val, str):
            maybe = _try_json_loads(val)
            if maybe:
                return maybe
        elif isinstance(val, dict):
            return val

    return event


# -----------------------------
# Normalização e regras
# -----------------------------
_ALLOWED_STATUSES = {"received", "started", "done", "failed"}

def _normalize_status(raw: Any) -> str:
    s = str(raw or "").strip().lower()
    if not s:
        return ""
    if s == "error":
        return "failed"
    if s in _ALLOWED_STATUSES:
        return s
    return "unknown"


def _status_to_result(status: str, ok_value: Optional[bool], error_value: Optional[str]) -> str:
    s = (status or "").lower().strip()
    if error_value:
        return "failed"
    if ok_value is False:
        return "failed"
    if s == "done":
        return "success"
    if s == "failed":
        return "failed"
    return "failed"


def _normalize_action(value: Any) -> Optional[str]:
    if value is None:
        return None
    s = str(value).strip().lower()
    return s if s else None


def _normalize_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(value)
    except Exception:
        return None


def _extract_mqtt_topic(ack: Dict[str, Any]) -> Optional[str]:
    """
    Tenta pegar o tópico MQTT do evento.
    - Sua IoT Rule usa: topic() as mqtt_topic
    """
    for key in ("mqtt_topic", "mqttTopic", "topic", "iot_topic"):
        v = ack.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None


def _normalize_reason_logic(
    reason: Optional[str],
    status: str,
    result: str,
    requested_action: Optional[str],
    requested_duration: Optional[int],
) -> tuple[Optional[str], Optional[str]]:
    """
    Se reason=timeout, status=done e result=success e action=on com duração,
    normaliza para 'duration_elapsed'.
    """
    if not reason:
        return None, None

    r_lower = reason.strip().lower()

    if (
        r_lower == "timeout"
        and status == "done"
        and result == "success"
        and (requested_action or "").lower() == "on"
        and (requested_duration or 0) > 0
    ):
        return "duration_elapsed", reason

    return reason, None


def _build_history_message_simple(
    result: str,
    requested_action: Optional[str],
    requested_duration: Optional[int],
    reason: Optional[str],
    error_value: Optional[str],
) -> str:
    def fmt_seconds(v: Optional[int]) -> Optional[str]:
        if v is None:
            return None
        return "1 s" if v == 1 else f"{v} s"

    reason_map = {
        "timeout": "timeout de segurança",
        "duration_elapsed": "ciclo concluído",
        "safety_timeout": "timeout de segurança",
        "watchdog": "proteção do sistema",
    }

    reason_txt = None
    if reason:
        reason_txt = reason_map.get(str(reason).strip().lower(), str(reason).strip())

    if result == "success":
        if requested_action == "on":
            dur = fmt_seconds(requested_duration)
            if dur:
                return f"Irrigação ligada por {dur}"
            return "Irrigação ligada"
        if requested_action == "off":
            return "Irrigação desligada"
        return "Comando executado"

    if reason_txt:
        return f"Comando interrompido ({reason_txt})"
    if error_value:
        return "Falha ao executar comando"
    return "Falha ao executar comando"


# -----------------------------
# Handler Principal
# -----------------------------
def lambda_handler(event, context):
    request_id = getattr(context, "aws_request_id", "n/a")

    db = _get_firestore()

    # Parse robusto
    try:
        ack = _parse_iot_payload(event)
    except Exception as e:
        _log("ERROR", "parse_payload_failed", request_id=request_id, error=str(e), raw_event=_json_safe(event))
        return {"ok": False, "error": "parse_error"}

    # Validação
    device_id = str(_safe_get(ack, "device_id", "")).strip()
    command_id = str(_safe_get(ack, "command_id", "")).strip()
    status = _normalize_status(_safe_get(ack, "status", ""))

    mqtt_topic = _extract_mqtt_topic(ack)

    if not device_id or not command_id or not status:
        _log(
            "ERROR",
            "missing_fields",
            request_id=request_id,
            device_id=device_id or None,
            command_id=command_id or None,
            status=status or None,
            mqtt_topic=mqtt_topic,
        )
        return {"ok": False, "error": "missing_fields"}

    # Se não tem DB, só registra observabilidade e retorna OK
    if db is None:
        _log(
            "WARN",
            "firestore_unavailable_ack_received",
            request_id=request_id,
            device_id=device_id,
            command_id=command_id,
            status=status,
            mqtt_topic=mqtt_topic,
        )
        return {"ok": True, "persisted": False}

    # Extração de dados
    action = _normalize_action(_safe_get(ack, "action"))
    duration = _normalize_int(_safe_get(ack, "duration"))
    ts_unix = _safe_get(ack, "ts")
    ok_value = _safe_get(ack, "ok")
    reason_in = _safe_get(ack, "reason")
    error_value = _safe_get(ack, "error")
    sys_obj = _safe_get(ack, "sys", {}) or {}

    now_server = firestore.SERVER_TIMESTAMP if FIREBASE_AVAILABLE else None

    # Firestore refs
    cmd_ref = db.collection("devices").document(device_id).collection("commands").document(command_id)

    existing = cmd_ref.get()
    existing_data = existing.to_dict() if existing.exists else {}

    # Update doc
    status_ts_field = f"status_ts.{status}" if status in _ALLOWED_STATUSES else "status_ts.unknown"

    update_doc: Dict[str, Any] = {
        "device_id": device_id,
        "command_id": command_id,
        "status": status,
        "last_status": status,
        "last_status_at": now_server,
        "updated_at": now_server,
        status_ts_field: now_server,
    }

    # Resultado para lógica de reason
    result_calculated = "pending"
    if status in ("done", "failed"):
        result_calculated = _status_to_result(status, ok_value=ok_value, error_value=error_value)
        update_doc["finished_at"] = now_server
        update_doc["result"] = result_calculated
    elif status == "received":
        update_doc["received_at"] = now_server
    elif status == "started":
        update_doc["started_at"] = now_server

    # Action/Duration pedidos
    req_action_for_logic = existing_data.get("requested_action", update_doc.get("action", action))
    req_duration_for_logic = existing_data.get("requested_duration", update_doc.get("duration", duration))

    # Normaliza reason
    final_reason, original_reason_raw = _normalize_reason_logic(
        reason=reason_in,
        status=status,
        result=result_calculated,
        requested_action=_normalize_action(req_action_for_logic),
        requested_duration=_normalize_int(req_duration_for_logic),
    )

    if final_reason is not None:
        update_doc["reason"] = final_reason
    if original_reason_raw is not None:
        update_doc["reason_raw"] = original_reason_raw

    # Campos opcionais
    if sys_obj:
        update_doc["sys"] = sys_obj
    if error_value is not None:
        update_doc["error"] = error_value
    if action is not None:
        update_doc["action"] = action
    if duration is not None:
        update_doc["duration"] = duration
    if ts_unix is not None:
        update_doc["device_ts"] = ts_unix
    if mqtt_topic is not None:
        update_doc["mqtt_topic"] = mqtt_topic  # <-- útil também no Firestore

    if status in ("received", "started"):
        if action and not existing_data.get("requested_action"):
            update_doc["requested_action"] = action
        if duration and not existing_data.get("requested_duration"):
            update_doc["requested_duration"] = duration

    # Upsert commands
    cmd_ref.set(update_doc, merge=True)

    _log(
        "INFO",
        "commands_updated",
        request_id=request_id,
        device_id=device_id,
        command_id=command_id,
        status=status,
        mqtt_topic=mqtt_topic,
        reason=final_reason,
        result=result_calculated if status in ("done", "failed") else None,
    )

    # History somente na finalização
    if status in ("done", "failed"):
        final_req_action = existing_data.get("requested_action", update_doc.get("requested_action", action))
        final_req_duration = existing_data.get("requested_duration", update_doc.get("requested_duration", duration))

        final_action = update_doc.get("final_action", action)
        final_duration = update_doc.get("final_duration", duration)

        message = _build_history_message_simple(
            result=result_calculated,
            requested_action=_normalize_action(final_req_action),
            requested_duration=_normalize_int(final_req_duration),
            reason=final_reason,
            error_value=error_value,
        )

        details = {
            "result": result_calculated,
            "final_status": status,
            "requested": {
                "action": _normalize_action(final_req_action),
                "duration": _normalize_int(final_req_duration),
            },
            "final": {
                "action": _normalize_action(final_action),
                "duration": _normalize_int(final_duration),
            },
            "reason": final_reason,
            "error": error_value,
            "sys": sys_obj if sys_obj else None,
            "device_ts": ts_unix,
            "mqtt_topic": mqtt_topic,
        }
        if original_reason_raw:
            details["reason_raw"] = original_reason_raw

        history_ref = db.collection("devices").document(device_id).collection("history").document(f"cmd-{command_id}")

        history_doc = {
            "type": "command_execution",
            "source": "command",
            "device_id": device_id,
            "command_id": command_id,
            "message": message,
            "timestamp": now_server,
            "updated_at": now_server,
            "schema_version": 1,
            "event_name": "command.execution.finished",
            "event_code": "CMD_EXEC_FINISHED",
            "status": status,
            "result": result_calculated,
            "reason": final_reason,
            "mqtt_topic": mqtt_topic,
            "details": details,
            "ui_hint": {
                "kind": "command",
                "severity": "info" if result_calculated == "success" else "error",
            },
        }
        if error_value:
            history_doc["error"] = error_value

        history_ref.set(history_doc, merge=True)

        _log(
            "INFO",
            "history_upserted",
            request_id=request_id,
            device_id=device_id,
            command_id=command_id,
            status=status,
            result=result_calculated,
            mqtt_topic=mqtt_topic,
        )

    return {
        "ok": True,
        "device_id": device_id,
        "command_id": command_id,
        "status": status,
        "mqtt_topic": mqtt_topic,
        "request_id": request_id,
        "at": _utc_now_iso(),
    }
