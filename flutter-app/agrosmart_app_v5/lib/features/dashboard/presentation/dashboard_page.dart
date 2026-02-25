// ARQUIVO: lib/features/dashboard/presentation/dashboard_page.dart

import 'package:flutter/material.dart';

import '../../../models/device_model.dart';
import '../../../services/device_service.dart';
import '../../../services/auth_service.dart';

import '../../settings/presentation/settings_tab.dart';
import '../../history/presentation/history_tab.dart';


import '../../monitor/presentation/monitor_tab.dart';
import '../../schedules/presentation/schedules_tab.dart';
import 'widgets/device_picker_sheet.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final DeviceService _deviceService = DeviceService();
  final AuthService _authService = AuthService();

  String? _selectedDeviceId;
  int _currentIndex = 0;

  void _onTabTapped(int index) {
    setState(() => _currentIndex = index);
  }

  void _showDevicePicker(List<String> userDevices) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DevicePickerSheet(
        userDevices: userDevices,
        selectedDeviceId: _selectedDeviceId,
        onDeviceSelected: (deviceId) {
          setState(() => _selectedDeviceId = deviceId);
          Navigator.pop(ctx);
        },
        onAddDeviceSelected: () {
          Navigator.pop(ctx);
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted) _showAddDeviceDialog();
          });
        },
      ),
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
            TextField(controller: idController, decoration: const InputDecoration(labelText: "ID Serial")),
            const SizedBox(height: 10),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: "Nome")),
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
                  setState(() => _selectedDeviceId = idController.text.trim());
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
            appBar: AppBar(title: const Text("AgroSmart V5")),
            body: Center(child: ElevatedButton(onPressed: _showAddDeviceDialog, child: const Text("ADICIONAR AGORA"))),
          );
        }

        if (_selectedDeviceId == null || !userDevices.contains(_selectedDeviceId)) {
          Future.microtask(() { if (mounted) setState(() => _selectedDeviceId = userDevices.first); });
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        return StreamBuilder<DeviceModel>(
          stream: _deviceService.getDeviceStream(_selectedDeviceId!),
          builder: (context, snapshotDevice) {
            final device = snapshotDevice.data ?? DeviceModel(id: _selectedDeviceId!, isOnline: false, settings: DeviceSettings(targetMoisture: 0, manualDuration: 0, deviceName: "Carregando...", timezoneOffset: -3, capabilities: []));
            
            final List<Widget> pages = [
              MonitorTab(device: device), // O Monitor agora cuida de si mesmo!
              SchedulesTab(device: device),
              HistoryTab(device: device),
              SettingsTab(device: device),
            ];

            return Scaffold(
              appBar: AppBar(
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
                                Text(device.settings.deviceName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                Row(
                                  children: [
                                    Container(width: 8, height: 8, decoration: BoxDecoration(color: device.isOnline ? Colors.lightGreenAccent : Colors.redAccent, shape: BoxShape.circle)),
                                    const SizedBox(width: 4),
                                    Text("${device.id} • ${device.isOnline ? 'Online' : 'Offline'}", style: const TextStyle(fontSize: 10, color: Colors.white70)),
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