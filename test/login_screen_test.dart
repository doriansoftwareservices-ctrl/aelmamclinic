import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/screens/auth/login_screen.dart';
import 'package:aelmamclinic/services/auth_supabase_service.dart';

class _NoopAuthSupabaseService extends AuthSupabaseService {
  _NoopAuthSupabaseService();

  @override
  Future<AuthResponse> signIn(String email, String password) async {
    return AuthResponse(session: null, user: null);
  }

  @override
  Future<void> signOut() async {}
}

class _LoginHarnessAuthProvider extends AuthProvider {
  _LoginHarnessAuthProvider({
    required List<AuthSessionResult> results,
    bool hasAccount = true,
    bool isSuperAdmin = false,
  })  : _results = ListQueue<AuthSessionResult>.from(results),
        _hasAccount = hasAccount,
        _superAdmin = isSuperAdmin,
        super(
            authService: _NoopAuthSupabaseService(), listenAuthChanges: false);

  final ListQueue<AuthSessionResult> _results;
  final bool _hasAccount;
  final bool _superAdmin;
  bool _loggedIn = false;
  bool bootstrapCalled = false;

  @override
  Future<void> signIn(String email, String password) async {}

  @override
  Future<AuthSessionResult> refreshAndValidateCurrentUser() async {
    final result = _results.isEmpty
        ? const AuthSessionResult.unknown()
        : _results.removeFirst();
    _loggedIn = result.isSuccess;
    return result;
  }

  @override
  Future<void> bootstrapSync({
    bool pull = true,
    bool realtime = true,
    bool enableLogs = true,
    Duration debounce = const Duration(seconds: 1),
    bool wipeLocalFirst = false,
  }) async {
    bootstrapCalled = true;
  }

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  bool get isSuperAdmin => _superAdmin;

  @override
  String? get accountId => _hasAccount ? 'acc-1' : '';
}

Future<void> _enterCredentials(WidgetTester tester) async {
  final emailField = find.bySemanticsLabel('البريد الإلكتروني');
  final passwordField = find.bySemanticsLabel('كلمة المرور');

  await tester.enterText(emailField, 'qa@clinic.test');
  await tester.enterText(passwordField, 'password123');
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'fake-anon-key',
    );
  });

  testWidgets('successful login clears errors and bootstraps sync',
      (tester) async {
    final provider = _LoginHarnessAuthProvider(
      results: const [AuthSessionResult.success()],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AuthProvider>.value(
          value: provider,
          child: const LoginScreen(),
        ),
      ),
    );

    await _enterCredentials(tester);
    await tester.tap(find.text('دخول'));
    await tester.pumpAndSettle();

    expect(provider.bootstrapCalled, isTrue);
    expect(find.textContaining('تم تعطيل هذا الحساب'), findsNothing);
  });

  testWidgets('disabled account shows appropriate error', (tester) async {
    final provider = _LoginHarnessAuthProvider(
      results: const [AuthSessionResult.disabled()],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AuthProvider>.value(
          value: provider,
          child: const LoginScreen(),
        ),
      ),
    );

    await _enterCredentials(tester);
    await tester.tap(find.text('دخول'));
    await tester.pumpAndSettle();

    expect(
      find.text('تم تعطيل هذا الحساب. يرجى التواصل مع الإدارة.'),
      findsOneWidget,
    );
  });

  testWidgets('missing clinic surfaces explanatory error', (tester) async {
    final provider = _LoginHarnessAuthProvider(
      results: const [AuthSessionResult.noAccount()],
      hasAccount: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AuthProvider>.value(
          value: provider,
          child: const LoginScreen(),
        ),
      ),
    );

    await _enterCredentials(tester);
    await tester.tap(find.text('دخول'));
    await tester.pumpAndSettle();

    expect(
      find.text(
          'لم يتم ربط هذا المستخدم بأي عيادة بعد. اطلب من الإدارة إكمال الإعداد.'),
      findsOneWidget,
    );
  });
}
