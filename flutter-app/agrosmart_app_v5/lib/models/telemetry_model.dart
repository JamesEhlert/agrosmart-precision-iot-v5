class TelemetryModel {
  final double airTemp;
  final double airHumidity;
  final double soilMoisture;
  final double uvIndex;
  final double lightLevel;
  final int rainRaw; // Sensor de chuva geralmente é int (0-4095)
  final DateTime timestamp;

  TelemetryModel({
    required this.airTemp,
    required this.airHumidity,
    required this.soilMoisture,
    required this.uvIndex,
    required this.lightLevel,
    required this.rainRaw,
    required this.timestamp,
  });

  factory TelemetryModel.fromJson(Map<String, dynamic> json) {
    // 1. O json que chega aqui é um item da lista 'data'.
    // Ex: { "device_id": "...", "sensors": { ... }, "timestamp": ... }
    
    final sensors = json['sensors'] ?? {};

    return TelemetryModel(
      // Usamos toDouble() para garantir que não quebre se vier int
      airTemp: (sensors['air_temp'] ?? 0).toDouble(),
      airHumidity: (sensors['air_humidity'] ?? 0).toDouble(),
      soilMoisture: (sensors['soil_moisture'] ?? 0).toDouble(),
      uvIndex: (sensors['uv_index'] ?? 0).toDouble(),
      lightLevel: (sensors['light_level'] ?? 0).toDouble(),
      rainRaw: (sensors['rain_raw'] ?? 0).toInt(),
      
      // O Timestamp da AWS geralmente vem em segundos (Unix Epoch)
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch((json['timestamp'] * 1000).toInt())
          : DateTime.now(),
    );
  }
}