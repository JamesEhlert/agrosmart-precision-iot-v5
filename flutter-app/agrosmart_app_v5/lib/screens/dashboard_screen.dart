// ARQUIVO: lib/screens/dashboard_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../models/schedule_model.dart';

import '../services/aws_service.dart';
import '../services/schedules_service.dart';
import '../services/device_service.dart';
import '../services/auth_service.dart';

import 'schedule_form_screen.dart';
import 'settings_tab.dart';
import 'history_tab.dart';
import 'login_screen.dart';

// ============================================================================
// ⚙️ ÁREA DE CONFIGURAÇÃO DO DASHBOARD
// ============================================================================

// CORREÇÃO: Nomes em lowerCamelCase conforme padrão Dart
const int refreshIntervalSeconds = 30;
const int offlineThresholdMinutes = 12;

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

  bool get _isDeviceOnline {
    if (_telemetryData == null) return false;
    final now = DateTime.now().toUtc();
    final difference = now.difference(_telemetryData!.timestamp);
    // Usa a constante corrigida
    return difference.inMinutes < offlineThresholdMinutes;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startTelemetryUpdates(String deviceId) {
    _refreshTimer?.cancel();
    _fetchTelemetry(deviceId);
    
    // Usa a constante corrigida
    _refreshTimer = Timer.periodic(
      const Duration(seconds: refreshIntervalSeconds), 
      (_) => _fetchTelemetry(deviceId)
    );
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

  void _showDevicePicker(List<String> userDevices) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) { 
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Meus Dispositivos", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              
              ...userDevices.map((deviceId) => ListTile(
                leading: Icon(Icons.router, color: deviceId == _selectedDeviceId ? Colors.green : Colors.grey),
                title: Text(deviceId, style: TextStyle(fontWeight: deviceId == _selectedDeviceId ? FontWeight.bold : FontWeight.normal)),
                trailing: deviceId == _selectedDeviceId ? const Icon(Icons.check, color: Colors.green) : null,
                onTap: () {
                  setState(() {
                    _selectedDeviceId = deviceId;
                    _telemetryData = null;
                    _isLoadingTelemetry = true;
                  });
                  _startTelemetryUpdates(deviceId);
                  Navigator.pop(ctx);
                },
              )),

              const Divider(),
              ListTile(
                leading: const CircleAvatar(backgroundColor: Colors.green, child: Icon(Icons.add, color: Colors.white)),
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
            TextField(controller: idController, decoration: const InputDecoration(labelText: "ID Serial", hintText: "Ex: ESP32-001")),
            const SizedBox(height: 10),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: "Nome", hintText: "Ex: Jardim")),
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
                   _startTelemetryUpdates(newId);
                }
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red));
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
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (c) => const LoginScreen()), (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<String>>(
      stream: _deviceService.getUserDeviceIds(),
      builder: (context, snapshotList) {
        if (snapshotList.connectionState == ConnectionState.waiting) return const Scaffold(body: Center(child: CircularProgressIndicator()));

        final userDevices = snapshotList.data ?? [];

        if (userDevices.isEmpty) {
          return Scaffold(
            appBar: AppBar(
              title: const Text("AgroSmart V5"),
              backgroundColor: Colors.green, foregroundColor: Colors.white,
              actions: [
                 PopupMenuButton<String>(
                  onSelected: (value) { if (value == 'logout') _handleLogout(); },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'logout', child: Row(children: [Icon(Icons.logout, color: Colors.red), SizedBox(width: 8), Text("Sair da Conta")])),
                  ],
                  child: const Padding(padding: EdgeInsets.only(right: 16.0), child: CircleAvatar(backgroundColor: Colors.white24, child: Icon(Icons.person, color: Colors.white))),
                ),
              ],
            ),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_circle_outline, size: 80, color: Colors.green),
                  const SizedBox(height: 16),
                  const Text("Bem-vindo! Adicione seu primeiro dispositivo.", style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _showAddDeviceDialog,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                    child: const Text("ADICIONAR AGORA"),
                  )
                ],
              ),
            ),
          );
        }

        if (_selectedDeviceId == null || !userDevices.contains(_selectedDeviceId)) {
          Future.microtask(() {
            if (mounted) {
              setState(() {
                _selectedDeviceId = userDevices.first;
                _isLoadingTelemetry = true;
              });
              _startTelemetryUpdates(userDevices.first);
            }
          });
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        return StreamBuilder<DeviceModel>(
          stream: _deviceService.getDeviceStream(_selectedDeviceId!),
          builder: (context, snapshotDevice) {
            
            final device = snapshotDevice.data ?? DeviceModel(
              id: _selectedDeviceId!, isOnline: false, 
              settings: DeviceSettings(targetMoisture: 0, manualDuration: 0, deviceName: "Carregando...", timezoneOffset: -3)
            );

            final isReallyOnline = _isDeviceOnline;

            final List<Widget> pages = [
              _MonitorTab(
                device: device, 
                telemetryData: _telemetryData, 
                isLoading: _isLoadingTelemetry,
                onRefreshRequest: () => _fetchTelemetry(device.id)
              ),
              _SchedulesTab(device: device),
              HistoryTab(device: device),
              SettingsTab(device: device),
            ];

            return Scaffold(
              appBar: AppBar(
                backgroundColor: Colors.green, foregroundColor: Colors.white, elevation: 0, automaticallyImplyLeading: false,
                title: GestureDetector(
                  onTap: () => _showDevicePicker(userDevices),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.green[700], borderRadius: BorderRadius.circular(20)),
                      child: Row(children: [
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(device.settings.deviceName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          Row(children: [
                            Container(width: 8, height: 8, decoration: BoxDecoration(color: isReallyOnline ? Colors.lightGreenAccent : Colors.redAccent, shape: BoxShape.circle)),
                            const SizedBox(width: 4),
                            Text("${device.id} • ${isReallyOnline ? 'Online' : 'Offline'}", style: const TextStyle(fontSize: 10, color: Colors.white70)),
                          ]),
                        ]),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_drop_down, color: Colors.white)
                      ]),
                    ),
                  ]),
                ),
                actions: [
                  PopupMenuButton<String>(
                    onSelected: (value) { if (value == 'logout') _handleLogout(); },
                    itemBuilder: (context) => [
                      const PopupMenuItem(enabled: false, child: Text("Minha Conta", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'logout', child: Row(children: [Icon(Icons.logout, color: Colors.red, size: 20), SizedBox(width: 10), Text("Sair", style: TextStyle(color: Colors.red))])),
                    ],
                    child: const Padding(padding: EdgeInsets.only(right: 16.0), child: CircleAvatar(backgroundColor: Colors.white24, child: Icon(Icons.person, color: Colors.white))),
                  ),
                ],
              ),
              body: pages[_currentIndex],
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: _currentIndex, onTap: (index) => setState(() => _currentIndex = index),
                type: BottomNavigationBarType.fixed, selectedItemColor: Colors.green, unselectedItemColor: Colors.grey, showUnselectedLabels: true,
                items: const [
                  BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), activeIcon: Icon(Icons.dashboard), label: "Monitor"),
                  BottomNavigationBarItem(icon: Icon(Icons.calendar_month_outlined), activeIcon: Icon(Icons.calendar_month), label: "Agenda"),
                  BottomNavigationBarItem(icon: Icon(Icons.history), activeIcon: Icon(Icons.history), label: "Histórico"),
                  BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), activeIcon: Icon(Icons.settings), label: "Config"),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _MonitorTab extends StatefulWidget {
  final DeviceModel device;
  final TelemetryModel? telemetryData;
  final bool isLoading;
  final VoidCallback onRefreshRequest;

  const _MonitorTab({required this.device, required this.telemetryData, required this.isLoading, required this.onRefreshRequest});

  @override
  State<_MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<_MonitorTab> {
  final AwsService _awsService = AwsService();
  bool _isSendingCommand = false;

  Future<void> _sendManualIrrigation() async {
    if (_isSendingCommand) return;
    setState(() => _isSendingCommand = true);

    try {
      final int durationMinutes = widget.device.settings.manualDuration;
      final int durationSeconds = durationMinutes * 60;
      final success = await _awsService.sendCommand(widget.device.id, "on", durationSeconds);
      if (!mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("✅ Comando enviado! Irrigando por $durationMinutes min."), backgroundColor: Colors.green));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("❌ Falha no comando. Verifique a conexão."), backgroundColor: Colors.red));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isSendingCommand = false);
    }
  }

  String _formatLastUpdate(DateTime utcTime) {
    final localTime = utcTime.add(Duration(hours: widget.device.settings.timezoneOffset));
    return DateFormat('dd/MM HH:mm:ss').format(localTime);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) return const Center(child: CircularProgressIndicator(color: Colors.green));

    final data = widget.telemetryData;
    if (data == null) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.cloud_off, size: 60, color: Colors.grey),
          const SizedBox(height: 16),
          const Text("Sem dados recentes.", style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 10),
          ElevatedButton(onPressed: widget.onRefreshRequest, child: const Text("Tentar Novamente"))
        ]),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => widget.onRefreshRequest(),
      color: Colors.green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Usa a constante corrigida
            Text("Atualizando a cada $refreshIntervalSeconds s • Última: ${_formatLastUpdate(data.timestamp)}", textAlign: TextAlign.right, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(height: 10),
            _buildSectionTitle("Ambiente & Solo"),
            Card(
              elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  _SensorWidget(icon: Icons.thermostat, value: "${data.airTemp.toStringAsFixed(1)}°C", label: "Temp Ar", color: Colors.orange),
                  _SensorWidget(icon: Icons.water_drop_outlined, value: "${data.airHumidity.toStringAsFixed(0)}%", label: "Umid. Ar", color: Colors.blueAccent),
                  _SensorWidget(icon: Icons.grass, value: "${data.soilMoisture.toStringAsFixed(0)}%", label: "Umid. Solo", color: Colors.brown),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            _buildSectionTitle("Externo"),
            Card(
              elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  _SensorWidget(icon: Icons.wb_sunny, value: data.uvIndex.toStringAsFixed(1), label: "Índice UV", color: Colors.amber),
                  _SensorWidget(icon: Icons.light_mode, value: data.lightLevel.toStringAsFixed(0), label: "Luz (Lux)", color: Colors.yellow[700]!),
                  _SensorWidget(icon: Icons.cloud, value: "${data.rainRaw}", label: "Chuva (Raw)", color: Colors.blueGrey),
                ]),
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionTitle("Ações"),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isSendingCommand ? null : _sendManualIrrigation,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue, foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.blue.withValues(alpha: 0.6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
                ),
                child: _isSendingCommand
                  ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.water), const SizedBox(width: 8), 
                      Text("IRRIGAÇÃO MANUAL (${widget.device.settings.manualDuration} min)")
                    ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(padding: const EdgeInsets.only(left: 8, bottom: 8), child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54)));
  }
}

