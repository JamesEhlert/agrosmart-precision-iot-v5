// ARQUIVO: lib/models/activity_log_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class ActivityLogModel {
  final String id;
  final DateTime timestamp;
  final String type;    // 'execution', 'skipped', 'error'
  final String source;  // 'schedule', 'manual', 'system'
  final String message; // Ex: "Umidade 85% > Alvo 60%"

  ActivityLogModel({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.source,
    required this.message,
  });

  factory ActivityLogModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return ActivityLogModel(
      id: docId,
      // Converte o Timestamp do Firestore para DateTime do Dart
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      type: data['type'] ?? 'info',
      source: data['source'] ?? 'system',
      message: data['message'] ?? 'Sem detalhes',
    );
  }
}