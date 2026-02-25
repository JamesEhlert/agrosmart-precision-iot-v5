// ARQUIVO: lib/features/monitor/presentation/monitor_tab.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:connectivity_plus/connectivity_plus.dart'; 
import 'package:shimmer/shimmer.dart'; 

import '../../../models/device_model.dart';
import '../../../models/telemetry_model.dart';
import '../../../services/aws_service.dart';
import '../../../core/theme/app_colors.dart';

// Importando os novos widgets isolados
import 'widgets/weather_summary_card.dart';
import 'widgets/sensor_cards.dart';

const int refreshIntervalSeconds = 30;

class MonitorTab extends StatefulWidget {
  final DeviceModel device;

  const MonitorTab({super.key, required this.device});

  @override
  State<MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<MonitorTab> {
  final AwsService _awsService = AwsService();

  TelemetryModel? _telemetryData;
  bool _isLoadingTelemetry = true;
  Timer? _telemetryTimer;

  bool _isSendingCommand = false;
  static final Map<String, DateTime> _irrigationUntilMemory = <String, DateTime>{};
  Timer? _irrigationTimer;
  DateTime? _irrigationUntil;
  int _remainingSeconds = 0;

  Map<String, dynamic>? _weatherSummary;
  bool _loadingWeather = false;

  bool _hasInternet = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool get _isIrrigating => _irrigationUntil != null && DateTime.now().isBefore(_irrigationUntil!);

  @override
  void initState() {
    super.initState();
    _setupConnectivity(); 
    _fetchWeatherSummary(); 
    _fetchTelemetry();      
    _startTelemetryPolling(); 
    _restoreCountdownFromMemory();
  }

  @override
  void didUpdateWidget(covariant MonitorTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (oldWidget.device.id != widget.device.id) {
      _fetchTelemetry(); 
      _fetchWeatherSummary();
      _clearIrrigationForCurrentDevice();
      _restoreCountdownFromMemory();
    }
    else if (oldWidget.device.settings.latitude != widget.device.settings.latitude) {
      _fetchWeatherSummary();
    }
  }

  @override
  void dispose() {
    _telemetryTimer?.cancel();
    _irrigationTimer?.cancel();
    _connectivitySubscription?.cancel(); 
    super.dispose();
  }

  void _setupConnectivity() {
    Connectivity().checkConnectivity().then(_updateConnectionStatus);
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_updateConnectionStatus);
  }

  void _updateConnectionStatus(List<ConnectivityResult> result) {
    final isOnline = !result.contains(ConnectivityResult.none);
    if (mounted && _hasInternet != isOnline) {
      setState(() => _hasInternet = isOnline);
      if (_hasInternet) {
        _handleManualRefresh();
      }
    }
  }

