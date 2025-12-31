import 'package:flutter/material.dart';
import '../services/device_service.dart';
import '../services/auth_service.dart';
import '../models/device_model.dart';
import 'login_screen.dart';
import 'dashboard_screen.dart'; // Importante para navegar ao clicar no dispositivo

class DevicesListScreen extends StatefulWidget {
  const DevicesListScreen({super.key});

  @override
  State<DevicesListScreen> createState() => _DevicesListScreenState();
}

class _DevicesListScreenState extends State<DevicesListScreen> {
  final _deviceService = DeviceService();
  final _authService = AuthService();

  // Função para abrir o diálogo de adicionar dispositivo
  void _showAddDeviceDialog() {
    final idController = TextEditingController();
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Novo Dispositivo"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(
                labelText: "ID Serial (ex: ESP32-001)",
                hintText: "Olhe na etiqueta do aparelho",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: "Nome (ex: Horta)",
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancelar"),
          ),
          ElevatedButton(
            onPressed: () async {
              // 1. Captura os valores dos campos
              final id = idController.text.trim();
              final name = nameController.text.trim();

              if (id.isEmpty || name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Preencha ID e Nome.")),
                );
                return;
              }

              try {
                // 2. Chama o serviço (Assíncrono)
                await _deviceService.linkDeviceToUser(id, name);

                // 3. CORREÇÃO DO ERRO DE CONTEXTO:
                // Verificamos se a tela ainda existe antes de tentar fechar o diálogo
                if (!context.mounted) return;

                Navigator.pop(context); // Fecha o diálogo com segurança
                
              } catch (e) {
                // Verificamos se a tela ainda existe antes de mostrar o erro
                if (!context.mounted) return;

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Erro ao adicionar: $e"), backgroundColor: Colors.red),
                );
              }
            },
            child: const Text("Adicionar"),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Meus Dispositivos"),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Sair",
            onPressed: () async {
              await _authService.logout();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (context) => const LoginScreen()),
              );
            },
          )
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDeviceDialog,
        backgroundColor: Colors.green,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: StreamBuilder<List<String>>(
        stream: _deviceService.getUserDeviceIds(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          
          if (snapshot.hasError) {
             return Center(child: Text("Erro ao carregar lista: ${snapshot.error}"));
          }

          final deviceIds = snapshot.data ?? [];

          if (deviceIds.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.grass, size: 80, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text("Nenhum dispositivo encontrado.", style: TextStyle(fontSize: 18, color: Colors.grey)),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _showAddDeviceDialog,
                    child: const Text("Adicionar meu primeiro AgroSmart"),
                  )
                ],
              ),
            );
          }

          // Lista de Cards dos dispositivos
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: deviceIds.length,
            itemBuilder: (context, index) {
              final id = deviceIds[index];
              return _DeviceCard(deviceId: id);
            },
          );
        },
      ),
    );
  }
}

// Widget separado para buscar os dados de CADA dispositivo individualmente
class _DeviceCard extends StatelessWidget {
  final String deviceId;
  final DeviceService _service = DeviceService();

  _DeviceCard({required this.deviceId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DeviceModel>(
      stream: _service.getDeviceStream(deviceId),
      builder: (context, snapshot) {
        // Enquanto carrega os detalhes, mostra um card placeholder simples ou nada
        if (!snapshot.hasData) {
          return const Card(
            child: ListTile(
              title: Text("Carregando..."),
              leading: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final device = snapshot.data!;
        
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              // NAVEGAÇÃO PARA O DASHBOARD
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DashboardScreen(device: device),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: device.isOnline ? Colors.green : Colors.grey,
                  child: const Icon(Icons.wifi, color: Colors.white),
                ),
                title: Text(
                  device.settings.deviceName, 
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("ID: ${device.id}", style: const TextStyle(fontSize: 12)),
                    if (device.isOnline)
                      const Text("Status: Online", style: TextStyle(color: Colors.green, fontSize: 12))
                    else
                      const Text("Status: Offline", style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
              ),
            ),
          ),
        );
      },
    );
  }
}