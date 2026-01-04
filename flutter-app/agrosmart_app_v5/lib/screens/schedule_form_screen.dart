import 'package:flutter/material.dart';
import '../models/schedule_model.dart';
import '../services/schedules_service.dart';

class ScheduleFormScreen extends StatefulWidget {
  final String deviceId;
  final ScheduleModel? scheduleToEdit; // Se vier preenchido, é Edição. Se nulo, é Criação.
  
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
    // Se estamos editando, preenchemos os campos com os dados existentes
    if (widget.scheduleToEdit != null) {
      final s = widget.scheduleToEdit!;
      _labelController.text = s.label;
      _duration = s.durationMinutes.toDouble();
      _selectedDays.addAll(s.days);
      
      // Converte string "18:30" de volta para TimeOfDay(18, 30)
      try {
        final parts = s.time.split(':');
        _selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      } catch (e) {
        // Se der erro no parse, mantém o padrão
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (_selectedDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Selecione pelo menos um dia.")));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final hour = _selectedTime.hour.toString().padLeft(2, '0');
      final minute = _selectedTime.minute.toString().padLeft(2, '0');
      final timeString = "$hour:$minute";

      // Verifica se é Edição (tem ID) ou Criação (ID vazio temporário)
      final bool isEditing = widget.scheduleToEdit != null;

      final scheduleData = ScheduleModel(
        id: isEditing ? widget.scheduleToEdit!.id : '', // Mantém ID se editando
        label: _labelController.text.trim(),
        time: timeString,
        days: _selectedDays..sort(),
        durationMinutes: _duration.toInt(),
        isEnabled: true, // Ao editar/criar, salvamos como ativo por padrão
      );

      if (isEditing) {
        await _schedulesService.updateSchedule(widget.deviceId, scheduleData);
      } else {
        await _schedulesService.addSchedule(widget.deviceId, scheduleData);
      }

      if (!mounted) return;
      Navigator.pop(context); // Fecha a tela

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _selectedTime);
    if (picked != null) setState(() => _selectedTime = picked);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.scheduleToEdit != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? "Editar Agendamento" : "Novo Agendamento"),
        backgroundColor: isEditing ? Colors.orange : Colors.green, // Cor diferente para indicar edição
        foregroundColor: Colors.white,
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
                decoration: const InputDecoration(labelText: "Nome", border: OutlineInputBorder(), prefixIcon: Icon(Icons.label)),
                validator: (val) => val == null || val.isEmpty ? "Digite um nome" : null,
              ),
              const SizedBox(height: 20),

              ListTile(
                title: const Text("Horário"),
                subtitle: Text("${_selectedTime.hour.toString().padLeft(2,'0')}:${_selectedTime.minute.toString().padLeft(2,'0')}",
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green)),
                trailing: const Icon(Icons.access_time, size: 30),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Colors.grey)),
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
                    selectedColor: Colors.green[100],
                    checkmarkColor: Colors.green,
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
                      value: _duration, min: 1, max: 60, divisions: 59, label: "${_duration.toInt()} min", activeColor: Colors.green,
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
                    backgroundColor: isEditing ? Colors.orange : Colors.green, 
                    foregroundColor: Colors.white
                  ),
                  child: _isLoading 
                    ? const CircularProgressIndicator(color: Colors.white)
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