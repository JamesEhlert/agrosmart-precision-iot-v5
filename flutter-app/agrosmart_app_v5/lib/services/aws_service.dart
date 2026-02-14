// ARQUIVO: lib/services/aws_service.dart
//
// Responsável por chamar a API Gateway (telemetry + command) adicionando:
// - Authorization: Bearer <Firebase ID Token>
// - retry automático em 401 (força refresh do token e tenta 1x de novo)
// - Exceptions tipadas (401/403/erros gerais) para a UI tratar
//
// Ajustes para "ACK ponta-a-ponta":
// - Mantém sendCommand(...) retornando bool (compatibilidade com UI atual)
// - Adiciona sendCommandWithAck(...) que retorna commandId (para correlacionar com ACK no Firestore)
// - Adiciona watchCommandStateForAck(...) (RECOMENDADO) para acompanhar ACK por command_id (doc único)
// - Mantém watchAckHistoryForCommand(...) para timeline (history) e debug

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

import '../models/telemetry_model.dart';

class HistoryResponse {
  final List<TelemetryModel> items;
  final String? nextToken;
  HistoryResponse({required this.items, this.nextToken});
}

/// Resultado do envio de comando com commandId (para E2E ACK).
class SendCommandResult {
  final bool ok;
  final String commandId;
  final String message;

  SendCommandResult({
    required this.ok,
    required this.commandId,
    required this.message,
  });

  @override
  String toString() => 'SendCommandResult(ok=$ok, commandId=$commandId, message=$message)';
}

/// Snapshot simples de ACK (normalizado do Firestore).
class AckEvent {
  final String commandId;
  final String status; // received|started|done|error|unknown
  final String? action;
  final int? duration;
  final String? reason;
  final String? error;
  final DateTime timestamp;

  AckEvent({
    required this.commandId,
    required this.status,
    required this.timestamp,
    this.action,
    this.duration,
    this.reason,
    this.error,
  });

  @override
  String toString() => 'AckEvent(cmd=$commandId, status=$status, ts=$timestamp)';
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

  // Firestore (para acompanhar ACK)
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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

    // Log seguro: mostra só os últimos chars do token (evita crash se token < 6)
    final suffix = token.length > 6 ? token.substring(token.length - 6) : token;
    debugPrint("[AUTH] Authorization header set (Bearer ****$suffix)");

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
  // COMMAND (compat + E2E ACK)
  // ===========================================================================

