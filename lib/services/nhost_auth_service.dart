import 'dart:async';

import 'package:nhost_dart/nhost_dart.dart';

import '../core/nhost_manager.dart';

/// مصادقة Nhost: هذه الخدمة ستحل تدريجيًا محل `auth_supabase_service`.
/// توفر عمليات الدخول والخروج ومراقبة حالة الجلسة باستخدام `nhost_dart`.
class NhostAuthService {
  final NhostClient _client;

  NhostAuthService({NhostClient? client})
      : _client = client ?? NhostManager.client;

  /// يسجّل الدخول بواسطة البريد وكلمة السر.
  Future<AuthResponse> signInWithEmailPassword({
    required String email,
    required String password,
  }) {
    return _client.auth.signInEmailPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// يسجّل الخروج من الجلسة الحالية.
  Future<void> signOut() => _client.auth.signOut();

  /// يسجّل حسابًا جديدًا بالبريد وكلمة السر.
  Future<AuthResponse> signUpWithEmailPassword({
    required String email,
    required String password,
    String? locale,
  }) {
    return _client.auth.signUpEmailPassword(
      email: email.trim(),
      password: password,
      locale: locale,
    );
  }

  /// المستخدم الحالي (إن وُجد).
  NhostUser? get currentUser => _client.auth.currentUser;

  /// رمز الـ JWT الحالي (إن وُجد). يستخدم لاحقًا في GraphQL/Storage.
  String? get accessToken => _client.auth.accessToken;

  /// بث للتغييرات في حالة المصادقة (يساعد في تحديث مزودي الحالة).
  Stream<AuthState> get authStateChanges => _client.auth.authStateChanges;
}
