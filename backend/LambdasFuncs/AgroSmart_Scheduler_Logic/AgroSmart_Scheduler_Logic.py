import os
import json
import boto3
import datetime
import pytz
import urllib.request
import hashlib
import time
from typing import Any, Dict, Optional, Tuple

from google.oauth2 import service_account
from google.cloud import firestore
from google.api_core.exceptions import AlreadyExists
from boto3.dynamodb.conditions import Key

# ==============================================================================
# AgroSmart_Scheduler_Logic (com observabilidade em JSON)
# ==============================================================================
# Logs estruturados no CloudWatch para filtrar por:
#   event_name, device_id, schedule_id, command_id, mqtt_topic, request_id
# ==============================================================================

# ------------------------------------------------------------------------------
# ENV / CONFIG
# ------------------------------------------------------------------------------
AWS_REGION = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "us-east-2"
TZ_NAME = os.getenv("TZ_NAME", "America/Sao_Paulo")

IOT_TOPIC_PREFIX = os.getenv("IOT_TOPIC_PREFIX", "agrosmart/v5").strip().strip("/")

# DynamoDB (telemetria)
# Prioriza variáveis que você já configurou:
#   DYNAMO_TABLE / DYNAMO_REGION
# E faz fallback para DYNAMODB_TABLE_NAME, etc.
DYNAMO_TABLE = (
    os.getenv("DYNAMO_TABLE")
    or os.getenv("DYNAMODB_TABLE")
    or os.getenv("DYNAMODB_TABLE_NAME")
    or "AgroTelemetryData_V5"
)
DYNAMO_REGION = (
    os.getenv("DYNAMO_REGION")
    or os.getenv("DYNAMODB_REGION")
    or os.getenv("AWS_REGION")
    or AWS_REGION
)

DYNAMODB_PARTITION_KEY = os.getenv("DYNAMODB_PARTITION_KEY", "device_id")
DYNAMODB_SORT_KEY = os.getenv("DYNAMODB_SORT_KEY", "timestamp")

# Telemetria máxima “aceitável” (anti-stale)
# Se a última telemetria for mais antiga que isso, o scheduler SKIPA por segurança.
TELEMETRY_MAX_AGE_SEC = int(os.getenv("TELEMETRY_MAX_AGE_SEC", "180"))

# Secrets Manager (Firestore)
GCP_SECRET_ARN = os.getenv("GCP_SECRET_ARN", "").strip() or os.getenv("FIREBASE_SA_SECRET_ARN", "").strip()

# ------------------------------------------------------------------------------
# LOG ESTRUTURADO
# ------------------------------------------------------------------------------
def _log(level: str, event_name: str, **fields):
    payload = {
        "level": level.upper(),
        "event_name": event_name,
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        **{k: v for k, v in fields.items() if v is not None},
    }
    print(json.dumps(payload, ensure_ascii=False, default=str))


# ------------------------------------------------------------------------------
# AWS Clients
# ------------------------------------------------------------------------------
# DynamoDB precisa usar a região/tabela corretas
dynamodb = boto3.resource("dynamodb", region_name=DYNAMO_REGION)
table = dynamodb.Table(DYNAMO_TABLE)

# IoT Data (mesma região da Lambda)
iot_client = boto3.client("iot-data", region_name=AWS_REGION)

# Secrets (mesma região da Lambda)
secrets_client = boto3.client("secretsmanager", region_name=AWS_REGION)

_firestore_client: Optional[firestore.Client] = None


# ==============================================================================
# FIRESTORE
# ==============================================================================
def get_firestore_client() -> firestore.Client:
    """
    Conecta no Firestore usando service account vindo do Secrets Manager.
    Cacheia o client para invocações "warm".
    """
    global _firestore_client

    if _firestore_client is not None:
        return _firestore_client

    if not GCP_SECRET_ARN:
        raise RuntimeError("GCP_SECRET_ARN/FIREBASE_SA_SECRET_ARN não configurado no ambiente da Lambda.")

    _log("INFO", "firestore_connect_start", secret_arn=GCP_SECRET_ARN)

    resp = secrets_client.get_secret_value(SecretId=GCP_SECRET_ARN)

    if "SecretString" in resp and resp["SecretString"]:
        sa_info = json.loads(resp["SecretString"])
    else:
        import base64
        sa_info = json.loads(base64.b64decode(resp["SecretBinary"]).decode("utf-8", errors="replace"))

    project_id = sa_info.get("project_id")
    creds = service_account.Credentials.from_service_account_info(sa_info)

    _firestore_client = firestore.Client(project=project_id, credentials=creds)

    _log("INFO", "firestore_connect_ok", project_id=project_id)
    return _firestore_client


