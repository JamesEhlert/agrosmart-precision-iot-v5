// ARQUIVO: lib/features/weather/presentation/weather_screen.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart'; 

import '../../../models/device_model.dart';
import '../../../core/theme/app_colors.dart'; 

class WeatherScreen extends StatefulWidget {
  final DeviceModel device;

  const WeatherScreen({super.key, required this.device});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  bool _isLoading = true;
  bool _hasError = false;
  Map<String, dynamic>? _weatherData;

  @override
  void initState() {
    super.initState();
    _fetchWeather();
  }

  Future<void> _fetchWeather() async {
    final lat = widget.device.settings.latitude;
    final lon = widget.device.settings.longitude;

    if (lat == 0 && lon == 0) {
      if (mounted) setState(() { _isLoading = false; _hasError = true; });
      return;
    }

    try {
      await initializeDateFormatting('pt_BR', null);

      final url = Uri.parse(
          "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max&timezone=auto");

      final response = await http.get(url);

      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _weatherData = json.decode(response.body);
            _isLoading = false;
          });
        }
      } else {
        throw Exception("Erro API: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _hasError = true; });
    }
  }

  Map<String, dynamic> _getWeatherInfo(int code) {
    switch (code) {
      case 0: return {'label': 'Céu Limpo', 'icon': Icons.wb_sunny, 'color': AppColors.sensorTemp};
      case 1:
      case 2:
      case 3: return {'label': 'Nublado', 'icon': Icons.cloud, 'color': AppColors.sensorRain};
      case 45:
      case 48: return {'label': 'Nevoeiro', 'icon': Icons.foggy, 'color': AppColors.textSecondary};
      case 51: case 53: case 55: return {'label': 'Garoa', 'icon': Icons.grain, 'color': AppColors.info};
      case 61: case 63: case 65: return {'label': 'Chuva', 'icon': Icons.water_drop, 'color': AppColors.sensorHumidity};
      case 80: case 81: case 82: return {'label': 'Chuva Forte', 'icon': Icons.tsunami, 'color': AppColors.primaryDark};
      case 95: case 96: case 99: return {'label': 'Tempestade', 'icon': Icons.flash_on, 'color': AppColors.errorAccent};
      default: return {'label': 'Desconhecido', 'icon': Icons.help_outline, 'color': AppColors.textSecondary};
    }
  }

  String _formatDay(String dateStr) {
    final date = DateTime.parse(dateStr);
    return DateFormat('EEEE, dd/MM', 'pt_BR').format(date); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      // CORREÇÃO DO BUG DA BARRA BRANCA:
      // Diz ao Flutter para não encolher a tela se ele achar que o teclado está aberto.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text("Previsão 7 Dias"),
        backgroundColor: AppColors.primary, 
        foregroundColor: AppColors.textLight,
        elevation: 0,
      ),
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_hasError) return const Center(child: Text("Erro ao carregar dados.", style: TextStyle(color: AppColors.error)));

    final current = _weatherData!['current'];
    final daily = _weatherData!['daily'];
    final currentInfo = _getWeatherInfo(current['weather_code']);

    return Column(
      children: [
        // --- CABEÇALHO (Ajustado para ficar mais compacto e elegante) ---
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Icon(currentInfo['icon'], size: 56, color: AppColors.textLight),
              const SizedBox(height: 8),
              Text("${current['temperature_2m']}°C", style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: AppColors.textLight)),
              Text(currentInfo['label'], style: TextStyle(fontSize: 18, color: AppColors.textLight.withValues(alpha: 0.9))),
            ],
          ),
        ),

        // --- LISTA MELHORADA ---
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(), // Adiciona um efeito de elástico na rolagem (padrão iOS/Android modernos)
            padding: const EdgeInsets.all(16),
            itemCount: (daily['time'] as List).length,
            itemBuilder: (context, index) {
              final date = daily['time'][index];
              final max = daily['temperature_2m_max'][index];
              final min = daily['temperature_2m_min'][index];
              final rainMm = daily['precipitation_sum'][index];
              final rainProb = daily['precipitation_probability_max'][index];
              final code = daily['weather_code'][index];
              final info = _getWeatherInfo(code);

              return Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  child: Row(
                    children: [
                      Column(
                        children: [
                          Icon(info['icon'], color: info['color'], size: 30),
                          const SizedBox(height: 4),
                          Text(_formatDay(date).split(',')[0], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.textPrimary)),
                        ],
                      ),
                      const SizedBox(width: 16),
                      
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_formatDay(date), style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.water_drop, size: 14, color: AppColors.info),
                                Text(" $rainProb% ($rainMm mm)", style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                              ],
                            )
                          ],
                        ),
                      ),

                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text("Máx $max°", style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.errorAccent)),
                          Text("Mín $min°", style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.info)),
                        ],
                      )
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}