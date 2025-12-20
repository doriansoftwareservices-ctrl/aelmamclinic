// lib/screens/auth/login_screen.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
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

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  UnsubscribeDelegate? _authUnsub;
  bool _navigating = false;

  // نضمن تشغيل الـ Bootstrap مرة واحدة عند وجود جلسة مسبقة
  bool _bootstrappedOnce = false;
  late final AnimationController _bgController;
  Offset _pointer = Offset.zero;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = MediaQuery.sizeOf(context);
      if (_pointer == Offset.zero) {
        setState(() => _pointer = size.center(Offset.zero));
      }
    });

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
    _bgController.dispose();
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
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _AnimatedLoginBackground(
                animation: _bgController,
                pointer: _pointer,
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withOpacity(0.0),
                      Colors.white.withOpacity(0.04),
                      Colors.black.withOpacity(0.06),
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: Listener(
                onPointerHover: (event) =>
                    setState(() => _pointer = event.position),
                onPointerMove: (event) =>
                    setState(() => _pointer = event.position),
                onPointerDown: (event) =>
                    setState(() => _pointer = event.position),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                      child: Container(
                        padding: kScreenPadding,
                          decoration: BoxDecoration(
                            color: scheme.surface.withOpacity(0.86),
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.18),
                                blurRadius: 24,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Column(
                                children: [
                                  Image.asset(
                                    'assets/images/logo.png',
                                    height: 72,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox.shrink(),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'تسجيل الدخول',
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 16),
                              // بطاقة العنوان
                              NeuCard(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 16),
                                child: Row(
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        color: kPrimaryColor.withValues(
                                            alpha: .1),
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
                                prefix:
                                    const Icon(Icons.alternate_email_rounded),
                                onChanged: (_) {
                                  if (_error != null) {
                                    setState(() => _error = null);
                                  }
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
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                  tooltip: _obscure ? 'إظهار' : 'إخفاء',
                                ),
                                onChanged: (_) {
                                  if (_error != null) {
                                    setState(() => _error = null);
                                  }
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
                                        padding:
                                            EdgeInsets.symmetric(vertical: 6),
                                        child: SizedBox(
                                          height: 44,
                                          width: 44,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 3),
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
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedLoginBackground extends StatelessWidget {
  const _AnimatedLoginBackground({
    required this.animation,
    required this.pointer,
  });

  final Animation<double> animation;
  final Offset pointer;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final size = MediaQuery.sizeOf(context);
        final px = size.width == 0 ? 0.0 : (pointer.dx / size.width) * 2 - 1;
        final py = size.height == 0 ? 0.0 : (pointer.dy / size.height) * 2 - 1;
        final t = animation.value * 2 * math.pi;

        return Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFFFFFFF),
                    Color(0xFFF5F8FB),
                    Color(0xFFEDF2F7),
                  ],
                ),
              ),
            ),
            _FloatingOrb(
              phase: t,
              offset: Offset(px, py),
              alignment: const Alignment(-0.65, -0.5),
              size: 180,
              colorA: const Color(0xFF5CE0FF),
              colorB: const Color(0xFF2D79FF),
            ),
            _FloatingOrb(
              phase: t + 1.6,
              offset: Offset(px, py),
              alignment: const Alignment(0.8, -0.2),
              size: 140,
              colorA: const Color(0xFFFFC27A),
              colorB: const Color(0xFFFF6A5F),
            ),
            _FloatingOrb(
              phase: t + 3.1,
              offset: Offset(px, py),
              alignment: const Alignment(0.2, 0.9),
              size: 220,
              colorA: const Color(0xFF7CFFD6),
              colorB: const Color(0xFF2AA8A1),
            ),
          ],
        );
      },
    );
  }
}

class _FloatingOrb extends StatelessWidget {
  const _FloatingOrb({
    required this.phase,
    required this.offset,
    required this.alignment,
    required this.size,
    required this.colorA,
    required this.colorB,
  });

  final double phase;
  final Offset offset;
  final Alignment alignment;
  final double size;
  final Color colorA;
  final Color colorB;

  @override
  Widget build(BuildContext context) {
    final dx = math.sin(phase) * 20 + offset.dx * 16;
    final dy = math.cos(phase * 1.1) * 18 + offset.dy * 14;
    final tiltX = math.sin(phase) * 0.14 + offset.dy * 0.2;
    final tiltY = math.cos(phase * 0.8) * -0.18 + offset.dx * 0.2;

    return Align(
      alignment: alignment,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..translate(dx, dy)
          ..rotateX(tiltX)
          ..rotateY(tiltY),
        child: Container(
          height: size,
          width: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                colorA.withOpacity(0.9),
                colorB.withOpacity(0.85),
                Colors.black.withOpacity(0.2),
              ],
              stops: const [0.0, 0.6, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: colorA.withOpacity(0.35),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: colorB.withOpacity(0.35),
                blurRadius: 60,
                offset: const Offset(0, 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
