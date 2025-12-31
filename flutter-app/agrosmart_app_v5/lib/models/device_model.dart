class DeviceSettings {
  double targetMoisture;   // Umidade ideal (ex: 60%)
  int manualDuration;      // Tempo de rega manual em minutos (ex: 5)
  String deviceName;       // Nome amigável (ex: "Jardim da Frente")

  DeviceSettings({
    required this.targetMoisture,
    required this.manualDuration,
    required this.deviceName,
  });

  // Converte JSON do Firebase para Objeto
  factory DeviceSettings.fromMap(Map<String, dynamic> map) {
    return DeviceSettings(
      targetMoisture: (map['target_soil_moisture'] ?? 60).toDouble(),
      manualDuration: map['manual_valve_duration'] ?? 5,
      deviceName: map['device_name'] ?? 'Dispositivo Sem Nome',
    );
  }

  // Converte Objeto para JSON (para salvar no Firebase)
  Map<String, dynamic> toMap() {
    return {
      'target_soil_moisture': targetMoisture,
      'manual_valve_duration': manualDuration,
      'device_name': deviceName,
    };
  }
}

class DeviceModel {
  final String id; // ID do Hardware (ex: ESP32-A1B2)
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