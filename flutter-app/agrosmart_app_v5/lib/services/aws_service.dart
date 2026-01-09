// ARQUIVO: lib/services/aws_service.dart

import 'dart:convert';
import 'package:flutter/foundation.dart'; // Para debugPrint e logs
import 'package:http/http.dart' as http; // Para requisições web
import '../models/telemetry_model.dart';

/// Classe de resposta auxiliar para a paginação
class HistoryResponse {
  final List<TelemetryModel> items;
  final String? nextToken;

  HistoryResponse({required this.items, this.nextToken});
}

/// Serviço responsável por toda a comunicação com a API Gateway da AWS
class AwsService {
  // URLs da API AWS (Endpoints)
  final String _telemetryUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/telemetry";
  final String _commandUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/command";

  /// --- BUSCAR DADOS ATUAIS (GET) ---
  /// Recupera a última leitura dos sensores para o Dashboard
  Future<TelemetryModel?> getLatestTelemetry(String deviceId) async {
    try {
      // Monta a URL com Query Parameter: ?device_id=ESP32-XXX&limit=1 (só queremos o último)
      final uri = Uri.parse("$_telemetryUrl?device_id=$deviceId&limit=1");

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);

        if (root.containsKey('data') && root['data'] is List) {
          final List list = root['data'];
          if (list.isNotEmpty) {
            return TelemetryModel.fromJson(list.first);
          }
        }
      } else {
        debugPrint("Erro API Telemetria: ${response.statusCode} - ${response.body}");
      }
      return null;
    } catch (e) {
      debugPrint("Erro AWS Service (GET Latest): $e");
      return null;
    }
  }

  /// --- NOVO: BUSCAR HISTÓRICO PAGINADO (GET) ---
  /// Busca uma lista de registros (ex: 50 itens).
  /// Se [nextToken] for enviado, busca a próxima página.
  Future<HistoryResponse> getTelemetryHistory(String deviceId, {String? nextToken, int limit = 50}) async {
    try {
      // Monta a URL base
      String url = "$_telemetryUrl?device_id=$deviceId&limit=$limit";

      // Se tiver token de paginação, adiciona na URL (codificado para evitar erros com símbolos como '=')
      if (nextToken != null && nextToken.isNotEmpty) {
        url += "&next_token=${Uri.encodeComponent(nextToken)}";
      }

      final uri = Uri.parse(url);
      debugPrint("Buscando histórico: $uri");

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> root = json.decode(response.body);
        
        List<TelemetryModel> items = [];
        String? newNextToken;

        // 1. Processa a lista de dados
        if (root.containsKey('data') && root['data'] is List) {
          items = (root['data'] as List)
              .map((item) => TelemetryModel.fromJson(item))
              .toList();
        }

        // 2. Verifica se tem token para a próxima página
        if (root.containsKey('next_token') && root['next_token'] != null) {
          newNextToken = root['next_token'];
        }

        return HistoryResponse(items: items, nextToken: newNextToken);
      } else {
        debugPrint("Erro ao buscar histórico: ${response.statusCode}");
        throw Exception("Falha na API: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Erro AWS Service (History): $e");
      // Em caso de erro, retorna lista vazia para não quebrar o app
      return HistoryResponse(items: [], nextToken: null);
    }
  }

  /// --- ENVIAR COMANDO (POST) ---
  /// Envia ordem para ligar a válvula
  Future<bool> sendCommand(String deviceId, String action, int duration) async {
    try {
      final uri = Uri.parse(_commandUrl);

      final body = json.encode({
        "device_id": deviceId,
        "action": action,      
        "duration": duration   
      });

      debugPrint("Enviando comando: $body");

      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: body,
      );

      return response.statusCode == 200;

    } catch (e) {
      debugPrint("Erro ao enviar comando (POST): $e");
      return false;
    }
  }
}