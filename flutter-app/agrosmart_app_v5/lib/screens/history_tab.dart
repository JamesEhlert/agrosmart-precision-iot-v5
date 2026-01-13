// ARQUIVO: lib/screens/history_tab.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart'; // Importante: Biblioteca de gráficos

import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../services/aws_service.dart';

class HistoryTab extends StatefulWidget {
  final DeviceModel device;
  const HistoryTab({super.key, required this.device});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  @override
  Widget build(BuildContext context) {
    // Usamos DefaultTabController para gerenciar as abas Lista vs Gráficos
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: Colors.white,
            child: const TabBar(
              labelColor: Colors.green,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.green,
              tabs: [
                Tab(icon: Icon(Icons.list), text: "Lista"),
                Tab(icon: Icon(Icons.show_chart), text: "Gráficos"),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(), // Evita conflito de gestos com o gráfico
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
// 📊 ABA 1: LISTA (Código original simplificado)
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
  bool _isLoading = true;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final res = await _awsService.getTelemetryHistory(widget.device.id, nextToken: _nextToken, limit: 50);
    if (mounted) {
      setState(() {
        _data.addAll(res.items);
        _nextToken = res.nextToken;
        _hasMore = res.nextToken != null;
        _isLoading = false;
      });
    }
  }

  String _fmt(DateTime d) {
    // Ajuste fuso horário
    final local = d.add(Duration(hours: widget.device.settings.timezoneOffset));
    return DateFormat('dd/MM HH:mm').format(local);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _data.isEmpty) return const Center(child: CircularProgressIndicator());
    
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _data.length + 1,
      itemBuilder: (ctx, i) {
        if (i == _data.length) {
          return _hasMore 
            ? TextButton(onPressed: _loadData, child: const Text("Carregar Mais")) 
            : const Padding(padding: EdgeInsets.all(16), child: Center(child: Text("Fim")));
        }
        final item = _data[i];
        return Card(
          elevation: 2,
          child: ListTile(
            leading: Text(_fmt(item.timestamp), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _iconText(Icons.thermostat, "${item.airTemp.toStringAsFixed(1)}°", Colors.orange),
                _iconText(Icons.water_drop, "${item.airHumidity.toStringAsFixed(0)}%", Colors.blue),
                _iconText(Icons.grass, "${item.soilMoisture.toStringAsFixed(0)}%", Colors.brown),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _iconText(IconData i, String t, Color c) => Row(children: [Icon(i, size: 14, color: c), const SizedBox(width: 4), Text(t)]);
}

// ============================================================================
// 📈 ABA 2: GRÁFICOS (NOVA FUNCIONALIDADE)
// ============================================================================
class _ChartsView extends StatefulWidget {
  final DeviceModel device;
  const _ChartsView({required this.device});
  @override
  State<_ChartsView> createState() => _ChartsViewState();
}

class _ChartsViewState extends State<_ChartsView> {
  final AwsService _awsService = AwsService();
  
  // Filtros
  DateTimeRange? _dateRange;
  // Mapa de sensores: Chave = Nome Técnico, Valor = [Nome Exibição, Cor, Ativo]
  final Map<String, dynamic> _sensorsConfig = {
    'soil': {'label': 'Solo (%)', 'color': Colors.brown, 'active': true, 'getter': (TelemetryModel t) => t.soilMoisture},
    'air_hum': {'label': 'Ar (%)', 'color': Colors.blue, 'active': false, 'getter': (TelemetryModel t) => t.airHumidity},
    'temp': {'label': 'Temp (°C)', 'color': Colors.orange, 'active': false, 'getter': (TelemetryModel t) => t.airTemp},
    'uv': {'label': 'UV', 'color': Colors.purple, 'active': false, 'getter': (TelemetryModel t) => t.uvIndex},
  };

  List<TelemetryModel> _chartData = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Padrão: Últimas 24 horas
    final now = DateTime.now();
    _dateRange = DateTimeRange(start: now.subtract(const Duration(hours: 24)), end: now);
    _fetchChartData();
  }

  Future<void> _fetchChartData() async {
    if (_dateRange == null) return;
    setState(() => _isLoading = true);

    // Busca dados filtrados por data (limite alto pois é gráfico)
    final res = await _awsService.getTelemetryHistory(
      widget.device.id, 
      start: _dateRange!.start.toUtc(), 
      end: _dateRange!.end.toUtc(),
      limit: 2000 // Traz até 500 pontos para o gráfico
    );

    if (mounted) {
      setState(() {
        // Ordena por data crescente para o gráfico desenhar certo (esquerda -> direita)
        _chartData = res.items.reversed.toList();
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: _dateRange,
      builder: (context, child) {
        return Theme(data: ThemeData.light().copyWith(primaryColor: Colors.green, colorScheme: const ColorScheme.light(primary: Colors.green)), child: child!);
      }
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
              // Seletor de Data
              OutlinedButton.icon(
                onPressed: _pickDateRange,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(_dateRange == null 
                  ? "Selecionar Data" 
                  : "${DateFormat('dd/MM').format(_dateRange!.start)} - ${DateFormat('dd/MM').format(_dateRange!.end)}"),
              ),
              const SizedBox(height: 8),
              // Chips de Sensores
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
                          color: conf['active'] ? conf['color'] : Colors.black54,
                          fontWeight: conf['active'] ? FontWeight.bold : FontWeight.normal
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
            ? const Center(child: CircularProgressIndicator()) 
            : _chartData.isEmpty 
              ? const Center(child: Text("Sem dados neste período.")) 
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 16), // Margem extra no topo para labels
                  child: LineChart(
                    LineChartData(
                      lineBarsData: _generateLines(),
                      titlesData: FlTitlesData(
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (val, meta) {
                              // Mostra Hora no eixo X
                              if (val.toInt() >= 0 && val.toInt() < _chartData.length) {
                                // Reduz labels para não encavalar (mostra a cada 5 pontos aprox)
                                if (val.toInt() % (_chartData.length ~/ 5 + 1) == 0) {
                                  final date = _chartData[val.toInt()].timestamp.add(Duration(hours: widget.device.settings.timezoneOffset));
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Text(DateFormat('HH:mm').format(date), style: const TextStyle(fontSize: 10)),
                                  );
                                }
                              }
                              return const SizedBox.shrink();
                            },
                            interval: 1, // Controle fino feito no getTitlesWidget
                          ),
                        ),
                        leftTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: true, border: Border.all(color: Colors.grey.withValues(alpha: 0.2))),
                      gridData: FlGridData(show: true, drawVerticalLine: false),
                      // Tooltip ao tocar
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          // substitua pelo seu theme se preferir
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              // Formata a data do ponto
                              final index = spot.x.toInt();
                              if (index < 0 || index >= _chartData.length) return null;
                              final date = _chartData[index].timestamp.add(Duration(hours: widget.device.settings.timezoneOffset));
                              final timeStr = DateFormat('HH:mm').format(date);
                              
                              return LineTooltipItem(
                                "$timeStr\n${spot.y.toStringAsFixed(1)}",
                                const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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

  // Gera as linhas do gráfico baseadas nos Chips selecionados
  List<LineChartBarData> _generateLines() {
    List<LineChartBarData> lines = [];

    _sensorsConfig.forEach((key, conf) {
      if (conf['active'] == true) {
        lines.add(LineChartBarData(
          spots: _chartData.asMap().entries.map((e) {
            // Eixo X = Índice da lista (0, 1, 2...)
            // Eixo Y = Valor do sensor obtido via 'getter'
            final val = (conf['getter'] as Function)(e.value) as double;
            return FlSpot(e.key.toDouble(), val);
          }).toList(),
          isCurved: true,
          color: conf['color'],
          barWidth: 3,
          dotData: const FlDotData(show: false), // Remove bolinhas para ficar clean
          belowBarData: BarAreaData(show: true, color: (conf['color'] as Color).withValues(alpha: 0.1)),
        ));
      }
    });

    return lines;
  }
}