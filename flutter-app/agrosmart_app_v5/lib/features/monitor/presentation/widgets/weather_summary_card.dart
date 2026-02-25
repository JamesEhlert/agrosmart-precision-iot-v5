// ARQUIVO: lib/features/monitor/presentation/widgets/weather_summary_card.dart

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../../../../models/device_model.dart';
import '../../../../../screens/weather_screen.dart';
import '../../../../../core/theme/app_colors.dart';

class WeatherSummaryCard extends StatelessWidget {
  final DeviceModel device;
  final bool loadingWeather;
  final Map<String, dynamic>? weatherSummary;
  final bool isLoadingTelemetry;

  const WeatherSummaryCard({
    super.key,
    required this.device,
    required this.loadingWeather,
    required this.weatherSummary,
    required this.isLoadingTelemetry,
  });

  Map<String, dynamic> _getWeatherInfo(int code) {
    switch (code) {
      case 0: return {'label': 'Limpo', 'icon': Icons.wb_sunny, 'color': Colors.orangeAccent};
      case 1: case 2: case 3: return {'label': 'Nublado', 'icon': Icons.cloud, 'color': Colors.white70};
      case 61: case 63: case 65: return {'label': 'Chuva', 'icon': Icons.water_drop, 'color': Colors.lightBlue};
      case 95: case 96: case 99: return {'label': 'Tempestade', 'icon': Icons.flash_on, 'color': Colors.deepOrangeAccent};
      default: return {'label': 'Instável', 'icon': Icons.cloud_queue, 'color': Colors.grey};
    }
  }

  Widget _buildWeatherShimmer() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Container(
        height: 110,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool hasGps = device.settings.latitude != 0 && device.settings.longitude != 0;
    
    if (!hasGps) return const SizedBox.shrink();

    if (loadingWeather || (weatherSummary == null && isLoadingTelemetry)) {
      return _buildWeatherShimmer();
    }

    return Card(
      color: AppColors.primary,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => WeatherScreen(device: device))),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 110,
          padding: const EdgeInsets.all(16),
          child: weatherSummary == null
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center, 
                  children: [
                    Icon(Icons.touch_app, color: Colors.white70), 
                    SizedBox(width: 8), 
                    Text("Ver previsão", style: TextStyle(color: Colors.white))
                  ]
                )
              : Row(
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(_getWeatherInfo(weatherSummary!['current']['weather_code'])['icon'], color: Colors.white, size: 36),
                        Text(_getWeatherInfo(weatherSummary!['current']['weather_code'])['label'], style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(width: 20),
                    Text("${weatherSummary!['current']['temperature_2m'].toInt()}°", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 42)),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Máx ${weatherSummary!['daily']['temperature_2m_max'][0].toInt()}°", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          Text("Mín ${weatherSummary!['daily']['temperature_2m_min'][0].toInt()}°", style: const TextStyle(color: Colors.white70)),
                          Row(
                            children: [
                              const Icon(Icons.water_drop, color: Colors.lightBlueAccent, size: 14),
                              Text(" ${weatherSummary!['daily']['precipitation_probability_max'][0]}%", style: const TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
                            ],
                          )
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, color: Colors.white30, size: 16)
                  ],
                ),
        ),
      ),
    );
  }
}