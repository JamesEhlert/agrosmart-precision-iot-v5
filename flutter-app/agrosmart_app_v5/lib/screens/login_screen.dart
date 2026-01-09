import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import 'signup_screen.dart';
import 'dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();
  bool _isLoading = false;

  // Login com Email
  Future<void> _login() async {
    setState(() => _isLoading = true);
    try {
      await _authService.loginWithEmail(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );
      // NÃO PRECISAMOS NAVEGAR MANUALMENTE MAIS
      // O main.dart já vai perceber que logou e mudar a tela sozinho, 
      // mas por garantia mantemos a navegação explícita:
      _goToDevicesList();
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? "Erro ao logar");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Login com Google
  Future<void> _loginGoogle() async {
    setState(() => _isLoading = true);
    try {
      final user = await _authService.loginWithGoogle();
      if (user != null) _goToDevicesList();
    } catch (e) {
      _showError("Erro no Google Login: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

// Navegação para a Home (Dashboard)
  void _goToDevicesList() { // Pode manter o nome se quiser, mas o destino muda
    if (mounted) {
      Navigator.of(context).pushReplacement(
        // MUDANÇA AQUI: Vai para DashboardScreen
        MaterialPageRoute(builder: (context) => const DashboardScreen()),
      );
    }
  }

  Future<void> _forgotPassword() async {
    if (_emailController.text.isEmpty) {
      _showError("Digite seu e-mail para recuperar a senha.");
      return;
    }
    try {
      await _authService.resetPassword(_emailController.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("E-mail de recuperação enviado!"), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      _showError("Erro ao enviar e-mail: $e");
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.eco, size: 80, color: Colors.green),
              const SizedBox(height: 16),
              const Text(
                "AgroSmart V5",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),

              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: "E-mail", border: OutlineInputBorder(), prefixIcon: Icon(Icons.email)),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: "Senha", border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock)),
                obscureText: true,
              ),
              
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _forgotPassword,
                  child: const Text("Esqueci minha senha"),
                ),
              ),
              
              const SizedBox(height: 10),

              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : const Text("ENTRAR"),
                ),
              ),

              const SizedBox(height: 20),
              
              OutlinedButton.icon(
                onPressed: _isLoading ? null : _loginGoogle,
                icon: const Icon(Icons.g_mobiledata, size: 30),
                label: const Text("Entrar com Google"),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
              ),

              const SizedBox(height: 20),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Não tem conta?"),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context) => const SignUpScreen()),
                      );
                    },
                    child: const Text("Crie agora"),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}