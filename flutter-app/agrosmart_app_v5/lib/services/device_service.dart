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
        return DeviceModel(
            id: deviceId,
            isOnline: false,
            settings: DeviceSettings(
              targetMoisture: 0, 
              manualDuration: 0, 
              deviceName: 'Desconhecido',
              timezoneOffset: -3,
              capabilities: [] 
            )
        );
      }
      return DeviceModel.fromFirestore(doc.data()!, doc.id);
    });
  }

  // Adicionar Dispositivo (Upsert Seguro) - CORREÇÃO DE PERMISSÃO
  Future<void> linkDeviceToUser(String deviceId, String initialName) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não logado");

    final deviceRef = _firestore.collection('devices').doc(deviceId);

    // Configurações padrão caso seja um dispositivo novo
    final defaultSettings = {
      'device_name': initialName,
      'target_soil_moisture': 60,
      'manual_valve_duration': 5,
      'timezone_offset': -3,
      'capabilities': ['air', 'soil', 'light', 'rain', 'uv'],
      'enable_weather_control': false,
    };

    try {
      // Usamos SetOptions(merge: true). 
      // Se não existir, ele cria obedecendo a regra 'allow create' (passando owner_uid correto).
      // Se existir e for seu, a regra 'allow update' permite a alteração do nome.
      // Se existir e for de outro, a regra 'allow update' BLOQUEIA na hora (permission-denied).
      await deviceRef.set({
        'device_id': deviceId,
        'owner_uid': user.uid,
        'settings': defaultSettings,
      }, SetOptions(merge: true));

    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw Exception("Falha de segurança: Este dispositivo já pertence a outra pessoa.");
      }
      rethrow;
    }

    // Adiciona o ID no array 'my_devices' da coleção do usuário
    await _firestore.collection('users').doc(user.uid).update({
      'my_devices': FieldValue.arrayUnion([deviceId])
    });
  }

  // Atualiza as configurações (Melhoria P1: Dot-notation)
  Future<void> updateDeviceSettings(String deviceId, DeviceSettings newSettings) async {
    // Agora atualizamos campo a campo. Isso evita apagar configurações novas 
    // que o firmware ou o backend possam adicionar no futuro dentro de 'settings'.
    await _firestore.collection('devices').doc(deviceId).update({
      'settings.device_name': newSettings.deviceName,
      'settings.target_soil_moisture': newSettings.targetMoisture,
      'settings.manual_valve_duration': newSettings.manualDuration,
      'settings.timezone_offset': newSettings.timezoneOffset,
      'settings.enable_weather_control': newSettings.enableWeatherControl,
      'settings.latitude': newSettings.latitude,   // <--- LINHA ADICIONADA
      'settings.longitude': newSettings.longitude, // <--- LINHA ADICIONADA
    });
  }

  // Desvincular Dispositivo
  Future<void> unlinkDeviceFromUser(String deviceId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não logado");

    await _firestore.collection('users').doc(user.uid).update({
      'my_devices': FieldValue.arrayRemove([deviceId])
    });
  }
}