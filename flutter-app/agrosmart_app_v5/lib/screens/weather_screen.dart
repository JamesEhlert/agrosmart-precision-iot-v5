// ARQUIVO: lib/screens/weather_screen.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart'; 
import '../models/device_model.dart';

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

      // ATUALIZADO: Adicionamos 'precipitation_probability_max' na chamada API
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

  // Helper para traduzir códigos WMO
  Map<String, dynamic> _getWeatherInfo(int code) {
    switch (code) {
      case 0: return {'label': 'Céu Limpo', 'icon': Icons.wb_sunny, 'color': Colors.orange};
      case 1:
      case 2:
      case 3: return {'label': 'Nublado', 'icon': Icons.cloud, 'color': Colors.blueGrey};
      case 45:
      case 48: return {'label': 'Nevoeiro', 'icon': Icons.foggy, 'color': Colors.grey};
      case 51: case 53: case 55: return {'label': 'Garoa', 'icon': Icons.grain, 'color': Colors.lightBlue};
      case 61: case 63: case 65: return {'label': 'Chuva', 'icon': Icons.water_drop, 'color': Colors.blue};
      case 80: case 81: case 82: return {'label': 'Chuva Forte', 'icon': Icons.tsunami, 'color': Colors.indigo};
      case 95: case 96: case 99: return {'label': 'Tempestade', 'icon': Icons.flash_on, 'color': Colors.deepOrange};
      default: return {'label': 'Desconhecido', 'icon': Icons.help_outline, 'color': Colors.grey};
    }
  }

  String _formatDay(String dateStr) {
    final date = DateTime.parse(dateStr);
    return DateFormat('EEEE, dd/MM', 'pt_BR').format(date); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Previsão 7 Dias"),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_hasError) return const Center(child: Text("Erro ao carregar dados."));

    final current = _weatherData!['current'];
    final daily = _weatherData!['daily'];
    final currentInfo = _getWeatherInfo(current['weather_code']);

    return Column(
      children: [
        // --- CABEÇALHO ---
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Colors.blueAccent,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
          ),
          child: Column(
            children: [
              Icon(currentInfo['icon'], size: 64, color: Colors.white),
              const SizedBox(height: 10),
              Text("${current['temperature_2m']}°C", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
              Text(currentInfo['label'], style: const TextStyle(fontSize: 20, color: Colors.white70)),
            ],
          ),
        ),

        // --- LISTA MELHORADA ---
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: (daily['time'] as List).length,
            itemBuilder: (context, index) {
              final date = daily['time'][index];
              final max = daily['temperature_2m_max'][index];
              final min = daily['temperature_2m_min'][index];
              final rainMm = daily['precipitation_sum'][index];
              final rainProb = daily['precipitation_probability_max'][index]; // Novo
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
                      // Ícone e Data
                      Column(
                        children: [
                          Icon(info['icon'], color: info['color'], size: 30),
                          const SizedBox(height: 4),
                          Text(_formatDay(date).split(',')[0], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)), // Apenas dia da semana
                        ],
                      ),
                      const SizedBox(width: 16),
                      
                      // Dados de Chuva
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_formatDay(date), style: const TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.water_drop, size: 14, color: Colors.blue),
                                Text(" $rainProb% ($rainMm mm)", style: TextStyle(color: Colors.grey[700], fontSize: 13)),
                              ],
                            )
                          ],
                        ),
                      ),

                      // Temperaturas Mín/Máx
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text("Máx $max°", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
                          Text("Mín $min°", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
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