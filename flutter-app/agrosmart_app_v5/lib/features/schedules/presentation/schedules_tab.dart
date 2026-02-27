// ARQUIVO: lib/features/schedules/presentation/schedules_tab.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 

import '../../../models/device_model.dart';
import '../../../models/schedule_model.dart';
import '../../../services/schedules_service.dart';
import 'schedule_form_screen.dart'; 
import '../../events/presentation/events_log_view.dart';
import '../../../core/theme/app_colors.dart'; 

class SchedulesTab extends StatelessWidget {
  final DeviceModel device;
  final SchedulesService _service = SchedulesService();

  SchedulesTab({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: AppColors.surface,
            child: const TabBar(
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              tabs: [
                Tab(text: "Agendamentos"),
                Tab(text: "Eventos (Logs)"),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                ScheduleListView(device: device, service: _service),
                EventsLogView(device: device),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ScheduleListView extends StatelessWidget {
  final DeviceModel device;
  final SchedulesService service;

  const ScheduleListView({super.key, required this.device, required this.service});

  String _formatDays(List<int> days) {
    if (days.length == 7) return "Todos os dias";
    if (days.isEmpty) return "Nenhum dia";
    const map = {1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sáb', 7: 'Dom'};
    final sortedDays = List<int>.from(days)..sort();
    return sortedDays.map((d) => map[d]).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => ScheduleFormScreen(deviceId: device.id)),
        ),
        label: const Text("Novo"),
        icon: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<ScheduleModel>>(
        stream: service.getSchedules(device.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Text("Erro: ${snapshot.error}", style: const TextStyle(color: AppColors.error)));

          final schedules = snapshot.data ?? [];

          // --- NOVO EMPTY STATE: Muito mais bonito e convidativo! ---
          if (schedules.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight.withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.auto_awesome, size: 80, color: AppColors.primary),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      "Nenhuma rotina ainda",
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      "Automatize sua horta! Crie agendamentos para o sistema irrigar sozinho nos dias e horários que você escolher.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => ScheduleFormScreen(deviceId: device.id)),
                      ),
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text("Criar Primeiro Agendamento"),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          // --------------------------------------------------------

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 80, top: 10),
            itemCount: schedules.length,
            itemBuilder: (context, index) {
              final schedule = schedules[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: ListTile(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ScheduleFormScreen(deviceId: device.id, scheduleToEdit: schedule),
                    ),
                  ),
                  leading: CircleAvatar(
                    backgroundColor: schedule.isEnabled ? AppColors.primaryLight : AppColors.background,
                    child: Icon(Icons.alarm, color: schedule.isEnabled ? AppColors.primary : AppColors.textSecondary),
                  ),
                  title: Text("${schedule.time} - ${schedule.label}", style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${_formatDays(schedule.days)}\nDuração: ${schedule.durationMinutes} min"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: schedule.isEnabled,
                        activeTrackColor: AppColors.primary,
                        thumbColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) return AppColors.surface;
                          return AppColors.background;
                        }),
                        onChanged: (val) {
                          HapticFeedback.lightImpact();
                          service.toggleEnabled(device.id, schedule.id, val).catchError((e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: AppColors.error));
                            }
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: AppColors.errorAccent),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text("Excluir?"),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
                                TextButton(
                                  onPressed: () {
                                    service.deleteSchedule(device.id, schedule.id);
                                    Navigator.pop(ctx);
                                  },
                                  child: const Text("Excluir", style: TextStyle(color: AppColors.error)),
                                )
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}