# ==============================================================================
# TOPICS / COMMAND_ID
# ==============================================================================
def build_device_command_topic(device_id: str) -> str:
    return f"{IOT_TOPIC_PREFIX}/{device_id}/command"


def build_command_id(schedule_id: str, now_local: datetime.datetime) -> str:
    """
    command_id determinístico por minuto:
      sched-<sha1(schedule_id:YYYYMMDDHHMM)[:16]>
    """
    minute_key = now_local.strftime("%Y%m%d%H%M")
    raw = f"{schedule_id}:{minute_key}".encode("utf-8")
    h = hashlib.sha1(raw).hexdigest()[:16]
    return f"sched-{h}"


# ==============================================================================
# DYNAMODB / TELEMETRIA
# ==============================================================================
def get_latest_soil_moisture(device_id: str, max_age_sec: int = TELEMETRY_MAX_AGE_SEC) -> Optional[float]:
    """
    Lê a última umidade do solo no DynamoDB.

    Espera formato de telemetria como o seu:
      sensors.soil_moisture
      timestamp (RangeKey)

    Retorna None se:
      - tabela não existe / região errada / erro Dynamo
      - não houver item
      - faltar sensors.soil_moisture
      - telemetria estiver antiga (stale)
    """
    try:
        resp = table.query(
            KeyConditionExpression=Key(DYNAMODB_PARTITION_KEY).eq(device_id),
            ScanIndexForward=False,  # pega o mais recente primeiro (RangeKey=timestamp)
            Limit=1,
        )

        items = resp.get("Items", []) or []
        if not items:
            _log(
                "WARN",
                "soil_moisture_empty",
                device_id=device_id,
                table=DYNAMO_TABLE,
                region=DYNAMO_REGION,
            )
            return None

        item = items[0]

        # Timestamp do item (RangeKey)
        ts_raw = item.get(DYNAMODB_SORT_KEY)
        ts_int: Optional[int] = None
        try:
            if ts_raw is not None:
                ts_int = int(ts_raw)
        except Exception:
            ts_int = None

        # Umidade está dentro do MAP "sensors"
        sensors = item.get("sensors") or {}
        moisture_raw = sensors.get("soil_moisture")

        if moisture_raw is None:
            _log(
                "WARN",
                "soil_moisture_missing_field",
                device_id=device_id,
                table=DYNAMO_TABLE,
                region=DYNAMO_REGION,
                item_keys=list(item.keys()),
                sensors_keys=list(sensors.keys()) if isinstance(sensors, dict) else None,
            )
            return None

        val = float(moisture_raw)

        # Anti-stale: se telemetria antiga, não confia
        now = int(time.time())
        age = (now - ts_int) if ts_int else None

        if age is None or age > max_age_sec:
            _log(
                "WARN",
                "soil_moisture_stale",
                device_id=device_id,
                soil_moisture=val,
                telemetry_ts=ts_int,
                telemetry_age_sec=age,
                max_age_sec=max_age_sec,
                table=DYNAMO_TABLE,
                region=DYNAMO_REGION,
            )
            return None

        _log(
            "INFO",
            "soil_moisture_read_ok",
            device_id=device_id,
            soil_moisture=val,
            telemetry_ts=ts_int,
            telemetry_age_sec=age,
            table=DYNAMO_TABLE,
            region=DYNAMO_REGION,
        )
        return val

    except Exception as e:
        _log(
            "WARN",
            "soil_moisture_read_failed",
            device_id=device_id,
            error=f"{type(e).__name__}: {e} (table={DYNAMO_TABLE}, region={DYNAMO_REGION})",
        )
        return None


# ==============================================================================
# CLIMA (opcional - mantive simples e robusto)
# ==============================================================================
def check_rain_forecast(lat: float, lon: float) -> Tuple[bool, str]:
    """
    Heurística simples: se max prob >= 70% no dia, sugere pular.
    """
    try:
        url = (
            "https://api.open-meteo.com/v1/forecast"
            f"?latitude={lat}&longitude={lon}"
            "&hourly=precipitation_probability"
            "&forecast_days=1"
            "&timezone=America%2FSao_Paulo"
        )
        _log("INFO", "weather_api_request", url=url, lat=lat, lon=lon)

        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode("utf-8", errors="replace"))

        hourly = (data.get("hourly") or {})
        probs = hourly.get("precipitation_probability") or []
        if not probs:
            return (False, "Sem dados de precipitação (prosseguindo)")

        max_prob = max([int(x) for x in probs if x is not None] or [0])
        if max_prob >= 70:
            return (True, f"Alta chance de chuva (max={max_prob}%)")
        return (False, f"Chance de chuva aceitável (max={max_prob}%)")

    except Exception as e:
        _log("WARN", "weather_api_failed", error=str(e), lat=lat, lon=lon)
        return (False, "Falha ao consultar clima (prosseguindo por segurança)")


