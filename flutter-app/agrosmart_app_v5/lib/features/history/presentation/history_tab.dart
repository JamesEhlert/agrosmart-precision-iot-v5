// ARQUIVO: lib/features/history/presentation/history_tab.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart'; 

import '../../../models/device_model.dart';
import '../../../models/telemetry_model.dart';
import '../../../services/aws_service.dart';
import '../../../core/theme/app_colors.dart'; // IMPORT DO NOVO DESIGN SYSTEM

class HistoryTab extends StatefulWidget {
  final DeviceModel device;
  const HistoryTab({super.key, required this.device});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: AppColors.surface, // Atualizado para usar cor de superfície
            child: const TabBar(
              labelColor: AppColors.primary, // Atualizado para a cor primária
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              tabs: [
                Tab(icon: Icon(Icons.list), text: "Lista"),
                Tab(icon: Icon(Icons.show_chart), text: "Gráficos"),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(), 
              children: [
                _SensorsListView(device: widget.device),
                _ChartsView(device: widget.device),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 📊 ABA 1: LISTA
// ============================================================================
class _SensorsListView extends StatefulWidget {
  final DeviceModel device;
  const _SensorsListView({required this.device});
  @override
  State<_SensorsListView> createState() => _SensorsListViewState();
}

class _SensorsListViewState extends State<_SensorsListView> {
  final AwsService _awsService = AwsService();
  final List<TelemetryModel> _data = [];
  String? _nextToken;
  bool _isLoading = false;
  bool _hasMore = true;

  DateTime? _lastSnackAt;
  String? _lastSnackKey;

  void _snackOnce(String key, String msg, {Color color = AppColors.error, int cooldownSeconds = 20}) {
    if (!mounted) return;
    final now = DateTime.now();
    final shouldShow = (_lastSnackKey != key) ||
        (_lastSnackAt == null) ||
        (now.difference(_lastSnackAt!).inSeconds >= cooldownSeconds);
    if (!shouldShow) return;
    _lastSnackKey = key;
    _lastSnackAt = now;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final res = await _awsService.getTelemetryHistory(
        widget.device.id,
        nextToken: _nextToken,
        limit: 50,
      );

      if (!mounted) return;
      setState(() {
        _data.addAll(res.items);
        _nextToken = res.nextToken;
        _hasMore = res.nextToken != null;
        _isLoading = false;
      });
    } on UnauthorizedException catch (_) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_list_401", "Sessão expirada. Faça login novamente.", color: AppColors.error);
      await FirebaseAuth.instance.signOut();
    } on ForbiddenException catch (_) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_list_403", "Sem permissão para acessar o histórico deste dispositivo.", color: AppColors.warning);
      if (mounted) setState(() => _hasMore = false);
    } on ApiException catch (e) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_list_${e.statusCode}", "Erro (${e.statusCode}): ${e.message}", color: AppColors.error);
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_list_unknown", "Erro ao carregar histórico: $e", color: AppColors.error);
    }
  }

