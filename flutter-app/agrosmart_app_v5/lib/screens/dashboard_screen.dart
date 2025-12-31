import 'dart:async'; // Necessário para o Timer
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../services/aws_service.dart';

class DashboardScreen extends StatefulWidget {
  final DeviceModel device;

  const DashboardScreen({super.key, required this.device});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    // Lista de abas (Telas)
    final List<Widget> pages = [
      _MonitorTab(device: widget.device),   // Aba 0: Monitoramento (AWS)
      _SchedulesTab(device: widget.device), // Aba 1: Agendamentos
      _HistoryTab(device: widget.device),   // Aba 2: Histórico
      _SettingsTab(device: widget.device),  // Aba 3: Configurações
    ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.device.settings.deviceName, style: const TextStyle(fontSize: 18)),
            Text(widget.device.id, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          // Indicador de Online/Offline
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: widget.device.isOnline ? Colors.greenAccent : Colors.redAccent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.device.isOnline ? "ONLINE" : "OFFLINE",
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
              ),
            ),
          )
        ],
      ),
      body: pages[_currentIndex], // Mostra a tela selecionada
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.green,
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), activeIcon: Icon(Icons.dashboard), label: "Monitor"),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month_outlined), activeIcon: Icon(Icons.calendar_month), label: "Agenda"),
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: "Histórico"),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), activeIcon: Icon(Icons.settings), label: "Config"),
        ],
      ),
    );
  }
}

// ==============================================================================
// ABA 1: MONITORAMENTO (Integração com AWS + Auto Update)
// ==============================================================================

class _MonitorTab extends StatefulWidget {
  final DeviceModel device;
  const _MonitorTab({required this.device});

  @override
  State<_MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<_MonitorTab> {
  final AwsService _awsService = AwsService();
  TelemetryModel? _data;
  bool _isLoading = true;
  String _errorMessage = '';
  Timer? _timer; // Variável para controlar o relógio de atualização

  @override
  void initState() {
    super.initState();
    // 1. Busca os dados imediatamente ao abrir
    _fetchData();

    // 2. Configura o timer para atualizar a cada 30 segundos
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _fetchData();
    });
  }

  @override
  void dispose() {
    // 3. Cancela o timer quando sair da tela para não gastar bateria/memória
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchData() async {
    if (!mounted) return;

    // Só mostra o loading girando se for a primeira vez (tela vazia)
    // Nas atualizações automáticas (Timer), atualizamos silenciosamente
    if (_data == null) {
      setState(() {
        _isLoading = true;
        _errorMessage = '';
      });
    }

    try {
      final data = await _awsService.getLatestTelemetry(widget.device.id);
      
      if (mounted) {
        setState(() {
          _data = data;
          _isLoading = false;
          if (data == null) {
            _errorMessage = "Dispositivo conectado, mas sem dados recentes.";
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          // Só mostra erro na tela se não tivermos dados antigos para mostrar
          if (_data == null) {
            _errorMessage = "Erro de conexão.";
          }
        });
      }
    }
  }

  Future<void> _sendManualIrrigation() async {
    // Aqui implementaremos a lógica real de envio no futuro
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Enviando comando para AWS...")),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.green));
    }

    // Se houve erro ou não tem dados
    if (_errorMessage.isNotEmpty || _data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 60, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                _errorMessage.isEmpty ? "Sem dados." : _errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _fetchData,
                icon: const Icon(Icons.refresh),
                label: const Text("Tentar Novamente"),
              )
            ],
          ),
        ),
      );
    }

    // Formatação da data
    final dateFormat = DateFormat('dd/MM HH:mm:ss');

    // --- TELA DO DASHBOARD ---
    return RefreshIndicator(
      onRefresh: _fetchData, // Permite puxar pra baixo manualmente também
      color: Colors.green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status da atualização
            Text(
              "Atualizando a cada 30s • Última: ${dateFormat.format(_data!.timestamp)}",
              textAlign: TextAlign.right,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 10),

            // CARD 1: AMBIENTE E SOLO
            _buildSectionTitle("Ambiente & Solo"),
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _SensorWidget(
                      icon: Icons.thermostat,
                      value: "${_data!.airTemp.toStringAsFixed(1)}°C",
                      label: "Temp Ar",
                      color: Colors.orange,
                    ),
                    _SensorWidget(
                      icon: Icons.water_drop_outlined,
                      value: "${_data!.airHumidity.toStringAsFixed(0)}%",
                      label: "Umid. Ar",
                      color: Colors.blueAccent,
                    ),
                    _SensorWidget(
                      icon: Icons.grass,
                      value: "${_data!.soilMoisture.toStringAsFixed(0)}%",
                      label: "Umid. Solo",
                      color: Colors.brown,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // CARD 2: EXTERNO (Luz, UV, Chuva)
            _buildSectionTitle("Externo"),
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _SensorWidget(
                      icon: Icons.wb_sunny,
                      value: _data!.uvIndex.toStringAsFixed(1),
                      label: "Índice UV",
                      color: Colors.amber,
                    ),
                    _SensorWidget(
                      icon: Icons.light_mode,
                      value: _data!.lightLevel.toStringAsFixed(0),
                      label: "Luz (Lux)",
                      color: Colors.yellow[700]!,
                    ),
                    _SensorWidget(
                      icon: Icons.cloud,
                      value: "${_data!.rainRaw}",
                      label: "Chuva (Raw)",
                      color: Colors.blueGrey,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),
            
            // CARD 3: AÇÕES
            _buildSectionTitle("Ações"),
            SizedBox(
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _sendManualIrrigation,
                icon: const Icon(Icons.water),
                label: const Text("IRRIGAÇÃO MANUAL (5 min)"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54)),
    );
  }
}

// Widget auxiliar para desenhar os ícones dos sensores
class _SensorWidget extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _SensorWidget({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            // Atualizado para usar withValues (substituto moderno do withOpacity)
            color: color.withValues(alpha: 0.15), 
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 28),
        ),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

// ==============================================================================
// OUTRAS ABAS (Placeholders)
// ==============================================================================

class _SchedulesTab extends StatelessWidget {
  final DeviceModel device;
  const _SchedulesTab({required this.device});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Lista de Agendamentos\n(Em Breve)"));
  }
}

class _HistoryTab extends StatelessWidget {
  final DeviceModel device;
  const _HistoryTab({required this.device});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Gráficos e Histórico\n(Em Breve)"));
  }
}

class _SettingsTab extends StatelessWidget {
  final DeviceModel device;
  const _SettingsTab({required this.device});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Configurações do Dispositivo\n(Em Breve)"));
  }
}