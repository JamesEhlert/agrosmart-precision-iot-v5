// ARQUIVO: lib/screens/history_tab.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../models/activity_log_model.dart';

import '../services/aws_service.dart';
import '../services/history_service.dart';

class HistoryTab extends StatefulWidget {
  final DeviceModel device;
  const HistoryTab({super.key, required this.device});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // --- BARRA DE ABAS ---
        Container(
          color: Colors.white,
          child: TabBar(
            controller: _tabController,
            labelColor: Colors.green,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.green,
            tabs: const [
              Tab(icon: Icon(Icons.show_chart), text: "Sensores"),
              Tab(icon: Icon(Icons.event_note), text: "Eventos"),
            ],
          ),
        ),
        
        // --- CONTEÚDO ---
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _SensorsHistoryView(device: widget.device),
              _EventsLogView(device: widget.device),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 📊 VISÃO 1: HISTÓRICO DE SENSORES (AWS)
// ============================================================================
class _SensorsHistoryView extends StatefulWidget {
  final DeviceModel device;
  const _SensorsHistoryView({required this.device});

  @override
  State<_SensorsHistoryView> createState() => _SensorsHistoryViewState();
}

class _SensorsHistoryViewState extends State<_SensorsHistoryView> {
  final AwsService _awsService = AwsService();
  final List<TelemetryModel> _historyData = [];
  String? _nextToken;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    if (!mounted) return;
    setState(() { _isLoading = true; _historyData.clear(); _nextToken = null; _hasMore = true; });
    try {
      final response = await _awsService.getTelemetryHistory(widget.device.id, limit: 50);
      if (mounted) {
        setState(() {
          _historyData.addAll(response.items);
          _nextToken = response.nextToken;
          if (_nextToken == null) _hasMore = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadNextPage() async {
    if (_isLoadingMore || !_hasMore || _nextToken == null) return;
    setState(() => _isLoadingMore = true);
    try {
      final response = await _awsService.getTelemetryHistory(widget.device.id, nextToken: _nextToken, limit: 50);
      if (mounted) {
        setState(() {
          _historyData.addAll(response.items);
          _nextToken = response.nextToken;
          if (_nextToken == null) _hasMore = false;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  String _formatDateTime(DateTime utcTime) {
    final localTime = utcTime.add(Duration(hours: widget.device.settings.timezoneOffset));
    return DateFormat('dd/MM\nHH:mm').format(localTime);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.green));
    if (_historyData.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.history, size: 60, color: Colors.grey),
        const SizedBox(height: 10), const Text("Sem dados de sensores."),
        TextButton(onPressed: _loadFirstPage, child: const Text("Atualizar"))
      ]));
    }

    return RefreshIndicator(
      onRefresh: _loadFirstPage, color: Colors.green,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _historyData.length + 1,
        itemBuilder: (context, index) {
          if (index == _historyData.length) return _buildLoadMoreButton();
          final item = _historyData[index];
          return Card(
            elevation: 2, margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withValues(alpha: 0.3))),
                  child: Text(_formatDateTime(item.timestamp), textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[800], fontSize: 12)),
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    _miniSensor(Icons.thermostat, "${item.airTemp.toStringAsFixed(1)}°C", Colors.orange),
                    _miniSensor(Icons.water_drop, "${item.airHumidity.toStringAsFixed(0)}%", Colors.blue),
                    _miniSensor(Icons.grass, "${item.soilMoisture.toStringAsFixed(0)}%", Colors.brown),
                  ]),
                  const Divider(height: 12),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    _miniSensor(Icons.wb_sunny, "UV ${item.uvIndex.toStringAsFixed(1)}", Colors.amber),
                    _miniSensor(Icons.light_mode, "${item.lightLevel.toStringAsFixed(0)} Lx", Colors.yellow[800]!),
                    _miniSensor(Icons.cloud, item.rainRaw < 4000 ? "Sim" : "Não", Colors.blueGrey),
                  ]),
                ]))
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadMoreButton() {
    if (!_hasMore) return const Padding(padding: EdgeInsets.all(16.0), child: Center(child: Text("Fim do histórico.", style: TextStyle(color: Colors.grey))));
    if (_isLoadingMore) return const Padding(padding: EdgeInsets.all(16.0), child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.green)));
    return Padding(padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32), child: OutlinedButton.icon(onPressed: _loadNextPage, icon: const Icon(Icons.download), label: const Text("CARREGAR MAIS ANTIGOS"), style: OutlinedButton.styleFrom(foregroundColor: Colors.green, side: const BorderSide(color: Colors.green))));
  }

  Widget _miniSensor(IconData icon, String text, Color color) {
    return Row(children: [Icon(icon, size: 14, color: color), const SizedBox(width: 4), Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))]);
  }
}

// ============================================================================
// 📝 VISÃO 2: LOG DE EVENTOS (Firestore)
// ============================================================================
class _EventsLogView extends StatefulWidget {
  final DeviceModel device;
  const _EventsLogView({required this.device});

  @override
  State<_EventsLogView> createState() => _EventsLogViewState();
}

class _EventsLogViewState extends State<_EventsLogView> {
  final HistoryService _historyService = HistoryService();
  final List<ActivityLogModel> _logs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    if (!mounted) return;
    setState(() { _isLoading = true; _logs.clear(); });
    try {
      final logs = await _historyService.getActivityLogs(widget.device.id, limit: 20);
      if (mounted) {
        setState(() {
          _logs.addAll(logs);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDateTime(DateTime time) {
    return DateFormat('dd/MM/yyyy HH:mm').format(time);
  }

  Widget _getTypeIcon(String type) {
    switch (type) {
      case 'execution': return const Icon(Icons.check_circle, color: Colors.green);
      case 'skipped': return const Icon(Icons.remove_circle_outline, color: Colors.orange);
      case 'error': return const Icon(Icons.error, color: Colors.red);
      default: return const Icon(Icons.info, color: Colors.blue);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.green));
    
    if (_logs.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.event_busy, size: 60, color: Colors.grey),
        const SizedBox(height: 10), 
        const Text("Nenhum evento registrado ainda."),
        const SizedBox(height: 5),
        const Text("Os logs aparecerão aqui quando o sistema atuar.", style: TextStyle(fontSize: 12, color: Colors.grey)),
        TextButton(onPressed: _loadLogs, child: const Text("Atualizar"))
      ]));
    }

    return RefreshIndicator(
      onRefresh: _loadLogs,
      color: Colors.green,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _logs.length,
        separatorBuilder: (ctx, i) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final log = _logs[index];
          return ListTile(
            leading: _getTypeIcon(log.type),
            title: Text(log.message, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            subtitle: Text("${_formatDateTime(log.timestamp)} • Fonte: ${log.source}"),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          );
        },
      ),
    );
  }
}