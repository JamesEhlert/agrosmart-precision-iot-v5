// ARQUIVO: lib/screens/dashboard_screen.dart

import 'dart:async';
import 'dart:convert'; // Decodificar JSON do clima
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http; // Requisições HTTP para API de clima
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../models/schedule_model.dart';
import '../models/activity_log_model.dart';

import '../services/aws_service.dart';
import '../services/schedules_service.dart';
import '../services/device_service.dart';
import '../services/auth_service.dart';
import '../services/history_service.dart';

import 'schedule_form_screen.dart';
import 'settings_tab.dart';
import 'history_tab.dart';
import 'login_screen.dart';
import 'weather_screen.dart';

// ============================================================================
// ⚙️ CONSTANTES
// ============================================================================
const int refreshIntervalSeconds = 30;
const int offlineThresholdMinutes = 12;

// ============================================================================
// MAIN DASHBOARD
// ============================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final DeviceService _deviceService = DeviceService();
  final AuthService _authService = AuthService();
  final AwsService _awsService = AwsService();

  String? _selectedDeviceId;
  int _currentIndex = 0;
  TelemetryModel? _telemetryData;
  bool _isLoadingTelemetry = true;
  Timer? _refreshTimer;

  // Verifica se o dispositivo enviou dados recentemente
  bool get _isDeviceOnline {
    if (_telemetryData == null) return false;
    final now = DateTime.now().toUtc();
    final difference = now.difference(_telemetryData!.timestamp);
    return difference.inMinutes < offlineThresholdMinutes;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _manageTimer() {
    _refreshTimer?.cancel();
    // Só atualiza automaticamente se estiver na aba "Monitor" (índice 0)
    if (_selectedDeviceId != null && _currentIndex == 0) {
      _fetchTelemetry(_selectedDeviceId!);
      _refreshTimer = Timer.periodic(
        const Duration(seconds: refreshIntervalSeconds),
        (_) => _fetchTelemetry(_selectedDeviceId!),
      );
    }
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
    _manageTimer();
  }

  Future<void> _fetchTelemetry(String deviceId) async {
    try {
      final data = await _awsService.getLatestTelemetry(deviceId);
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

  // Modal para trocar de dispositivo
  void _showDevicePicker(List<String> userDevices) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Meus Dispositivos",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ...userDevices.map(
                (deviceId) => ListTile(
                  leading: Icon(
                    Icons.router,
                    color: deviceId == _selectedDeviceId ? Colors.green : Colors.grey,
                  ),
                  title: Text(
                    deviceId,
                    style: TextStyle(
                      fontWeight: deviceId == _selectedDeviceId ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: deviceId == _selectedDeviceId ? const Icon(Icons.check, color: Colors.green) : null,
                  onTap: () {
                    setState(() {
                      _selectedDeviceId = deviceId;
                      _telemetryData = null;
                      _isLoadingTelemetry = true;
                    });
                    Navigator.pop(ctx);
                    _manageTimer();
                  },
                ),
              ),
              const Divider(),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.green,
                  child: Icon(Icons.add, color: Colors.white),
                ),
                title: const Text("Adicionar Novo Dispositivo"),
                onTap: () {
                  Navigator.pop(ctx);
                  Future.delayed(const Duration(milliseconds: 200), () {
                    if (mounted) _showAddDeviceDialog();
                  });
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // Dialog para vincular novo hardware
  void _showAddDeviceDialog() {
    final idController = TextEditingController();
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Novo Dispositivo"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(labelText: "ID Serial", hintText: "Ex: ESP32-001"),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: "Nome", hintText: "Ex: Jardim"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          ElevatedButton(
            onPressed: () async {
              try {
                await _deviceService.linkDeviceToUser(idController.text.trim(), nameController.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
                if (_selectedDeviceId == null && mounted) {
                  final newId = idController.text.trim();
                  setState(() {
                    _selectedDeviceId = newId;
                    _isLoadingTelemetry = true;
                  });
                  _manageTimer();
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red),
                  );
                }
              }
            },
            child: const Text("Adicionar"),
          )
        ],
      ),
    );
  }

  Future<void> _handleLogout() async {
    await _authService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (c) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<String>>(
      stream: _deviceService.getUserDeviceIds(),
      builder: (context, snapshotList) {
        if (snapshotList.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final userDevices = snapshotList.data ?? [];

        if (userDevices.isEmpty) {
          return Scaffold(
            appBar: AppBar(
              title: const Text("AgroSmart V5"),
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            body: Center(
              child: ElevatedButton(onPressed: _showAddDeviceDialog, child: const Text("ADICIONAR AGORA")),
            ),
          );
        }

        // Seleciona o primeiro dispositivo se nenhum estiver selecionado
        if (_selectedDeviceId == null || !userDevices.contains(_selectedDeviceId)) {
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _selectedDeviceId = userDevices.first;
                _isLoadingTelemetry = true;
              });
              _manageTimer();
            }
          });
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        return StreamBuilder<DeviceModel>(
          stream: _deviceService.getDeviceStream(_selectedDeviceId!),
          builder: (context, snapshotDevice) {
            // Se ainda não carregou, usa um modelo placeholder
            final device = snapshotDevice.data ??
                DeviceModel(
                  id: _selectedDeviceId!,
                  isOnline: false,
                  settings: DeviceSettings(
                    targetMoisture: 0,
                    manualDuration: 0,
                    deviceName: "Carregando...",
                    timezoneOffset: -3,
                    capabilities: [],
                  ),
                );
            final isReallyOnline = _isDeviceOnline;

            // Lista de Abas
            final List<Widget> pages = [
              _MonitorTab(
                device: device,
                telemetryData: _telemetryData,
                isLoading: _isLoadingTelemetry,
                onRefreshRequest: () => _fetchTelemetry(device.id),
              ),
              _SchedulesTab(device: device),
              HistoryTab(device: device),
              SettingsTab(device: device),
            ];

            return Scaffold(
              appBar: AppBar(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                elevation: 0,
                automaticallyImplyLeading: false,
                title: GestureDetector(
                  onTap: () => _showDevicePicker(userDevices),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.green[700], borderRadius: BorderRadius.circular(20)),
                        child: Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  device.settings.deviceName,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: isReallyOnline ? Colors.lightGreenAccent : Colors.redAccent,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      "${device.id} • ${isReallyOnline ? 'Online' : 'Offline'}",
                                      style: const TextStyle(fontSize: 10, color: Colors.white70),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.arrow_drop_down, color: Colors.white),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [IconButton(icon: const Icon(Icons.logout), onPressed: _handleLogout)],
              ),
              body: pages[_currentIndex],
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: _currentIndex,
                onTap: _onTabTapped,
                type: BottomNavigationBarType.fixed,
                selectedItemColor: Colors.green,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.dashboard_outlined),
                    activeIcon: Icon(Icons.dashboard),
                    label: "Monitor",
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.calendar_month_outlined),
                    activeIcon: Icon(Icons.calendar_month),
                    label: "Agenda",
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.history),
                    activeIcon: Icon(Icons.history),
                    label: "Histórico",
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings_outlined),
                    activeIcon: Icon(Icons.settings),
                    label: "Config",
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// 📊 ABA 1: MONITORAMENTO (COM CAPABILITIES E WEATHER CARD)
// ============================================================================
class _MonitorTab extends StatefulWidget {
  final DeviceModel device;
  final TelemetryModel? telemetryData;
  final bool isLoading;
  final VoidCallback onRefreshRequest;

