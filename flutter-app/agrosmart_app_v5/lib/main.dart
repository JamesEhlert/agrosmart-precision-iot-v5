import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart'; // Arquivo gerado pelo CLI
import 'screens/login_screen.dart'; // Vamos criar este arquivo já já

void main() async {
  // 1. Garante que o motor do Flutter esteja pronto antes de chamar código nativo
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Inicializa o Firebase usando as configurações que geramos no terminal
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 3. Roda o Aplicativo
  runApp(const AgroSmartApp());
}

class AgroSmartApp extends StatelessWidget {
  const AgroSmartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgroSmart V5',
      debugShowCheckedModeBanner: false, // Remove a faixa "DEBUG" do canto
      theme: ThemeData(
        // Definindo a cor verde como tema principal (Agro)
        primarySwatch: Colors.green,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32), // Verde Floresta
          brightness: Brightness.light,
        ),
      ),
      // Tela inicial: Login
      home: const LoginScreen(),
    );
  }
}