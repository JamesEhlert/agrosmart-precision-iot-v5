// ARQUIVO: lib/services/device_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/device_model.dart';

class DeviceService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

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

  // Adicionar Dispositivo (Upsert Seguro) - Tratamento de Erro Aprimorado
  Future<void> linkDeviceToUser(String deviceId, String initialName) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não logado");

    final deviceRef = _firestore.collection('devices').doc(deviceId);

    try {
      // 1. TENTA LER O DISPOSITIVO
      // Se não existir ou o usuário não for o dono (segundo as regras), o Firebase vai lançar 'permission-denied'
      final docSnap = await deviceRef.get();
      
      if (!docSnap.exists) {
         // Na teoria, com a regra atual, nunca vai cair aqui, pois o Firebase bloqueia a leitura de docs inexistentes se o owner não bater.
         // Mas deixamos por precaução caso as regras do Firestore mudem no futuro.
        throw Exception("Dispositivo não encontrado no sistema. Verifique se o ID está correto ou se a placa já foi provisionada.");
      }

      // 2. Dispositivo existe e o usuário tem permissão de leitura. Aplicamos as configurações básicas.
      final defaultSettings = {
        'device_name': initialName,
        'target_soil_moisture': 60,
        'manual_valve_duration': 5,
        'timezone_offset': -3,
        'capabilities': ['air', 'soil', 'light', 'rain', 'uv'],
        'enable_weather_control': false,
      };

      await deviceRef.set({
        'device_id': deviceId,
        'owner_uid': user.uid,
        'settings': defaultSettings,
      }, SetOptions(merge: true));

    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        // MENSAGEM AJUSTADA: Agora cobre tanto a inexistência quanto a apropriação por terceiros.
        throw Exception("Não foi possível vincular. Verifique se o ID está correto ou se o dispositivo já foi registrado em outra conta.");
      }
      rethrow;
    }

    // 3. Adiciona o ID no array 'my_devices' do perfil do usuário
    await _firestore.collection('users').doc(user.uid).update({
      'my_devices': FieldValue.arrayUnion([deviceId])
    });
  }

  Future<void> updateDeviceSettings(String deviceId, DeviceSettings newSettings) async {
    await _firestore.collection('devices').doc(deviceId).update({
      'settings.device_name': newSettings.deviceName,
      'settings.target_soil_moisture': newSettings.targetMoisture,
      'settings.manual_valve_duration': newSettings.manualDuration,
      'settings.timezone_offset': newSettings.timezoneOffset,
      'settings.enable_weather_control': newSettings.enableWeatherControl,
      'settings.latitude': newSettings.latitude,   
      'settings.longitude': newSettings.longitude, 
    });
  }

  Future<void> unlinkDeviceFromUser(String deviceId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não logado");

    await _firestore.collection('users').doc(user.uid).update({
      'my_devices': FieldValue.arrayRemove([deviceId])
    });
  }
}