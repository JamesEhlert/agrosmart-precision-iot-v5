// ARQUIVO: lib/models/telemetry_model.dart

class TelemetryModel {
  final double airTemp;
  final double airHumidity;
  final double soilMoisture;
  final double uvIndex;
  final double lightLevel;
  final int rainRaw;
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
    final sensors = json['sensors'] ?? {};

    return TelemetryModel(
      airTemp: (sensors['air_temp'] ?? 0).toDouble(),
      airHumidity: (sensors['air_humidity'] ?? 0).toDouble(),
      soilMoisture: (sensors['soil_moisture'] ?? 0).toDouble(),
      uvIndex: (sensors['uv_index'] ?? 0).toDouble(),
      lightLevel: (sensors['light_level'] ?? 0).toDouble(),
      rainRaw: (sensors['rain_raw'] ?? 0).toInt(),

      // CORREÇÃO AQUI: isUtc: true
      // Isso impede que o Flutter converta automaticamente para local antes da hora,
      // evitando que nosso ajuste de fuso horário seja aplicado duas vezes.
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['timestamp'] * 1000).toInt(), 
              isUtc: true // <--- O SEGREDO ESTÁ AQUI
            )
          : DateTime.now().toUtc(),
    );
  }
}