import 'package:flutter/material.dart';
import '../models/schedule_model.dart';
import '../services/schedules_service.dart';

class ScheduleFormScreen extends StatefulWidget {
  final String deviceId;
  
  const ScheduleFormScreen({super.key, required this.deviceId});

  @override
  State<ScheduleFormScreen> createState() => _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _schedulesService = SchedulesService();
  
  TimeOfDay _selectedTime = const TimeOfDay(hour: 8, minute: 0);
  double _duration = 5; // Duração em minutos (slider)
  
  // Dias da semana selecionados (começa vazio)
  final List<int> _selectedDays = []; 
  
  // Mapa para exibir os nomes dos dias
  final Map<int, String> _daysMap = {
    1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sáb', 7: 'Dom'
  };

  bool _isLoading = false;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (_selectedDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Selecione pelo menos um dia da semana."))
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Formata a hora para String "HH:mm"
      final hour = _selectedTime.hour.toString().padLeft(2, '0');
      final minute = _selectedTime.minute.toString().padLeft(2, '0');
      final timeString = "$hour:$minute";

      // Cria o objeto modelo
      final newSchedule = ScheduleModel(
        id: '', // O Firebase vai gerar o ID
        label: _labelController.text.trim(),
        time: timeString,
        days: _selectedDays..sort(), // Ordena os dias (Seg -> Dom)
        durationMinutes: _duration.toInt(),
        isEnabled: true,
      );

      // Envia para o serviço
      await _schedulesService.addSchedule(widget.deviceId, newSchedule);

      if (!mounted) return;
      Navigator.pop(context); // Volta para a tela anterior

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red)
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
    );
    if (picked != null) {
      setState(() => _selectedTime = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Novo Agendamento")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Nome do Agendamento
              TextFormField(
                controller: _labelController,
                decoration: const InputDecoration(
                  labelText: "Nome (ex: Rega Manhã)",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.label),
                ),
                validator: (val) => val == null || val.isEmpty ? "Digite um nome" : null,
              ),
              const SizedBox(height: 20),

              // Seletor de Hora
              ListTile(
                title: const Text("Horário de Início"),
                subtitle: Text(
                  "${_selectedTime.hour.toString().padLeft(2,'0')}:${_selectedTime.minute.toString().padLeft(2,'0')}",
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green),
                ),
                trailing: const Icon(Icons.access_time, size: 30),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Colors.grey)),
                onTap: _pickTime,
              ),
              const SizedBox(height: 20),

              // Seletor de Dias da Semana (Chips)
              const Text("Dias da Semana:", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: _daysMap.entries.map((entry) {
                  final dayNum = entry.key;
                  final dayName = entry.value;
                  final isSelected = _selectedDays.contains(dayNum);
                  
                  return FilterChip(
                    label: Text(dayName),
                    selected: isSelected,
                    selectedColor: Colors.green[100],
                    checkmarkColor: Colors.green,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedDays.add(dayNum);
                        } else {
                          _selectedDays.remove(dayNum);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              
              const SizedBox(height: 20),

              // Slider de Duração
              const Text("Duração da Rega:", style: TextStyle(fontWeight: FontWeight.bold)),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _duration,
                      min: 1,
                      max: 60,
                      divisions: 59,
                      label: "${_duration.toInt()} min",
                      activeColor: Colors.green,
                      onChanged: (val) => setState(() => _duration = val),
                    ),
                  ),
                  Text("${_duration.toInt()} min", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),

              const SizedBox(height: 30),

              // Botão Salvar
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _save,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  child: _isLoading 
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text("SALVAR AGENDAMENTO"),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}