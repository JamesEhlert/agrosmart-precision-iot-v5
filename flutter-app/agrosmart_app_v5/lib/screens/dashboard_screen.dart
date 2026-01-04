import 'dart:async'; // Necessário para o Timer (atualização automática)
import 'package:flutter/material.dart'; // Biblioteca de UI do Flutter
import 'package:intl/intl.dart'; // Biblioteca para formatar datas

// Importações dos modelos e serviços
import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../services/aws_service.dart';

/// Tela Principal de Controle do Dispositivo (Dashboard)
class DashboardScreen extends StatefulWidget {
  final DeviceModel device;

  const DashboardScreen({super.key, required this.device});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0; // Índice da aba selecionada

  @override
  Widget build(BuildContext context) {
    // Lista de telas correspondentes a cada aba
    final List<Widget> pages = [
      _MonitorTab(device: widget.device),   // Aba 0: Monitoramento (Corrigida)
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
          // Status (Online/Offline)
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
      body: pages[_currentIndex],
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
// ABA 1: MONITORAMENTO
// ==============================================================================

class _MonitorTab extends StatefulWidget {
  final DeviceModel device;
  const _MonitorTab({required this.device});

  @override
  State<_MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<_MonitorTab> {
  final AwsService _awsService = AwsService();
  
  TelemetryModel? _data;          // Dados dos sensores
  bool _isLoadingData = true;     // Loading dos dados
  bool _isSendingCommand = false; // Loading do botão de comando
  String _errorMessage = '';      // Mensagem de erro
  Timer? _timer;                  // Timer para auto-update

  @override
  void initState() {
    super.initState();
    _fetchData();
    // Atualiza a cada 30 segundos
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) => _fetchData());
  }

  @override
  void dispose() {
    _timer?.cancel(); // Limpa o timer ao sair
    super.dispose();
  }

  /// Busca dados na AWS
  Future<void> _fetchData() async {
    if (!mounted) return;

    // Apenas mostra loading visual se for a primeira carga
    if (_data == null) {
      setState(() {
        _isLoadingData = true;
        _errorMessage = '';
      });
    }

    try {
      final data = await _awsService.getLatestTelemetry(widget.device.id);
      
      if (mounted) {
        setState(() {
          _data = data;
          _isLoadingData = false;
          if (data == null) {
            _errorMessage = "Dispositivo conectado, mas sem dados recentes.";
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingData = false;
          if (_data == null) _errorMessage = "Erro de conexão.";
        });
      }
    }
  }

  /// Envia comando de irrigação (AJUSTADO PARA O SEU POSTMAN)
  Future<void> _sendManualIrrigation() async {
    if (_isSendingCommand) return; // Evita cliques duplos

    setState(() => _isSendingCommand = true);

    try {
      // CORREÇÃO: Enviando "on" em vez de "OPEN_VALVE"
      // Mantive 300 segundos (5 min) pois é o padrão do botão, mas você pode mudar para 10 se quiser testar
      final success = await _awsService.sendCommand(
        widget.device.id, 
        "on",  // <--- AQUI ESTAVA A DIFERENÇA
        300    // Duração em segundos
      );

      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ Comando enviado! A irrigação deve iniciar."),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("❌ A API rejeitou o comando. Verifique logs."),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro técnico: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSendingCommand = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingData) return const Center(child: CircularProgressIndicator(color: Colors.green));

    // Exibe erro apenas se não houver dados antigos em cache
    if ((_errorMessage.isNotEmpty && _data == null) || (_data == null && _errorMessage.isEmpty)) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 60, color: Colors.grey),
            const SizedBox(height: 16),
            Text(_errorMessage.isEmpty ? "Sem dados recebidos." : _errorMessage, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _fetchData, child: const Text("Tentar Novamente"))
          ],
        ),
      );
    }

    final dateFormat = DateFormat('dd/MM HH:mm:ss');

    return RefreshIndicator(
      onRefresh: _fetchData,
      color: Colors.green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status do Update
            Text(
              "Atualizando a cada 30s • Última: ${dateFormat.format(_data!.timestamp)}",
              textAlign: TextAlign.right,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 10),

            // --- BLOCO 1: AMBIENTE ---
            _buildSectionTitle("Ambiente & Solo"),
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _SensorWidget(icon: Icons.thermostat, value: "${_data!.airTemp.toStringAsFixed(1)}°C", label: "Temp Ar", color: Colors.orange),
                    _SensorWidget(icon: Icons.water_drop_outlined, value: "${_data!.airHumidity.toStringAsFixed(0)}%", label: "Umid. Ar", color: Colors.blueAccent),
                    _SensorWidget(icon: Icons.grass, value: "${_data!.soilMoisture.toStringAsFixed(0)}%", label: "Umid. Solo", color: Colors.brown),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // --- BLOCO 2: EXTERNO ---
            _buildSectionTitle("Externo"),
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _SensorWidget(icon: Icons.wb_sunny, value: _data!.uvIndex.toStringAsFixed(1), label: "Índice UV", color: Colors.amber),
                    _SensorWidget(icon: Icons.light_mode, value: _data!.lightLevel.toStringAsFixed(0), label: "Luz (Lux)", color: Colors.yellow[700]!),
                    _SensorWidget(icon: Icons.cloud, value: "${_data!.rainRaw}", label: "Chuva (Raw)", color: Colors.blueGrey),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),
            
            // --- BLOCO 3: BOTÃO DE AÇÃO ---
            _buildSectionTitle("Ações"),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isSendingCommand ? null : _sendManualIrrigation,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.blue.withValues(alpha: 0.6),
                ),
                child: _isSendingCommand
                    ? const SizedBox(
                        height: 24, width: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.water),
                          SizedBox(width: 8),
                          Text("IRRIGAÇÃO MANUAL (5 min)"),
                        ],
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

class _SensorWidget extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _SensorWidget({required this.icon, required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
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

// Placeholders para outras abas
class _SchedulesTab extends StatelessWidget { final DeviceModel device; const _SchedulesTab({required this.device}); @override Widget build(BuildContext context) => const Center(child: Text("Agendas")); }
class _HistoryTab extends StatelessWidget { final DeviceModel device; const _HistoryTab({required this.device}); @override Widget build(BuildContext context) => const Center(child: Text("Histórico")); }
class _SettingsTab extends StatelessWidget { final DeviceModel device; const _SettingsTab({required this.device}); @override Widget build(BuildContext context) => const Center(child: Text("Configs")); }