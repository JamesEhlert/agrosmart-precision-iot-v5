// ARQUIVO: lib/features/dashboard/presentation/widgets/device_picker_sheet.dart

import 'package:flutter/material.dart';

class DevicePickerSheet extends StatelessWidget {
  final List<String> userDevices;
  final String? selectedDeviceId;
  final Function(String) onDeviceSelected;
  final VoidCallback onAddDeviceSelected;

  const DevicePickerSheet({
    super.key,
    required this.userDevices,
    this.selectedDeviceId,
    required this.onDeviceSelected,
    required this.onAddDeviceSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Meus Dispositivos",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          ...userDevices.map(
            (deviceId) => ListTile(
              leading: Icon(
                Icons.router,
                color: deviceId == selectedDeviceId ? Colors.green : Colors.grey,
              ),
              title: Text(
                deviceId,
                style: TextStyle(
                  fontWeight: deviceId == selectedDeviceId ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              trailing: deviceId == selectedDeviceId ? const Icon(Icons.check, color: Colors.green) : null,
              onTap: () => onDeviceSelected(deviceId),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.green,
              child: Icon(Icons.add, color: Colors.white),
            ),
            title: const Text("Adicionar Novo Dispositivo"),
            onTap: onAddDeviceSelected,
          ),
        ],
      ),
    );
  }
}