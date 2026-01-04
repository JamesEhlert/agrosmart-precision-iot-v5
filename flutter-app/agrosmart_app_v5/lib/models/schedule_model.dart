/// Modelo de dados para um Agendamento de Irrigação
class ScheduleModel {
  final String id;              // ID do documento no Firestore
  final String label;           // Nome (ex: "Rega Manhã")
  final String time;            // Horário (Format: "HH:mm")
  final List<int> days;         // Dias da semana (1=Segunda, ..., 7=Domingo)
  final int durationMinutes;    // Duração em minutos
  final bool isEnabled;         // Se está ativo ou pausado

  ScheduleModel({
    required this.id,
    required this.label,
    required this.time,
    required this.days,
    required this.durationMinutes,
    required this.isEnabled,
  });

  // Converte do formato Firestore (Map) para o Objeto Dart
  factory ScheduleModel.fromMap(Map<String, dynamic> map, String docId) {
    return ScheduleModel(
      id: docId,
      label: map['label'] ?? 'Sem Nome',
      time: map['time'] ?? '00:00',
      // Converte a lista dinâmica do Firebase para lista de inteiros
      days: List<int>.from(map['days'] ?? []),
      durationMinutes: map['duration_minutes'] ?? 5,
      isEnabled: map['enabled'] ?? true,
    );
  }

  // Converte do Objeto Dart para o formato Firestore (para salvar)
  Map<String, dynamic> toMap() {
    return {
      'label': label,
      'time': time,
      'days': days,
      'duration_minutes': durationMinutes,
      'enabled': isEnabled,
    };
  }
}