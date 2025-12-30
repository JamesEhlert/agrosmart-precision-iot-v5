import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // Para usar debugPrint

// TRUQUE PARA RESOLVER O ERRO:
// Estamos dando um apelido 'provider' para a biblioteca oficial.
// Isso evita que o Flutter confunda com outros arquivos do seu projeto.
import 'package:google_sign_in/google_sign_in.dart' as provider; 

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  // Usamos o apelido 'provider' aqui para garantir que é a classe certa
  final provider.GoogleSignIn _googleSignIn = provider.GoogleSignIn();

  User? get currentUser => _auth.currentUser;

  // --- LOGIN COM E-MAIL ---
  Future<void> loginWithEmail(String email, String password) async {
    await _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  // --- REGISTRO COM E-MAIL ---
  Future<void> registerWithEmail(String email, String password, String name) async {
    UserCredential result = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    User? user = result.user;

    if (user != null) {
      await _createUserDocument(user, name);
    }
  }

  // --- LOGIN COM GOOGLE ---
  Future<User?> loginWithGoogle() async {
    try {
      // 1. Inicia o fluxo
      final provider.GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      
      if (googleUser == null) return null; // Cancelado pelo usuário

      // 2. Autenticação
      final provider.GoogleSignInAuthentication googleAuth = googleUser.authentication;

      // 3. Credenciais
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // 4. Login no Firebase
      final UserCredential result = await _auth.signInWithCredential(credential);
      final User? user = result.user;

      // 5. Salva no banco se for novo
      if (user != null) {
        final userDoc = await _firestore.collection('users').doc(user.uid).get();
        if (!userDoc.exists) {
          await _createUserDocument(user, user.displayName ?? 'Usuário Google');
        }
      }
      return user;
      
    } catch (e) {
      // Usamos debugPrint em vez de print (boa prática para não dar erro de linter)
      debugPrint("Erro no Google Sign In: $e");
      return null;
    }
  }

  // --- RECUPERAÇÃO DE SENHA ---
  Future<void> resetPassword(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  // --- LOGOUT ---
  Future<void> logout() async {
    try {
      await _googleSignIn.signOut();
      await _auth.signOut();
    } catch (e) {
      debugPrint("Erro ao deslogar: $e");
    }
  }

  // --- AUXILIAR: CRIAR DOCUMENTO ---
  Future<void> _createUserDocument(User user, String name) async {
    await _firestore.collection('users').doc(user.uid).set({
      'uid': user.uid,
      'email': user.email,
      'name': name,
      'created_at': FieldValue.serverTimestamp(),
      'role': 'customer',
      'my_devices': [],
    });
  }
}