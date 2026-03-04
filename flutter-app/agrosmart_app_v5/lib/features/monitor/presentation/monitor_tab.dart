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

  // NOVO: Timer apenas para “rebuild” do cronômetro (1s)
  Timer? _uiTimer;

  bool _isSendingCommand = false;

  Map<String, dynamic>? _weatherSummary;
  bool _loadingWeather = false;

  bool _hasInternet = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Lógica baseada na “Source of Truth” do Firestore:
  bool get _isValveOpen => widget.device.state.valveOpen;

  // Se estiver aberto e origin for schedule, consideramos travado por agendamento
  bool get _isLockedBySchedule =>
      _isValveOpen && widget.device.state.valveOrigin == 'schedule';

  // Atalho: só vale iniciar timer visual se existe endsAt
  bool get _hasValveEndsAt => widget.device.state.valveEndsAt != null;

  @override
  void initState() {
    super.initState();
    _setupConnectivity();
    _fetchWeatherSummary();
    _fetchTelemetry();
    _startTelemetryPolling();
    _startUiTimer(); // NOVO
  }

  @override
  void didUpdateWidget(covariant MonitorTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.device.id != widget.device.id) {
      _fetchTelemetry();
      _fetchWeatherSummary();
    } else if (oldWidget.device.settings.latitude !=
        widget.device.settings.latitude) {
      _fetchWeatherSummary();
    }

    // Se mudou valveEndsAt / valveOpen, força um rebuild
    // (útil quando Firestore atualiza “state”)
    if (mounted &&
        (oldWidget.device.state.valveEndsAt != widget.device.state.valveEndsAt ||
            oldWidget.device.state.valveOpen != widget.device.state.valveOpen)) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _telemetryTimer?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  void _setupConnectivity() {
    Connectivity().checkConnectivity().then(_updateConnectionStatus);
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen(_updateConnectionStatus);
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

  // NOVO: Timer visual do cronômetro (1 segundo)
  void _startUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Atualiza a UI enquanto existir endsAt (manual ou schedule)
      if (mounted && _hasValveEndsAt) {
        setState(() {});
      }
    });
  }

  // NOVO: Calcula o tempo restante baseado no relógio global (endsAt) do Firestore
  String _getRemainingTimeStr() {
    final endsAt = widget.device.state.valveEndsAt;
    if (endsAt == null) return "--:--";

    // Normaliza para UTC para evitar diferença entre “local vs UTC”
    final endsUtc = endsAt.toUtc();
    final nowUtc = DateTime.now().toUtc();

    final diffSeconds = endsUtc.difference(nowUtc).inSeconds;

    if (diffSeconds <= 0) return "Finalizando...";

    final minutes = diffSeconds ~/ 60;
    final seconds = diffSeconds % 60;

    return "${minutes}m ${seconds.toString().padLeft(2, '0')}s";
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
      final url = Uri.parse(
          "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto");
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

  Future<void> _startManualIrrigation() async {
    final minutes = widget.device.settings.manualDuration.clamp(1, 15);
    if (minutes <= 0) return;

    final durationSeconds = minutes * 60;

    try {
      final result = await _awsService.sendCommandWithAck(
        deviceId: widget.device.id,
        action: "on",
        duration: durationSeconds,
      );

      if (!mounted) return;

      if (!result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Falha ao enviar comando"),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }

      final ack = await _awsService
          .watchCommandStateForAck(
            deviceId: widget.device.id,
            commandId: result.commandId,
          )
          .firstWhere((e) =>
              e != null &&
              (e.status == 'started' ||
                  e.status == 'failed' ||
                  e.status == 'error'))
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (ack != null && ack.status == 'started') {
        HapticFeedback.heavyImpact();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("A placa recusou ou falhou ao ligar a válvula"),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } on ConflictException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.orange),
      );
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("A placa não respondeu (Timeout)"),
          backgroundColor: AppColors.warning,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro: $e"), backgroundColor: AppColors.error),
      );
    }
  }

  // Renomeado (mais genérico): para manual e schedule, é o mesmo comando OFF
  Future<void> _stopIrrigation() async {
    try {
      final result = await _awsService.sendCommandWithAck(
        deviceId: widget.device.id,
        action: "off",
        duration: 0,
      );

      if (!mounted) return;
      if (!result.ok) return;

      // CORREÇÃO DO TIMEOUT:
      // Ao enviar OFF, esperamos RECEIVED (ou done/failed se vier),
      // porque a ESP32 pode vincular o DONE ao command_id original do ON.
      final ack = await _awsService
          .watchCommandStateForAck(
            deviceId: widget.device.id,
            commandId: result.commandId,
          )
          .firstWhere((e) =>
              e != null &&
              (e.status == 'received' ||
                  e.status == 'done' ||
                  e.status == 'failed' ||
                  e.status == 'error'))
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (ack != null) {
        HapticFeedback.heavyImpact();
      }
    } on TimeoutException {
      if (!mounted) return;

      // Evita snackbar “barulhento”:
      // o state global deve ser fechado pela Lambda de qualquer forma.
      debugPrint("OFF timeout: sem ack rápido, aguardando atualização do state.");
    } catch (e) {
      if (!mounted) return;
      debugPrint("Erro ao enviar OFF: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro ao desligar: $e"), backgroundColor: AppColors.error),
      );
    }
  }

  Future<void> _onIrrigationButtonPressed() async {
    if (_isSendingCommand) return;

    HapticFeedback.mediumImpact();
    setState(() => _isSendingCommand = true);

    try {
      if (_isValveOpen) {
        await _stopIrrigation();
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
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.black54,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _telemetryData;
    final caps = widget.device.settings.capabilities;

    final remainingStr = _getRemainingTimeStr();

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
                Icon(Icons.wifi_off,
                    color: AppColors.textLight, size: 16),
                SizedBox(width: 8),
                Text(
                  "Sem conexão. Tentando reconectar...",
                  style: TextStyle(
                    color: AppColors.textLight,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
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
                  if (widget.device.settings.latitude != 0 &&
                      widget.device.settings.longitude != 0)
                    const SizedBox(height: 16),
                  SensorCards(
                    data: data,
                    isLoadingTelemetry: _isLoadingTelemetry,
                    capabilities: caps,
                  ),

                  if (_isLoadingTelemetry && data == null) ...[
                    _buildSectionTitle("Ações"),
                    Shimmer.fromColors(
                      baseColor: Colors.grey[300]!,
                      highlightColor: Colors.grey[100]!,
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ] else if (data != null) ...[
                    _buildSectionTitle("Ações"),

                    // Se está rodando por agendamento, mostramos botão de “cancelar”
                    if (_isLockedBySchedule)
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: (_isSendingCommand ||
                                  !_hasInternet ||
                                  !widget.device.isOnline)
                              ? null
                              : _onIrrigationButtonPressed,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                          ),
                          child: _isSendingCommand
                              ? const SizedBox(
                                  height: 24,
                                  width: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 3,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.stop_circle,
                                        color: Colors.white),
                                    const SizedBox(width: 8),
                                    Text(
                                      "CANCELAR AGENDAMENTO ($remainingStr)",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      )
                    else
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: (_isSendingCommand ||
                                  !_hasInternet ||
                                  !widget.device.isOnline)
                              ? null
                              : _onIrrigationButtonPressed,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isValveOpen ? AppColors.error : AppColors.info,
                          ),
                          child: _isSendingCommand
                              ? const SizedBox(
                                  height: 24,
                                  width: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 3,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(_isValveOpen
                                        ? Icons.stop_circle
                                        : Icons.water),
                                    const SizedBox(width: 8),
                                    Text(
                                      _isValveOpen
                                          ? "PARAR ($remainingStr)"
                                          : "IRRIGAÇÃO MANUAL (${widget.device.settings.manualDuration.clamp(1, 15)} min)",
                                    ),
                                  ],
                                ),
                        ),
                      ),
                  ] else
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          "Nenhum dado recebido do dispositivo.",
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}