class _SchedulesTab extends StatelessWidget {
  final DeviceModel device;
  final SchedulesService _service = SchedulesService();

  _SchedulesTab({required this.device});

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
        onPressed: () {
          Navigator.push(context, MaterialPageRoute(builder: (context) => ScheduleFormScreen(deviceId: device.id)));
        },
        label: const Text("Novo"), icon: const Icon(Icons.add), backgroundColor: Colors.green,
      ),
      body: StreamBuilder<List<ScheduleModel>>(
        stream: _service.getSchedules(device.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Text("Erro: ${snapshot.error}"));

          final schedules = snapshot.data ?? [];

          if (schedules.isEmpty) {
            return const Center(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.calendar_month_outlined, size: 60, color: Colors.grey),
                SizedBox(height: 10), Text("Nenhum agendamento criado."),
              ]),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 80, top: 10),
            itemCount: schedules.length,
            itemBuilder: (context, index) {
              final schedule = schedules[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => ScheduleFormScreen(deviceId: device.id, scheduleToEdit: schedule)));
                  },
                  leading: CircleAvatar(backgroundColor: schedule.isEnabled ? Colors.green[100] : Colors.grey[200], child: Icon(Icons.alarm, color: schedule.isEnabled ? Colors.green : Colors.grey)),
                  title: Text("${schedule.time} - ${schedule.label}", style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("${_formatDays(schedule.days)}\nDuração: ${schedule.durationMinutes} min"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: schedule.isEnabled,
                        // CORREÇÃO: Usando activeTrackColor (Flutter novo)
                        activeTrackColor: Colors.green, 
                        activeColor: Colors.white,
                        onChanged: (val) {
                          _service.toggleEnabled(device.id, schedule.id, val).catchError((e) {
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red));
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
                                TextButton(onPressed: () { _service.deleteSchedule(device.id, schedule.id); Navigator.pop(ctx); }, child: const Text("Excluir", style: TextStyle(color: Colors.red)))
                              ],
                            )
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

class _SensorWidget extends StatelessWidget {
  final IconData icon; final String value; final String label; final Color color;
  
  const _SensorWidget({required this.icon, required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle), child: Icon(icon, color: color, size: 28)),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    ]);
  }
}