  String _fmt(DateTime d) {
    final local = d.add(Duration(hours: widget.device.settings.timezoneOffset));
    return DateFormat('dd/MM HH:mm').format(local);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _data.isEmpty) return const Center(child: CircularProgressIndicator(color: AppColors.primary));

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _data.length + 1,
      itemBuilder: (ctx, i) {
        if (i == _data.length) {
          return _hasMore
              ? TextButton(
                  onPressed: _loadData, 
                  child: const Text("Carregar Mais", style: TextStyle(color: AppColors.primary))
                )
              : const Padding(padding: EdgeInsets.all(16), child: Center(child: Text("Fim", style: TextStyle(color: AppColors.textSecondary))));
        }
        final item = _data[i];
        return Card(
          elevation: 2,
          child: ListTile(
            leading: Text(_fmt(item.timestamp),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _iconText(Icons.thermostat, "${item.airTemp.toStringAsFixed(1)}°", AppColors.sensorTemp),
                _iconText(Icons.water_drop, "${item.airHumidity.toStringAsFixed(0)}%", AppColors.sensorHumidity),
                _iconText(Icons.grass, "${item.soilMoisture.toStringAsFixed(0)}%", AppColors.sensorSoil),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _iconText(IconData i, String t, Color c) => Row(
        children: [Icon(i, size: 14, color: c), const SizedBox(width: 4), Text(t)],
      );
}

// ============================================================================
// 📈 ABA 2: GRÁFICOS
// ============================================================================
class _ChartsView extends StatefulWidget {
  final DeviceModel device;
  const _ChartsView({required this.device});
  @override
  State<_ChartsView> createState() => _ChartsViewState();
}

class _ChartsViewState extends State<_ChartsView> {
  final AwsService _awsService = AwsService();

  DateTimeRange? _dateRange;

  // Atualizado para as cores do Design System
  final Map<String, dynamic> _sensorsConfig = {
    'soil': {
      'label': 'Solo (%)',
      'color': AppColors.sensorSoil,
      'active': true,
      'getter': (TelemetryModel t) => t.soilMoisture
    },
    'air_hum': {
      'label': 'Ar (%)',
      'color': AppColors.sensorHumidity,
      'active': false,
      'getter': (TelemetryModel t) => t.airHumidity
    },
    'temp': {
      'label': 'Temp (°C)',
      'color': AppColors.sensorTemp,
      'active': false,
      'getter': (TelemetryModel t) => t.airTemp
    },
    'uv': {
      'label': 'UV',
      'color': AppColors.sensorUv,
      'active': false,
      'getter': (TelemetryModel t) => t.uvIndex
    },
  };

  List<TelemetryModel> _chartData = [];
  bool _isLoading = false;

  DateTime? _lastSnackAt;
  String? _lastSnackKey;

  void _snackOnce(String key, String msg, {Color color = AppColors.error, int cooldownSeconds = 20}) {
    if (!mounted) return;
    final now = DateTime.now();
    final shouldShow = (_lastSnackKey != key) ||
        (_lastSnackAt == null) ||
        (now.difference(_lastSnackAt!).inSeconds >= cooldownSeconds);
    if (!shouldShow) return;
    _lastSnackKey = key;
    _lastSnackAt = now;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _dateRange = DateTimeRange(start: now.subtract(const Duration(hours: 24)), end: now);
    _fetchChartData();
  }

  Future<void> _fetchChartData() async {
    if (_dateRange == null) return;
    setState(() => _isLoading = true);

    try {
      final res = await _awsService.getTelemetryHistory(
        widget.device.id,
        start: _dateRange!.start.toUtc(),
        end: _dateRange!.end.toUtc(),
        limit: 2000,
      );

      if (!mounted) return;
      setState(() {
        _chartData = res.items.reversed.toList();
        _isLoading = false;
      });
    } on UnauthorizedException catch (_) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_chart_401", "Sessão expirada. Faça login novamente.", color: AppColors.error);
      await FirebaseAuth.instance.signOut();
    } on ForbiddenException catch (_) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_chart_403", "Sem permissão para acessar dados deste dispositivo.", color: AppColors.warning);
      if (mounted) setState(() => _chartData = []);
    } on ApiException catch (e) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_chart_${e.statusCode}", "Erro (${e.statusCode}): ${e.message}", color: AppColors.error);
      if (mounted) setState(() => _chartData = []);
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      _snackOnce("hist_chart_unknown", "Erro ao carregar gráfico: $e", color: AppColors.error);
      if (mounted) setState(() => _chartData = []);
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: _dateRange,
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            primaryColor: AppColors.primary,
            colorScheme: const ColorScheme.light(primary: AppColors.primary),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() => _dateRange = picked);
      _fetchChartData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // --- 1. BARRA DE FILTROS ---
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              OutlinedButton.icon(
                onPressed: _pickDateRange,
                icon: const Icon(Icons.calendar_today, size: 16, color: AppColors.primary),
                label: Text(
                  _dateRange == null
                    ? "Selecionar Data"
                    : "${DateFormat('dd/MM').format(_dateRange!.start)} - ${DateFormat('dd/MM').format(_dateRange!.end)}",
                  style: const TextStyle(color: AppColors.primary),
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _sensorsConfig.entries.map((entry) {
                    final key = entry.key;
                    final conf = entry.value;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(conf['label']),
                        selected: conf['active'],
                        selectedColor: (conf['color'] as Color).withValues(alpha: 0.2),
                        checkmarkColor: conf['color'],
                        labelStyle: TextStyle(
                          color: conf['active'] ? conf['color'] : AppColors.textSecondary,
                          fontWeight: conf['active'] ? FontWeight.bold : FontWeight.normal,
                        ),
                        onSelected: (bool selected) {
                          setState(() {
                            _sensorsConfig[key]['active'] = selected;
                          });
                        },
                      ),
                    );
                  }).toList(),
                ),
              )
            ],
          ),
        ),

        const Divider(height: 1),

        // --- 2. ÁREA DO GRÁFICO ---
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
              : _chartData.isEmpty
                  ? const Center(child: Text("Sem dados neste período.", style: TextStyle(color: AppColors.textSecondary)))
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                      child: LineChart(
                        LineChartData(
                          lineBarsData: _generateLines(),
                          titlesData: FlTitlesData(
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                getTitlesWidget: (val, meta) {
                                  if (val.toInt() >= 0 && val.toInt() < _chartData.length) {
                                    if (val.toInt() % (_chartData.length ~/ 5 + 1) == 0) {
                                      final date = _chartData[val.toInt()].timestamp
                                          .add(Duration(hours: widget.device.settings.timezoneOffset));
                                      return Padding(
                                        padding: const EdgeInsets.only(top: 8.0),
                                        child: Text(DateFormat('HH:mm').format(date),
                                            style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                                      );
                                    }
                                  }
                                  return const SizedBox.shrink();
                                },
                                interval: 1,
                              ),
                            ),
                            leftTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                            ),
                            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          borderData: FlBorderData(
                            show: true,
                            border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                          ),
                          gridData: FlGridData(show: true, drawVerticalLine: false),
                          lineTouchData: LineTouchData(
                            touchTooltipData: LineTouchTooltipData(
                              getTooltipItems: (touchedSpots) {
                                return touchedSpots.map((spot) {
                                  final index = spot.x.toInt();
                                  if (index < 0 || index >= _chartData.length) return null;
                                  final date = _chartData[index].timestamp
                                      .add(Duration(hours: widget.device.settings.timezoneOffset));
                                  final timeStr = DateFormat('HH:mm').format(date);
                                  return LineTooltipItem(
                                    "$timeStr\n${spot.y.toStringAsFixed(1)}",
                                    const TextStyle(color: AppColors.textLight, fontWeight: FontWeight.bold),
                                  );
                                }).toList();
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  List<LineChartBarData> _generateLines() {
    List<LineChartBarData> lines = [];

    _sensorsConfig.forEach((key, conf) {
      if (conf['active'] == true) {
        lines.add(
          LineChartBarData(
            spots: _chartData.asMap().entries.map((e) {
              final val = (conf['getter'] as Function)(e.value) as double;
              return FlSpot(e.key.toDouble(), val);
            }).toList(),
            isCurved: true,
            color: conf['color'],
            barWidth: 3,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: (conf['color'] as Color).withValues(alpha: 0.1),
            ),
          ),
        );
      }
    });

    return lines;
  }
}