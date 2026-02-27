// ARQUIVO: lib/models/activity_log_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class ActivityLogModel {
  final String id;
  final DateTime timestamp;
  final String type;    
  final String source;  
  final String message; 
  
  final String? result; 
  final String? reason;
  final Map<String, dynamic>? details;
  
  // NOVO CAMPO: Para pegarmos a assinatura do comando
  final String? commandId;

  ActivityLogModel({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.source,
    required this.message,
    this.result,
    this.reason,
    this.details,
    this.commandId,
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
      commandId: data['command_id'], // Lendo o ID que vem do Firestore
    );
  }

  // --- REGRAS INTELIGENTES ---
  
  // É um agendamento se a fonte for 'schedule' OU se for um comando cujo ID começa com 'sched-'
  bool get isFromSchedule {
    if (source == 'schedule') return true;
    if (source == 'command' && commandId != null && commandId!.startsWith('sched-')) return true;
    return false;
  }

  // É um comando manual se a fonte for 'command' e NÃO for de um agendamento
  bool get isManualCommand {
    if (source == 'command' && !isFromSchedule) return true;
    return false;
  }
}