  const _MonitorTab({
    required this.device,
    required this.telemetryData,
    required this.isLoading,
    required this.onRefreshRequest,
  });

  @override
  State<_MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<_MonitorTab> {
  final AwsService _awsService = AwsService();
  final AuthService _authService = AuthService();

  bool _isSendingCommand = false;

  // ============================
  // IRRIGAÇÃO MANUAL: STOP + CONTADOR
  // ============================

  /// Cache estático por deviceId:
  /// mantém o "até quando" irrigando mesmo que a tela reconstrua.
  static final Map<String, DateTime> _irrigationUntilMemory = <String, DateTime>{};

  Timer? _irrigationTimer;
  DateTime? _irrigationUntil;
  int _remainingSeconds = 0;

  bool get _isIrrigating {
    if (_irrigationUntil == null) return false;
    return DateTime.now().isBefore(_irrigationUntil!);
  }

  String _formatMmSs(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return "${m}m ${s.toString().padLeft(2, '0')}s";
  }

  void _startCountdownTo(DateTime until) {
    _irrigationUntil = until;
    final rem = until.difference(DateTime.now()).inSeconds;
    _remainingSeconds = rem > 0 ? rem : 0;

    _irrigationTimer?.cancel();
    _irrigationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      final localUntil = _irrigationUntil;
      if (localUntil == null) {
        _irrigationTimer?.cancel();
        return;
      }

      final r = localUntil.difference(DateTime.now()).inSeconds;
      if (r <= 0) {
        _irrigationTimer?.cancel();
        setState(() {
          _irrigationUntilMemory.remove(widget.device.id);
          _irrigationUntil = null;
          _remainingSeconds = 0;
        });
      } else {
        setState(() => _remainingSeconds = r);
      }
    });
  }

  void _restoreCountdownFromMemory() {
    final mem = _irrigationUntilMemory[widget.device.id];
    if (mem == null) return;

    final rem = mem.difference(DateTime.now()).inSeconds;
    if (rem <= 0) {
      _irrigationUntilMemory.remove(widget.device.id);
      return;
    }

    // Restaura estado e retoma contador
    setState(() {
      _irrigationUntil = mem;
      _remainingSeconds = rem;
    });
    _startCountdownTo(mem);
  }

  void _clearIrrigationForCurrentDevice() {
    _irrigationTimer?.cancel();
    _irrigationTimer = null;
    _irrigationUntilMemory.remove(widget.device.id);
    _irrigationUntil = null;
    _remainingSeconds = 0;
  }

  // Estado para o Card de Clima
  Map<String, dynamic>? _weatherSummary;
  bool _loadingWeather = false;

  @override
  void initState() {
    super.initState();
    _fetchWeatherSummary();
    _restoreCountdownFromMemory();
  }

  @override
  void didUpdateWidget(covariant _MonitorTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Se trocar de device, restaura o estado daquele device (se houver)
    if (oldWidget.device.id != widget.device.id) {
      _irrigationTimer?.cancel();
      _irrigationTimer = null;
      _irrigationUntil = null;
      _remainingSeconds = 0;
      _restoreCountdownFromMemory();
    }

    // Atualiza se mudar o dispositivo ou se as coordenadas mudarem (GPS carregou)
    if (oldWidget.device.id != widget.device.id ||
        oldWidget.device.settings.latitude != widget.device.settings.latitude) {
      _fetchWeatherSummary();
    }

    // Segurança extra: se por qualquer motivo o widget reconstruir e o estado local zerar,
    // mas ainda existir no cache, restaura.
    if (!_isIrrigating && _irrigationUntilMemory.containsKey(widget.device.id)) {
      Future.microtask(() {
        if (!mounted) return;
        if (!_isIrrigating) _restoreCountdownFromMemory();
      });
    }
  }

  @override
  void dispose() {
    _irrigationTimer?.cancel();
    super.dispose();
  }

  // Busca resumo do tempo (Open-Meteo)
  Future<void> _fetchWeatherSummary() async {
    final lat = widget.device.settings.latitude;
    final lon = widget.device.settings.longitude;

    // Se não tem GPS, não faz nada
    if (lat == 0 && lon == 0) return;

    if (mounted) setState(() => _loadingWeather = true);

    try {
      final url = Uri.parse(
        "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto",
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        if (mounted) setState(() => _weatherSummary = json.decode(response.body));
      }
    } catch (e) {
      debugPrint("Erro Card Clima: $e");
    } finally {
      if (mounted) setState(() => _loadingWeather = false);
    }
  }

  Map<String, dynamic> _getWeatherInfo(int code) {
    switch (code) {
      case 0:
        return {'label': 'Limpo', 'icon': Icons.wb_sunny, 'color': Colors.orangeAccent};
      case 1:
      case 2:
      case 3:
        return {'label': 'Nublado', 'icon': Icons.cloud, 'color': Colors.white70};
      case 45:
      case 48:
        return {'label': 'Nevoeiro', 'icon': Icons.foggy, 'color': Colors.blueGrey};
      case 51:
      case 53:
      case 55:
        return {'label': 'Garoa', 'icon': Icons.grain, 'color': Colors.lightBlueAccent};
      case 61:
      case 63:
      case 65:
        return {'label': 'Chuva', 'icon': Icons.water_drop, 'color': Colors.lightBlue};
      case 80:
      case 81:
      case 82:
        return {'label': 'Chuva Forte', 'icon': Icons.tsunami, 'color': Colors.indigoAccent};
      case 95:
      case 96:
      case 99:
        return {'label': 'Tempestade', 'icon': Icons.flash_on, 'color': Colors.deepOrangeAccent};
      default:
        return {'label': '--', 'icon': Icons.help_outline, 'color': Colors.grey};
    }
  }

  Future<void> _startManualIrrigation() async {
    final minutes = widget.device.settings.manualDuration;
    if (minutes <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Defina a duração manual nas configurações."), backgroundColor: Colors.orange),
      );
      return;
    }

    final int durationSeconds = minutes * 60;

    final success = await _awsService.sendCommand(widget.device.id, "on", durationSeconds);

    if (!mounted) return;

    if (success) {
      final until = DateTime.now().add(Duration(seconds: durationSeconds));
      _irrigationUntilMemory[widget.device.id] = until;

      setState(() {
        _irrigationUntil = until;
        _remainingSeconds = durationSeconds;
      });

      _startCountdownTo(until);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✅ Irrigação iniciada por $minutes min"),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("❌ Falha no comando."), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _stopManualIrrigation() async {
    // STOP imediato: API aceita apenas action "on", então paramos com duration=0
    final success = await _awsService.sendCommand(widget.device.id, "on", 0);

    if (!mounted) return;

    if (success) {
      setState(() => _clearIrrigationForCurrentDevice());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("⏹️ Irrigação parada!"), backgroundColor: Colors.orange),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("❌ Falha ao parar irrigação."), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _onIrrigationButtonPressed() async {
    if (_isSendingCommand) return;

    setState(() => _isSendingCommand = true);

    try {
      if (_isIrrigating) {
        await _stopManualIrrigation();
      } else {
        await _startManualIrrigation();
      }
    } on UnauthorizedException catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Sessão expirada. Faça login novamente."),
          backgroundColor: Colors.red,
        ),
      );

      await _authService.logout();
      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (c) => const LoginScreen()),
        (route) => false,
      );
    } on ForbiddenException catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Sem permissão para enviar comando para este dispositivo."),
          backgroundColor: Colors.orange,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro (${e.statusCode}): ${e.message}"), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro inesperado: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSendingCommand = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) return const Center(child: CircularProgressIndicator(color: Colors.green));

    final data = widget.telemetryData;
    final bool hasGps = widget.device.settings.latitude != 0 && widget.device.settings.longitude != 0;
    final caps = widget.device.settings.capabilities;

    return RefreshIndicator(
      onRefresh: () async {
        widget.onRefreshRequest();
        _fetchWeatherSummary();
      },
      color: Colors.green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data != null)
              Text(
                "Atualizando a cada $refreshIntervalSeconds s • Última: ${DateFormat('dd/MM HH:mm:ss').format(data.timestamp.add(Duration(hours: widget.device.settings.timezoneOffset)))}",
                textAlign: TextAlign.right,
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            const SizedBox(height: 10),

            if (hasGps)
              Card(
                color: Colors.blueAccent,
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: InkWell(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => WeatherScreen(device: widget.device)),
                  ),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    height: 110,
                    padding: const EdgeInsets.all(16),
                    child: _loadingWeather
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : _weatherSummary == null
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.touch_app, color: Colors.white70),
                                  SizedBox(width: 8),
                                  Text("Toque para ver previsão", style: TextStyle(color: Colors.white)),
                                ],
                              )
                            : Row(
                                children: [
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        _getWeatherInfo(_weatherSummary!['current']['weather_code'])['icon'],
                                        color: Colors.white,
                                        size: 36,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _getWeatherInfo(_weatherSummary!['current']['weather_code'])['label'],
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 20),
                                  Text(
                                    "${_weatherSummary!['current']['temperature_2m'].toInt()}°",
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 42),
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          "Máx ${_weatherSummary!['daily']['temperature_2m_max'][0].toInt()}°",
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                        ),
                                        Text(
                                          "Mín ${_weatherSummary!['daily']['temperature_2m_min'][0].toInt()}°",
                                          style: const TextStyle(color: Colors.white70),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const Icon(Icons.water_drop, color: Colors.lightBlueAccent, size: 14),
                                            Text(
                                              " ${_weatherSummary!['daily']['precipitation_probability_max'][0]}%",
                                              style: const TextStyle(
                                                color: Colors.lightBlueAccent,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        )
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.arrow_forward_ios, color: Colors.white30, size: 16)
                                ],
                              ),
                  ),
                ),
              ),

            if (hasGps) const SizedBox(height: 16),

            if (data != null) ...[
              if (caps.contains('air') || caps.contains('soil')) ...[
                _buildSectionTitle("Ambiente & Solo"),
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        if (caps.contains('air')) ...[
                          _SensorWidget(
                            icon: Icons.thermostat,
                            value: "${data.airTemp.toStringAsFixed(1)}°C",
                            label: "Temp Ar",
                            color: Colors.orange,
                          ),
                          _SensorWidget(
                            icon: Icons.water_drop_outlined,
                            value: "${data.airHumidity.toStringAsFixed(0)}%",
                            label: "Umid. Ar",
                            color: Colors.blueAccent,
                          ),
                        ],
                        if (caps.contains('soil'))
                          _SensorWidget(
                            icon: Icons.grass,
                            value: "${data.soilMoisture.toStringAsFixed(0)}%",
                            label: "Umid. Solo",
                            color: Colors.brown,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              if (caps.any((c) => ['uv', 'light', 'rain'].contains(c))) ...[
                _buildSectionTitle("Externo"),
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        if (caps.contains('uv'))
                          _SensorWidget(
                            icon: Icons.wb_sunny,
                            value: data.uvIndex.toStringAsFixed(1),
                            label: "Índice UV",
                            color: Colors.amber,
                          ),
                        if (caps.contains('light'))
                          _SensorWidget(
                            icon: Icons.light_mode,
                            value: data.lightLevel.toStringAsFixed(0),
                            label: "Luz (Lux)",
                            color: Colors.yellow[700]!,
                          ),
                        if (caps.contains('rain'))
                          _SensorWidget(
                            icon: Icons.cloud,
                            value: "${data.rainRaw}",
                            label: "Chuva (Raw)",
                            color: Colors.blueGrey,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              _buildSectionTitle("Ações"),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isSendingCommand ? null : _onIrrigationButtonPressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isIrrigating ? Colors.red : Colors.blue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: (_isIrrigating ? Colors.red : Colors.blue).withAlpha(150),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isSendingCommand
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_isIrrigating ? Icons.stop_circle : Icons.water),
                            const SizedBox(width: 8),
                            Text(
                              _isIrrigating
                                  ? "PARAR (${_formatMmSs(_remainingSeconds)})"
                                  : "IRRIGAÇÃO MANUAL (${widget.device.settings.manualDuration} min)",
                            ),
                          ],
                        ),
                ),
              ),
            ] else
              const Center(
                child: Text("Aguardando dados dos sensores...", style: TextStyle(color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54),
      ),
    );
  }
}

