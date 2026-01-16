// ARQUIVO: lib/models/device_model.dart

/// Classe que representa as configurações editáveis de um dispositivo.
class DeviceSettings {
  double targetMoisture;   // Umidade alvo (Se sensor > isso, não rega)
  int manualDuration;      // Tempo da rega manual (minutos)
  String deviceName;       // Nome amigável do dispositivo
  int timezoneOffset;      // Deslocamento do UTC (ex: -3 para Brasília)
  
  // --- NOVOS CAMPOS PARA INTEGRAÇÃO DE CLIMA ---
  double latitude;         // Latitude geográfica do dispositivo
  double longitude;        // Longitude geográfica do dispositivo
  bool enableWeatherControl; // Ativa/Desativa a inteligência baseada em chuva

  DeviceSettings({
    required this.targetMoisture,
    required this.manualDuration,
    required this.deviceName,
    required this.timezoneOffset,
    // Valores padrão no construtor para evitar null
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.enableWeatherControl = false,
  });

  /// Cria uma instância de DeviceSettings a partir de um Map (JSON do Firestore).
  factory DeviceSettings.fromMap(Map<String, dynamic> map) {
    return DeviceSettings(
      targetMoisture: (map['target_soil_moisture'] ?? 60).toDouble(),
      manualDuration: map['manual_valve_duration'] ?? 5,
      deviceName: map['device_name'] ?? 'Dispositivo Sem Nome',
      timezoneOffset: map['timezone_offset'] ?? -3, // Padrão Brasília
      
      // Mapeamento dos novos campos com valores de segurança (fallback)
      latitude: (map['latitude'] ?? 0.0).toDouble(),
      longitude: (map['longitude'] ?? 0.0).toDouble(),
      enableWeatherControl: map['enable_weather_control'] ?? false,
    );
  }

  /// Converte o objeto para Map (JSON) para salvar no Firestore.
  Map<String, dynamic> toMap() {
    return {
      'target_soil_moisture': targetMoisture,
      'manual_valve_duration': manualDuration,
      'device_name': deviceName,
      'timezone_offset': timezoneOffset,
      
      // Salvando os novos campos
      'latitude': latitude,
      'longitude': longitude,
      'enable_weather_control': enableWeatherControl,
    };
  }
}

/// Modelo principal que representa um Dispositivo completo (Estado + Configurações).
class DeviceModel {
  final String id;              // ID do documento/hardware
  final bool isOnline;          // Status de conexão
  final DeviceSettings settings; // Objeto de configurações aninhado

  DeviceModel({
    required this.id,
    required this.isOnline,
    required this.settings,
  });

  /// Factory para criar o modelo vindo do Firestore.
  factory DeviceModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return DeviceModel(
      id: docId,
      isOnline: data['online'] ?? false,
      settings: DeviceSettings.fromMap(data['settings'] ?? {}),
    );
  }
}