# ==============================================================================
# FIRESTORE: COMMAND DOC / HISTORY LOG
# ==============================================================================
def create_command_document(
    db: firestore.Client,
    device_id: str,
    command_id: str,
    action: str,
    duration_s: int,
    origin: str,
    schedule_ref,
    schedule_label: str,
    now_local: datetime.datetime,
):
    """
    Cria devices/<device>/commands/<command_id> com create() para idempotência.
    """
    now_server = firestore.SERVER_TIMESTAMP
    topic = build_device_command_topic(device_id)

    cmd_ref = db.collection("devices").document(device_id).collection("commands").document(command_id)

    doc = {
        "device_id": device_id,
        "command_id": command_id,
        "origin": origin,
        "status": "pending",
        "last_status": "pending",
        "requested_action": action,
        "requested_duration": duration_s,
        "action": action,
        "duration": duration_s,
        "created_at": now_server,
        "updated_at": now_server,
        "schedule": {
            "id": schedule_ref.id,
            "path": schedule_ref.path,
            "label": schedule_label,
            "local_time": now_local.isoformat(),
        },
        "mqtt": {"topic": topic, "qos": 1},
        "schema_version": 1,
    }
    cmd_ref.create(doc)


def save_history_log(
    db: firestore.Client,
    device_id: str,
    log_type: str,
    source: str,
    message: str,
    command_id: Optional[str] = None,
    extra: Optional[Dict[str, Any]] = None,
):
    now_server = firestore.SERVER_TIMESTAMP
    doc = {
        "type": log_type,
        "source": source,
        "device_id": device_id,
        "message": message,
        "timestamp": now_server,
        "updated_at": now_server,
        "command_id": command_id,
        "extra": extra,
    }
    doc = {k: v for k, v in doc.items() if v is not None}

    ref = db.collection("devices").document(device_id).collection("history")
    doc_id = f"log-{command_id}" if command_id else None
    if doc_id:
        ref.document(doc_id).set(doc, merge=True)
    else:
        ref.add(doc)


def publish_iot_command(device_id: str, payload: dict):
    topic = build_device_command_topic(device_id)
    iot_client.publish(
        topic=topic,
        qos=1,
        payload=json.dumps(payload, separators=(",", ":"), ensure_ascii=False),
    )
    return topic


