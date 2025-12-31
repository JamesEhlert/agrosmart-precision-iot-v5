import 'package:flutter/material.dart';
import '../models/device_model.dart';

class DashboardScreen extends StatefulWidget {
  final DeviceModel device;

  const DashboardScreen({super.key, required this.device});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0;

  // Lista de Telas para cada Aba
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      _MonitorTab(device: widget.device),   // Aba 0: Monitoramento (AWS)
      _SchedulesTab(device: widget.device), // Aba 1: Agendamentos (Firebase)
      _HistoryTab(device: widget.device),   // Aba 2: Histórico (AWS)
      _SettingsTab(device: widget.device),  // Aba 3: Configurações (Firebase)
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.settings.deviceName),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          // Indicador de Online/Offline no topo
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Icon(
              Icons.circle,
              color: widget.device.isOnline ? Colors.greenAccent : Colors.red,
              size: 16,
            ),
          )
        ],
      ),
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed, // Necessário para 4 itens
        selectedItemColor: Colors.green,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.speed), label: "Monitor"),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: "Agenda"),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: "Histórico"),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: "Config"),
        ],
      ),
    );
  }
}

// --- PLACEHOLDERS PARA AS ABAS (Vamos preencher depois) ---

class _MonitorTab extends StatelessWidget {
  final DeviceModel device;
  const _MonitorTab({required this.device});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_download, size: 80, color: Colors.green),
          const SizedBox(height: 20),
          Text("Aqui virão os dados da AWS para o ID:\n${device.id}", textAlign: TextAlign.center),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: (){}, child: const Text("Acionar Válvula (Manual)"))
        ],
      ),
    );
  }
}

class _SchedulesTab extends StatelessWidget {
  final DeviceModel device;
  const _SchedulesTab({required this.device});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Lista de Agendamentos (Firebase)"));
  }
}

class _HistoryTab extends StatelessWidget {
  final DeviceModel device;
  const _HistoryTab({required this.device});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Gráficos e Histórico Paginado (AWS)"));
  }
}

class _SettingsTab extends StatelessWidget {
  final DeviceModel device;
  const _SettingsTab({required this.device});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Configurações do Dispositivo (Firebase)"));
  }
}