// ARQUIVO: lib/services/aws_service.dart
//
// Responsável por chamar a API Gateway (telemetry + command) adicionando:
// - Authorization: Bearer <Firebase ID Token>
// - retry automático em 401 (força refresh do token e tenta 1x de novo)
// - Exceptions tipadas (401/403/erros gerais) para a UI tratar

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

// Importa a configuração de ambiente que criamos
import '../core/config/app_config.dart'; 
import '../models/telemetry_model.dart';

class HistoryResponse {
  final List<TelemetryModel> items;
  final String? nextToken;
  HistoryResponse({required this.items, this.nextToken});
}

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

class AckEvent {
  final String commandId;
  final String status;
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

class ApiException implements Exception {
  final int statusCode;
  final String message;
  final String? body;

  ApiException(this.statusCode, this.message, {this.body});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class UnauthorizedException extends ApiException {
  UnauthorizedException(String message, {String? body})
      : super(401, message, body: body);
}

class ForbiddenException extends ApiException {
  ForbiddenException(String message, {String? body})
      : super(403, message, body: body);
}

class AwsService {
  // Agora as URLs vêm dinamicamente do AppConfig
  final String _telemetryUrl = AppConfig.telemetryEndpoint;
  final String _commandUrl = AppConfig.commandEndpoint;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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

    final suffix = token.length > 6 ? token.substring(token.length - 6) : token;
    debugPrint("[AUTH] Authorization header set (Bearer ****$suffix)");

    return <String, String>{
      "Content-Type": "application/json",
      "Authorization": "Bearer $token",
    };
  }

  Future<http.Response> _sendWithAuthRetry(
    Future<http.Response> Function(Map<String, String> headers) send,
  ) async {
    Map<String, String> headers = await _buildHeaders(forceRefresh: false);
    http.Response res = await send(headers);

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

    String msg = defaultMessage ?? "Falha na API";
    try {
      final decoded = json.decode(body);
      if (decoded is Map && decoded["message"] is String) {
        msg = decoded["message"] as String;
      }
    } catch (_) {}

    if (code == 401) throw UnauthorizedException(msg, body: body);
    if (code == 403) throw ForbiddenException(msg, body: body);
    throw ApiException(code, msg, body: body);
  }

  Future<TelemetryModel?> getLatestTelemetry(String deviceId) async {
    // Validação de segurança para garantir que a URL base foi injetada corretamente
    if (_telemetryUrl.isEmpty || _telemetryUrl == '/telemetry') {
      throw Exception("URL da API não configurada. Verifique o --dart-define.");
    }

    final uri = Uri.parse("$_telemetryUrl?device_id=$deviceId&limit=1");

    try {
      final res = await _sendWithAuthRetry((headers) => http.get(uri, headers: headers));

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

      if (start != null && end != null) {
        final startTs = (start.millisecondsSinceEpoch / 1000).floor();
        final endTs = (end.millisecondsSinceEpoch / 1000).floor();
        url += "&start_time=$startTs&end_time=$endTs";
      }

      final uri = Uri.parse(url);
      debugPrint("Buscando histórico: $uri");

      final res = await _sendWithAuthRetry((headers) => http.get(uri, headers: headers));

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

  String _generateCommandId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final r = Random().nextInt(1 << 20);
    return "app-$ms-$r";
  }

  Future<bool> sendCommand(String deviceId, String action, int duration) async {
    final result = await sendCommandWithAck(
      deviceId: deviceId,
      action: action,
      duration: duration,
      commandId: null, 
    );
    return result.ok;
  }

  Future<SendCommandResult> sendCommandWithAck({
    required String deviceId,
    required String action,
    required int duration,
    String? commandId,
  }) async {
    // Validação de segurança
    if (_commandUrl.isEmpty || _commandUrl == '/command') {
      throw Exception("URL da API não configurada. Verifique o --dart-define.");
    }

    final uri = Uri.parse(_commandUrl);

    final generated = commandId == null || commandId.isEmpty;
    final cmdId = generated ? _generateCommandId() : commandId;

    final bodyMap = <String, dynamic>{
      "device_id": deviceId,
      "action": action,
      "duration": duration,
      "command_id": cmdId, 
    };

    final body = json.encode(bodyMap);

    debugPrint("Enviando comando para $deviceId: $body");

    try {
      final res = await _sendWithAuthRetry(
        (headers) => http.post(uri, headers: headers, body: body),
      );

      if (res.statusCode == 200) {
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
        } catch (_) {}

        debugPrint("Comando enviado OK. command_id=$finalCmdId (generated=$generated)");
        return SendCommandResult(ok: true, commandId: finalCmdId, message: message);
      }

      _throwForStatus(res, defaultMessage: "Falha ao enviar comando.");
    } catch (e) {
      debugPrint("Exceção no envio de comando: $e");
      rethrow;
    }
  }

  String _normalizeStatus(dynamic raw) {
    if (raw == null) return "unknown";
    final s = raw.toString().trim().toLowerCase();
    // AJUSTE: Adicionado o "failed" na lista de permitidos
    if (s == "received" || s == "started" || s == "done" || s == "failed" || s == "error") {
      return s;
    }
    return s.isEmpty ? "unknown" : s;
  }

  DateTime _parseTimestamp(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

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
        // AJUSTE: Parar de escutar se o status for failed, error ou done
        if (st == 'done' || st == 'failed' || st == 'error') {
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

      events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return events;
    });
  }

  Stream<List<AckEvent>> watchAckForCommand({
    required String deviceId,
    required String commandId,
    int limit = 20,
  }) {
    return watchAckHistoryForCommand(deviceId: deviceId, commandId: commandId, limit: limit);
  }

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
        // AJUSTE: Parar de escutar se o status for failed, error ou done
        if (st == 'done' || st == 'failed' || st == 'error') {
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