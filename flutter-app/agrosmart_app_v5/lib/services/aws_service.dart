import 'dart:convert';
import 'package:flutter/foundation.dart'; // Para debugPrint e logs
import 'package:http/http.dart' as http; // Para requisições web
import '../models/telemetry_model.dart';

/// Serviço responsável por toda a comunicação com a API Gateway da AWS
class AwsService {
  // URLs da API AWS (Endpoints)
  final String _telemetryUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/telemetry";
  final String _commandUrl = "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/command";

  /// --- BUSCAR DADOS (GET) ---
  /// Recupera a última leitura dos sensores para um dispositivo específico
  Future<TelemetryModel?> getLatestTelemetry(String deviceId) async {
    try {
      // Monta a URL com Query Parameter: ?device_id=ESP32-XXX
      final uri = Uri.parse("$_telemetryUrl?device_id=$deviceId");
      
      // debugPrint("Tentando buscar dados em: $uri"); 

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        // Decodifica o JSON recebido
        final Map<String, dynamic> root = json.decode(response.body);
        
        // A API retorna { "data": [ ... ], ... }
        // Verificamos se existe a lista 'data' e se não está vazia
        if (root.containsKey('data') && root['data'] is List) {
          final List list = root['data'];
          if (list.isNotEmpty) {
            // Sucesso: Converte o primeiro item da lista para nosso Modelo
            return TelemetryModel.fromJson(list.first); 
          }
        }
      } else {
        debugPrint("Erro API Telemetria: ${response.statusCode} - ${response.body}");
      }
      return null;
    } catch (e) {
      debugPrint("Erro AWS Service (GET): $e");
      return null;
    }
  }

  /// --- ENVIAR COMANDO (POST) ---
  /// Envia ordem para ligar a válvula (Estrutura corrigida conforme Postman)
  Future<bool> sendCommand(String deviceId, String action, int duration) async {
    try {
      final uri = Uri.parse(_commandUrl);
      
      // Montagem do corpo da requisição (Body)
      // CORREÇÃO: Chaves ajustadas para "action" e "duration"
      final body = json.encode({
        "device_id": deviceId, // Identifica qual ESP32 deve ligar
        "action": action,      // Ex: "on" (Conforme seu Postman)
        "duration": duration   // Ex: 10 ou 300 (segundos)
      });

      debugPrint("Enviando comando para: $uri");
      debugPrint("Body enviado: $body");

      final response = await http.post(
        uri,
        headers: {
          "Content-Type": "application/json", // Informa que estamos enviando JSON
        },
        body: body,
      );
      
      debugPrint("Resposta do Comando: ${response.statusCode} - ${response.body}");
      
      // Consideramos sucesso se o código for 200 (OK)
      return response.statusCode == 200;

    } catch (e) {
      debugPrint("Erro ao enviar comando (POST): $e");
      return false;
    }
  }
}