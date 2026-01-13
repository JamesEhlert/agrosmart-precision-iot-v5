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
  final String _telemetryUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/telemetry";
  final String _commandUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/command";

  // Busca último dado
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

  // --- ATUALIZADO: Suporte a filtro de data ---
  Future<HistoryResponse> getTelemetryHistory(String deviceId, {
    String? nextToken, 
    int limit = 50,
    DateTime? start, // Novo
    DateTime? end    // Novo
  }) async {
    try {
      String url = "$_telemetryUrl?device_id=$deviceId&limit=$limit";

      if (nextToken != null) {
        url += "&next_token=${Uri.encodeComponent(nextToken)}";
      }

      // Adiciona parâmetros de data se existirem (Converte para Unix Timestamp em segundos)
      if (start != null && end != null) {
        // .floor() garante número inteiro
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

  Future<bool> sendCommand(String deviceId, String action, int duration) async {
    try {
      final uri = Uri.parse(_commandUrl);
      final body = json.encode({"device_id": deviceId, "action": action, "duration": duration});
      final response = await http.post(uri, headers: {"Content-Type": "application/json"}, body: body);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}