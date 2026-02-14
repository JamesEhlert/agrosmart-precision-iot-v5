// ARQUIVO: lib/services/history_service.dart
//
// Responsável por buscar o histórico (events/acks) do Firestore em:
// devices/{deviceId}/history
//
// Este service foi feito para ser COMPATÍVEL com duas abordagens de paginação:
// 1) Dashboard antigo: usa named param `lastDocument` e lê `result.lastDoc`
// 2) Dashboard novo: usa `cursor` e lê `result.nextCursor` / `result.hasMore`
//
// Assim você não fica “quebrando” telas quando muda a estratégia.

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/activity_log_model.dart';

class ActivityLogsResponse {
  final List<ActivityLogModel> logs;

  /// Ponteiro de paginação (forma Firestore nativa)
  final DocumentSnapshot? lastDoc;

  /// Cursor simples (docId do lastDoc), útil se você quiser guardar como String
  final String? nextCursor;

  /// Heurística de “tem mais”: se veio uma página cheia, provavelmente há mais
  final bool hasMore;

  ActivityLogsResponse({
    required this.logs,
    required this.lastDoc,
    required this.nextCursor,
    required this.hasMore,
  });
}

class HistoryService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Busca logs com paginação.
  ///
  /// Use UM destes:
  /// - lastDocument: DocumentSnapshot (modo clássico Firestore)
  /// - cursor: pode ser DocumentSnapshot OU String (docId)
  Future<ActivityLogsResponse> getActivityLogs(
    String deviceId, {
    DocumentSnapshot? lastDocument,
    Object? cursor,
    int limit = 20,
  }) async {
    Query<Map<String, dynamic>> query = _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('history')
        .orderBy('timestamp', descending: true)
        .limit(limit);

    // Resolve o “ponteiro” de paginação (startAfterDocument)
    DocumentSnapshot? startAfterDoc;

    // Prioridade 1: lastDocument (usado no seu dashboard atual)
    if (lastDocument != null) {
      startAfterDoc = lastDocument;
    } else if (cursor != null) {
      // Prioridade 2: cursor (pode ser DocumentSnapshot ou String docId)
      if (cursor is DocumentSnapshot) {
        startAfterDoc = cursor;
      } else if (cursor is String && cursor.isNotEmpty) {
        final snap = await _firestore
            .collection('devices')
            .doc(deviceId)
            .collection('history')
            .doc(cursor)
            .get();

        if (snap.exists) {
          startAfterDoc = snap;
        }
      }
    }

    if (startAfterDoc != null) {
      query = query.startAfterDocument(startAfterDoc);
    }

    final snapshot = await query.get();
    final docs = snapshot.docs;

    final logs = docs.map((doc) {
      return ActivityLogModel.fromFirestore(doc.data(), doc.id);
    }).toList();

    final DocumentSnapshot? lastDoc = docs.isNotEmpty ? docs.last : null;

    return ActivityLogsResponse(
      logs: logs,
      lastDoc: lastDoc,
      nextCursor: lastDoc?.id,
      hasMore: docs.length == limit,
    );
  }
}
