// ARQUIVO: lib/features/events/presentation/events_log_view.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../../../models/device_model.dart';
import '../../../models/activity_log_model.dart';
import '../../../services/history_service.dart';
import '../../../core/theme/app_colors.dart'; 

class EventsLogView extends StatefulWidget {
  final DeviceModel device;
  const EventsLogView({super.key, required this.device});

  @override
  State<EventsLogView> createState() => _EventsLogViewState();
}

class _EventsLogViewState extends State<EventsLogView> {
  final HistoryService _historyService = HistoryService();

  final List<ActivityLogModel> _logs = [];
  DocumentSnapshot? _lastDoc;
  bool _isLoading = false;
  bool _hasMore = true;

  String _mainFilter = 'all'; 

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  List<ActivityLogModel> get _filteredLogs {
    if (_mainFilter == 'all') return _logs;
    if (_mainFilter == 'schedule') return _logs.where((l) => l.source == 'schedule').toList();
    if (_mainFilter == 'command') return _logs.where((l) => l.source == 'command').toList();
    if (_mainFilter == 'alerts') return _logs.where((l) => l.type == 'error' || l.type == 'skipped' || l.source == 'weather_ai').toList();
    return _logs;
  }

  Future<void> _fetchLogs({bool refresh = false}) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final result = await _historyService.getActivityLogs(
        widget.device.id,
        lastDocument: refresh ? null : _lastDoc,
        limit: 20,
      );

      setState(() {
        if (refresh) _logs.clear();
        _logs.addAll(result.logs);
        _lastDoc = result.lastDoc;
        _hasMore = result.logs.length == 20;
      });
    } catch (e) {
      debugPrint('Erro ao buscar logs: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refresh() async => _fetchLogs(refresh: true);
  void _loadMore() { if (_hasMore && !_isLoading) _fetchLogs(); }

  IconData _getTypeIcon(ActivityLogModel log) {
    if (log.type == 'error') return Icons.error_outline;
    if (log.type == 'skipped') return Icons.skip_next;
    if (log.source == 'command') return Icons.touch_app;
    if (log.source == 'schedule') return Icons.timer;
    if (log.source == 'weather_ai') return Icons.cloud_off;
    return Icons.info_outline;
  }

  Color _getTypeColor(ActivityLogModel log) {
    if (log.type == 'error') return AppColors.error;
    if (log.type == 'skipped') return AppColors.warning;
    if (log.source == 'command') return AppColors.info;
    if (log.source == 'schedule') return AppColors.success;
    return AppColors.textSecondary;
  }

  // --- FUNÇÕES DE TRADUÇÃO PARA USUÁRIO FINAL ---
  String _translateSource(String source) {
    switch (source) {
      case 'command': return 'Acionamento Manual (App)';
      case 'schedule': return 'Agendamento Automático';
      case 'weather_ai': return 'Previsão do Tempo Inteligente';
      case 'system': return 'Sistema de Segurança';
      default: return source.toUpperCase();
    }
  }

  String _translateResult(String? result, String type) {
    if (result == 'success') return 'Concluído com Sucesso';
    if (result == 'failed') return 'Falha na Execução';
    if (type == 'skipped') return 'Ignorado (Não era necessário)';
    if (type == 'error') return 'Erro Reportado';
    return 'Informação Registrada';
  }

  String _translateReason(String? reason) {
    if (reason == null) return 'Registro padrão';
    switch (reason) {
      case 'duration_elapsed': return 'Tempo programado concluído';
      case 'timeout': return 'A placa não respondeu a tempo';
      case 'manual_stop': 
      case 'manual_off': return 'Interrompido pelo usuário';
      case 'already_off': return 'A válvula já estava desligada';
      case 'valve_not_on': return 'A válvula não ligou fisicamente';
      case 'failsafe_no_deadline': 
      case 'failsafe': return 'Desligamento por segurança (Failsafe)';
      default: return reason; // Retorna o texto original se não houver tradução
    }
  }

  Widget _buildChipsHeader() {
    int count(bool Function(ActivityLogModel) test) => _logs.where(test).length;

    Widget choice(String key, String label, int count) {
      return ChoiceChip(
        selected: _mainFilter == key,
        label: Text('$label ($count)'),
        selectedColor: AppColors.primaryLight,
        onSelected: (v) { if (v) setState(() => _mainFilter = key); },
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Wrap(
          spacing: 8,
          children: [
            choice('all', 'Todos', _logs.length),
            choice('schedule', 'Agendas', count((l) => l.source == 'schedule')),
            choice('command', 'Manuais', count((l) => l.source == 'command')),
            choice('alerts', 'Alertas', count((l) => l.type == 'error' || l.type == 'skipped' || l.source == 'weather_ai')),
          ],
        ),
      ),
    );
  }

  // --- NOVO LAYOUT DO POPUP DE DETALHES ---
  void _showLogDetails(ActivityLogModel log) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(_getTypeIcon(log), color: _getTypeColor(log)),
            const SizedBox(width: 8),
            const Text('Status da Operação', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(log.message, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              const Divider(height: 24),
              
              _buildDetailRow(Icons.calendar_today, 'Data', DateFormat('dd/MM/yyyy • HH:mm:ss').format(log.timestamp)),
              _buildDetailRow(Icons.settings_remote, 'Origem', _translateSource(log.source)),
              _buildDetailRow(Icons.verified, 'Resultado', _translateResult(log.result, log.type)),
              
              if (log.reason != null || log.result == 'success')
                _buildDetailRow(Icons.info_outline, 'Motivo', _translateReason(log.reason)),
                
              // Mostra o sinal de Wi-Fi apenas se a placa tiver enviado esse dado!
              if (log.details?['sys']?['rssi'] != null)
                _buildDetailRow(Icons.wifi, 'Sinal da Placa', '${log.details!['sys']['rssi']} dBm'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), 
            child: const Text('FECHAR', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold))
          ),
        ],
      ),
    );
  }

  // Helper para desenhar as linhas do Popup
  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleLogs = _filteredLogs;

    if (_logs.isEmpty && _isLoading) return const Center(child: CircularProgressIndicator());

    if (_logs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.2), width: 2),
                ),
                child: const Icon(Icons.receipt_long_outlined, size: 80, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 24),
              const Text(
                "Histórico Limpo",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              const Text(
                "Nenhuma atividade registrada ainda. As execuções manuais, acionamentos de agendamento e alertas do sistema aparecerão aqui em tempo real.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text("Atualizar Página"),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 20),
        itemCount: visibleLogs.length + 2,
        separatorBuilder: (ctx, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == 0) return _buildChipsHeader();
          
          if (index == visibleLogs.length + 1) {
            if (!_hasMore) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: _isLoading ? null : _loadMore,
                child: _isLoading ? const CircularProgressIndicator(color: AppColors.textLight) : const Text('Carregar mais antigos'),
              ),
            );
          }

          final log = visibleLogs[index - 1];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: _getTypeColor(log).withValues(alpha: 0.2),
              child: Icon(_getTypeIcon(log), color: _getTypeColor(log)),
            ),
            title: Text(log.message, maxLines: 2, overflow: TextOverflow.ellipsis),
            // A legenda da lista também ganha a tradução bonitinha
            subtitle: Text('${DateFormat('dd/MM HH:mm').format(log.timestamp)} • ${_translateSource(log.source)}'),
            onTap: () => _showLogDetails(log),
          );
        },
      ),
    );
  }
}