# ==============================================================================
# HANDLER
# ==============================================================================
def lambda_handler(event, context):
    tz = pytz.timezone(TZ_NAME)
    now_local = datetime.datetime.now(tz)

    current_day_flutter = now_local.weekday() + 1  # 1=Seg ... 7=Dom
    current_time_str = now_local.strftime("%H:%M")

    request_id = getattr(context, "aws_request_id", "n/a")

    _log(
        "INFO",
        "scheduler_tick",
        request_id=request_id,
        now_local=now_local.isoformat(),
        day_flutter=current_day_flutter,
        time_hhmm=current_time_str,
        dynamo_table=DYNAMO_TABLE,
        dynamo_region=DYNAMO_REGION,
        telemetry_max_age_sec=TELEMETRY_MAX_AGE_SEC,
    )

    try:
        db = get_firestore_client()

        docs_stream = (
            db.collection_group("schedules")
            .where("enabled", "==", True)
            .where("days", "array_contains", current_day_flutter)
            .where("time", "==", current_time_str)
            .stream()
        )

        executed = 0
        skipped = 0
        duplicates = 0
        errors = 0

        for doc in docs_stream:
            schedule = doc.to_dict() or {}

            device_ref = doc.reference.parent.parent
            device_id = device_ref.id
            schedule_ref = doc.reference
            schedule_id = schedule_ref.id

            label = schedule.get("label", "Schedule")
            duration_s = int(schedule.get("duration_minutes", 5)) * 60

            _log(
                "INFO",
                "schedule_match",
                request_id=request_id,
                device_id=device_id,
                schedule_id=schedule_id,
                label=label,
                duration_s=duration_s,
            )

            # Carrega device settings
            device_doc = device_ref.get()
            if not device_doc.exists:
                _log("WARN", "device_not_found", request_id=request_id, device_id=device_id)
                errors += 1
                continue

            device_data = device_doc.to_dict() or {}
            settings = (device_data.get("settings") or {})

            target_moisture = float(settings.get("target_soil_moisture", 100))
            enable_weather = bool(settings.get("enable_weather_control", False))

            lat = float(settings.get("latitude", 0.0) or 0.0)
            lon = float(settings.get("longitude", 0.0) or 0.0)

            # SOLO (FAIL-CLOSED)
            current_moisture = get_latest_soil_moisture(device_id)
            if current_moisture is None:
                msg = "Ignorado: Telemetria indisponível/antiga (proteção fail-closed)."
                save_history_log(
                    db,
                    device_id,
                    "skipped",
                    "schedule",
                    msg,
                    extra={"telemetry_max_age_sec": TELEMETRY_MAX_AGE_SEC},
                )
                _log(
                    "WARN",
                    "schedule_skipped_telemetry_unavailable",
                    request_id=request_id,
                    device_id=device_id,
                    schedule_id=schedule_id,
                    telemetry_max_age_sec=TELEMETRY_MAX_AGE_SEC,
                )
                skipped += 1
                continue

            if current_moisture >= target_moisture:
                msg = f"Ignorado: Solo em {int(current_moisture)}% (Alvo: {int(target_moisture)}%)"
                save_history_log(
                    db,
                    device_id,
                    "skipped",
                    "schedule",
                    msg,
                    extra={"soil_moisture": current_moisture, "target_moisture": target_moisture},
                )
                _log(
                    "INFO",
                    "schedule_skipped_soil_moisture",
                    request_id=request_id,
                    device_id=device_id,
                    schedule_id=schedule_id,
                    soil_moisture=current_moisture,
                    target_moisture=target_moisture,
                )
                skipped += 1
                continue

            # CLIMA
            if enable_weather:
                should_skip, reason = check_rain_forecast(lat, lon)
                if should_skip:
                    save_history_log(db, device_id, "skipped", "weather_ai", f"Cancelado: {reason}")
                    _log(
                        "INFO",
                        "schedule_skipped_weather",
                        request_id=request_id,
                        device_id=device_id,
                        schedule_id=schedule_id,
                        reason=reason,
                    )
                    skipped += 1
                    continue

            # COMMAND
            command_id = build_command_id(schedule_id, now_local)

            payload = {
                "device_id": device_id,
                "command_id": command_id,
                "action": "on",
                "duration": duration_s,
                "origin": "schedule",
                "schedule_id": schedule_id,
            }

            try:
                try:
                    create_command_document(
                        db=db,
                        device_id=device_id,
                        command_id=command_id,
                        action="on",
                        duration_s=duration_s,
                        origin="schedule",
                        schedule_ref=schedule_ref,
                        schedule_label=label,
                        now_local=now_local,
                    )
                except AlreadyExists:
                    duplicates += 1
                    save_history_log(
                        db,
                        device_id,
                        "duplicate",
                        "schedule",
                        "Duplicado (retry) no mesmo minuto.",
                        command_id=command_id,
                    )
                    _log(
                        "INFO",
                        "schedule_duplicate_idempotent",
                        request_id=request_id,
                        device_id=device_id,
                        schedule_id=schedule_id,
                        command_id=command_id,
                    )
                    continue

                mqtt_topic = publish_iot_command(device_id, payload)

                save_history_log(
                    db,
                    device_id,
                    "execution",
                    "schedule",
                    f"Executado: {label} por {int(duration_s/60)} min",
                    command_id=command_id,
                    extra={"mqtt_topic": mqtt_topic},
                )

                executed += 1
                _log(
                    "INFO",
                    "schedule_executed",
                    request_id=request_id,
                    device_id=device_id,
                    schedule_id=schedule_id,
                    command_id=command_id,
                    mqtt_topic=mqtt_topic,
                )

            except Exception as e:
                errors += 1
                save_history_log(
                    db,
                    device_id,
                    "error",
                    "system",
                    f"Falha ao enviar comando: {str(e)}",
                    command_id=command_id,
                )
                _log(
                    "ERROR",
                    "schedule_execution_failed",
                    request_id=request_id,
                    device_id=device_id,
                    schedule_id=schedule_id,
                    command_id=command_id,
                    error=str(e),
                )

        body = {
            "message": "Scheduler cycle completed",
            "executed": executed,
            "skipped": skipped,
            "duplicates": duplicates,
            "errors": errors,
            "timestamp": now_local.isoformat(),
            "request_id": request_id,
        }

        _log("INFO", "scheduler_cycle_completed", **body)
        return {"statusCode": 200, "body": json.dumps(body, ensure_ascii=False)}

    except Exception as e:
        _log("ERROR", "scheduler_critical_error", request_id=request_id, error=str(e))
        return {"statusCode": 500, "body": json.dumps({"error": str(e), "request_id": request_id}, ensure_ascii=False)}