// ============================================================================
// 📅 ABA 2: AGENDAMENTOS E LOGS
// ============================================================================
class _SchedulesTab extends StatelessWidget {
  final DeviceModel device;
  final SchedulesService _service = SchedulesService();

  _SchedulesTab({required this.device});

  @override
  Widget build(BuildContext context) {
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
                Tab(text: "Agendamentos"),
                Tab(text: "Eventos (Logs)"),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ScheduleListView(device: device, service: _service),
                _EventsLogView(device: device),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// WIDGET AUXILIAR: LISTA DE AGENDAMENTOS
// ============================================================================
class _ScheduleListView extends StatelessWidget {
  final DeviceModel device;
  final SchedulesService service;

  const _ScheduleListView({required this.device, required this.service});

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
        backgroundColor: Colors.green,
      ),
      body: StreamBuilder<List<ScheduleModel>>(
        stream: service.getSchedules(device.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Text("Erro: ${snapshot.error}"));

          final schedules = snapshot.data ?? [];

          if (schedules.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.calendar_month_outlined, size: 60, color: Colors.grey),
                  SizedBox(height: 10),
                  Text("Nenhum agendamento criado."),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 80, top: 10),
            itemCount: schedules.length,
            itemBuilder: (context, index) {
              final schedule = schedules[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ScheduleFormScreen(deviceId: device.id, scheduleToEdit: schedule),
                    ),
                  ),
                  leading: CircleAvatar(
                    backgroundColor: schedule.isEnabled ? Colors.green[100] : Colors.grey[200],
                    child: Icon(Icons.alarm, color: schedule.isEnabled ? Colors.green : Colors.grey),
                  ),
                  title: Text("${schedule.time} - ${schedule.label}", style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${_formatDays(schedule.days)}\nDuração: ${schedule.durationMinutes} min"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: schedule.isEnabled,
                        activeTrackColor: Colors.green,
                        thumbColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) return Colors.white;
                          return Colors.grey[200];
                        }),
                        onChanged: (val) {
                          service.toggleEnabled(device.id, schedule.id, val).catchError((e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red),
                              );
                            }
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
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
                                  child: const Text("Excluir", style: TextStyle(color: Colors.red)),
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

