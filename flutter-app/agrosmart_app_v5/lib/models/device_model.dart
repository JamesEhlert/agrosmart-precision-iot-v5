// ARQUIVO: lib/models/device_model.dart

class DeviceSettings {
  double targetMoisture;   // Umidade alvo (Se sensor > isso, não rega)
  int manualDuration;      // Tempo da rega manual (minutos)
  String deviceName;       // Nome amigável
  int timezoneOffset;      // NOVO: Deslocamento do UTC (ex: -3 para Brasília)

  DeviceSettings({
    required this.targetMoisture,
    required this.manualDuration,
    required this.deviceName,
    required this.timezoneOffset,
  });

  // Converte JSON do Firebase para Objeto
  factory DeviceSettings.fromMap(Map<String, dynamic> map) {
    return DeviceSettings(
      targetMoisture: (map['target_soil_moisture'] ?? 60).toDouble(),
      manualDuration: map['manual_valve_duration'] ?? 5,
      deviceName: map['device_name'] ?? 'Dispositivo Sem Nome',
      // Se não tiver configurado ainda, assume -3 (Brasília) como padrão
      timezoneOffset: map['timezone_offset'] ?? -3,
    );
  }

  // Converte Objeto para JSON (para salvar no Firebase)
  Map<String, dynamic> toMap() {
    return {
      'target_soil_moisture': targetMoisture,
      'manual_valve_duration': manualDuration,
      'device_name': deviceName,
      'timezone_offset': timezoneOffset,
    };
  }
}

class DeviceModel {
  final String id;
  final bool isOnline;
  final DeviceSettings settings;

  DeviceModel({
    required this.id,
    required this.isOnline,
    required this.settings,
  });

  factory DeviceModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return DeviceModel(
      id: docId,
      isOnline: data['online'] ?? false,
      settings: DeviceSettings.fromMap(data['settings'] ?? {}),
    );
  }
}