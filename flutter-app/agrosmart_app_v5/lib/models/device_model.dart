// ARQUIVO: lib/models/device_model.dart

class DeviceSettings {
  double targetMoisture;
  int manualDuration;
  String deviceName;
  int timezoneOffset;
  double latitude;
  double longitude;
  bool enableWeatherControl;
  
  // Lista de capacidades (quais sensores esse dispositivo tem)
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
    // --- LÓGICA DE COMPATIBILIDADE ---
    // Se o campo 'capabilities' não existir (dispositivos antigos),
    // assumimos que ele é um dispositivo completo (V5) para não sumir os sensores.
    var caps = <String>['air', 'soil', 'light', 'rain', 'uv']; 
    
    if (map['capabilities'] != null) {
      // Converte a lista dinâmica do Firebase para List<String>
      caps = List<String>.from(map['capabilities']);
    }

    return DeviceSettings(
      targetMoisture: (map['target_soil_moisture'] ?? 60).toDouble(),
      manualDuration: map['manual_valve_duration'] ?? 5,
      deviceName: map['device_name'] ?? 'Dispositivo Sem Nome',
      timezoneOffset: map['timezone_offset'] ?? -3,
      // Garante que lat/lon sejam double mesmo que venham como int do banco
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