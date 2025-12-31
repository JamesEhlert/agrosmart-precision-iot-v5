import 'dart:convert';
import 'package:flutter/foundation.dart'; // Para debugPrint
import 'package:http/http.dart' as http;
import '../models/telemetry_model.dart';

class AwsService {
  // URLs da API AWS
  final String _telemetryUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/telemetry";
  final String _commandUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/command";

  // --- BUSCAR DADOS (GET) ---
  Future<TelemetryModel?> getLatestTelemetry(String deviceId) async {
    try {
      // CORREÇÃO AQUI: Mudamos de '?deviceId=' para '?device_id='
      final uri = Uri.parse("$_telemetryUrl?device_id=$deviceId");
      
      debugPrint("Tentando buscar dados em: $uri"); // Log para conferência

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        
        // A API retorna { "data": [ ... ], "count": 1, ... }
        // Precisamos entrar na lista 'data' e pegar o primeiro item
        if (root.containsKey('data') && root['data'] is List) {
          final List list = root['data'];
          if (list.isNotEmpty) {
            debugPrint("Dados recebidos com sucesso!");
            return TelemetryModel.fromJson(list.first); 
          } else {
            debugPrint("A lista 'data' veio vazia.");
          }
        }
      } else {
        // Se der erro 400 ou 500, mostramos o corpo da mensagem
        debugPrint("Erro API: ${response.statusCode} - ${response.body}");
      }
      return null;
    } catch (e) {
      debugPrint("Erro AWS Service: $e");
      return null;
    }
  }

  // --- ENVIAR COMANDO (POST) ---
  Future<bool> sendCommand(String deviceId, String command, int duration) async {
    try {
      // Aqui também vamos garantir que estamos usando snake_case se a API exigir
      final response = await http.post(
        Uri.parse(_commandUrl),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "device_id": deviceId, // Garantindo snake_case aqui também
          "command": command,    // ex: "OPEN_VALVE"
          "duration": duration
        }),
      );
      
      debugPrint("Status envio comando: ${response.statusCode}");
      return response.statusCode == 200;
    } catch (e) {
      debugPrint("Erro ao enviar comando: $e");
      return false;
    }
  }
}