// ============================================================================
// WIDGET AUXILIAR: LOG DE EVENTOS (PAGINADO)
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
  DocumentSnapshot? _lastDoc;
  bool _isLoading = false;
  bool _hasMore = true;

  // Chips / filtros no topo
  String _mainFilter = 'all'; // all | schedule | ack
  String _ackFilter = 'all';  // all | received | started | done | error

  @override
  void initState() {
    super.initState();
    _fetchLogs();
  }

  // ---------- Helpers ACK ----------
  bool _isAckLog(ActivityLogModel log) {
    final t = log.type.toLowerCase().trim();
    if (t == 'ack') return true;
    final msg = log.message.trimLeft();
    return msg.toUpperCase().startsWith('ACK ');
  }

  String? _parseAckStatus(ActivityLogModel log) {
    // Prefer mensagem do lambda: "ACK <status> | ..."
    final msg = log.message.trimLeft();
    if (!msg.toUpperCase().startsWith('ACK ')) {
      // fallback: se o backend mudar para type "ack_<status>"
      final t = log.type.toLowerCase();
      if (t.startsWith('ack_')) return t.substring(4);
      return null;
    }
    final rest = msg.substring(4);
    final cut = rest.indexOf('|');
    final st = (cut >= 0 ? rest.substring(0, cut) : rest).trim().toLowerCase();
    if (st.isEmpty) return null;
    // normaliza alguns sinônimos
    if (st == 'ok' || st == 'success') return 'done';
    if (st == 'start' || st == 'running') return 'started';
    return st;
  }

  List<ActivityLogModel> get _filteredLogs {
    if (_mainFilter == 'all') return _logs;

    if (_mainFilter == 'schedule') {
      return _logs.where((l) => !_isAckLog(l)).toList();
    }

    // _mainFilter == 'ack'
    final onlyAck = _logs.where(_isAckLog).toList();
    if (_ackFilter == 'all') return onlyAck;

    return onlyAck.where((l) => (_parseAckStatus(l) ?? '') == _ackFilter).toList();
  }

  Map<String, int> _countAckStatuses() {
    final Map<String, int> counts = {
      'received': 0,
      'started': 0,
      'done': 0,
      'error': 0,
    };

    for (final l in _logs) {
      if (!_isAckLog(l)) continue;
      final st = _parseAckStatus(l);
      if (st == null) continue;
      if (counts.containsKey(st)) counts[st] = (counts[st] ?? 0) + 1;
    }
    return counts;
  }

  // ---------- Data fetch ----------
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

        // Como a response não expõe "hasMore", usamos o tamanho da página como heurística.
        _hasMore = result.logs.length == 20;

        // Se eu estava filtrando um status de ACK que não existe mais,
        // volta pro "all" para não parecer que a lista "sumiu".
        if (_mainFilter == 'ack' && _ackFilter != 'all') {
          final any = _logs.any((l) => _parseAckStatus(l) == _ackFilter);
          if (!any) _ackFilter = 'all';
        }
      });
    } catch (e) {
      debugPrint('Erro ao buscar logs: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refresh() async => _fetchLogs(refresh: true);

  void _loadMore() {
    if (_hasMore && !_isLoading) _fetchLogs();
  }

  // ---------- UI helpers ----------
  IconData _getTypeIcon(ActivityLogModel log) {
    // ACK com ícone por status
    if (_isAckLog(log)) {
      final st = _parseAckStatus(log);
      switch (st) {
        case 'received':
          return Icons.mark_email_read_outlined;
        case 'started':
          return Icons.play_circle_outline;
        case 'done':
          return Icons.check_circle_outline;
        case 'error':
          return Icons.error_outline;
        default:
          return Icons.notifications_active_outlined;
      }
    }

    switch (log.type) {
      case 'schedule_executed':
        return Icons.check_circle;
      case 'schedule_skipped':
        return Icons.skip_next;
      case 'schedule_error':
        return Icons.error;
      case 'valve_on':
        return Icons.water_drop;
      case 'valve_off':
        return Icons.water_drop_outlined;
      default:
        return Icons.info;
    }
  }

  Color _getTypeColor(ActivityLogModel log) {
    if (_isAckLog(log)) {
      final st = _parseAckStatus(log);
      switch (st) {
        case 'received':
          return Colors.blue;
        case 'started':
          return Colors.orange;
        case 'done':
          return Colors.green;
        case 'error':
          return Colors.red;
        default:
          return Colors.purple;
      }
    }

    switch (log.type) {
      case 'schedule_executed':
        return Colors.green;
      case 'schedule_skipped':
        return Colors.orange;
      case 'schedule_error':
        return Colors.red;
      case 'valve_on':
        return Colors.blue;
      case 'valve_off':
        return Colors.grey;
      default:
        return Colors.blueGrey;
    }
  }

  Widget _buildChipsHeader() {
    final total = _logs.length;
    final ackTotal = _logs.where(_isAckLog).length;
    final schedTotal = total - ackTotal;
    final ackCounts = _countAckStatuses();

    Widget choice(String key, String label, int count) {
      final selected = _mainFilter == key;
      return ChoiceChip(
        selected: selected,
        label: Text('$label ($count)'),
        onSelected: (v) {
          if (!v) return;
          setState(() {
            _mainFilter = key;
            if (_mainFilter != 'ack') _ackFilter = 'all';
          });
        },
      );
    }

    Widget ackChip(String st, String label) {
      final selected = _ackFilter == st;
      final count = st == 'all'
          ? ackTotal
          : (ackCounts[st] ?? 0);
      return ChoiceChip(
        selected: selected,
        label: Text('$label ($count)'),
        onSelected: (v) {
          if (!v) return;
          setState(() => _ackFilter = st);
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                choice('all', 'Todos', total),
                choice('schedule', 'Agendamentos', schedTotal),
                choice('ack', 'ACK', ackTotal),
              ],
            ),
          ),
          if (_mainFilter == 'ack') ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ackChip('all', 'Todos'),
                  ackChip('received', 'Recebido'),
                  ackChip('started', 'Iniciado'),
                  ackChip('done', 'Concluído'),
                  ackChip('error', 'Erro'),
                ],
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Divider(height: 1),
        ],
      ),
    );
  }

  void _showLogDetails(ActivityLogModel log) {
    final isAck = _isAckLog(log);
    final ackStatus = _parseAckStatus(log);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isAck ? 'ACK do Dispositivo' : 'Detalhes do Evento'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isAck && ackStatus != null) ...[
                Text('Status: $ackStatus'),
                const SizedBox(height: 8),
              ],
              Text(log.message),
              const SizedBox(height: 16),
              Text('Tipo: ${log.type}'),
              Text('Fonte: ${log.source}'),
              Text('Data: ${DateFormat('dd/MM/yyyy HH:mm').format(log.timestamp)}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleLogs = _filteredLogs;

    if (_logs.isEmpty && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_logs.isEmpty) {
      // Mesmo sem logs, mantém uma dica simples
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.event_note, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Nenhum evento registrado',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _refresh,
              child: const Text('Atualizar'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: visibleLogs.length + 2, // header + logs + loadMore
        separatorBuilder: (context, index) {
          // evita divisor depois do header
          if (index == 0) return const SizedBox.shrink();
          return const Divider();
        },
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildChipsHeader();
          }

          // load more card
          if (index == visibleLogs.length + 1) {
            if (!_hasMore) return const SizedBox(height: 24);
            return Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: _isLoading ? null : _loadMore,
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Carregar mais'),
              ),
            );
          }

          final log = visibleLogs[index - 1];

          return ListTile(
            leading: CircleAvatar(
              backgroundColor: _getTypeColor(log).withAlpha(51), // 0.2 * 255 ≈ 51
              child: Icon(_getTypeIcon(log), color: _getTypeColor(log)),
            ),
            title: Text(log.message),
            subtitle: Text(
              '${DateFormat('dd/MM HH:mm').format(log.timestamp)} • ${log.source}',
            ),
            onTap: () => _showLogDetails(log),
          );
        },
      ),
    );
  }
}

class _SensorWidget extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _SensorWidget({required this.icon, required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withAlpha(38), shape: BoxShape.circle),
        child: Icon(icon, color: color, size: 28),
      ),
      const SizedBox(height: 8),
      Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    ]);
  }
}
