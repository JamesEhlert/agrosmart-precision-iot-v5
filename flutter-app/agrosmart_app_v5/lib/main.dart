// ARQUIVO: lib/main.dart

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';

// Import atualizado para a nova pasta
import 'features/auth/presentation/login_screen.dart';
import 'features/dashboard/presentation/dashboard_page.dart'; 
import 'core/theme/app_theme.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const AgroSmartApp());
}

class AgroSmartApp extends StatelessWidget {
  const AgroSmartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgroSmart V5',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme, 
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasData) {
            return const DashboardPage(); 
          }
          return const LoginScreen();
        },
      ),
    );
  }
}