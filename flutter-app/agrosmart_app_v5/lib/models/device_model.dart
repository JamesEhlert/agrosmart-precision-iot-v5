// ARQUIVO: lib/models/device_model.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class DeviceSettings {
  double targetMoisture;
  int manualDuration;
  String deviceName;
  int timezoneOffset;
  double latitude;
  double longitude;
  bool enableWeatherControl;
  List<String> capabilities;

  DeviceSettings({
    required this.targetMoisture,
    required this.manualDuration,
    required this.deviceName,
    required this.timezoneOffset,
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.enableWeatherControl = false,
    required this.capabilities,
  });

  factory DeviceSettings.fromMap(Map<String, dynamic> map) {
    // Capabilities padrão (fallback)
    var caps = <String>['air', 'soil', 'light', 'rain', 'uv'];
    if (map['capabilities'] != null) {
      caps = List<String>.from(map['capabilities']);
    }

    return DeviceSettings(
      targetMoisture: (map['target_soil_moisture'] ?? 60).toDouble(),
      manualDuration: map['manual_valve_duration'] ?? 5,
      deviceName: map['device_name'] ?? 'Dispositivo Sem Nome',
      timezoneOffset: map['timezone_offset'] ?? -3,
      latitude: (map['latitude'] ?? 0.0).toDouble(),
      longitude: (map['longitude'] ?? 0.0).toDouble(),
      enableWeatherControl: map['enable_weather_control'] ?? false,
      capabilities: caps,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'target_soil_moisture': targetMoisture,
      'manual_valve_duration': manualDuration,
      'device_name': deviceName,
      'timezone_offset': timezoneOffset,
      'latitude': latitude,
      'longitude': longitude,
      'enable_weather_control': enableWeatherControl,
      'capabilities': capabilities,
    };
  }
}

// =====================================================================================
// STATE (Source of truth do device, vindo do Firestore)
// =====================================================================================
class DeviceState {
  final bool valveOpen;
  final String? valveOrigin;

  /// Timestamp vindo da nuvem:
  /// - quando abre: pode ser um horário "previsto" (agora + duração)
  /// - quando fecha: pode virar o horário real de término
  final DateTime? valveEndsAt;

  DeviceState({
    this.valveOpen = false,
    this.valveOrigin,
    this.valveEndsAt,
  });

  factory DeviceState.fromMap(Map<String, dynamic>? map) {
    if (map == null) return DeviceState();

    return DeviceState(
      valveOpen: map['valve_open'] ?? false,
      valveOrigin: map['valve_origin'],
      valveEndsAt: _parseFirestoreDate(map['valve_ends_at']),
    );
  }

  /// Parser robusto para data vinda do Firestore / mocks / integrações.
  /// Aceita:
  /// - Timestamp (Firestore)
  /// - DateTime (mocks/testes)
  /// - String ISO-8601
  /// - int epoch (ms ou s)
  static DateTime? _parseFirestoreDate(dynamic value) {
    if (value == null) return null;

    // Firestore Timestamp
    if (value is Timestamp) {
      return value.toDate();
    }

    // Test/mocks
    if (value is DateTime) {
      return value;
    }

    // ISO string
    if (value is String) {
      return DateTime.tryParse(value);
    }

    // Epoch (segundos ou milissegundos)
    if (value is int) {
      // Heurística: se for muito grande, assume ms
      final isMilliseconds = value > 100000000000; // ~ ano 5138 em segundos, então aqui é ms com folga
      final ms = isMilliseconds ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    }

    // Qualquer outro tipo não suportado
    return null;
  }
}

class DeviceModel {
  final String id;
  final bool isOnline;
  final DeviceSettings settings;
  final DeviceState state;

  DeviceModel({
    required this.id,
    required this.isOnline,
    required this.settings,
    required this.state,
  });

  factory DeviceModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return DeviceModel(
      id: docId,
      isOnline: data['online'] ?? false,
      settings: DeviceSettings.fromMap(data['settings'] ?? {}),
      state: DeviceState.fromMap(data['state']),
    );
  }
}