import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/schedule_model.dart';

class SchedulesService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Limite máximo de agendamentos por dispositivo (Regra de Negócio)
  static const int MAX_SCHEDULES = 100;

  /// Retorna um fluxo (Stream) com a lista de agendamentos em tempo real
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

  /// Adiciona um novo agendamento (Com verificação de limite)
  Future<void> addSchedule(String deviceId, ScheduleModel schedule) async {
    final collectionRef = _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('schedules');

    // 1. Verifica quantos agendamentos já existem
    final countQuery = await collectionRef.count().get();
    final currentCount = countQuery.count ?? 0;

    if (currentCount >= MAX_SCHEDULES) {
      throw Exception("Limite de agendamentos atingido ($MAX_SCHEDULES). Remova um antigo para criar novo.");
    }

    // 2. Se estiver dentro do limite, cria o novo
    await collectionRef.add(schedule.toMap());
  }

  /// Atualiza um agendamento existente (ex: mudar horário ou ativar/desativar)
  Future<void> updateSchedule(String deviceId, String scheduleId, Map<String, dynamic> data) async {
    await _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('schedules')
        .doc(scheduleId)
        .update(data);
  }

  /// Remove um agendamento
  Future<void> deleteSchedule(String deviceId, String scheduleId) async {
    await _firestore
        .collection('devices')
        .doc(deviceId)
        .collection('schedules')
        .doc(scheduleId)
        .delete();
  }

  /// Alterna entre Ativado/Desativado
  Future<void> toggleEnabled(String deviceId, String scheduleId, bool currentValue) async {
    await updateSchedule(deviceId, scheduleId, {'enabled': !currentValue});
  }
}