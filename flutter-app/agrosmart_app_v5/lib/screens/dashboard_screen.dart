import 'dart:async'; // Para o Timer de atualização automática
import 'package:flutter/material.dart'; // Componentes visuais do Flutter
import 'package:intl/intl.dart'; // Para formatar datas e horas

// --- IMPORTAÇÕES DOS NOSSOS MÓDULOS ---
import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../models/schedule_model.dart'; // Novo: Modelo de Agendamento

import '../services/aws_service.dart';
import '../services/schedules_service.dart'; // Novo: Serviço do Firebase

import 'schedule_form_screen.dart'; // Novo: Tela de criar agendamento

/// TELA PRINCIPAL (DASHBOARD)
/// Gerencia as 4 abas principais: Monitor, Agenda, Histórico, Configurações
class DashboardScreen extends StatefulWidget {
  final DeviceModel device;

  const DashboardScreen({super.key, required this.device});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0; // Controla qual aba está visível

  @override
  Widget build(BuildContext context) {
    // Lista das páginas (Abas)
    final List<Widget> pages = [
      _MonitorTab(device: widget.device),   // Aba 0: Monitoramento AWS
      _SchedulesTab(device: widget.device), // Aba 1: Agendamentos Firebase (ATUALIZADO)
      _HistoryTab(device: widget.device),   // Aba 2: Histórico (Futuro)
      _SettingsTab(device: widget.device),  // Aba 3: Configurações (Futuro)
    ];

    return Scaffold(
      // --- APP BAR (CABEÇALHO) ---
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
          // Indicador de Status (Online/Offline)
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
      
      // --- CORPO DA TELA (Muda conforme a aba) ---
      body: pages[_currentIndex],

      // --- BARRA DE NAVEGAÇÃO INFERIOR ---
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed, // Impede animação de "dança" dos ícones
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
// 🟢 ABA 1: MONITORAMENTO (AWS + Controle Manual)
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
  bool _isLoadingData = true;     // Loading inicial
  bool _isSendingCommand = false; // Loading do botão
  String _errorMessage = '';      // Mensagem de erro
  Timer? _timer;                  // Atualização automática

  @override
  void initState() {
    super.initState();
    _fetchData();
    // Atualiza a cada 30 segundos
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) => _fetchData());
  }

  @override
  void dispose() {
    _timer?.cancel(); // Limpa timer ao sair
    super.dispose();
  }

