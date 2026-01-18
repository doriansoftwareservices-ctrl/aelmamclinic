// lib/screens/auth/login_screen.dart
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:nhost_dart/nhost_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/constants.dart';

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
  bool _rememberMe = false;

  UnsubscribeDelegate? _authUnsub;
  bool _navigating = false;
  bool _routeCheckScheduled = false;

  // نضمن تشغيل الـ Bootstrap مرة واحدة عند وجود جلسة مسبقة
  bool _bootstrappedOnce = false;

  static const _rememberMeKey = 'auth.remember_me';
  static const _rememberEmailKey = 'auth.remember_email';
  static const _rememberPassKey = 'auth.remember_pass';

  Future<void> _callNumber(String number) async {
    final uri = Uri.parse('tel:$number');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح تطبيق الاتصال.')),
      );
    }
  }

  Future<void> _openWhatsApp(String number) async {
    final clean = number.replaceAll('+', '');
    final uri = Uri.parse('https://wa.me/$clean');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب.')),
      );
    }
  }

  @override
  void initState() {
    super.initState();

    _loadRememberedCredentials();

    // 1) لو فيه جلسة محفوظة، قرّر الوجهة + فعّل المزامنة بعد أول إطار.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRouteIfSignedIn();
    });

    // 2) استمع لتغيّر حالة المصادقة لتوجيه مضمون بعد signIn.
    _authUnsub = NhostManager.client.auth.addAuthStateChangedCallback((state) {
      if (state == AuthenticationState.signedIn) {
        if (_loading || _navigating) return;
        _checkAndRouteIfSignedIn();
      }
    });
  }

  Future<void> _loadRememberedCredentials() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final remember = sp.getBool(_rememberMeKey) ?? false;
      if (!remember) return;
      final email = sp.getString(_rememberEmailKey) ?? '';
      final pass = sp.getString(_rememberPassKey) ?? '';
      if (email.isEmpty || pass.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _rememberMe = true;
        _email.text = email;
        _pass.text = pass;
      });
    } catch (_) {}
  }

  Future<void> _persistRememberedCredentials({
    required String email,
    required String password,
  }) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_rememberMeKey, _rememberMe);
      if (_rememberMe) {
        await sp.setString(_rememberEmailKey, email);
        await sp.setString(_rememberPassKey, password);
      } else {
        await sp.remove(_rememberEmailKey);
        await sp.remove(_rememberPassKey);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _authUnsub?.call();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// يقرر التوجيه حسب المستخدم الحالي (سوبر أدمن أو لا) ويضمن تشغيل المزامنة.
  Future<void> _checkAndRouteIfSignedIn({bool force = false}) async {
    if (_navigating || (!force && _loading) || !mounted) return;

    final authProv = context.read<AuthProvider>();
    final user = NhostManager.client.auth.currentUser;
    if (user == null) return;

    if (!authProv.isLoggedIn ||
        (!authProv.isSuperAdmin && (authProv.accountId ?? '').isEmpty)) {
      final result = await authProv.refreshAndValidateCurrentUser();
      if (!mounted) return;
      if (!result.isSuccess) {
        var allowContinue = false;
        if (result.status == AuthSessionStatus.planUpgradeRequired) {
          final role = authProv.role?.toLowerCase();
          if (role == 'owner' || role == 'admin') {
            allowContinue = true;
          } else {
            await authProv.signOut();
          }
        } else if (result.status == AuthSessionStatus.noAccount) {
          await authProv.signOut();
        }
        if (!allowContinue) {
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
    }

    final isSuper = authProv.isSuperAdmin;
    final hasAccount = (authProv.accountId ?? '').isNotEmpty;
    if (!isSuper && !hasAccount) {
      return;
    }

    if (!_bootstrappedOnce) {
      if (!isSuper) {
        await _ensureClinicProfileComplete(authProv);
      }
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
    if (pass.length < 9) {
      setState(() => _error = 'كلمة المرور يجب ألا تقل عن 9 أحرف.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final signInResp = await auth.signIn(email, pass);
      if (signInResp.session == null) {
        setState(
          () => _error =
              'تعذّر تسجيل الدخول. تأكد من البريد وكلمة المرور أو فعّل حسابك عبر البريد.',
        );
        return;
      }
      await _persistRememberedCredentials(email: email, password: pass);

      final result = await auth.refreshAndValidateCurrentUser();
      if (!mounted) return;

      if (result.status == AuthSessionStatus.noAccount) {
        final clinicProfile = await _askClinicProfile();
        if (clinicProfile == null) {
          await auth.signOut();
          setState(() => _error = 'اسم العيادة مطلوب لإكمال إنشاء الحساب.');
          return;
        }
        auth.setPendingClinicProfile(clinicProfile);
        try {
          await auth.selfCreateAccount(clinicProfile);
        } catch (e) {
          await auth.signOut();
          setState(() => _error = 'تعذّر إنشاء الحساب: $e');
          return;
        }
        final recheck = await auth.refreshAndValidateCurrentUser();
        if (!mounted) return;
        if (!recheck.isSuccess) {
          if (recheck.status == AuthSessionStatus.noAccount ||
              recheck.status == AuthSessionStatus.planUpgradeRequired) {
            await auth.signOut();
          }
          setState(() => _error = _messageForStatus(recheck.status) ??
              'تعذّر التحقق من الحساب. حاول مرة أخرى.');
          return;
        }
      }

      if (!result.isSuccess) {
        if (result.status == AuthSessionStatus.planUpgradeRequired) {
          final role = auth.role?.toLowerCase();
          if (role == 'owner' || role == 'admin') {
            // Treat as success for owners/admins; they can upgrade from داخل التطبيق.
          } else {
            await auth.signOut();
            final message = _messageForStatus(result.status) ??
                'تعذّر التحقق من الحساب. حاول مرة أخرى.';
            setState(() => _error = message);
            return;
          }
        } else if (result.status == AuthSessionStatus.noAccount) {
          await auth.signOut();
          final message =
              _messageForStatus(result.status) ??
              'تعذّر التحقق من الحساب. حاول مرة أخرى.';
          setState(() => _error = message);
          return;
        } else {
          final message =
              _messageForStatus(result.status) ??
              'تعذّر التحقق من الحساب. حاول مرة أخرى.';
          setState(() => _error = message);
          return;
        }
      }

      await _ensureClinicProfileComplete(auth);

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
      await _checkAndRouteIfSignedIn(force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'فشل تسجيل الدخول: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _signUp(AuthProvider auth) async {
    if (_loading) return;
    FocusScope.of(context).unfocus();

    final email = _email.text.trim();
    final pass = _pass.text.trim();
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'أدخل البريد وكلمة المرور أولًا.');
      return;
    }
    if (pass.length < 9) {
      setState(() => _error = 'كلمة المرور يجب ألا تقل عن 9 أحرف.');
      return;
    }

    final clinicProfile = await _askClinicProfile();

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      auth.setPendingClinicProfile(clinicProfile);
      auth.allowAutoCreateAccountOnce();
      var signUpResp = await auth.signUp(email, pass);
      if (signUpResp.session == null) {
        // بعض البيئات لا تُرجع session مباشرةً؛ جرّب تسجيل الدخول فورًا.
        try {
          signUpResp = await auth.signIn(email, pass);
        } catch (_) {}
        if (signUpResp.session == null) {
          setState(
            () => _error =
                'تم إنشاء الحساب. يرجى تأكيد البريد الإلكتروني ثم تسجيل الدخول.',
          );
          return;
        }
      }
      await _persistRememberedCredentials(email: email, password: pass);
      if (clinicProfile != null) {
        await auth.selfCreateAccount(clinicProfile);
      } else {
        setState(() => _error = 'اسم العيادة مطلوب لإكمال إنشاء الحساب.');
        return;
      }
      final result = await auth.refreshAndValidateCurrentUser();
      if (!mounted) return;
      if (!result.isSuccess) {
        setState(() => _error = _messageForStatus(result.status));
        return;
      }
      await auth.bootstrapSync(
        pull: true,
        realtime: true,
        enableLogs: kDebugMode,
        debounce: const Duration(seconds: 1),
      );
      _bootstrappedOnce = true;
      await _checkAndRouteIfSignedIn(force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر إنشاء الحساب: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<ClinicProfileInput?> _askClinicProfile() async {
    final arStep = await _askClinicProfileStep(
      title: 'بيانات المرفق الصحي (عربي)',
      nameLabel: 'اسم المرفق الصحي',
      cityLabel: 'المدينة',
      streetLabel: 'الشارع',
      nearLabel: 'بجوار',
      phoneLabel: 'رقم الهاتف',
      prefillPhone: null,
    );
    if (arStep == null) return null;

    final enStep = await _askClinicProfileStep(
      title: 'Clinic Info (English)',
      nameLabel: 'Clinic name',
      cityLabel: 'City',
      streetLabel: 'Street',
      nearLabel: 'Near',
      phoneLabel: 'Phone',
      prefillPhone: arStep.phone,
    );
    if (enStep == null) return null;

    return ClinicProfileInput(
      nameAr: arStep.name,
      cityAr: arStep.city,
      streetAr: arStep.street,
      nearAr: arStep.near,
      nameEn: enStep.name,
      cityEn: enStep.city,
      streetEn: enStep.street,
      nearEn: enStep.near,
      phone: arStep.phone,
    );
  }

  Future<void> _ensureClinicProfileComplete(AuthProvider auth) async {
    if (!mounted) return;
    try {
      if (auth.isSuperAdmin) return;
      if ((auth.accountId ?? '').trim().isEmpty) return;
      final complete = await ClinicProfileService.isProfileComplete();
      if (complete) return;
      final profile = await _askClinicProfile();
      if (profile == null) return;
      await auth.updateClinicProfile(profile);
      await auth.refreshAndValidateCurrentUser();
    } catch (_) {}
  }

  Future<_ClinicProfileStep?> _askClinicProfileStep({
    required String title,
    required String nameLabel,
    required String cityLabel,
    required String streetLabel,
    required String nearLabel,
    required String phoneLabel,
    String? prefillPhone,
  }) async {
    final nameCtrl = TextEditingController();
    final cityCtrl = TextEditingController();
    final streetCtrl = TextEditingController();
    final nearCtrl = TextEditingController();
    final phoneCtrl = TextEditingController(text: prefillPhone ?? '');

    final result = await showDialog<_ClinicProfileStep>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: nameLabel),
                ),
                TextField(
                  controller: cityCtrl,
                  decoration: InputDecoration(labelText: cityLabel),
                ),
                TextField(
                  controller: streetCtrl,
                  decoration: InputDecoration(labelText: streetLabel),
                ),
                TextField(
                  controller: nearCtrl,
                  decoration: InputDecoration(labelText: nearLabel),
                ),
                TextField(
                  controller: phoneCtrl,
                  decoration: InputDecoration(labelText: phoneLabel),
                  keyboardType: TextInputType.phone,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final city = cityCtrl.text.trim();
                final street = streetCtrl.text.trim();
                final near = nearCtrl.text.trim();
                final phone = phoneCtrl.text.trim();
                if (name.isEmpty ||
                    city.isEmpty ||
                    street.isEmpty ||
                    near.isEmpty ||
                    phone.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('يرجى تعبئة جميع الحقول.')),
                  );
                  return;
                }
                Navigator.of(ctx).pop(_ClinicProfileStep(
                  name: name,
                  city: city,
                  street: street,
                  near: near,
                  phone: phone,
                ));
              },
              child: const Text('متابعة'),
            ),
          ],
        );
      },
    );

    nameCtrl.dispose();
    cityCtrl.dispose();
    streetCtrl.dispose();
    nearCtrl.dispose();
    phoneCtrl.dispose();
    return result;
  }

  String? _messageForStatus(AuthSessionStatus status) {
    switch (status) {
      case AuthSessionStatus.success:
        return null;
      case AuthSessionStatus.disabled:
        return 'قم بمراجعة الإدارة.';
      case AuthSessionStatus.accountFrozen:
        return 'تم تجميد حساب العيادة. تواصل مع الإدارة لاستعادة الوصول.';
      case AuthSessionStatus.noAccount:
        return 'للأسف تم اقصائك من الإدارة للمرفق الصحي';
      case AuthSessionStatus.planUpgradeRequired:
        return 'ناسف فالخطة الحالية للمرفق الصحي هي FREE يجب تجديد الاشتراك';
      case AuthSessionStatus.signedOut:
        return 'انتهت الجلسة أثناء التحقق من الحساب. حاول تسجيل الدخول مجددًا.';
      case AuthSessionStatus.networkError:
        return 'تعذّر التحقق من الحساب بسبب مشكلة في الاتصال. حاول مرة أخرى.';
      case AuthSessionStatus.unknown:
        return 'حدث خطأ غير متوقع أثناء التحقق من الحساب. حاول لاحقًا.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;

    if (!_routeCheckScheduled && auth.isLoggedIn && auth.isSuperAdmin) {
      _routeCheckScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          await _checkAndRouteIfSignedIn(force: true);
        } finally {
          _routeCheckScheduled = false;
        }
      });
    }

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
                      horizontal: 18,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: kPrimaryColor.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(
                            Icons.lock_rounded,
                            color: kPrimaryColor,
                            size: 26,
                          ),
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

                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'تذكرني',
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.75),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Checkbox(
                        value: _rememberMe,
                        onChanged: (value) {
                          setState(() => _rememberMe = value ?? false);
                        },
                      ),
                    ],
                  ),

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

                  // زر تسجيل الدخول
                  SizedBox(
                    width: double.infinity,
                    child: NeuButton.primary(
                      label: 'تسجيل الدخول',
                      leading: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Icon(
                              Icons.login_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.max,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      onPressed: _loading ? null : () => _submit(auth),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: NeuButton.flat(
                      label: 'إنشاء حساب جديد',
                      icon: Icons.person_add_alt_1_rounded,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.max,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      onPressed: _loading ? null : () => _signUp(auth),
                    ),
                  ),
                  const SizedBox(height: 12),
                  NeuCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'تواصل معنا',
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _ContactRow(
                          label: '+967780696069',
                          onCall: () => _callNumber('+967780696069'),
                          onWhatsApp: () => _openWhatsApp('+967780696069'),
                        ),
                        const SizedBox(height: 8),
                        _ContactRow(
                          label: '+967730696069',
                          onCall: () => _callNumber('+967730696069'),
                          onWhatsApp: () => _openWhatsApp('+967730696069'),
                        ),
                      ],
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

class _ContactRow extends StatelessWidget {
  final String label;
  final VoidCallback onCall;
  final VoidCallback onWhatsApp;

  const _ContactRow({
    required this.label,
    required this.onCall,
    required this.onWhatsApp,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.left,
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.9),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        NeuButton.flat(
          label: 'اتصال',
          icon: Icons.phone_rounded,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          onPressed: onCall,
        ),
        const SizedBox(width: 8),
        NeuButton.flat(
          label: 'واتساب',
          icon: Icons.chat_rounded,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          onPressed: onWhatsApp,
        ),
      ],
    );
  }
}

class _ClinicProfileStep {
  final String name;
  final String city;
  final String street;
  final String near;
  final String phone;

  const _ClinicProfileStep({
    required this.name,
    required this.city,
    required this.street,
    required this.near,
    required this.phone,
  });
}
