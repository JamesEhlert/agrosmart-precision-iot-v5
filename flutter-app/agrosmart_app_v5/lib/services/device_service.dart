// ARQUIVO: lib/services/device_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/device_model.dart';

class DeviceService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Retorna uma Stream (fluxo) com a lista de IDs dos dispositivos do usuário
  Stream<List<String>> getUserDeviceIds() {
    final user = _auth.currentUser;
    if (user == null) return const Stream.empty();

    return _firestore
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) return [];
      final data = snapshot.data();
      if (data == null || !data.containsKey('my_devices')) return [];

      // Converte a lista do Firebase para lista de Strings
      return List<String>.from(data['my_devices']);
    });
  }

  // Busca os detalhes completos de um dispositivo específico
  Stream<DeviceModel> getDeviceStream(String deviceId) {
    return _firestore
        .collection('devices')
        .doc(deviceId)
        .snapshots()
        .map((doc) {
      if (!doc.exists) {
        // Retorna um modelo padrão caso não ache (evita crash)
        return DeviceModel(
            id: deviceId,
            isOnline: false,
            settings: DeviceSettings(
              targetMoisture: 0, 
              manualDuration: 0, 
              deviceName: 'Desconhecido',
              timezoneOffset: -3, // Default Brasília se não encontrar
              // CORREÇÃO 1: Adicionado capabilities vazio para satisfazer o modelo
              capabilities: [] 
            )
        );
      }
      return DeviceModel.fromFirestore(doc.data()!, doc.id);
    });
  }

  // Adicionar Dispositivo (Vincular ao Usuário)
  Future<void> linkDeviceToUser(String deviceId, String initialName) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não logado");

    // 1. Verifica se o dispositivo existe na coleção 'devices' (Segurança)
    final deviceRef = _firestore.collection('devices').doc(deviceId);
    final deviceDoc = await deviceRef.get();

    // Se não existir, criamos o registro inicial do dispositivo
    if (!deviceDoc.exists) {
      // CORREÇÃO 2: Usar o método toMap() do modelo para garantir consistência
      // Isso já inclui o campo 'capabilities' padrão.
      
      final defaultSettings = DeviceSettings(
        deviceName: initialName,
        targetMoisture: 60,
        manualDuration: 5,
        timezoneOffset: -3,
        // Assume que novos dispositivos são completos por padrão (V5)
        capabilities: ['air', 'soil', 'light', 'rain', 'uv'] 
      );

      await deviceRef.set({
        'device_id': deviceId,
        'online': false,
        'owner_uid': user.uid,
        'created_at': FieldValue.serverTimestamp(),
        'settings': defaultSettings.toMap(), // Salva o mapa completo
      });
    }

    // 2. Adiciona o ID no array 'my_devices' do usuário
    await _firestore.collection('users').doc(user.uid).update({
      'my_devices': FieldValue.arrayUnion([deviceId])
    });
  }

  // Atualiza as configurações (Nome, Umidade, Tempo Manual, Fuso) no Firestore
  Future<void> updateDeviceSettings(String deviceId, DeviceSettings newSettings) async {
    // Atualiza apenas o campo 'settings' dentro do documento do dispositivo
    await _firestore.collection('devices').doc(deviceId).update({
      'settings': newSettings.toMap(),
    });
  }

  // Desvincular Dispositivo
  Future<void> unlinkDeviceFromUser(String deviceId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não logado");

    // Remove o ID do array 'my_devices' do usuário
    await _firestore.collection('users').doc(user.uid).update({
      'my_devices': FieldValue.arrayRemove([deviceId])
    });
  }
}