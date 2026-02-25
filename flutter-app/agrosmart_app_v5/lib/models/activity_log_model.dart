// ARQUIVO: lib/models/activity_log_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class ActivityLogModel {
  final String id;
  final DateTime timestamp;
  final String type;    
  final String source;  
  final String message; 
  
  // NOVOS CAMPOS PARA OS DETALHES AVANÇADOS
  final String? result; 
  final String? reason;
  final Map<String, dynamic>? details;

  ActivityLogModel({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.source,
    required this.message,
    this.result,
    this.reason,
    this.details,
  });

  factory ActivityLogModel.fromFirestore(Map<String, dynamic> data, String docId) {
    return ActivityLogModel(
      id: docId,
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      type: data['type'] ?? 'info',
      source: data['source'] ?? 'system',
      message: data['message'] ?? 'Sem detalhes',
      result: data['result'],
      reason: data['reason'],
      details: data['details'] as Map<String, dynamic>?,
    );
  }
}