// lib/core/features.dart
//
// أدوات موحّدة لإدارة "ميزات" التطبيق (Feature Flags/Permissions)
// - تعريف مفاتيح الميزات FeatureKeys لاستخدام واحد في جميع الشاشات.
// - Widget FeatureGate لإخفاء/تعطيل عناصر الواجهة اعتمادًا على الصلاحيات.
// - Widget FeatureSwitch يمرّر حالة السماحية إلى builder.
// - توابع مختصرة عبر BuildContext لقراءة السماحية.
// ملاحظات:
// * يفترض أن AuthProvider يملك الحقول/الواجهات التالية:
//    - bool get isSuperAdmin
//    - String? get role
//    - bool featureAllowed(String featureKey)          ← تتحقق من allowed_features
//    - bool get canCreate / canUpdate / canDelete      ← CRUD من account_feature_permissions
// * في حال لم تكن هذه الواجهات متوفرة (مثلاً قبل دمج التعديلات على AuthProvider)
//   فالكود يحاول الاستدعاء ديناميكيًا، ويعتمد "سماحية افتراضية" لا تمنع الواجهة (fail-open)
//   حتى لا تنكسر الواجهة. بعد دمج AuthProvider المحدّث، سيعمل الفلتر بدقة.
//

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';

/// مفاتيح الميزات كما تُخزّن في account_feature_permissions.allowed_features
class FeatureKeys {
  static const String dashboard = 'dashboard';
  static const String patientNew = 'patients.new';
  static const String patientsList = 'patients.list';
  static const String returns = 'returns';
  static const String employees = 'employees';
  static const String payments = 'payments';
  static const String labRadiology = 'lab_radiology';
  static const String charts = 'charts';
  static const String repository = 'repository';
  static const String prescriptions = 'prescriptions';
  static const String patientQuestions = 'patients.questions';
  static const String clinicProfile = 'clinic.profile';
  static const String backup = 'backup';
  static const String accounts = 'accounts'; // إدارة المستخدمين داخل الحساب
  static const String employeeAccounts = 'employee.accounts';
  static const String chat = 'chat'; // 🔹 ميزة الدردشة
  static const String auditLogs = 'audit.logs';
  static const String auditPermissions = 'audit.permissions';

  static const List<String> all = [
    dashboard,
    patientNew,
    patientsList,
    returns,
    employees,
    payments,
    labRadiology,
    charts,
    repository,
    prescriptions,
    patientQuestions,
    clinicProfile,
    backup,
    accounts,
    employeeAccounts,
    chat,
    auditLogs,
    auditPermissions,
  ];
}

/// متطلبات CRUD اختيارية عند التحقق من ميزة معيّنة
class FeatureNeeds {
  final bool create;
  final bool update;
  final bool delete;

  const FeatureNeeds(
      {this.create = false, this.update = false, this.delete = false});

  static const none = FeatureNeeds();
  FeatureNeeds requireCreate() =>
      FeatureNeeds(create: true, update: update, delete: delete);
  FeatureNeeds requireUpdate() =>
      FeatureNeeds(create: create, update: true, delete: delete);
  FeatureNeeds requireDelete() =>
      FeatureNeeds(create: create, update: update, delete: true);
}

/// خيارات التصرف عند المنع
enum DenyBehavior {
  /// إخفاء عنصر الواجهة تمامًا
  hide,

  /// إبقاء العنصر ظاهرًا لكن غير فعّال (Disabled) ويمكن اعتراض النقر لعرض رسالة
  disable,
}

/// أداة خفيفة للوصول الموحّد إلى الصلاحيات من AuthProvider مع تحمّل النواقص
class FeatureAccess {
  final Object auth;

  FeatureAccess(this.auth);

  /// تحمل غياب isSuperAdmin/role أثناء التطوير
  bool get isSuperAdmin {
    try {
      final dyn = auth as dynamic;
      final v = dyn.isSuperAdmin;
      if (v is bool) return v;
      final role = dyn.role;
      if (role is String) {
        return role.toLowerCase() == 'superadmin';
      }
    } catch (_) {}
    return false;
  }

  bool get _permissionsReady {
    try {
      final dyn = auth as dynamic;
      final ready = dyn.permissionsLoaded;
      if (ready is bool) return ready;
    } catch (_) {}
    return false;
  }

  bool _safeFeatureAllowed(String key) {
    if (!_permissionsReady) return false;
    // نحاول استدعاء دالة featureAllowed إن كانت متوفرة في AuthProvider المحدَّث
    try {
      final dyn = auth as dynamic;
      final res = dyn.featureAllowed(key);
      if (res is bool) return res;
    } catch (_) {/* تجاهل */}
    return false;
  }

  bool _safeCanCreate() {
    if (!_permissionsReady) return false;
    try {
      final dyn = auth as dynamic;
      final v = dyn.canCreate;
      if (v is bool) return v;
    } catch (_) {}
    return false;
  }

  bool _safeCanUpdate() {
    if (!_permissionsReady) return false;
    try {
      final dyn = auth as dynamic;
      final v = dyn.canUpdate;
      if (v is bool) return v;
    } catch (_) {}
    return false;
  }

