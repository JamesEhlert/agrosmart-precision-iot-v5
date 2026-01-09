// ARQUIVO: lib/services/history_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/activity_log_model.dart';

class HistoryService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Busca os logs de um dispositivo com paginação
  Future<List<ActivityLogModel>> getActivityLogs(String deviceId, {DocumentSnapshot? lastDocument, int limit = 20}) async {
    Query query = _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('history') // A tal coleção nova
        .orderBy('timestamp', descending: true) // Mais recentes primeiro
        .limit(limit);

    // Se tiver um último documento, começa depois dele (Paginação)
    if (lastDocument != null) {
      query = query.startAfterDocument(lastDocument);
    }

    final snapshot = await query.get();

    return snapshot.docs.map((doc) {
      return ActivityLogModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    }).toList();
  }
  
  // Retorna o último documento da lista (útil para o controle de paginação na tela)
  Future<DocumentSnapshot?> getLastDocument(String deviceId) async {
     // Lógica simplificada: a tela vai controlar o snapshot, aqui é só apoio se precisar
     return null; 
  }
}