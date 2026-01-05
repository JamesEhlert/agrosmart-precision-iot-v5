// ARQUIVO: lib/screens/settings_tab.dart

import 'package:flutter/material.dart';
import '../models/device_model.dart';
import '../services/device_service.dart';

class SettingsTab extends StatefulWidget {
  final DeviceModel device;

  const SettingsTab({super.key, required this.device});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _formKey = GlobalKey<FormState>();
  final _deviceService = DeviceService();

  // Controladores e Variáveis de Estado
  late TextEditingController _nameController;
  late double _targetMoisture;
  late double _manualDuration;
  late int _timezoneOffset;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Inicializa os campos com os valores atuais do dispositivo
    final settings = widget.device.settings;
    _nameController = TextEditingController(text: settings.deviceName);
    _targetMoisture = settings.targetMoisture;
    _manualDuration = settings.manualDuration.toDouble();
    _timezoneOffset = settings.timezoneOffset;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // Função para salvar no Firebase
  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final newSettings = DeviceSettings(
        deviceName: _nameController.text.trim(),
        targetMoisture: _targetMoisture,
        manualDuration: _manualDuration.toInt(),
        timezoneOffset: _timezoneOffset,
      );

      await _deviceService.updateDeviceSettings(widget.device.id, newSettings);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Configurações salvas com sucesso!"), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erro ao salvar: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50], // Fundo levemente cinza
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSectionHeader("Identificação"),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: "Nome do Dispositivo",
                      hintText: "Ex: Horta dos Fundos",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.edit),
                    ),
                    validator: (val) => val == null || val.isEmpty ? "O nome não pode ser vazio" : null,
                  ),
                ),
              ),

              const SizedBox(height: 20),
              _buildSectionHeader("Parâmetros de Irrigação"),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // --- SLIDER DE UMIDADE ---
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Umidade Alvo (Max)", style: TextStyle(fontWeight: FontWeight.bold)),
                          Chip(label: Text("${_targetMoisture.toInt()}%"), backgroundColor: Colors.blue[100]),
                        ],
                      ),
                      const Text(
                        "Se o solo estiver acima deste valor, agendamentos serão ignorados para economizar água.",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      Slider(
                        value: _targetMoisture,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        activeColor: Colors.blue,
                        label: "${_targetMoisture.toInt()}%",
                        onChanged: (val) => setState(() => _targetMoisture = val),
                      ),

                      const Divider(height: 30),

                      // --- SLIDER DE DURAÇÃO MANUAL ---
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Tempo Rega Manual", style: TextStyle(fontWeight: FontWeight.bold)),
                          Chip(label: Text("${_manualDuration.toInt()} min"), backgroundColor: Colors.orange[100]),
                        ],
                      ),
                      const Text(
                        "Duração ao clicar no botão 'Irrigação Manual' na tela inicial.",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      Slider(
                        value: _manualDuration,
                        min: 1,
                        max: 60,
                        divisions: 59,
                        activeColor: Colors.orange,
                        label: "${_manualDuration.toInt()} min",
                        onChanged: (val) => setState(() => _manualDuration = val),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
              _buildSectionHeader("Localização & Hora"),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Fuso Horário (UTC)", style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _timezoneOffset,
                            isExpanded: true,
                            items: [
                              const DropdownMenuItem(value: 0, child: Text("UTC +00:00 (Londres)")),
                              const DropdownMenuItem(value: -3, child: Text("UTC -03:00 (Brasília)")),
                              const DropdownMenuItem(value: -4, child: Text("UTC -04:00 (Amazonas)")),
                              const DropdownMenuItem(value: -5, child: Text("UTC -05:00 (Nova York)")),
                              const DropdownMenuItem(value: 1, child: Text("UTC +01:00 (Berlim)")),
                              // Você pode adicionar mais fusos conforme a necessidade
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _timezoneOffset = val);
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Configurado atualmente: UTC ${_timezoneOffset >= 0 ? '+' : ''}$_timezoneOffset",
                        style: TextStyle(fontSize: 12, color: Colors.green[700]),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 30),

              // --- BOTÃO SALVAR ---
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _saveSettings,
                  icon: const Icon(Icons.save),
                  label: _isLoading 
                      ? const CircularProgressIndicator(color: Colors.white) 
                      : const Text("SALVAR ALTERAÇÕES"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 14, 
          fontWeight: FontWeight.bold, 
          color: Colors.grey,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}