  bool _safeCanDelete() {
    if (!_permissionsReady) return false;
    try {
      final dyn = auth as dynamic;
      final v = dyn.canDelete;
      if (v is bool) return v;
    } catch (_) {}
    return false;
  }

  /// هل الميزة مسموحة مع مراعاة متطلبات CRUD (اختياريًا)
  bool allowed(String featureKey, {FeatureNeeds needs = FeatureNeeds.none}) {
    // تيسير التطوير: حذّر في debug عند استخدام مفتاح غير معرّف (لا يوقف التنفيذ)
    if (kDebugMode && !FeatureKeys.all.contains(featureKey)) {
      debugPrint(
          '[FeatureAccess] تحذير: featureKey="$featureKey" غير موجود في FeatureKeys.all');
    }

    if (isSuperAdmin) return true;
    if (!_permissionsReady) return false;

    final featOk = _safeFeatureAllowed(featureKey);
    if (!featOk) return false;

    // تطبيق متطلبات CRUD إن طُلِبت
    if (needs.create && !_safeCanCreate()) return false;
    if (needs.update && !_safeCanUpdate()) return false;
    if (needs.delete && !_safeCanDelete()) return false;

    return true;
  }
}

/// ويدجت لحماية/إخفاء جزء من الواجهة بناءً على ميزة معيّنة
class FeatureGate extends StatelessWidget {
  final String featureKey;
  final FeatureNeeds needs;
  final DenyBehavior onDeny;
  final Widget child;
  final Widget? loading;

  /// ردّة فعل عند النقر على عنصر معطّل. إن لم تُمرَّر سيعرض Snackbar افتراضيًا.
  final VoidCallback? onDeniedTap;

  /// نص تلميح (Tooltip) يُعرض عندما يكون العنصر معطّل
  final String? deniedTooltip;

  const FeatureGate({
    super.key,
    required this.featureKey,
    this.needs = FeatureNeeds.none,
    this.onDeny = DenyBehavior.disable,
    required this.child,
    this.loading,
    this.onDeniedTap,
    this.deniedTooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (_, auth, __) {
        final fx = FeatureAccess(auth);
        final waiting = !auth.permissionsLoaded && !fx.isSuperAdmin;
        if (waiting) {
          return loading ?? const _FeatureLoadingPlaceholder();
        }
        final ok = fx.allowed(featureKey, needs: needs);

        if (ok) return child;

        if (onDeny == DenyBehavior.hide) {
          return const SizedBox.shrink();
        }

        // حالة التعطيل: نغلف العنصر بـ IgnorePointer وطبقة تلتقط النقر لعرض رسالة
        final wrapper = _DisabledWrapper(
          onTap: onDeniedTap ??
              () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('ليس لديك صلاحية للوصول إلى هذه الميزة'),
                      behavior: SnackBarBehavior.floating,
                      duration: Duration(seconds: 2),
                    ),
                  ),
          child: child,
        );

        if ((deniedTooltip ?? '').isEmpty) return wrapper;
        return Tooltip(message: deniedTooltip, child: wrapper);
      },
    );
  }
}

/// Builder يُمرِّر حالة السماحية للواجهة بدل الإخفاء/التعطيل التلقائي.
class FeatureSwitch extends StatelessWidget {
  final String featureKey;
  final FeatureNeeds needs;
  final Widget? loading;
  final Widget Function(BuildContext context, bool allowed) builder;

  const FeatureSwitch({
    super.key,
    required this.featureKey,
    required this.builder,
    this.needs = FeatureNeeds.none,
    this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (_, auth, __) {
        final fx = FeatureAccess(auth);
        final waiting = !auth.permissionsLoaded && !fx.isSuperAdmin;
        if (waiting) {
          return loading ?? const _FeatureLoadingPlaceholder();
        }
        final ok = fx.allowed(featureKey, needs: needs);
        return builder(context, ok);
      },
    );
  }
}

/// غلاف بسيط لتعطيل التفاعل بصريًا ووظيفيًا مع إمكانية تنبيه المستخدم
class _DisabledWrapper extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _DisabledWrapper({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // مظهر معطّل + منع التفاعل الأصلي
        Opacity(
          opacity: 0.45,
          child: IgnorePointer(ignoring: true, child: child),
        ),
        // طبقة تلتقط النقر لعرض رسالة أو تنفيذ onTap
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(onTap: onTap),
          ),
        ),
      ],
    );
  }
}

class _FeatureLoadingPlaceholder extends StatelessWidget {
  const _FeatureLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'جاري تحميل الصلاحيات...',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// امتدادات مريحة على BuildContext
extension FeatureContextX on BuildContext {
  /// اختصار: هل الميزة مسموحة؟ مع متطلبات CRUD اختيارية
  bool featureAllowed(
    String featureKey, {
    FeatureNeeds needs = FeatureNeeds.none,
  }) {
    final auth = this.read<AuthProvider>();
    return FeatureAccess(auth).allowed(featureKey, needs: needs);
  }

  /// اختصار لعرض SnackBar منع الوصول
  void showNotAllowedSnack({String? message}) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message ?? 'ليس لديك صلاحية للوصول إلى هذه الميزة'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
