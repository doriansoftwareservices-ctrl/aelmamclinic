// lib/screens/auth/login_screen.dart
import 'dart:math' as math;
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

  static const _supportNumbers = <String>[
    '+967780696069',
    '+967730696069',
  ];

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

  Future<void> _openContactPicker({required bool whatsapp}) async {
    if (!mounted) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;

        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        whatsapp ? Icons.chat_rounded : Icons.phone_rounded,
                        color: whatsapp ? scheme.secondary : scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          whatsapp ? 'اختيار رقم واتساب' : 'اختيار رقم الاتصال',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Divider(height: 1),
                  const SizedBox(height: 6),
                  ..._supportNumbers.map((n) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        whatsapp ? Icons.chat_rounded : Icons.phone_rounded,
                        color: whatsapp ? scheme.secondary : scheme.primary,
                      ),
                      title: Text(
                        n,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      onTap: () => Navigator.of(ctx).pop(n),
                    );
                  }),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (selected == null) return;
    if (whatsapp) {
      await _openWhatsApp(selected);
    } else {
      await _callNumber(selected);
    }
  }

  @override
  void initState() {
    super.initState();

    _loadRememberedCredentials();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRouteIfSignedIn();
    });

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

    if (force ||
        !authProv.isLoggedIn ||
        (authProv.accountId ?? '').isEmpty) {
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

      var result = await auth.refreshAndValidateCurrentUser();
      if (!mounted) return;

      if (result.status == AuthSessionStatus.noAccount) {
        final clinicProfile = await _askClinicProfile();
        if (clinicProfile == null) {
          await auth.signOut();
          setState(() => _error = 'اسم العيادة مطلوب لإكمال إنشاء الحساب.');
          return;
        }
        auth.setPendingClinicProfile(clinicProfile);
        Object? createError;
        try {
          await auth.selfCreateAccount(clinicProfile);
        } catch (e) {
          createError = e;
        }
        final recheck = await auth.refreshAndValidateCurrentUser();
        if (!mounted) return;
        if (!recheck.isSuccess) {
          if (recheck.status == AuthSessionStatus.noAccount ||
              recheck.status == AuthSessionStatus.planUpgradeRequired) {
            await auth.signOut();
          }
          final base = _messageForStatus(recheck.status) ??
              'تعذّر التحقق من الحساب. حاول مرة أخرى.';
          if (createError != null) {
            final mapped = _mapLoginError(createError);
            setState(() => _error = 'تعذّر إنشاء الحساب: $mapped');
          } else {
            setState(() => _error = base);
          }
          return;
        }
        result = recheck;
      }

      if (!result.isSuccess) {
        if (result.status == AuthSessionStatus.planUpgradeRequired) {
          final role = auth.role?.toLowerCase();
          if (role == 'owner' || role == 'admin') {
            // owners/admins can upgrade from داخل التطبيق.
          } else {
            await auth.signOut();
            final message = _messageForStatus(result.status) ??
                'تعذّر التحقق من الحساب. حاول مرة أخرى.';
            setState(() => _error = message);
            return;
          }
        } else if (result.status == AuthSessionStatus.noAccount) {
          await auth.signOut();
          final message = _messageForStatus(result.status) ??
              'تعذّر التحقق من الحساب. حاول مرة أخرى.';
          setState(() => _error = message);
          return;
        } else {
          final message = _messageForStatus(result.status) ??
              'تعذّر التحقق من الحساب. حاول مرة أخرى.';
          setState(() => _error = message);
          return;
        }
      }

      await _ensureClinicProfileComplete(auth);

      if (auth.isLoggedIn) {
        await auth.bootstrapSync(
          pull: true,
          realtime: true,
          enableLogs: kDebugMode,
          debounce: const Duration(seconds: 1),
        );
        _bootstrappedOnce = true;
      }

      await _checkAndRouteIfSignedIn(force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mapLoginError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
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
      if (mounted) setState(() => _loading = false);
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

    final isEnglish = title.toLowerCase().contains('english') ||
        title.toLowerCase().contains('clinic');

    final result = await showDialog<_ClinicProfileStep>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;

        InputDecoration dec(String label, IconData icon) {
          return InputDecoration(
            labelText: label,
            prefixIcon: Icon(icon),
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.55)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.55)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: scheme.primary.withValues(alpha: 0.9),
                width: 1.2,
              ),
            ),
          );
        }

        return Directionality(
          textDirection: isEnglish ? TextDirection.ltr : TextDirection.rtl,
          child: Dialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            scheme.surface,
                            scheme.surfaceContainerHighest
                                .withValues(alpha: 0.75),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: -60,
                    right: -60,
                    child: _BlurBlob(
                      size: 180,
                      color: scheme.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _NeoIconBadge(
                              icon: Icons.assignment_rounded,
                              size: 44,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w900,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isEnglish
                                        ? 'Please fill all fields to complete account setup.'
                                        : 'يرجى تعبئة جميع الحقول لإكمال إنشاء الحساب.',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: scheme.onSurface
                                          .withValues(alpha: 0.65),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: nameCtrl,
                          decoration:
                              dec(nameLabel, Icons.local_hospital_rounded),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: cityCtrl,
                          decoration:
                              dec(cityLabel, Icons.location_city_rounded),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: streetCtrl,
                          decoration: dec(streetLabel, Icons.signpost_rounded),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: nearCtrl,
                          decoration: dec(nearLabel, Icons.place_rounded),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: phoneCtrl,
                          decoration: dec(phoneLabel, Icons.phone_rounded),
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: Text(isEnglish ? 'Cancel' : 'إلغاء'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
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
                                      SnackBar(
                                        content: Text(
                                          isEnglish
                                              ? 'Please fill all fields.'
                                              : 'يرجى تعبئة جميع الحقول.',
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  Navigator.of(ctx).pop(
                                    _ClinicProfileStep(
                                      name: name,
                                      city: city,
                                      street: street,
                                      near: near,
                                      phone: phone,
                                    ),
                                  );
                                },
                                style: FilledButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: Text(isEnglish ? 'Continue' : 'متابعة'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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

  String _mapLoginError(Object error) {
    final msg = error.toString();
    final lower = msg.toLowerCase();
    if (lower.contains('invalid-email-password') ||
        lower.contains('incorrect email or password') ||
        lower.contains('statuscode=401') ||
        lower.contains('status: 401')) {
      return 'البريد الإلكتروني أو كلمة المرور غير صحيحة.';
    }
    if (lower.contains('invalid-email') ||
        lower.contains('email format') ||
        lower.contains('bad email')) {
      return 'صيغة البريد الإلكتروني غير صحيحة.';
    }
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('network') ||
        lower.contains('connection')) {
      return 'تعذّر الاتصال بالخادم. تحقّق من الإنترنت وحاول مرة أخرى.';
    }
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('no stream event') ||
        lower.contains('503') ||
        lower.contains('bad gateway') ||
        lower.contains('temporarily unavailable') ||
        lower.contains('service unavailable')) {
      return 'الخادم غير متاح مؤقتًا. انتظر قليلًا ثم أعد المحاولة.';
    }
    return 'فشل تسجيل الدخول. حاول مرة أخرى.';
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

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          centerTitle: true,
          elevation: 0,
          backgroundColor: scheme.surface,
          surfaceTintColor: scheme.surface,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/logo.png',
                height: 22,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              const Text('تسجيل الدخول'),
            ],
          ),
        ),
        body: Stack(
          children: [
            _AnimatedBubbleBackdrop(scheme: scheme),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: kScreenPadding,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          elevation: 0,
                          color: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: BorderSide(
                              color:
                                  scheme.outlineVariant.withValues(alpha: 0.25),
                              width: 0.7,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Center(
                                  child: Image.asset(
                                    'assets/images/logo.png',
                                    height: 56,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  AppConstants.appName,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 18,
                                    color: scheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'أدخل بيانات الدخول للمتابعة',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5,
                                    color: scheme.onSurface
                                        .withValues(alpha: 0.65),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                NeuField(
                                  controller: _email,
                                  labelText: 'البريد الإلكتروني',
                                  keyboardType: TextInputType.emailAddress,
                                  textInputAction: TextInputAction.next,
                                  prefix:
                                      const Icon(Icons.alternate_email_rounded),
                                  onChanged: (_) {
                                    if (_error != null)
                                      setState(() => _error = null);
                                  },
                                ),
                                const SizedBox(height: 12),
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
                                    if (_error != null)
                                      setState(() => _error = null);
                                  },
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Checkbox(
                                      value: _rememberMe,
                                      onChanged: (v) => setState(
                                          () => _rememberMe = v ?? false),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'تذكرني على هذا الجهاز',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSurface
                                              .withValues(alpha: 0.80),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: 8),
                                  _ErrorBanner(text: _error!),
                                ],
                                const SizedBox(height: 12),
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
                                                  AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                            ),
                                          )
                                        : const Icon(Icons.login_rounded,
                                            color: Colors.white, size: 20),
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.max,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 16,
                                    ),
                                    onPressed:
                                        _loading ? null : () => _submit(auth),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: NeuButton.flat(
                                    label: 'إنشاء حساب جديد',
                                    icon: Icons.person_add_alt_1_rounded,
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.max,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 14,
                                    ),
                                    onPressed:
                                        _loading ? null : () => _signUp(auth),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _SupportBar(
                          onCall: _loading
                              ? null
                              : () => _openContactPicker(whatsapp: false),
                          onWhatsApp: _loading
                              ? null
                              : () => _openContactPicker(whatsapp: true),
                        ),
                      ],
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

class _BlurBlob extends StatelessWidget {
  const _BlurBlob({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _AnimatedBubbleBackdrop extends StatefulWidget {
  const _AnimatedBubbleBackdrop({required this.scheme});
  final ColorScheme scheme;

  @override
  State<_AnimatedBubbleBackdrop> createState() =>
      _AnimatedBubbleBackdropState();
}

class _AnimatedBubbleBackdropState extends State<_AnimatedBubbleBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_BubbleParticle> _bubbles;
  Size _size = Size.zero;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _bubbles = _createBubbles(widget.scheme);
    _controller.addListener(_tick);
  }

  @override
  void didUpdateWidget(covariant _AnimatedBubbleBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scheme != widget.scheme) {
      _bubbles.clear();
      _bubbles.addAll(_createBubbles(widget.scheme));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_BubbleParticle> _createBubbles(ColorScheme scheme) {
    final rng = math.Random(42);
    return List.generate(28, (i) {
      final radius = 11 + rng.nextDouble() * 14;
      final x = rng.nextDouble();
      final y = rng.nextDouble();
      final speed = 8 + rng.nextDouble() * 14;
      final angle = rng.nextDouble() * math.pi * 2;
      final vx = math.cos(angle) * speed;
      final vy = math.sin(angle) * speed;
      final color = (i % 3 == 0
              ? scheme.primary
              : (i % 3 == 1 ? scheme.secondary : scheme.tertiary))
          .withValues(alpha: 0.18);
      return _BubbleParticle(
        pos: Offset(x, y),
        vel: Offset(vx, vy),
        radius: radius,
        color: color,
      );
    });
  }

  void _ensureSize(Size size) {
    if (_size == size || size.isEmpty) return;
    _size = size;
    for (final b in _bubbles) {
      if (!b.initialized) {
        b.pos = Offset(b.pos.dx * _size.width, b.pos.dy * _size.height);
        b.initialized = true;
      }
    }
  }

  void _tick() {
    if (!mounted || _size.isEmpty) return;
    final elapsed = _controller.lastElapsedDuration;
    if (elapsed == null) return;
    final last = _lastTick ?? elapsed;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) return;
    _step(dt.clamp(0.0, 0.05));
  }

  void _step(double dt) {
    // Update positions
    for (final b in _bubbles) {
      b.pos = Offset(
        b.pos.dx + b.vel.dx * dt,
        b.pos.dy + b.vel.dy * dt,
      );

      // Wall collisions
      if (b.pos.dx - b.radius < 0) {
        b.pos = Offset(b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      } else if (b.pos.dx + b.radius > _size.width) {
        b.pos = Offset(_size.width - b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      }
      if (b.pos.dy - b.radius < 0) {
        b.pos = Offset(b.pos.dx, b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      } else if (b.pos.dy + b.radius > _size.height) {
        b.pos = Offset(b.pos.dx, _size.height - b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      }
    }

    // Simple elastic collisions
    for (var i = 0; i < _bubbles.length; i++) {
      for (var j = i + 1; j < _bubbles.length; j++) {
        final a = _bubbles[i];
        final b = _bubbles[j];
        final dx = b.pos.dx - a.pos.dx;
        final dy = b.pos.dy - a.pos.dy;
        final dist = math.sqrt(dx * dx + dy * dy);
        final minDist = a.radius + b.radius;
        if (dist == 0 || dist >= minDist) continue;

        final nx = dx / dist;
        final ny = dy / dist;
        final rvx = b.vel.dx - a.vel.dx;
        final rvy = b.vel.dy - a.vel.dy;
        final velAlongNormal = rvx * nx + rvy * ny;

        if (velAlongNormal < 0) {
          final impulse = -velAlongNormal;
          a.vel = Offset(
            a.vel.dx - impulse * nx,
            a.vel.dy - impulse * ny,
          );
          b.vel = Offset(
            b.vel.dx + impulse * nx,
            b.vel.dy + impulse * ny,
          );
        }

        final overlap = minDist - dist;
        if (overlap > 0) {
          final correction = overlap / 2;
          a.pos = Offset(a.pos.dx - nx * correction, a.pos.dy - ny * correction);
          b.pos = Offset(b.pos.dx + nx * correction, b.pos.dy + ny * correction);
        }
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _ensureSize(constraints.biggest);
          return CustomPaint(
            painter: _BubblePainter(
              bubbles: _bubbles,
              scheme: widget.scheme,
            ),
          );
        },
      ),
    );
  }
}

class _BubbleParticle {
  _BubbleParticle({
    required this.pos,
    required this.vel,
    required this.radius,
    required this.color,
  });

  Offset pos;
  Offset vel;
  final double radius;
  final Color color;
  bool initialized = false;
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({
    required this.bubbles,
    required this.scheme,
  });

  final List<_BubbleParticle> bubbles;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bgPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          scheme.surface,
          scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          scheme.surface,
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    for (final bubble in bubbles) {
      final paint = Paint()..color = bubble.color;
      canvas.drawCircle(bubble.pos, bubble.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) {
    return oldDelegate.bubbles != bubbles || oldDelegate.scheme != scheme;
  }
}

class _NeoIconBadge extends StatelessWidget {
  const _NeoIconBadge({
    required this.icon,
    required this.size,
    required this.color,
  });

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highlight = (isDark ? Colors.white : Colors.white)
        .withValues(alpha: isDark ? 0.08 : 0.65);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surface,
        boxShadow: [
          BoxShadow(
            color: highlight,
            offset: const Offset(-6, -6),
            blurRadius: 14,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
            offset: const Offset(8, 10),
            blurRadius: 18,
          ),
        ],
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Icon(icon, color: color),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SupportBar extends StatelessWidget {
  const _SupportBar({
    required this.onCall,
    required this.onWhatsApp,
  });

  final VoidCallback? onCall;
  final VoidCallback? onWhatsApp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.25),
          width: 0.7,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.support_agent_rounded, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'الدعم الفني',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: scheme.onSurface,
                ),
              ),
            ),
            _SupportIconButton(
              tooltip: 'اتصال',
              icon: Icons.phone_rounded,
              onTap: onCall,
            ),
            const SizedBox(width: 10),
            _SupportIconButton(
              tooltip: 'واتساب',
              icon: Icons.chat_rounded,
              onTap: onWhatsApp,
            ),
          ],
        ),
      ),
    );
  }
}

class _SupportIconButton extends StatelessWidget {
  const _SupportIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Icon(icon, color: scheme.primary),
        ),
      ),
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
