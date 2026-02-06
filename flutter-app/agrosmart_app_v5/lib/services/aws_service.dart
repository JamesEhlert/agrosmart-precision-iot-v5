// ARQUIVO: lib/services/aws_service.dart
//
// Responsável por chamar a API Gateway (telemetry + command) adicionando:
// - Authorization: Bearer <Firebase ID Token>
// - retry automático em 401 (força refresh do token e tenta 1x de novo)
// - Exceptions tipadas (401/403/erros gerais) para a UI tratar

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

import '../models/telemetry_model.dart';

class HistoryResponse {
  final List<TelemetryModel> items;
  final String? nextToken;
  HistoryResponse({required this.items, this.nextToken});
}

/// Erro genérico da API (HTTP != 200)
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final String? body;

  ApiException(this.statusCode, this.message, {this.body});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// 401 - usuário sem sessão/token inválido/expirado
class UnauthorizedException extends ApiException {
  UnauthorizedException(String message, {String? body})
      : super(401, message, body: body);
}

/// 403 - token ok, mas sem permissão (IAM/Authorizer/Policy)
class ForbiddenException extends ApiException {
  ForbiddenException(String message, {String? body})
      : super(403, message, body: body);
}

class AwsService {
  // URLs da sua API Gateway
  final String _telemetryUrl =
      "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/telemetry";
  final String _commandUrl =
      "https://r6rky7wzx6.execute-api.us-east-2.amazonaws.com/prod/command";

  // ----------------------------
  // Helpers: token + headers
  // ----------------------------
  Future<String> _getFirebaseIdToken({bool forceRefresh = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw UnauthorizedException("Usuário não autenticado.");
    }

    final String? token = await user.getIdToken(forceRefresh);

    if (token == null || token.isEmpty) {
      throw UnauthorizedException("Não foi possível obter token de autenticação.");
    }

    return token;
  }

  Future<Map<String, String>> _buildHeaders({bool forceRefresh = false}) async {
    final token = await _getFirebaseIdToken(forceRefresh: forceRefresh);

    // Log seguro: mostra só os últimos 6 chars do token
    debugPrint(
      "[AUTH] Authorization header set (Bearer ****${token.substring(token.length - 6)})",
    );

    return <String, String>{
      "Content-Type": "application/json",
      "Authorization": "Bearer $token",
    };
  }

  /// Faz request e, se vier 401, força refresh do token e tenta mais 1 vez.
  Future<http.Response> _sendWithAuthRetry(
    Future<http.Response> Function(Map<String, String> headers) send,
  ) async {
    // Tentativa 1
    Map<String, String> headers = await _buildHeaders(forceRefresh: false);
    http.Response res = await send(headers);

    // Se 401, faz refresh e tenta novamente 1x
    if (res.statusCode == 401) {
      debugPrint("[AWS] 401 recebido. Forçando refresh do token e tentando novamente...");
      headers = await _buildHeaders(forceRefresh: true);
      res = await send(headers);
    }

    return res;
  }

  Never _throwForStatus(http.Response res, {String? defaultMessage}) {
    final code = res.statusCode;
    final body = res.body;

    // Tenta pegar uma mensagem amigável do JSON: {"message":"..."}
    String msg = defaultMessage ?? "Falha na API";
    try {
      final decoded = json.decode(body);
      if (decoded is Map && decoded["message"] is String) {
        msg = decoded["message"] as String;
      }
    } catch (_) {
      // ignora - body pode não ser JSON
    }

    if (code == 401) throw UnauthorizedException(msg, body: body);
    if (code == 403) throw ForbiddenException(msg, body: body);
    throw ApiException(code, msg, body: body);
  }

  // ===========================================================================
  // TELEMETRY
  // ===========================================================================

  /// Busca apenas o último dado (para o Dashboard)
  Future<TelemetryModel?> getLatestTelemetry(String deviceId) async {
    final uri = Uri.parse("$_telemetryUrl?device_id=$deviceId&limit=1");

    try {
      final res =
          await _sendWithAuthRetry((headers) => http.get(uri, headers: headers));

      if (res.statusCode != 200) {
        _throwForStatus(res, defaultMessage: "Falha ao buscar telemetria.");
      }

      final Map<String, dynamic> root = json.decode(res.body);
      if (root.containsKey('data') && root['data'] is List) {
        final List list = root['data'];
        if (list.isNotEmpty) {
          return TelemetryModel.fromJson(list.first);
        }
      }
      return null;
    } catch (e) {
      debugPrint("Erro GET Latest: $e");
      rethrow;
    }
  }

  /// Busca histórico com paginação e filtro de data
  Future<HistoryResponse> getTelemetryHistory(
    String deviceId, {
    String? nextToken,
    int limit = 50,
    DateTime? start,
    DateTime? end,
  }) async {
    try {
      String url = "$_telemetryUrl?device_id=$deviceId&limit=$limit";

      if (nextToken != null) {
        url += "&next_token=${Uri.encodeComponent(nextToken)}";
      }

      // Filtros de data (timestamps em segundos)
      if (start != null && end != null) {
        final startTs = (start.millisecondsSinceEpoch / 1000).floor();
        final endTs = (end.millisecondsSinceEpoch / 1000).floor();
        url += "&start_time=$startTs&end_time=$endTs";
      }

      final uri = Uri.parse(url);
      debugPrint("Buscando histórico: $uri");

      final res =
          await _sendWithAuthRetry((headers) => http.get(uri, headers: headers));

      if (res.statusCode != 200) {
        _throwForStatus(res, defaultMessage: "Falha ao buscar histórico.");
      }

      final Map<String, dynamic> root = json.decode(res.body);

      List<TelemetryModel> items = [];
      String? newNextToken;

      if (root.containsKey('data') && root['data'] is List) {
        items = (root['data'] as List)
            .map((item) => TelemetryModel.fromJson(item))
            .toList();
      }

      if (root.containsKey('next_token')) {
        newNextToken = root['next_token'];
      }

      return HistoryResponse(items: items, nextToken: newNextToken);
    } catch (e) {
      debugPrint("Erro History: $e");
      rethrow;
    }
  }

  // ===========================================================================
  // COMMAND
  // ===========================================================================

  /// Envia comando para a válvula (device_id + action + duration)
  ///
  /// Retorna `true` se a API respondeu 200.
  /// Para erros:
  /// - 401 -> lança UnauthorizedException
  /// - 403 -> lança ForbiddenException
  /// - outros -> lança ApiException
  Future<bool> sendCommand(String deviceId, String action, int duration) async {
    final uri = Uri.parse(_commandUrl);

    final body = json.encode({
      "device_id": deviceId,
      "action": action,
      "duration": duration,
    });

    debugPrint("Enviando comando para $deviceId: $body");

    try {
      final res = await _sendWithAuthRetry(
        (headers) => http.post(uri, headers: headers, body: body),
      );

      if (res.statusCode == 200) {
        debugPrint("Comando enviado com sucesso!");
        return true;
      }

      _throwForStatus(res, defaultMessage: "Falha ao enviar comando.");
    } catch (e) {
      debugPrint("Exceção no envio de comando: $e");
      rethrow;
    }

    return false; // unreachable
  }
}
