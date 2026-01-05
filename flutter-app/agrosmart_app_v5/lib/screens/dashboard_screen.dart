// ARQUIVO: lib/screens/dashboard_screen.dart

import 'dart:async'; // Para o Timer de atualização automática da telemetria
import 'package:flutter/material.dart'; // Componentes visuais do Flutter
import 'package:intl/intl.dart'; // Para formatar datas e horas

// --- IMPORTAÇÕES DOS NOSSOS MÓDULOS ---
import '../models/device_model.dart';
import '../models/telemetry_model.dart';
import '../models/schedule_model.dart';

import '../services/aws_service.dart';
import '../services/schedules_service.dart';
import '../services/device_service.dart'; // IMPORTANTE: Para ouvir atualizações do device

import 'schedule_form_screen.dart'; // Tela de formulário de agendamento
import 'settings_tab.dart'; // Tela de configurações (Engrenagem)

/// ============================================================================
/// TELA PRINCIPAL (DASHBOARD)
/// Gerencia as 4 abas: Monitor, Agenda, Histórico, Configurações.
/// ============================================================================
class DashboardScreen extends StatefulWidget {
  final DeviceModel device; // Dispositivo inicial (passado pela lista)

  const DashboardScreen({super.key, required this.device});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0; // Controla qual aba está visível
  final DeviceService _deviceService = DeviceService(); // Para ouvir mudanças nas configurações

  @override
  Widget build(BuildContext context) {
    // 1. STREAM BUILDER GLOBAL
    // Envolvemos todo o Scaffold num StreamBuilder do Dispositivo.
    // Isso garante que se mudarmos o nome ou tempo de rega na aba Config,
    // a aba Monitor (e o cabeçalho) atualizam imediatamente.
    return StreamBuilder<DeviceModel>(
      stream: _deviceService.getDeviceStream(widget.device.id),
      initialData: widget.device, // Começa com os dados que já temos
      builder: (context, snapshot) {
        
        // Se houver erro ou estiver carregando sem dados, usamos o widget.device como fallback
        final device = snapshot.data ?? widget.device;

        // Lista das páginas (Abas) - Recriadas com os dados atualizados (device)
        final List<Widget> pages = [
          _MonitorTab(device: device),     // Aba 0: Monitoramento (Recebe device atualizado)
          _SchedulesTab(device: device),   // Aba 1: Agendamentos
          _HistoryTab(device: device),     // Aba 2: Histórico (Placeholder)
          SettingsTab(device: device),     // Aba 3: Configurações (Sua nova tela)
        ];

        return Scaffold(
          // --- CABEÇALHO (APP BAR) ---
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Nome do Dispositivo (Atualiza em tempo real se mudar nas configs)
                Text(device.settings.deviceName, style: const TextStyle(fontSize: 18)),
                Text(device.id, style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ],
            ),
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            elevation: 0,
            actions: [
              // Indicador de Status (Online/Offline)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: device.isOnline ? Colors.greenAccent : Colors.redAccent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      device.isOnline ? "ONLINE" : "OFFLINE",
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                  ),
                ),
              )
            ],
          ),

          // --- CORPO DA TELA ---
          body: pages[_currentIndex],

          // --- BARRA DE NAVEGAÇÃO INFERIOR ---
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
    );
  }
}

/// ============================================================================
/// 🟢 ABA 1: MONITORAMENTO (AWS + Controle Manual)
/// ============================================================================
class _MonitorTab extends StatefulWidget {
  final DeviceModel device;
  const _MonitorTab({required this.device});

