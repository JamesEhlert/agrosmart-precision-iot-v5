// ARQUIVO: lib/screens/weather_screen.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
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

    // Se não tiver GPS, mostra erro amigável
    if (lat == 0 && lon == 0) {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      return;
    }

    try {
      // API Open-Meteo (Gratuita, sem chave)
      final url = Uri.parse(
          "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum&timezone=auto");

      debugPrint("Baixando previsão: $url");
      
      final response = await http.get(url);

      if (response.statusCode == 200) {
        setState(() {
          _weatherData = json.decode(response.body);
          _isLoading = false;
        });
      } else {
        throw Exception("Erro API: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Erro Weather: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  // Helper para traduzir códigos WMO para Texto e Ícones
  // Fonte: https://open-meteo.com/en/docs
  Map<String, dynamic> _getWeatherInfo(int code) {
    switch (code) {
      case 0: return {'label': 'Céu Limpo', 'icon': Icons.wb_sunny, 'color': Colors.orange};
      case 1:
      case 2:
      case 3: return {'label': 'Nublado', 'icon': Icons.cloud, 'color': Colors.grey};
      case 45:
      case 48: return {'label': 'Nevoeiro', 'icon': Icons.foggy, 'color': Colors.blueGrey};
      case 51:
      case 53:
      case 55: return {'label': 'Garoa', 'icon': Icons.grain, 'color': Colors.lightBlue};
      case 61:
      case 63:
      case 65: return {'label': 'Chuva', 'icon': Icons.water_drop, 'color': Colors.blue};
      case 80:
      case 81:
      case 82: return {'label': 'Chuva Forte', 'icon': Icons.tsunami, 'color': Colors.indigo};
      case 95:
      case 96:
      case 99: return {'label': 'Tempestade', 'icon': Icons.flash_on, 'color': Colors.deepOrange};
      default: return {'label': 'Desconhecido', 'icon': Icons.help_outline, 'color': Colors.grey};
    }
  }

  String _formatDay(String dateStr) {
    final date = DateTime.parse(dateStr);
    return DateFormat('EEEE, dd/MM', 'pt_BR').format(date); // Requer 'intl' configurado ou padrão
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Previsão do Tempo"),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.gps_off, size: 60, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              "Não foi possível carregar a previsão.\nVerifique se o dispositivo tem GPS configurado.",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchWeather,
              child: const Text("Tentar Novamente"),
            )
          ],
        ),
      );
    }

    final current = _weatherData!['current'];
    final daily = _weatherData!['daily'];
    final currentInfo = _getWeatherInfo(current['weather_code']);

    return Column(
      children: [
        // --- CABEÇALHO (AGORA) ---
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
              Text(
                "${current['temperature_2m']}°C",
                style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              Text(
                currentInfo['label'],
                style: const TextStyle(fontSize: 20, color: Colors.white70),
              ),
            ],
          ),
        ),

        // --- LISTA (PRÓXIMOS DIAS) ---
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: (daily['time'] as List).length,
            itemBuilder: (context, index) {
              final date = daily['time'][index];
              final max = daily['temperature_2m_max'][index];
              final min = daily['temperature_2m_min'][index];
              final rain = daily['precipitation_sum'][index];
              final code = daily['weather_code'][index];
              final info = _getWeatherInfo(code);

              return Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: (info['color'] as Color).withAlpha(30), // Correção para versão nova do Flutter
                    child: Icon(info['icon'], color: info['color']),
                  ),
                  title: Text(_formatDay(date), style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("Chuva: ${rain}mm"),
                  trailing: Text(
                    "$max° / $min°",
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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