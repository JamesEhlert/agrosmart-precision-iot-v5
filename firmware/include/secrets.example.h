#pragma once

/*
  AgroSmart Precision IoT V5 — Secrets Template

  ✅ How to use:
    1) Copy this file to: firmware/include/secrets.h
    2) Fill in your real values in secrets.h
    3) NEVER commit secrets.h (it is gitignored)

  ⚠️ Security note:
    - This file is safe to commit because it contains placeholders only.
    - secrets.h contains Wi-Fi credentials + AWS IoT certificates/private key.
*/

static const char* WIFI_SSID     = "YOUR_WIFI_SSID";
static const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

/*
  AWS IoT Core endpoint (ATS), example format:
  a1234567890-ats.iot.us-east-2.amazonaws.com
*/
static const char* AWS_IOT_ENDPOINT = "YOUR_AWS_IOT_ENDPOINT";

/*
  Topics (current AS-IS project setup)
  Later (hardening), we will move to per-device topics.
*/
static const char* AWS_IOT_PUBLISH_TOPIC   = "agrosmart/v5/telemetry";
static const char* AWS_IOT_SUBSCRIBE_TOPIC = "agrosmart/v5/command";

/*
  Thing name / device_id.
  Must match:
   - Your AWS IoT Thing Name
   - The certificate policy (clientId) expectations
*/
static const char* THINGNAME = "ESP32-AgroSmart-Station-V5";

/*
  Certificates in PEM format (keep the BEGIN/END lines).
  Tip: use the exact PEM text including line breaks.

  These strings are used by:
    net.setCACert(AWS_CERT_CA);
    net.setCertificate(AWS_CERT_CRT);
    net.setPrivateKey(AWS_CERT_PRIVATE);
*/
static const char AWS_CERT_CA[] = R"EOF(
-----BEGIN CERTIFICATE-----
YOUR_ROOT_CA_CERT_HERE
-----END CERTIFICATE-----
)EOF";

static const char AWS_CERT_CRT[] = R"EOF(
-----BEGIN CERTIFICATE-----
YOUR_DEVICE_CERT_HERE
-----END CERTIFICATE-----
)EOF";

static const char AWS_CERT_PRIVATE[] = R"EOF(
-----BEGIN RSA PRIVATE KEY-----
YOUR_DEVICE_PRIVATE_KEY_HERE
-----END RSA PRIVATE KEY-----
)EOF";