  @override
  State<_MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<_MonitorTab> {
  final AwsService _awsService = AwsService();
  TelemetryModel? _data;          // Dados dos sensores vindos da AWS
  bool _isLoadingData = true;     // Loading inicial da telemetria
  bool _isSendingCommand = false; // Loading do botão de ação
  String _errorMessage = '';      // Mensagem de erro amigável
  Timer? _timer;                  // Timer para buscar dados periodicamente

  @override
  void initState() {
    super.initState();
    _fetchData();
    // Atualiza a cada 30 segundos automaticamente
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) => _fetchData());
  }

  @override
  void dispose() {
    _timer?.cancel(); // Importante: Parar o timer ao sair da tela para não gastar bateria
    super.dispose();
  }

  /// Busca dados na AWS (GET)
  Future<void> _fetchData() async {
    if (!mounted) return;
    // Só mostra loading na primeira vez, nas atualizações automáticas não
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
          // Só mostra erro se não tivermos dados antigos para mostrar
          if (_data == null) _errorMessage = "Erro de conexão.";
        });
      }
    }
  }

  /// Envia comando manual (POST) respeitando a configuração do usuário
  Future<void> _sendManualIrrigation() async {
    if (_isSendingCommand) return;
    setState(() => _isSendingCommand = true);

    try {
      // 1. Pega a duração configurada (em minutos) e converte para segundos
      final int durationMinutes = widget.device.settings.manualDuration;
      final int durationSeconds = durationMinutes * 60;

      // 2. Envia para a AWS
      final success = await _awsService.sendCommand(
        widget.device.id, 
        "on", 
        durationSeconds
      );

      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("✅ Comando enviado! Irrigando por $durationMinutes min."),
          backgroundColor: Colors.green,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("❌ Falha no comando. Verifique a conexão."),
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

  /// Auxiliar para formatar a data considerando o Fuso Horário Configurado
  String _formatLastUpdate(DateTime utcTime) {
    // Adiciona o offset (ex: -3 horas) ao horário UTC que veio da AWS
    final localTime = utcTime.add(Duration(hours: widget.device.settings.timezoneOffset));
    return DateFormat('dd/MM HH:mm:ss').format(localTime);
  }

  @override
  Widget build(BuildContext context) {
    // Exibe Loading Centralizado se não tiver dados ainda
    if (_isLoadingData) return const Center(child: CircularProgressIndicator(color: Colors.green));

    // Exibe Erro se falhou e não tem dados cache
    if ((_errorMessage.isNotEmpty && _data == null) || (_data == null && _errorMessage.isEmpty)) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 60, color: Colors.grey),
            const SizedBox(height: 16),
            Text(_errorMessage.isEmpty ? "Sem dados." : _errorMessage, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 10),
            ElevatedButton(onPressed: _fetchData, child: const Text("Tentar Novamente"))
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchData,
      color: Colors.green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(), // Permite arrastar pra atualizar mesmo se lista for pequena
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Texto de última atualização com Fuso Horário aplicado
            Text(
              "Atualizando a cada 30s • Última: ${_formatLastUpdate(_data!.timestamp)}",
              textAlign: TextAlign.right, 
              style: TextStyle(color: Colors.grey[600], fontSize: 12)
            ),
            const SizedBox(height: 10),

            // --- CARD 1: AMBIENTE ---
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

            // --- CARD 2: EXTERNO ---
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

            // --- BOTÃO DE AÇÃO DINÂMICO ---
            _buildSectionTitle("Ações"),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isSendingCommand ? null : _sendManualIrrigation,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue, 
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.blue.withOpacity(0.6), // Correção para versão nova do Flutter
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
                ),
                child: _isSendingCommand
                  ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center, 
                      children: [
                        const Icon(Icons.water), 
                        const SizedBox(width: 8), 
                        // TEXTO DINÂMICO: Mostra o tempo configurado pelo usuário
                        Text("IRRIGAÇÃO MANUAL (${widget.device.settings.manualDuration} min)")
                      ]
                    ),
              ),
            ),
            
            const SizedBox(height: 8),
            Center(child: Text("Tempo configurável na aba Configurações", style: TextStyle(fontSize: 10, color: Colors.grey[400]))),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8), 
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54))
    );
  }
}

/// ============================================================================
/// 📅 ABA 2: AGENDAMENTOS (Firebase Firestore)
/// ============================================================================
class _SchedulesTab extends StatelessWidget {
  final DeviceModel device;
  final SchedulesService _service = SchedulesService();

  _SchedulesTab({required this.device}); // Removi o 'const' pois instanciamos _service

  // Formata lista de dias [1,3] -> "Seg, Qua"
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
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => ScheduleFormScreen(deviceId: device.id)),
          );
        },
        label: const Text("Novo"),
        icon: const Icon(Icons.add),
        backgroundColor: Colors.green,
      ),

      body: StreamBuilder<List<ScheduleModel>>(
        stream: _service.getSchedules(device.id),
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
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ScheduleFormScreen(
                          deviceId: device.id,
                          scheduleToEdit: schedule,
                        ),
                      ),
                    );
                  },
                  leading: CircleAvatar(
                    backgroundColor: schedule.isEnabled ? Colors.green[100] : Colors.grey[200],
                    child: Icon(Icons.alarm, color: schedule.isEnabled ? Colors.green : Colors.grey),
                  ),
                  title: Text(
                    "${schedule.time} - ${schedule.label}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    "${_formatDays(schedule.days)}\nDuração: ${schedule.durationMinutes} min",
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: schedule.isEnabled,
                        activeColor: Colors.green,
                        onChanged: (val) {
                          _service.toggleEnabled(device.id, schedule.id, val).catchError((e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red)
                            );
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

/// ============================================================================
/// 📊 ABAS PLACEHOLDER (Histórico)
/// ============================================================================
class _HistoryTab extends StatelessWidget {
  final DeviceModel device;
  const _HistoryTab({required this.device});
  @override Widget build(BuildContext context) => const Center(child: Text("Histórico (Em Breve)"));
}

/// ============================================================================
/// 🧩 WIDGETS AUXILIARES
/// ============================================================================
class _SensorWidget extends StatelessWidget {
  final IconData icon; 
  final String value; 
  final String label; 
  final Color color;
  
  const _SensorWidget({
    required this.icon, 
    required this.value, 
    required this.label, 
    required this.color
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 28),
        ),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}