  /// Busca dados na AWS (GET)
  Future<void> _fetchData() async {
    if (!mounted) return;
    if (_data == null) {
      setState(() { _isLoadingData = true; _errorMessage = ''; });
    }

    try {
      final data = await _awsService.getLatestTelemetry(widget.device.id);
      if (mounted) {
        setState(() {
          _data = data;
          _isLoadingData = false;
          if (data == null) _errorMessage = "Dispositivo conectado, mas sem dados recentes.";
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

  /// Envia comando manual (POST)
  Future<void> _sendManualIrrigation() async {
    if (_isSendingCommand) return;
    setState(() => _isSendingCommand = true);

    try {
      // Envia "on" para a Lambda
      final success = await _awsService.sendCommand(widget.device.id, "on", 300);

      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("✅ Comando enviado! Irrigação iniciará em breve."),
          backgroundColor: Colors.green,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("❌ Falha no comando. Verifique conexão."),
          backgroundColor: Colors.red,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red)
      );
    } finally {
      if (mounted) setState(() => _isSendingCommand = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingData) return const Center(child: CircularProgressIndicator(color: Colors.green));

    if ((_errorMessage.isNotEmpty && _data == null) || (_data == null && _errorMessage.isEmpty)) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 60, color: Colors.grey),
            const SizedBox(height: 16),
            Text(_errorMessage.isEmpty ? "Sem dados." : _errorMessage, style: const TextStyle(color: Colors.grey)),
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
            Text("Atualizando a cada 30s • Última: ${dateFormat.format(_data!.timestamp)}", 
              textAlign: TextAlign.right, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(height: 10),

            // Card 1: Ambiente
            _buildSectionTitle("Ambiente & Solo"),
            Card(
              elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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

            // Card 2: Externo
            _buildSectionTitle("Externo"),
            Card(
              elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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

            // Botão de Ação
            _buildSectionTitle("Ações"),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isSendingCommand ? null : _sendManualIrrigation,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue, foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.blue.withValues(alpha: 0.6),
                ),
                child: _isSendingCommand
                  ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.water), SizedBox(width: 8), Text("IRRIGAÇÃO MANUAL (5 min)")]),
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

// ==============================================================================
// 📅 ABA 2: AGENDAMENTOS (Firebase Firestore) - ATUALIZADA!
// ==============================================================================

class _SchedulesTab extends StatelessWidget {
  final DeviceModel device;
  final SchedulesService _service = SchedulesService(); // Instância do Serviço

  _SchedulesTab({required this.device});

  // Função auxiliar para transformar [1, 3, 5] em "Seg, Qua, Sex"
  String _formatDays(List<int> days) {
    if (days.length == 7) return "Todos os dias";
    if (days.isEmpty) return "Nenhum dia selecionado";
    const map = {1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sáb', 7: 'Dom'};
    // Ordena os dias e mapeia para os nomes
    final sortedDays = List<int>.from(days)..sort();
    return sortedDays.map((d) => map[d]).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold interno para poder usar o FloatingActionButton apenas nesta aba
    return Scaffold(
      backgroundColor: Colors.transparent, // Usa o fundo da tela principal
      
      // Botão Flutuante (+) para criar novo agendamento
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // Navega para a tela de formulário
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ScheduleFormScreen(deviceId: device.id),
            ),
          );
        },
        label: const Text("Novo"),
        icon: const Icon(Icons.add),
        backgroundColor: Colors.green,
      ),
      
      // Lista de Agendamentos (StreamBuilder ouve o Firestore em tempo real)
      body: StreamBuilder<List<ScheduleModel>>(
        stream: _service.getSchedules(device.id),
        builder: (context, snapshot) {
          // Estado 1: Carregando
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          // Estado 2: Erro
          if (snapshot.hasError) {
            return Center(child: Text("Erro ao carregar: ${snapshot.error}"));
          }

          final schedules = snapshot.data ?? [];

          // Estado 3: Lista Vazia
          if (schedules.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.calendar_month_outlined, size: 60, color: Colors.grey),
                  SizedBox(height: 10),
                  Text("Nenhum agendamento criado.", style: TextStyle(fontSize: 16)),
                  Text("Toque em 'Novo' para automatizar.", style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          // Estado 4: Lista com Dados
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 80, top: 10), // Espaço para o botão flutuante não tapar o último item
            itemCount: schedules.length,
            itemBuilder: (context, index) {
              final schedule = schedules[index];
              
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  // Ícone lateral: Verde se ativado, Cinza se desativado
                  leading: CircleAvatar(
                    backgroundColor: schedule.isEnabled ? Colors.green[100] : Colors.grey[200],
                    child: Icon(
                      Icons.alarm, 
                      color: schedule.isEnabled ? Colors.green : Colors.grey
                    ),
                  ),
                  
                  // Título: Hora e Nome
                  title: Text(
                    "${schedule.time} - ${schedule.label}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  
                  // Subtítulo: Dias da semana e Duração
                  subtitle: Text(
                    "${_formatDays(schedule.days)}\nDuração: ${schedule.durationMinutes} min",
                    style: TextStyle(color: Colors.grey[700]),
                  ),
                  
                  // Ações (Direita): Switch e Lixeira
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Toggle: Ativar/Desativar
                      Switch(
                        value: schedule.isEnabled,
                        activeColor: Colors.green,
                        onChanged: (val) {
                          _service.toggleEnabled(device.id, schedule.id, val);
                        },
                      ),
                      // Delete: Excluir
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        onPressed: () {
                          // Confirmação antes de deletar
                          showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text("Excluir Agendamento?"),
                              content: const Text("Essa ação não pode ser desfeita."),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
                                TextButton(
                                  onPressed: () {
                                    _service.deleteSchedule(device.id, schedule.id);
                                    Navigator.pop(ctx);
                                  },
                                  child: const Text("Excluir", style: TextStyle(color: Colors.red)),
                                )
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

// ==============================================================================
// 📊 ABA 3 E 4: PLACEHOLDERS (Histórico e Configurações)
// ==============================================================================

class _HistoryTab extends StatelessWidget { 
  final DeviceModel device; 
  const _HistoryTab({required this.device}); 
  @override Widget build(BuildContext context) => const Center(child: Text("Histórico (Em Breve)")); 
}

class _SettingsTab extends StatelessWidget { 
  final DeviceModel device; 
  const _SettingsTab({required this.device}); 
  @override Widget build(BuildContext context) => const Center(child: Text("Configurações (Em Breve)")); 
}

// ==============================================================================
// WIDGETS AUXILIARES REUTILIZÁVEIS
// ==============================================================================

class _SensorWidget extends StatelessWidget {
  final IconData icon; final String value; final String label; final Color color;
  const _SensorWidget({required this.icon, required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 28),
        ),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}