"""
AgroSmart V5 - Presence to Firestore (Online/Offline via MQTT LWT/Birth)

Objetivo:
- Receber eventos de presença vindos do AWS IoT Rule (topic agrosmart/v5/+/presence)
- Atualizar o documento do dispositivo no Firestore: devices/{device_id}
- Substituir heurística de "última telemetria" por presença real (Birth/LWT)

Campos gravados em devices/{device_id}:
- connection.state            -> "online" | "offline"
- connection.kind             -> "birth" | "lwt"
- connection.fw               -> versão firmware (se vier)
- connection.ip               -> ip local (se vier)
- connection.updatedAt        -> server timestamp (Firestore)
- connection.lastConnectAt    -> server timestamp (somente quando state="online")
- connection.lastDisconnectAt -> server timestamp (somente quando state="offline")
- connection_state            -> "online" | "offline"  (espelho para query/ordenação)
- online                      -> true/false            (campo legado para compatibilidade)

Boas práticas:
- Server timestamps (não confiamos em epoch do device, e LWT não representa hora real)
- Merge no documento para não apagar outros campos do device
"""

import os
import json
import base64
import boto3
from typing import Any, Dict, Tuple

from google.oauth2 import service_account
from google.cloud import firestore

AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
FIREBASE_SA_SECRET_ARN = os.environ["FIREBASE_SA_SECRET_ARN"]  # obrigatório

_firestore_client = None  # cache global


def _load_firebase_service_account() -> Dict[str, Any]:
    """Lê o JSON da service account do Firebase a partir do AWS Secrets Manager."""
    sm = boto3.client("secretsmanager", region_name=AWS_REGION)
    resp = sm.get_secret_value(SecretId=FIREBASE_SA_SECRET_ARN)

    if "SecretString" in resp and resp["SecretString"]:
        return json.loads(resp["SecretString"])

    if "SecretBinary" in resp and resp["SecretBinary"]:
        raw = base64.b64decode(resp["SecretBinary"]).decode("utf-8")
        return json.loads(raw)

    raise RuntimeError("SecretsManager returned empty secret (no SecretString/SecretBinary).")


def _get_firestore_client():
    """Inicializa o client Firestore uma vez (cache global)."""
    global _firestore_client
    if _firestore_client is not None:
        return _firestore_client

    sa_info = _load_firebase_service_account()
    creds = service_account.Credentials.from_service_account_info(sa_info)
    _firestore_client = firestore.Client(credentials=creds, project=sa_info.get("project_id"))
    return _firestore_client


def _safe_get(d: Dict[str, Any], key: str, default=None):
    v = d.get(key, default)
    return v if v is not None else default


def _normalize_presence(payload: Dict[str, Any], fallback_device_id: str) -> Tuple[str, Dict[str, Any]]:
    """
    Normaliza entradas do payload para o formato padrão do Firestore.

    Esperado do firmware (exemplo):
      {"device_id":"ESP32-...","state":"online","kind":"birth","fw":"5.17.4","ip":"192.168.0.103"}

    Retorna:
      device_id, connection_dict_base
    """
    device_id = _safe_get(payload, "device_id", fallback_device_id) or fallback_device_id
    device_id = str(device_id).strip()

    state = str(_safe_get(payload, "state", "")).lower().strip()
    kind = str(_safe_get(payload, "kind", "")).lower().strip()

    # Normalizações defensivas
    if state not in ("online", "offline"):
        # Se vier algo inesperado, ainda assim grava (pra debug), mas não quebra
        # (você pode optar por return erro; eu prefiro não perder evento)
        pass

    fw = _safe_get(payload, "fw", None)
    ip = _safe_get(payload, "ip", None)

    conn: Dict[str, Any] = {
        "state": state,
        "kind": kind,
        "fw": fw,
        "ip": ip,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }

    if state == "online":
        conn["lastConnectAt"] = firestore.SERVER_TIMESTAMP
    elif state == "offline":
        conn["lastDisconnectAt"] = firestore.SERVER_TIMESTAMP

    # remove None/"" para não sujar doc
    conn = {k: v for k, v in conn.items() if v is not None and v != ""}

    return device_id, conn


def _extract_event_payload(event: Dict[str, Any]) -> Tuple[Dict[str, Any], str]:
    """
    Extrai payload e device_id do evento vindo do IoT Rule.
    Aceita:
    - campos no root (state/kind/fw/ip/device_id)
    - ou dict/string JSON em message/payload/data
    """
    fallback_device_id = str(event.get("device_id", "") or event.get("thingName", "") or "").strip()

    if isinstance(event, dict) and ("state" in event or "kind" in event or "fw" in event):
        return event, fallback_device_id

    for k in ("message", "payload", "data"):
        v = event.get(k)
        if isinstance(v, dict):
            return v, fallback_device_id
        if isinstance(v, str) and v.strip().startswith("{"):
            try:
                return json.loads(v), fallback_device_id
            except Exception:
                pass

    return {}, fallback_device_id


def lambda_handler(event, context):
    try:
        payload, fallback_device_id = _extract_event_payload(event)
        if not payload and not fallback_device_id:
            return {"ok": False, "error": "invalid_event_no_payload"}

        device_id, connection = _normalize_presence(payload, fallback_device_id)
        if not device_id:
            return {"ok": False, "error": "missing_device_id"}

        state = connection.get("state")
        if not state:
            return {"ok": False, "error": "missing_state"}

        # Campo legado (compatibilidade com app/estrutura antiga)
        online_bool = True if state == "online" else False if state == "offline" else None

        db = _get_firestore_client()
        doc_ref = db.collection("devices").document(device_id)

        update_doc = {
            "connection": connection,
            "connection_state": state,
        }

        if online_bool is not None:
            update_doc["online"] = online_bool

        doc_ref.set(update_doc, merge=True)

        return {"ok": True, "device_id": device_id, "state": state, "kind": connection.get("kind")}

    except Exception as e:
        print("ERROR:", repr(e))
        return {"ok": False, "error": str(e)}
