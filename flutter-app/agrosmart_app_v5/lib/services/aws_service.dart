// ARQUIVO: lib/services/aws_service.dart

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/telemetry_model.dart';

class HistoryResponse {
  final List<TelemetryModel> items;
  final String? nextToken;
  HistoryResponse({required this.items, this.nextToken});
}

class AwsService {
  // URLs da sua API Gateway (Mantenha as suas se forem diferentes destas)
  final String _telemetryUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/telemetry";
  final String _commandUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/command";

  // --- Busca apenas o último dado (Para o Dashboard) ---
  Future<TelemetryModel?> getLatestTelemetry(String deviceId) async {
    try {
      final uri = Uri.parse("$_telemetryUrl?device_id=$deviceId&limit=1");
      final response = await http.get(uri);
      
      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        if (root.containsKey('data') && root['data'] is List) {
          final List list = root['data'];
          if (list.isNotEmpty) return TelemetryModel.fromJson(list.first);
        }
      }
      return null;
    } catch (e) {
      debugPrint("Erro GET Latest: $e");
      return null;
    }
  }

  // --- Busca Histórico com Paginação e Filtro de Data ---
  Future<HistoryResponse> getTelemetryHistory(String deviceId, {
    String? nextToken, 
    int limit = 50,
    DateTime? start,
    DateTime? end
  }) async {
    try {
      String url = "$_telemetryUrl?device_id=$deviceId&limit=$limit";

      if (nextToken != null) {
        url += "&next_token=${Uri.encodeComponent(nextToken)}";
      }

      // Adiciona filtros de data se fornecidos
      if (start != null && end != null) {
        final startTs = (start.millisecondsSinceEpoch / 1000).floor();
        final endTs = (end.millisecondsSinceEpoch / 1000).floor();
        url += "&start_time=$startTs&end_time=$endTs";
      }

      final uri = Uri.parse(url);
      debugPrint("Buscando histórico: $uri");

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        List<TelemetryModel> items = [];
        String? newNextToken;

        if (root.containsKey('data') && root['data'] is List) {
          items = (root['data'] as List).map((item) => TelemetryModel.fromJson(item)).toList();
        }
        if (root.containsKey('next_token')) {
          newNextToken = root['next_token'];
        }

        return HistoryResponse(items: items, nextToken: newNextToken);
      } else {
        throw Exception("Falha API: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Erro History: $e");
      return HistoryResponse(items: [], nextToken: null);
    }
  }

  // --- Envia Comando para a Válvula ---
  Future<bool> sendCommand(String deviceId, String action, int duration) async {
    try {
      final uri = Uri.parse(_commandUrl);
      
      // AQUI ESTÁ O SEGREDO: Enviamos 'device_id' junto com a ação.
      // A Lambda vai ler isso e repassar para o MQTT.
      final body = json.encode({
        "device_id": deviceId, 
        "action": action, 
        "duration": duration
      });
      
      debugPrint("Enviando comando para $deviceId: $body");

      final response = await http.post(
        uri, 
        headers: {"Content-Type": "application/json"}, 
        body: body
      );

      if (response.statusCode == 200) {
        debugPrint("Comando enviado com sucesso!");
        return true;
      } else {
        debugPrint("Erro ao enviar comando: ${response.statusCode} - ${response.body}");
        return false;
      }
    } catch (e) {
      debugPrint("Exceção no envio de comando: $e");
      return false;
    }
  }
}