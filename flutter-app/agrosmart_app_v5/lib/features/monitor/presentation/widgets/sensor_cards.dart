// ARQUIVO: lib/features/monitor/presentation/widgets/sensor_cards.dart

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../../../../models/telemetry_model.dart';
import '../../../../../core/theme/app_colors.dart';

class SensorCards extends StatelessWidget {
  final TelemetryModel? data;
  final bool isLoadingTelemetry;
  final List<String> capabilities;

  const SensorCards({
    super.key,
    required this.data,
    required this.isLoadingTelemetry,
    required this.capabilities,
  });

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54)),
    );
  }

  Widget _buildSensorsShimmer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle("Ambiente & Solo"),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildSingleSensorShimmer(),
                _buildSingleSensorShimmer(),
                _buildSingleSensorShimmer(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSingleSensorShimmer() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[300]!,
      highlightColor: Colors.grey[100]!,
      child: Column(
        children: [
          Container(width: 52, height: 52, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
          const SizedBox(height: 8),
          Container(width: 50, height: 18, color: Colors.white),
          const SizedBox(height: 4),
          Container(width: 40, height: 12, color: Colors.white),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoadingTelemetry && data == null) {
      return _buildSensorsShimmer();
    }

    if (data == null) {
      return const SizedBox.shrink();
    }

    if (!capabilities.contains('air') && !capabilities.contains('soil')) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle("Ambiente & Solo"),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                if (capabilities.contains('air')) ...[
                  _SensorWidget(icon: Icons.thermostat, value: "${data!.airTemp.toStringAsFixed(1)}°C", label: "Temp Ar", color: AppColors.sensorTemp),
                  _SensorWidget(icon: Icons.water_drop_outlined, value: "${data!.airHumidity.toStringAsFixed(0)}%", label: "Umid. Ar", color: AppColors.sensorHumidity),
                ],
                if (capabilities.contains('soil'))
                  _SensorWidget(icon: Icons.grass, value: "${data!.soilMoisture.toStringAsFixed(0)}%", label: "Umid. Solo", color: AppColors.sensorSoil),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _SensorWidget extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _SensorWidget({required this.icon, required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
        child: Icon(icon, color: color, size: 28),
      ),
      const SizedBox(height: 8),
      Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    ]);
  }
}