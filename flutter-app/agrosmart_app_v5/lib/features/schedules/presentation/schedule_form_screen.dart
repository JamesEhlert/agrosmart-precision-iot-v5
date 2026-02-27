// ARQUIVO: lib/features/schedules/presentation/schedule_form_screen.dart

import 'package:flutter/material.dart';

import '../../../models/schedule_model.dart';
import '../../../services/schedules_service.dart';
import '../../../core/theme/app_colors.dart';

class ScheduleFormScreen extends StatefulWidget {
  final String deviceId;
  final ScheduleModel? scheduleToEdit;
  
  const ScheduleFormScreen({
    super.key, 
    required this.deviceId, 
    this.scheduleToEdit
  });

  @override
  State<ScheduleFormScreen> createState() => _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _schedulesService = SchedulesService();
  
  TimeOfDay _selectedTime = const TimeOfDay(hour: 8, minute: 0);
  double _duration = 5; 
  final List<int> _selectedDays = []; 
  
  final Map<int, String> _daysMap = {
    1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sáb', 7: 'Dom'
  };

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.scheduleToEdit != null) {
      final s = widget.scheduleToEdit!;
      _labelController.text = s.label;
      // Garante que agendamentos legados não passem de 15 no UI
      _duration = s.durationMinutes.toDouble().clamp(1.0, 15.0);
      _selectedDays.addAll(s.days);
      
      try {
        final parts = s.time.split(':');
        _selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      } catch (e) {
        // Ignora erro de parse
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (_selectedDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Selecione pelo menos um dia."), backgroundColor: AppColors.errorAccent)
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final hour = _selectedTime.hour.toString().padLeft(2, '0');
      final minute = _selectedTime.minute.toString().padLeft(2, '0');
      final timeString = "$hour:$minute";

      final bool isEditing = widget.scheduleToEdit != null;

      final scheduleData = ScheduleModel(
        id: isEditing ? widget.scheduleToEdit!.id : '', 
        label: _labelController.text.trim(),
        time: timeString,
        days: _selectedDays..sort(),
        durationMinutes: _duration.toInt(),
        isEnabled: true, 
      );

      if (isEditing) {
        await _schedulesService.updateSchedule(widget.deviceId, scheduleData);
      } else {
        await _schedulesService.addSchedule(widget.deviceId, scheduleData);
      }

      if (!mounted) return;
      Navigator.pop(context); 

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro: $e"), backgroundColor: AppColors.error)
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context, 
      initialTime: _selectedTime,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primary, 
              onPrimary: AppColors.textLight, 
              onSurface: AppColors.textPrimary,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary, 
              ),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) setState(() => _selectedTime = picked);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.scheduleToEdit != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? "Editar Agendamento" : "Novo Agendamento"),
        backgroundColor: isEditing ? AppColors.warning : AppColors.primary,
        foregroundColor: AppColors.textLight,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _labelController,
                decoration: const InputDecoration(labelText: "Nome", prefixIcon: Icon(Icons.label)),
                validator: (val) => val == null || val.isEmpty ? "Digite um nome" : null,
              ),
              const SizedBox(height: 20),

              ListTile(
                title: const Text("Horário"),
                subtitle: Text("${_selectedTime.hour.toString().padLeft(2,'0')}:${_selectedTime.minute.toString().padLeft(2,'0')}",
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppColors.primary)),
                trailing: const Icon(Icons.access_time, size: 30),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: AppColors.textSecondary)),
                onTap: _pickTime,
              ),
              const SizedBox(height: 20),

              const Text("Dias da Semana:", style: TextStyle(fontWeight: FontWeight.bold)),
              Wrap(
                spacing: 8,
                children: _daysMap.entries.map((entry) {
                  final isSelected = _selectedDays.contains(entry.key);
                  return FilterChip(
                    label: Text(entry.value),
                    selected: isSelected,
                    selectedColor: AppColors.primaryLight,
                    checkmarkColor: AppColors.primary,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedDays.add(entry.key);
                        } else {
                          _selectedDays.remove(entry.key);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),

              const Text("Duração (minutos):", style: TextStyle(fontWeight: FontWeight.bold)),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _duration, 
                      min: 1, 
                      max: 15, // Ajuste do limite máximo de 60 para 15
                      divisions: 14, // 15 - 1
                      label: "${_duration.toInt()} min", 
                      activeColor: AppColors.primary,
                      onChanged: (val) => setState(() => _duration = val),
                    ),
                  ),
                  Text("${_duration.toInt()} min", style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 30),

              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isEditing ? AppColors.warning : AppColors.primary, 
                  ),
                  child: _isLoading 
                    ? const CircularProgressIndicator(color: AppColors.textLight)
                    : Text(isEditing ? "ATUALIZAR" : "CRIAR"),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}