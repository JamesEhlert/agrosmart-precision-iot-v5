// ARQUIVO: lib/services/schedules_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // Para debugPrint
import '../models/schedule_model.dart';

class SchedulesService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // CORREÇÃO: Nome da constante em camelCase
  static const int maxSchedules = 100;

  /// Retorna a lista de agendamentos em tempo real
  Stream<List<ScheduleModel>> getSchedules(String deviceId) {
    return _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('schedules')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return ScheduleModel.fromMap(doc.data(), doc.id);
      }).toList();
    });
  }

  /// Cria um novo agendamento
  Future<void> addSchedule(String deviceId, ScheduleModel schedule) async {
    final collectionRef = _firestore.collection('devices').doc(deviceId).collection('schedules');

    // Verifica limite
    final countQuery = await collectionRef.count().get();
    if ((countQuery.count ?? 0) >= maxSchedules) {
      throw Exception("Limite de $maxSchedules agendamentos atingido.");
    }

    await collectionRef.add(schedule.toMap());
  }

  /// Atualiza um agendamento existente
  Future<void> updateSchedule(String deviceId, ScheduleModel schedule) async {
    if (schedule.id.isEmpty) throw Exception("ID inválido para atualização");

    await _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('schedules')
        .doc(schedule.id)
        .update(schedule.toMap());
  }

  /// Deleta um agendamento
  Future<void> deleteSchedule(String deviceId, String scheduleId) async {
    await _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('schedules')
        .doc(scheduleId)
        .delete();
  }

  /// Alterna o status Ativo/Inativo
  Future<void> toggleEnabled(String deviceId, String scheduleId, bool newValue) async {
    try {
      debugPrint("Alterando status do agendamento $scheduleId para $newValue");
      await _firestore
          .collection('devices')
          .doc(deviceId)
          .collection('schedules')
          .doc(scheduleId)
          .update({'enabled': newValue});
    } catch (e) {
      debugPrint("Erro ao alterar status: $e");
      rethrow; // CORREÇÃO: Usa rethrow para manter a pilha de erros original
    }
  }
}