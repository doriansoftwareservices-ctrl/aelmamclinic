// lib/screens/auth/login_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:nhost_dart/nhost_dart.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';

// 👇 إضافات مهمة
import 'package:aelmamclinic/screens/admin/admin_dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  UnsubscribeDelegate? _authUnsub;
  bool _navigating = false;

  // نضمن تشغيل الـ Bootstrap مرة واحدة عند وجود جلسة مسبقة
  bool _bootstrappedOnce = false;

  @override
  void initState() {
    super.initState();

    // 1) لو فيه جلسة محفوظة، قرّر الوجهة + فعّل المزامنة بعد أول إطار.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRouteIfSignedIn();
    });

    // 2) استمع لتغيّر حالة المصادقة لتوجيه مضمون بعد signIn.
    _authUnsub = NhostManager.client.auth.addAuthStateChangedCallback((state) {
      if (state == AuthenticationState.signedIn) {
        _checkAndRouteIfSignedIn();
      }
    });
  }

  @override
  void dispose() {
    _authUnsub?.call();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// يقرر التوجيه حسب المستخدم الحالي (سوبر أدمن أو لا) ويضمن تشغيل المزامنة.
  Future<void> _checkAndRouteIfSignedIn() async {
    if (_navigating || !mounted) return;

    final authProv = context.read<AuthProvider>();
    final user = NhostManager.client.auth.currentUser;
    if (user == null) return;

    if (!authProv.isSuperAdmin &&
        ((authProv.accountId ?? '').isEmpty || !authProv.isLoggedIn)) {
      final result = await authProv.refreshAndValidateCurrentUser();
      if (!mounted) return;
      if (!result.isSuccess) {
        final message = _messageForStatus(result.status);
        if (message != null) {
          setState(() {
            _error = message;
            _loading = false;
          });
        }
        return;
      }
    }

    if (!authProv.isLoggedIn) {
      return;
    }

    final isSuper = authProv.isSuperAdmin;
    final hasAccount = (authProv.accountId ?? '').isNotEmpty;
    if (!isSuper && !hasAccount) {
      return;
    }

    if (!_bootstrappedOnce) {
      await authProv.bootstrapSync(
        pull: false,
        realtime: true,
        enableLogs: kDebugMode,
        debounce: const Duration(seconds: 1),
      );
      _bootstrappedOnce = true;
    }

    _navigating = true;
    if (!mounted) return;

    if (isSuper) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
      );
    } else {
      Navigator.of(context).pushReplacementNamed('/');
    }
  }

  Future<void> _submit(AuthProvider auth) async {
    if (_loading) return;

    // إلغاء التركيز لإغلاق لوحة المفاتيح
    FocusScope.of(context).unfocus();

    final email = _email.text.trim();
    final pass = _pass.text.trim();

    if (email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'من فضلك أدخل البريد الإلكتروني وكلمة المرور.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await auth.signIn(email, pass);
      final result = await auth.refreshAndValidateCurrentUser();
      if (!mounted) return;

      if (!result.isSuccess) {
        final message = _messageForStatus(result.status) ??
            'تعذّر التحقق من الحساب. حاول مرة أخرى.';
        setState(() => _error = message);
        return;
      }

      // ✅ بعد نجاح التحقق، نفّذ سحبًا أوليًا + Realtime
      if (auth.isLoggedIn) {
        await auth.bootstrapSync(
          pull: true,
          realtime: true,
          enableLogs: kDebugMode,
          debounce: const Duration(seconds: 1),
        );
        _bootstrappedOnce = true;
      }

      // نوجّه فورًا (ولا نعتمد فقط على المستمع).
      await _checkAndRouteIfSignedIn();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = 'فشل تسجيل الدخول: $e');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'فشل تسجيل الدخول: $e');
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String? _messageForStatus(AuthSessionStatus status) {
    switch (status) {
      case AuthSessionStatus.success:
        return null;
      case AuthSessionStatus.disabled:
        return 'تم تعطيل هذا الحساب. يرجى التواصل مع الإدارة.';
      case AuthSessionStatus.accountFrozen:
        return 'تم تجميد حساب العيادة. تواصل مع الإدارة لاستعادة الوصول.';
      case AuthSessionStatus.noAccount:
        return 'لم يتم ربط هذا المستخدم بأي عيادة بعد. اطلب من الإدارة إكمال الإعداد.';
      case AuthSessionStatus.signedOut:
        return 'انتهت الجلسة أثناء التحقق من الحساب. حاول تسجيل الدخول مجددًا.';
      case AuthSessionStatus.networkError:
        return 'تعذّر التحقق من الحساب بسبب مشكلة في الاتصال. حاول مرة أخرى.';
      case AuthSessionStatus.backendMisconfigured:
        return 'الخادم غير مهيأ بالشكل الصحيح. تأكد من تطبيق المايغريشن والـ metadata.';
      case AuthSessionStatus.unknown:
        return 'حدث خطأ غير متوقع أثناء التحقق من الحساب. حاول لاحقًا.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              height: 24,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            const Text('تسجيل الدخول'),
          ],
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: kScreenPadding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // بطاقة العنوان
                  NeuCard(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 16),
                    child: Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: kPrimaryColor.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(Icons.lock_rounded,
                              color: kPrimaryColor, size: 26),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'مرحبًا بعودتك إلى ${AppConstants.appName}',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // البريد الإلكتروني
                  NeuField(
                    controller: _email,
                    labelText: 'البريد الإلكتروني',
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    prefix: const Icon(Icons.alternate_email_rounded),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),

                  const SizedBox(height: 12),

                  // كلمة المرور
                  NeuField(
                    controller: _pass,
                    labelText: 'كلمة المرور',
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(auth),
                    prefix: const Icon(Icons.lock_outline_rounded),
                    suffix: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                      tooltip: _obscure ? 'إظهار' : 'إخفاء',
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),

                  const SizedBox(height: 10),

                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: scheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),

                  const SizedBox(height: 6),

                  // زر الدخول
                  Align(
                    alignment: Alignment.centerRight,
                    child: _loading
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 6),
                            child: SizedBox(
                              height: 44,
                              width: 44,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                          )
                        : NeuButton.primary(
                            label: 'دخول',
                            icon: Icons.login_rounded,
                            onPressed: () => _submit(auth),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
