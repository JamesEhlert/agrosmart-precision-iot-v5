// ARQUIVO: lib/features/settings/presentation/settings_tab.dart

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../models/device_model.dart';
import '../../../services/device_service.dart';
import '../../../core/theme/app_colors.dart';

class SettingsTab extends StatefulWidget {
  final DeviceModel device;

  const SettingsTab({super.key, required this.device});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _formKey = GlobalKey<FormState>();
  final _deviceService = DeviceService();

  late TextEditingController _nameController;
  
  double _targetMoisture = 60;
  double _manualDuration = 5;
  int _timezoneOffset = -3;
  
  bool _enableWeatherControl = false;
  double _latitude = 0.0;
  double _longitude = 0.0;
  bool _isLoadingLocation = false;

  bool _isLoading = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _updateFieldsFromDevice();
  }

  @override
  void didUpdateWidget(covariant SettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device != widget.device) {
      _updateFieldsFromDevice();
    }
  }

  void _updateFieldsFromDevice() {
    final settings = widget.device.settings;

    if (!_isInitialized || _nameController.text != settings.deviceName) {
      _nameController.text = settings.deviceName;
    }

    setState(() {
      _targetMoisture = settings.targetMoisture;
      double dur = settings.manualDuration.toDouble();
      if (dur < 1.0) dur = 5.0;
      _manualDuration = dur;
      _timezoneOffset = settings.timezoneOffset;
      _enableWeatherControl = settings.enableWeatherControl;
      _latitude = settings.latitude;
      _longitude = settings.longitude;
      _isInitialized = true;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    setState(() => _isLoadingLocation = true);
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('O GPS do celular está desativado.');

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) throw Exception('Permissão de localização negada.');
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception('Permissão de localização permanentemente negada.');
      }

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
      );

      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("📍 Localização atualizada com sucesso!"), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erro no GPS: $e"), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    try {
      final newSettings = DeviceSettings(
        deviceName: _nameController.text.trim(),
        targetMoisture: _targetMoisture,
        manualDuration: _manualDuration.toInt(),
        timezoneOffset: _timezoneOffset,
        latitude: _latitude,
        longitude: _longitude,
        enableWeatherControl: _enableWeatherControl,
        capabilities: widget.device.settings.capabilities,
      );

      await _deviceService.updateDeviceSettings(widget.device.id, newSettings);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Configurações salvas com sucesso!"), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erro ao salvar: $e"), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteDevice() async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Remover Dispositivo?"),
          content: const Text("Você perderá o acesso a este dispositivo."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancelar")),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("REMOVER", style: TextStyle(color: AppColors.error, fontWeight: FontWeight.bold))
            ),
          ],
        )
    );

    if (confirm != true) return;
    setState(() => _isLoading = true);

    try {
      await _deviceService.unlinkDeviceFromUser(widget.device.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Dispositivo desvinculado."), backgroundColor: AppColors.textSecondary));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: AppColors.error));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) return const Center(child: CircularProgressIndicator());

    // Removido o Scaffold desnecessário, usando apenas um Container com a cor de fundo
    return Container(
      color: AppColors.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSectionHeader("Identificação"),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: "Nome do Dispositivo",
                      hintText: "Ex: Horta dos Fundos",
                      prefixIcon: Icon(Icons.edit),
                    ),
                    validator: (val) => val == null || val.isEmpty ? "O nome não pode ser vazio" : null,
                  ),
                ),
              ),

              const SizedBox(height: 20),
              _buildSectionHeader("Parâmetros de Irrigação"),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Umidade Alvo (Max)", style: TextStyle(fontWeight: FontWeight.bold)),
                          Chip(label: Text("${_targetMoisture.toInt()}%"), backgroundColor: AppColors.info.withValues(alpha: 0.2)),
                        ],
                      ),
                      const Text("Se o solo estiver acima deste valor, agendamentos serão ignorados.", style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      Slider(
                        value: _targetMoisture,
                        min: 0, max: 100, divisions: 100,
                        activeColor: AppColors.info,
                        label: "${_targetMoisture.toInt()}%",
                        onChanged: (val) => setState(() => _targetMoisture = val),
                      ),
                      const Divider(height: 30),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Tempo Rega Manual", style: TextStyle(fontWeight: FontWeight.bold)),
                          Chip(label: Text("${_manualDuration.toInt()} min"), backgroundColor: AppColors.warning.withValues(alpha: 0.2)),
                        ],
                      ),
                      Slider(
                        value: _manualDuration,
                        min: 1, max: 60, divisions: 59,
                        activeColor: AppColors.warning, thumbColor: AppColors.warning,
                        label: "${_manualDuration.toInt()} min",
                        onChanged: (val) => setState(() => _manualDuration = val),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
              _buildSectionHeader("Inteligência Meteorológica"),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text("Previsão de Chuva Inteligente", style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text("Não irrigar se houver previsão de chuva nas próximas 6h."),
                      activeThumbColor: AppColors.primary,
                      value: _enableWeatherControl,
                      onChanged: (val) => setState(() => _enableWeatherControl = val),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("Localização do Dispositivo:", style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text("Lat: ${_latitude.toStringAsFixed(5)}"),
                                      Text("Long: ${_longitude.toStringAsFixed(5)}"),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              ElevatedButton.icon(
                                onPressed: _isLoadingLocation ? null : _getCurrentLocation,
                                icon: _isLoadingLocation 
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textLight)) 
                                    : const Icon(Icons.my_location),
                                label: const Text("GPS Atual"),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.info, 
                                ),
                              )
                            ],
                          ),
                          const SizedBox(height: 5),
                          const Text("* Necessário estar próximo ao dispositivo para configurar.", style: TextStyle(fontSize: 10, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                        ],
                      ),
                    )
                  ],
                ),
              ),

              const SizedBox(height: 20),
              _buildSectionHeader("Localização & Hora"),
              Card(
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
                          border: Border.all(color: AppColors.textSecondary),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _timezoneOffset,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 0, child: Text("UTC +00:00 (Londres)")),
                              DropdownMenuItem(value: -3, child: Text("UTC -03:00 (Brasília)")),
                              DropdownMenuItem(value: -4, child: Text("UTC -04:00 (Amazonas)")),
                              DropdownMenuItem(value: -5, child: Text("UTC -05:00 (Nova York)")),
                              DropdownMenuItem(value: 1, child: Text("UTC +01:00 (Berlim)")),
                            ],
                            onChanged: (val) {
                              if (val != null) setState(() => _timezoneOffset = val);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 30),
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _saveSettings,
                  icon: const Icon(Icons.save),
                  label: _isLoading ? const CircularProgressIndicator(color: AppColors.textLight) : const Text("SALVAR ALTERAÇÕES"),
                ),
              ),

              const SizedBox(height: 40),
              const Divider(color: AppColors.errorAccent),
              Center(
                child: TextButton.icon(
                  onPressed: _isLoading ? null : _deleteDevice,
                  icon: const Icon(Icons.delete_forever, color: AppColors.error),
                  label: const Text("Remover este Dispositivo", style: TextStyle(color: AppColors.error)),
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
      child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textSecondary, letterSpacing: 1.0)),
    );
  }
}