  void _startTelemetryPolling() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(
      const Duration(seconds: refreshIntervalSeconds),
      (_) {
        if (_hasInternet) {
          _fetchTelemetry();
        }
      },
    );
  }

  Future<void> _fetchTelemetry() async {
    if (!_hasInternet) return; 
    try {
      final data = await _awsService.getLatestTelemetry(widget.device.id);
      if (mounted) {
        setState(() {
          _telemetryData = data;
          _isLoadingTelemetry = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingTelemetry = false);
    }
  }

  Future<void> _handleManualRefresh() async {
    if (!_hasInternet) return;
    setState(() => _isLoadingTelemetry = true);
    await Future.wait([
      _fetchTelemetry(),
      _fetchWeatherSummary(),
    ]);
  }

  Future<void> _fetchWeatherSummary() async {
    if (!_hasInternet) return;
    final lat = widget.device.settings.latitude;
    final lon = widget.device.settings.longitude;
    if (lat == 0 && lon == 0) return;

    if (mounted) setState(() => _loadingWeather = true);
    try {
      final url = Uri.parse("https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto");
      final response = await http.get(url);
      if (response.statusCode == 200 && mounted) {
        setState(() => _weatherSummary = json.decode(response.body));
      }
    } catch (e) {
      debugPrint("Erro Clima: $e");
    } finally {
      if (mounted) setState(() => _loadingWeather = false);
    }
  }

  String _formatMmSs(int totalSeconds) => "${totalSeconds ~/ 60}m ${(totalSeconds % 60).toString().padLeft(2, '0')}s";

  void _startCountdownTo(DateTime until) {
    _irrigationUntil = until;
    _remainingSeconds = until.difference(DateTime.now()).inSeconds;
    if (_remainingSeconds < 0) _remainingSeconds = 0;

    _irrigationTimer?.cancel();
    _irrigationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _irrigationUntil == null) return _irrigationTimer?.cancel();
      final r = _irrigationUntil!.difference(DateTime.now()).inSeconds;
      if (r <= 0) {
        setState(() => _clearIrrigationForCurrentDevice());
      } else {
        setState(() => _remainingSeconds = r);
      }
    });
  }

  void _restoreCountdownFromMemory() {
    final mem = _irrigationUntilMemory[widget.device.id];
    if (mem != null && mem.difference(DateTime.now()).inSeconds > 0) {
      setState(() => _irrigationUntil = mem);
      _startCountdownTo(mem);
    } else {
      _clearIrrigationForCurrentDevice();
    }
  }

  void _clearIrrigationForCurrentDevice() {
    _irrigationTimer?.cancel();
    _irrigationUntilMemory.remove(widget.device.id);
    _irrigationUntil = null;
    _remainingSeconds = 0;
  }

  Future<void> _startManualIrrigation() async {
    final minutes = widget.device.settings.manualDuration;
    if (minutes <= 0) return;
    final durationSeconds = minutes * 60;

    final result = await _awsService.sendCommandWithAck(deviceId: widget.device.id, action: "on", duration: durationSeconds);
    if (!mounted || !result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Falha ao enviar comando"), backgroundColor: AppColors.error));
      return;
    }

    try {
      final ack = await _awsService.watchCommandStateForAck(
        deviceId: widget.device.id, 
        commandId: result.commandId,
      ).firstWhere(
        (e) => e != null && (e.status == 'started' || e.status == 'failed' || e.status == 'error')
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (ack != null && ack.status == 'started') {
        final until = DateTime.now().add(Duration(seconds: durationSeconds));
        _irrigationUntilMemory[widget.device.id] = until;
        setState(() => _irrigationUntil = until);
        _startCountdownTo(until);
        HapticFeedback.heavyImpact(); 
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("A placa recusou ou falhou ao ligar a válvula"), backgroundColor: AppColors.error));
      }
    } on TimeoutException {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("A placa não respondeu (Timeout)"), backgroundColor: AppColors.warning));
    }
  }

  Future<void> _stopManualIrrigation() async {
    final result = await _awsService.sendCommandWithAck(deviceId: widget.device.id, action: "off", duration: 0);
    if (!mounted || !result.ok) return;

    try {
      final ack = await _awsService.watchCommandStateForAck(
        deviceId: widget.device.id, 
        commandId: result.commandId,
      ).firstWhere(
        (e) => e != null && (e.status == 'done' || e.status == 'failed' || e.status == 'error')
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (ack != null && ack.status == 'done') {
        setState(() => _clearIrrigationForCurrentDevice());
        HapticFeedback.heavyImpact();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Falha na placa ao desligar"), backgroundColor: AppColors.error));
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _clearIrrigationForCurrentDevice());
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Sem confirmação da placa ao desligar"), backgroundColor: AppColors.warning));
      }
    }
  }

  Future<void> _onIrrigationButtonPressed() async {
    if (_isSendingCommand) return;
    
    HapticFeedback.mediumImpact(); 
    setState(() => _isSendingCommand = true);
    
    try {
      if (_isIrrigating) {
        await _stopManualIrrigation();
      } else {
        await _startManualIrrigation();
      }
    } finally {
      if (mounted) setState(() => _isSendingCommand = false);
    }
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _telemetryData;
    final caps = widget.device.settings.capabilities;

    return Column(
      children: [
        if (!_hasInternet)
          Container(
            color: AppColors.errorAccent,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_off, color: AppColors.textLight, size: 16),
                SizedBox(width: 8),
                Text("Sem conexão. Tentando reconectar...", style: TextStyle(color: AppColors.textLight, fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        
        Expanded(
          child: RefreshIndicator(
            onRefresh: _handleManualRefresh,
            color: AppColors.primary,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (data != null && !_isLoadingTelemetry)
                    Text(
                      "Sincronizado: ${DateFormat('HH:mm:ss').format(data.timestamp.add(Duration(hours: widget.device.settings.timezoneOffset)))}",
                      textAlign: TextAlign.right,
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  const SizedBox(height: 10),

                  WeatherSummaryCard(
                    device: widget.device,
                    loadingWeather: _loadingWeather,
                    weatherSummary: _weatherSummary,
                    isLoadingTelemetry: _isLoadingTelemetry,
                  ),

                  if (widget.device.settings.latitude != 0 && widget.device.settings.longitude != 0)
                    const SizedBox(height: 16),

                  SensorCards(
                    data: data,
                    isLoadingTelemetry: _isLoadingTelemetry,
                    capabilities: caps,
                  ),

                  // Seção de Ações
                  if (_isLoadingTelemetry && data == null) ...[
                    _buildSectionTitle("Ações"),
                    Shimmer.fromColors(
                      baseColor: Colors.grey[300]!,
                      highlightColor: Colors.grey[100]!,
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ] else if (data != null) ...[
                    _buildSectionTitle("Ações"),
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: (_isSendingCommand || !_hasInternet || !widget.device.isOnline) 
                            ? null 
                            : _onIrrigationButtonPressed,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isIrrigating ? AppColors.error : AppColors.info,
                        ),
                        child: _isSendingCommand
                            ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(_isIrrigating ? Icons.stop_circle : Icons.water),
                                  const SizedBox(width: 8),
                                  Text(_isIrrigating ? "PARAR (${_formatMmSs(_remainingSeconds)})" : "IRRIGAÇÃO MANUAL (${widget.device.settings.manualDuration} min)"),
                                ],
                              ),
                      ),
                    ),
                  ] else
                    const Center(child: Padding(padding: EdgeInsets.all(20), child: Text("Nenhum dado recebido do dispositivo.", style: TextStyle(color: Colors.grey)))),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}