  /// Gera um command_id no app (caso a API não gere ou para correlacionar com ACK).
  String _generateCommandId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final r = Random().nextInt(1 << 20);
    return "app-$ms-$r";
  }

  /// Envia comando para a válvula (device_id + action + duration)
  ///
  /// Compatibilidade com a UI atual: retorna bool.
  /// Para E2E ACK, use sendCommandWithAck(...) abaixo.
  Future<bool> sendCommand(String deviceId, String action, int duration) async {
    final result = await sendCommandWithAck(
      deviceId: deviceId,
      action: action,
      duration: duration,
      commandId: null, // gera automaticamente
    );
    return result.ok;
  }

  /// Versão "profissional": envia comando e retorna commandId para acompanhar ACK ponta-a-ponta.
  ///
  /// - Se commandId for null, gera um commandId no app.
  /// - Envia esse commandId para a API Gateway.
  /// - Tenta ler um command_id retornado pela API (se existir), mas mantém o do app como fallback.
  Future<SendCommandResult> sendCommandWithAck({
    required String deviceId,
    required String action,
    required int duration,
    String? commandId,
  }) async {
    final uri = Uri.parse(_commandUrl);

    final generated = commandId == null || commandId.isEmpty;
    final cmdId = generated ? _generateCommandId() : commandId;

    final bodyMap = <String, dynamic>{
      "device_id": deviceId,
      "action": action,
      "duration": duration,
      "command_id": cmdId, // <<< IMPORTANTE PARA E2E ACK
    };

    final body = json.encode(bodyMap);

    debugPrint("Enviando comando para $deviceId: $body");

    try {
      final res = await _sendWithAuthRetry(
        (headers) => http.post(uri, headers: headers, body: body),
      );

      if (res.statusCode == 200) {
        // Se a API devolver JSON com command_id, ótimo; se não, usamos cmdId
        String finalCmdId = cmdId;
        String message = "Comando enviado com sucesso.";

        try {
          final decoded = json.decode(res.body);
          if (decoded is Map) {
            if (decoded["command_id"] is String &&
                (decoded["command_id"] as String).isNotEmpty) {
              finalCmdId = decoded["command_id"] as String;
            }
            if (decoded["message"] is String &&
                (decoded["message"] as String).isNotEmpty) {
              message = decoded["message"] as String;
            }
          }
        } catch (_) {
          // body pode não ser JSON
        }

        debugPrint("Comando enviado OK. command_id=$finalCmdId (generated=$generated)");
        return SendCommandResult(ok: true, commandId: finalCmdId, message: message);
      }

      _throwForStatus(res, defaultMessage: "Falha ao enviar comando.");
    } catch (e) {
      debugPrint("Exceção no envio de comando: $e");
      rethrow;
    }
  }

  // ===========================================================================
  // ACK (Firestore) — acompanhar por command_id
  // ===========================================================================

  String _normalizeStatus(dynamic raw) {
    if (raw == null) return "unknown";
    final s = raw.toString().trim().toLowerCase();
    if (s == "received" || s == "started" || s == "done" || s == "error") {
      return s;
    }
    return s.isEmpty ? "unknown" : s;
  }

  DateTime _parseTimestamp(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// ✅ RECOMENDADO (E2E):
  /// Escuta o documento de estado do comando:
  ///   devices/{deviceId}/commands/{commandId}
  ///
  /// Espera campos criados pela Lambda:
  /// - last_status
  /// - last_status_at (Timestamp)
  /// - action, duration, reason, error (opcionais)
  Stream<AckEvent?> watchCommandStateForAck({
    required String deviceId,
    required String commandId,
  }) {
    final docRef = _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('commands')
        .doc(commandId);

    return docRef.snapshots().map((snap) {
      if (!snap.exists) return null;

      final data = snap.data();
      if (data == null) return null;

      final status = _normalizeStatus(data['last_status']);
      final action = data['action']?.toString();
      final duration = (data['duration'] is num) ? (data['duration'] as num).toInt() : null;
      final reason = data['reason']?.toString();
      final error = data['error']?.toString();

      final ts = _parseTimestamp(data['last_status_at']);

      return AckEvent(
        commandId: commandId,
        status: status,
        timestamp: ts,
        action: action,
        duration: duration,
        reason: reason,
        error: error,
      );
    });
  }

  /// Aguarda até aparecer um ACK final ("done" ou "error") no doc commands/`commandId`.
  Future<AckEvent?> waitForFinalAckFromCommandState({
    required String deviceId,
    required String commandId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final completer = Completer<AckEvent?>();
    StreamSubscription<AckEvent?>? sub;

    Timer? timer;
    timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
      sub?.cancel();
    });

    sub = watchCommandStateForAck(deviceId: deviceId, commandId: commandId).listen(
      (event) {
        if (event == null) return;
        final st = event.status.toLowerCase();
        if (st == 'done' || st == 'error') {
          if (!completer.isCompleted) completer.complete(event);
          timer?.cancel();
          sub?.cancel();
        }
      },
      onError: (err) {
        if (!completer.isCompleted) completer.completeError(err);
        timer?.cancel();
        sub?.cancel();
      },
    );

    return completer.future;
  }

  /// (Timeline/Debug)
  /// Stream que emite eventos de ACK no history para um command_id.
  ///
  /// Útil para “Eventos”, auditoria e debug.
  /// Para E2E ACK e UX, prefira watchCommandStateForAck().
  Stream<List<AckEvent>> watchAckHistoryForCommand({
    required String deviceId,
    required String commandId,
    int limit = 20,
  }) {
    final col = _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('history');

    final q = col
        .where('command_id', isEqualTo: commandId)
        .limit(limit);

    return q.snapshots().map((snap) {
      final events = <AckEvent>[];
      for (final doc in snap.docs) {
        final data = doc.data();

        final status = _normalizeStatus(data['status']);
        final action = data['action']?.toString();
        final duration = (data['duration'] is num) ? (data['duration'] as num).toInt() : null;
        final reason = data['reason']?.toString();
        final error = data['error']?.toString();

        final ts = _parseTimestamp(data['timestamp']);

        events.add(AckEvent(
          commandId: commandId,
          status: status,
          action: action,
          duration: duration,
          reason: reason,
          error: error,
          timestamp: ts,
        ));
      }

      // Ordena localmente (mais recente primeiro)
      events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return events;
    });
  }

  /// Mantém compatibilidade com seu nome antigo (se alguma tela já usa).
  /// (Opcional: você pode remover depois que migrar tudo)
  Stream<List<AckEvent>> watchAckForCommand({
    required String deviceId,
    required String commandId,
    int limit = 20,
  }) {
    return watchAckHistoryForCommand(deviceId: deviceId, commandId: commandId, limit: limit);
  }

  /// Helper antigo (baseado no history). Mantido por compatibilidade.
  /// Para UX melhor, prefira waitForFinalAckFromCommandState().
  Future<AckEvent?> waitForFinalAck({
    required String deviceId,
    required String commandId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final completer = Completer<AckEvent?>();
    StreamSubscription<List<AckEvent>>? sub;

    Timer? timer;
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      sub?.cancel();
    });

    sub = watchAckHistoryForCommand(deviceId: deviceId, commandId: commandId).listen((events) {
      for (final e in events) {
        final st = e.status.toLowerCase();
        if (st == 'done' || st == 'error') {
          if (!completer.isCompleted) {
            completer.complete(e);
          }
          timer?.cancel();
          sub?.cancel();
          break;
        }
      }
    }, onError: (err) {
      if (!completer.isCompleted) completer.completeError(err);
      timer?.cancel();
      sub?.cancel();
    });

    return completer.future;
  }
}
