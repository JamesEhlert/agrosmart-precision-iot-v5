import 'package:flutter/material.dart';
import '../services/device_service.dart';
import '../services/auth_service.dart';
import '../models/device_model.dart';
import 'dashboard_screen.dart';
import 'login_screen.dart';
// import 'dashboard_screen.dart'; // Faremos na próxima

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
      builder: (context) => AlertDialog(
        title: const Text("Novo Dispositivo"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(
                labelText: "ID Serial (ex: ESP32-001)",
                hintText: "Olhe na etiqueta do aparelho",
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: "Nome (ex: Horta)"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancelar"),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await _deviceService.linkDeviceToUser(
                  idController.text.trim(),
                  nameController.text.trim(),
                );
                if (mounted) Navigator.pop(context);
              } catch (e) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text("Erro: $e")));
              }
            },
            child: const Text("Adicionar"),
          ),
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
            onPressed: () {
              _authService.logout();
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (context) => const LoginScreen()),
              );
            },
          ),
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

          final deviceIds = snapshot.data ?? [];

          if (deviceIds.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.grass, size: 60, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text("Nenhum dispositivo encontrado."),
                  TextButton(
                    onPressed: _showAddDeviceDialog,
                    child: const Text("Adicionar meu primeiro AgroSmart"),
                  ),
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
        if (!snapshot.hasData) return const SizedBox(); // Carregando silencioso

        final device = snapshot.data!;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: device.isOnline ? Colors.green : Colors.grey,
              child: const Icon(Icons.wifi, color: Colors.white),
            ),
            title: Text(
              device.settings.deviceName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text("ID: ${device.id}"),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
onTap: () {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => DashboardScreen(device: device),
    ),
  );
},
          ),
        );
      },
    );
  }
}
