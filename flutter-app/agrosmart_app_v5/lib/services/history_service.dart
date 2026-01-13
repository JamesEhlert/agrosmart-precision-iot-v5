// ARQUIVO: lib/services/history_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/activity_log_model.dart';

// Classe auxiliar para retornar os dados + o ponteiro da paginação
class ActivityLogsResponse {
  final List<ActivityLogModel> logs;
  final DocumentSnapshot? lastDoc; // O "marcador" de onde paramos

  ActivityLogsResponse(this.logs, this.lastDoc);
}

class HistoryService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Busca os logs com suporte a paginação
  Future<ActivityLogsResponse> getActivityLogs(String deviceId, {DocumentSnapshot? lastDocument, int limit = 20}) async {
    Query query = _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('history')
        .orderBy('timestamp', descending: true) // Mais recentes primeiro
        .limit(limit);

    // Se tivermos um ponto de partida, continuamos dele
    if (lastDocument != null) {
      query = query.startAfterDocument(lastDocument);
    }

    final snapshot = await query.get();

    // Converte os documentos para nosso Modelo
    final logs = snapshot.docs.map((doc) {
      return ActivityLogModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    }).toList();

    // Pega o último documento para usar como ponteiro na próxima chamada
    final lastDoc = snapshot.docs.isNotEmpty ? snapshot.docs.last : null;

    return ActivityLogsResponse(logs, lastDoc);
  }
}