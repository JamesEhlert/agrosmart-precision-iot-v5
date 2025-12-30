import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

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
    if (result.user != null) {
      await _createUserDocument(result.user!, name);
    }
  }

  // --- LOGIN COM GOOGLE ---
  Future<User?> loginWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null;

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential result = await _auth.signInWithCredential(credential);
      
      if (result.user != null) {
        final doc = await _firestore.collection('users').doc(result.user!.uid).get();
        if (!doc.exists) {
          await _createUserDocument(result.user!, result.user!.displayName ?? 'Usuário Google');
        }
      }
      return result.user;
    } catch (e) {
      debugPrint("Erro Google: $e");
      return null;
    }
  }

  // --- RECUPERAÇÃO DE SENHA (O QUE ESTAVA FALTANDO) ---
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

  // --- CRIAR DOCUMENTO NO BANCO ---
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