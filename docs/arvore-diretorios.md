.
└── agrosmart-precision-iot-v5
    ├── backend
    │   └── lambda
    │       ├── aws_lambda_scheduler
    │       │   └── AgroSmart_Scheduler_Logic.py
    │       ├── get-telemetry
    │       │   └── AgroSmart_V5_GetTelemetry.py
    │       └── send-command
    │           └── AgroSmart_V5_SendCommand.py
    ├── docs
    │   ├── API_CONTRACT.md
    │   ├── ARCHITECTURE.md
    │   ├── auth-aws-firebase.md
    │   ├── DATA_MODEL.md
    │   ├── diagrams
    │   │   ├── architecture.mmd
    │   │   └── mermaid-ai-diagram-2026-02-04-034129.png
    │   └── SECURITY.md
    ├── firmware
    │   ├── include
    │   │   └── secrets.example.h
    │   ├── platformio.ini
    │   └── src
    │       └── main.cpp
    ├── flutter-app
    │   └── agrosmart_app_v5
    │       ├── analysis_options.yaml
    │       ├── android
    │       │   ├── app
    │       │   │   ├── build.gradle.kts
    │       │   │   └── src
    │       │   │       ├── debug
    │       │   │       │   └── AndroidManifest.xml
    │       │   │       └── profile
    │       │   │           └── AndroidManifest.xml
    │       │   ├── build
    │       │   │   └── reports
    │       │   │       └── problems
    │       │   │           └── problems-report.html
    │       │   ├── build.gradle.kts
    │       │   ├── gradle
    │       │   │   └── wrapper
    │       │   │       └── gradle-wrapper.properties
    │       │   ├── gradle.properties
    │       │   └── settings.gradle.kts
    │       ├── firebase.json
    │       ├── lib
    │       │   ├── firebase_options.dart
    │       │   ├── main.dart
    │       │   ├── models
    │       │   │   ├── activity_log_model.dart
    │       │   │   ├── device_model.dart
    │       │   │   ├── schedule_model.dart
    │       │   │   └── telemetry_model.dart
    │       │   ├── screens
    │       │   │   ├── dashboard_screen.dart
    │       │   │   ├── history_tab.dart
    │       │   │   ├── home_screen.dart
    │       │   │   ├── login_screen.dart
    │       │   │   ├── schedule_form_screen.dart
    │       │   │   ├── settings_tab.dart
    │       │   │   ├── signup_screen.dart
    │       │   │   └── weather_screen.dart
    │       │   └── services
    │       │       ├── auth_service.dart
    │       │       ├── aws_service.dart
    │       │       ├── device_service.dart
    │       │       ├── history_service.dart
    │       │       └── schedules_service.dart
    │       ├── pubspec.lock
    │       ├── pubspec.yaml
    │       ├── README.md
    │       └── test
    │           └── widget_test.dart
    ├── README.md
    └── workspace.code-workspace


