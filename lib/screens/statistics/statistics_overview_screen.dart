// lib/screens/statistics/statistics_overview_screen.dart

import 'dart:async';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/features.dart';

import 'package:aelmamclinic/providers/statistics_provider.dart';
import 'package:aelmamclinic/services/db_service.dart';

/*── شاشات مختلفة ───────────────────────────────────────────*/
import 'package:aelmamclinic/services/backup_restore_service.dart';
import 'package:aelmamclinic/screens/drugs/drug_list_screen.dart';
import 'package:aelmamclinic/screens/employees/employees_home_screen.dart';
import 'package:aelmamclinic/screens/patients/list_patients_screen.dart';
import 'package:aelmamclinic/screens/patients/new_patient_screen.dart';
import 'package:aelmamclinic/screens/patient_questions/complaint_templates_screen.dart';
import 'package:aelmamclinic/screens/payments/payments_home_screen.dart';
import 'package:aelmamclinic/screens/prescriptions/patient_prescriptions_screen.dart';
import 'package:aelmamclinic/screens/prescriptions/prescription_list_screen.dart';
import 'package:aelmamclinic/screens/reminders/reminder_screen.dart';
import 'package:aelmamclinic/screens/repository/menu/repository_menu_screen.dart';
import 'package:aelmamclinic/screens/help/user_guide_screen.dart';
import 'package:aelmamclinic/screens/returns/list_returns_screen.dart';
import 'package:aelmamclinic/screens/returns/new_return_screen.dart';
import 'package:aelmamclinic/screens/statistics/statistics_screen.dart';

/*── شاشة الأشعة والمختبرات ─*/
/*── استيرادات لإدارة الحسابات ─*/
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/chat_provider.dart';
import 'package:aelmamclinic/screens/users/employee_accounts_screen.dart';
import 'package:aelmamclinic/screens/users/users_screen.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';

/*── شاشات التدقيق والصلاحيات (جديدة في الـ Drawer للمالك فقط) ─*/
import 'package:aelmamclinic/screens/audit/logs_screen.dart';
import 'package:aelmamclinic/screens/audit/permissions_screen.dart';

/*── شاشة الدردشة ─*/
import 'package:aelmamclinic/screens/chat/chat_home_screen.dart';
import 'package:aelmamclinic/screens/complaints/complaints_screen.dart';
import 'package:aelmamclinic/screens/clinic/clinic_profile_screen.dart';
import 'package:aelmamclinic/screens/subscription/my_plan_screen.dart';
import 'package:aelmamclinic/utils/chat_code_utils.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
import 'package:aelmamclinic/widgets/language_switch_button.dart';

/*── لتسجيل الخروج ─*/
import 'package:aelmamclinic/screens/auth/login_screen.dart';
import 'package:aelmamclinic/screens/admin/admin_dashboard_screen.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

/// غيّر هذا الثابت حسب المطلوب:
/// true  → إخفاء العناصر غير المسموح بها.
/// false → إظهارها لكن تعطيل التفاعل مع تنبيه المستخدم.
const bool kHideDeniedTabs = false;

class StatisticsOverviewScreen extends StatefulWidget {
  const StatisticsOverviewScreen({super.key});

  @override
  State<StatisticsOverviewScreen> createState() =>
      _StatisticsOverviewScreenState();
}

class _StatisticsOverviewScreenState extends State<StatisticsOverviewScreen>
    with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // عدّاد المحادثات غير المقروءة (يأتي من ChatProvider)
  StreamSubscription<String>? _dbChangesSub;
  bool _hasComplaintReply = false;
  AuthProvider? _authListener;
  String _lastPlanStamp = '';

  int? _planDaysLeft;
  bool _planExpirySoon = false;

  // حالة الترحيب لأول مرة/مرحبًا بعودتك — تُحتسب مرة واحدة ثم نحدّث التخزين
  late final Future<bool> _firstOpenFuture = _getAndMarkFirstOpenForUser();

  Future<void> _exportClinicHtml() async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final file = await BackupRestoreService.exportClinicHtml();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تم إنشاء ملف HTML في Downloads:\n${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذّر استخراج البيانات: $e')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.canEnterRemoteAdminShell) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
        );
      }
    });
    final auth = context.read<AuthProvider>();
    if (auth.canEnterRemoteAdminShell) {
      return;
    }
    _refreshComplaintsBadge();
    _dbChangesSub = DBService.instance.changes.listen((table) {
      if (table == 'complaints') {
        _refreshComplaintsBadge();
      }
    });
    _attachAuthListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPlanUiFromAuth();
    });
  }

  void _attachAuthListener() {
    final auth = context.read<AuthProvider>();
    _authListener = auth;
    _lastPlanStamp = _planStamp(auth);
    auth.addListener(_handleAuthChanged);
  }

  String _planStamp(AuthProvider auth) {
    final code = auth.planCode.toLowerCase();
    final end = auth.planEndAt?.toUtc().toIso8601String() ?? '';
    return '$code|$end';
  }

  void _handleAuthChanged() {
    if (!mounted) return;
    final auth = _authListener;
    if (auth == null) return;
    final stamp = _planStamp(auth);
    if (stamp == _lastPlanStamp) return;
    _lastPlanStamp = stamp;
    _syncPlanUiFromAuth();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
  }

  @override
  void dispose() {
    _dbChangesSub?.cancel();
    _authListener?.removeListener(_handleAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshComplaintsBadge() async {
    try {
      final db = await DBService.instance.database;
      final cols = await db.rawQuery('PRAGMA table_info(complaints)');
      final hasReplyMessage =
          cols.any((c) => (c['name']?.toString() ?? '') == 'reply_message');
      final where = hasReplyMessage
          ? "(IFNULL(replyMessage, '') != '' OR IFNULL(reply_message, '') != '')"
          : "IFNULL(replyMessage, '') != ''";
      final rows = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM complaints WHERE $where AND IFNULL(replySeen, 0) = 0",
      );
      final count = (rows.first['c'] as int?) ?? 0;
      if (!mounted) return;
      setState(() => _hasComplaintReply = count > 0);
    } catch (_) {
      if (!mounted) return;
      setState(() => _hasComplaintReply = false);
    }
  }

  Future<void> _syncPlanUiFromAuth() async {
    await _checkPlanExpiryNotice();
    await _checkPlanUpgradeNotice();
  }

  Future<void> _checkPlanExpiryNotice() async {
    final auth = context.read<AuthProvider>();
    if (auth.isSuperAdmin) return;
    if ((auth.role ?? '').toLowerCase() != 'owner') {
      if (!mounted) return;
      setState(() {
        _planDaysLeft = null;
        _planExpirySoon = false;
      });
      return;
    }
    final planCode = auth.planCode.toLowerCase();
    final endAt = auth.planEndAt?.toLocal();
    if (!mounted) return;
    if (planCode == 'free' || endAt == null) {
      setState(() {
        _planDaysLeft = null;
        _planExpirySoon = false;
      });
      return;
    }
    final daysLeft = endAt.difference(DateTime.now()).inDays;
    final show = daysLeft >= 0 && daysLeft <= 7;
    setState(() {
      _planDaysLeft = daysLeft;
      _planExpirySoon = show;
    });
  }

  Future<void> _checkPlanUpgradeNotice() async {
    final auth = context.read<AuthProvider>();
    if (auth.isSuperAdmin) return;
    final role = auth.role?.toLowerCase();
    if (role != 'owner' && role != 'admin') return;
    final uid = auth.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final planCode = auth.planCode.toLowerCase();
      final endAt = auth.planEndAt;
      if (planCode == 'free' || endAt == null) return;

      final sp = await SharedPreferences.getInstance();
      final key = 'plan.upgrade.notice.$uid';
      final stamp = '$planCode|${endAt.toIso8601String()}';
      final last = sp.getString(key);
      if (last == stamp) return;
      await sp.setString(key, stamp);
      if (!mounted) return;

      final planLabel = _planNameFromCode(planCode);
      final endStr = DateFormat('yyyy-MM-dd').format(endAt.toLocal());
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const LocalizedText('تمت الموافقة على الترقية'),
          content: LocalizedText(
            _planUpgradeApprovalMessage(
              context,
              planLabel: planLabel,
              endStr: endStr,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const LocalizedText('تم'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  String _planNameFromCode(String code) {
    final c = code.toLowerCase();
    if (c == 'year_pro') return 'السنوية برو';
    if (c == 'year_plus') return 'السنوية بلس';
    if (c == 'year' || c.contains('annual')) return 'السنوية';
    if (c == 'trial_month') return 'التجريبية الشهرية';
    if (c == 'month_pro') return 'الشهرية برو القديمة';
    if (c == 'month_plus') return 'الشهرية بلس القديمة';
    if (c == 'month') return 'الشهرية القديمة';
    if (c == 'free') return 'المجانية';
    return c.toUpperCase();
  }

  String _planUpgradeApprovalMessage(
    BuildContext context, {
    required String planLabel,
    required String endStr,
  }) {
    final localizedPlan = context.trRaw(planLabel);
    final localizedEnd = AppFormatters.localizeDigits(
      endStr,
      languageCode: context.currentLocaleCode,
    );
    final isTrial = planLabel == 'التجريبية الشهرية';
    if (context.currentLocaleCode == 'en') {
      return isTrial
          ? 'Your monthly trial activation request was approved.\n'
              'The $localizedPlan plan is now active and ends on $localizedEnd.\n'
              'Please sign out and sign in again to enable the new features.'
          : 'Your upgrade request was reviewed and approved.\n'
              'The $localizedPlan plan has been activated and ends on $localizedEnd.\n'
              'Please sign out and sign in again to enable the new features.';
    }
    return isTrial
        ? 'تمت مراجعة طلب التفعيل التجريبي والموافقة عليه.\n'
            'تم تفعيل الخطة $localizedPlan وتنتهي بتاريخ $localizedEnd.\n'
            'يرجى تسجيل الخروج والدخول مرة أخرى لتفعيل المميزات الجديدة.'
        : 'تمت مراجعة طلبك والموافقة عليه.\n'
            'تم تفعيل الخطة $localizedPlan وتنتهي بتاريخ $localizedEnd.\n'
            'يرجى تسجيل الخروج والدخول مرة أخرى لتفعيل المميزات الجديدة.';
  }

  Widget _buildPlanExpiryBanner() {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.read<AuthProvider>();
    final isOwner = auth.role?.toLowerCase() == 'owner';
    final daysLeft = _planDaysLeft ?? 0;
    final msg = context.currentLocaleCode == 'en'
        ? (daysLeft == 0
            ? 'Your plan ends today. Renewing is recommended.'
            : 'Your plan ends in ${AppFormatters.localizeDigits('$daysLeft')} ${daysLeft == 1 ? 'day' : 'days'}.')
        : (daysLeft == 0
            ? 'تنتهي خطتك اليوم. يُفضّل تجديد الاشتراك.'
            : 'تنتهي خطتك خلال ${AppFormatters.localizeDigits('$daysLeft')} يوم.');
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: LocalizedText(
              msg,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (isOwner)
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MyPlanScreen()),
              ),
              child: const LocalizedText('تجديد'),
            ),
        ],
      ),
    );
  }

  void _showNotAllowedSnack() {
    final auth = context.read<AuthProvider>();
    final isFree = auth.planCode == 'free' && !auth.isSuperAdmin;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: LocalizedText(isFree
            ? 'هذه الميزة متاحة للخطط المدفوعة فقط.'
            : 'ليس لديك صلاحية للوصول إلى هذه الميزة'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _handleDeniedAccess() {
    final auth = context.read<AuthProvider>();
    final isFree = auth.planCode == 'free' && !auth.isSuperAdmin;
    final role = auth.role?.toLowerCase();
    final canUpgrade = role == 'owner';
    _showNotAllowedSnack();
    if (!isFree || !canUpgrade) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MyPlanScreen()),
    );
  }

  void _showUnderDevelopmentNotice() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('dashboard_under_development_notice')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openMyPlanFromDrawer() {
    final auth = context.read<AuthProvider>();
    final isFree = auth.planCode == 'free' && !auth.isSuperAdmin;
    final role = auth.role?.toLowerCase();
    final canUpgrade = role == 'owner';
    _showNotAllowedSnack();
    if (!isFree || !canUpgrade) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MyPlanScreen()),
    );
  }

  /// يحدد إن كانت هذه أول مرة يفتح فيها هذا المستخدم (UID) التطبيق على هذا الجهاز
  /// ثم يضع العلامة ليصبح لاحقًا "مرحبًا بعودتك".
  Future<bool> _getAndMarkFirstOpenForUser() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = NhostManager.client.auth.currentUser?.id ?? 'anonymous';
    final key = 'welcome_seen_$uid';
    final seen = prefs.getBool(key) ?? false;
    if (!seen) {
      await prefs.setBool(key, true);
    }
    return !seen; // true = أول مرة
  }

  /*──────── قائمة العودات المنبثقة────────*/
  void _showReturnsMenu(BuildContext ctx) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final scheme = Theme.of(ctx).colorScheme;

    final canView =
        auth.isSuperAdmin || auth.featureAllowed(FeatureKeys.returns);
    final canCreate = auth.isSuperAdmin ||
        (auth.featureAllowed(FeatureKeys.returns) && auth.canCreate);

    if (!canView) {
      _handleDeniedAccess();
      return;
    }

    showModalBottomSheet(
      context: ctx,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: ListTile(
                  enabled: canCreate,
                  leading: const Icon(Icons.add_circle_outline),
                  title: const LocalizedText('إنشاء عودة',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  trailing: Icon(
                    context.isRtl
                        ? Icons.chevron_left_rounded
                        : Icons.chevron_right_rounded,
                  ),
                  onTap: canCreate
                      ? () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => NewReturnScreen()),
                          );
                        }
                      : () {
                          Navigator.pop(ctx);
                          _handleDeniedAccess();
                        },
                ),
              ),
              const SizedBox(height: 8),
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: ListTile(
                  enabled: canView,
                  leading: const Icon(Icons.list_alt_outlined),
                  title: const LocalizedText('استعراض العودات',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  trailing: Icon(
                    context.isRtl
                        ? Icons.chevron_left_rounded
                        : Icons.chevron_right_rounded,
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ListReturnsScreen()),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /*──────── قائمة الوصفات الطبية المنبثقة────────*/
  void _showPrescriptionsMenu(BuildContext ctx) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final scheme = Theme.of(ctx).colorScheme;

    final allowed =
        auth.isSuperAdmin || auth.featureAllowed(FeatureKeys.prescriptions);
    if (!allowed) {
      _handleDeniedAccess();
      return;
    }

    showModalBottomSheet(
      context: ctx,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            NeuCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: ListTile(
                leading: const Icon(Icons.medication_outlined),
                title: const LocalizedText('إدارة الأدوية',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                trailing: Icon(
                  context.isRtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DrugListScreen()),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            NeuCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: ListTile(
                leading: const Icon(Icons.medical_services_outlined),
                title: const LocalizedText('وصفات المرضى',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                trailing: Icon(
                  context.isRtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PatientPrescriptionsScreen()),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            NeuCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: ListTile(
                leading: const Icon(Icons.list_alt_outlined),
                title: const LocalizedText('قائمة الوصفات الطبية',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                trailing: Icon(
                  context.isRtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PrescriptionListScreen()),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /*──────── عنصر فى القائمة الجانبية ────────*/
  Widget _drawerItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    VoidCallback? onDenied,
    bool enabled = true,
    bool showProBadge = false,
    bool showAlertDot = false,
    String? badgeText,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isRtl = Directionality.of(context) == ui.TextDirection.rtl;
    final badge = badgeText;

    final iconColor = enabled
        ? scheme.onSurface.withValues(alpha: .85)
        : scheme.onSurface.withValues(alpha: .30);

    final titleStyle = TextStyle(
      fontWeight: FontWeight.w700,
      fontSize: 13.5,
      color:
          enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: .35),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: NeuCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: ListTile(
          dense: true,
          minLeadingWidth: 6,
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: iconColor),
          title: Row(
            children: [
              Expanded(child: LocalizedText(title, style: titleStyle)),
              if (showProBadge)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.tertiary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: LocalizedText('مدفوع',
                    style: TextStyle(
                      color: scheme.tertiary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (badge != null && badge.trim().isNotEmpty)
                Container(
                  margin: const EdgeInsetsDirectional.only(start: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: LocalizedText(
                    badge,
                    style: TextStyle(
                      color: scheme.error,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (showAlertDot)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsetsDirectional.only(start: 8),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
          trailing: Icon(
            isRtl ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
            color: iconColor,
          ),
          onTap: enabled
              ? onTap
              : () {
                  Navigator.pop(context);
                  if (onDenied != null) {
                    onDenied();
                  } else {
                    _handleDeniedAccess();
                  }
                },
        ),
      ),
    );
  }

  /// يبني عنصر Drawer مرتبط بمفتاح ميزة مع خيار الإخفاء عند المنع
  Widget _featureDrawerItem({
    required AuthProvider auth,
    required String featureKey,
    required IconData icon,
    required String title,
    bool requireCreate = false,
    bool requireUpdate = false,
    bool requireDelete = false,
    required VoidCallback onTap,
  }) {
    final allowed = _isFeatureAllowed(
      auth,
      featureKey,
      requireCreate: requireCreate,
      requireUpdate: requireUpdate,
      requireDelete: requireDelete,
    );
    if (_hideDeniedTabs(auth) && !allowed && !auth.isSuperAdmin) {
      return const SizedBox.shrink();
    }
    final showProBadge =
        !auth.isSuperAdmin && !allowed && auth.planCode == 'free';

    return _drawerItem(
      icon: icon,
      title: title,
      enabled: allowed,
      onTap: onTap,
      onDenied: _openMyPlanFromDrawer,
      showProBadge: showProBadge,
    );
  }

  bool _hideDeniedTabs(AuthProvider auth) {
    if (kHideDeniedTabs) return true;
    return !auth.isSuperAdmin && !auth.isOwnerOrAdmin;
  }

  bool _isFeatureAllowed(
    AuthProvider auth,
    String featureKey, {
    bool requireCreate = false,
    bool requireUpdate = false,
    bool requireDelete = false,
  }) {
    // السوبر أدمن يرى الكل، والباقي عبر permissions/feature matrix
    bool allowed = auth.isSuperAdmin || auth.featureAllowed(featureKey);

    // تطبيق CRUD إذا طُلب (لمالك/سوبر نتجاوز، للموظف نطبّق)
    if (allowed && !auth.isSuperAdmin) {
      if (requireCreate) allowed = allowed && auth.canCreate;
      if (requireUpdate) allowed = allowed && auth.canUpdate;
      if (requireDelete) allowed = allowed && auth.canDelete;
    }

    return allowed;
  }

  bool _canManageEmployeeAccounts(AuthProvider auth) {
    if (auth.isSuperAdmin) return true;
    if (!auth.featureAllowed(FeatureKeys.employeeAccounts)) return false;
    final role = auth.role?.toLowerCase();
    return role == 'owner' || role == 'admin';
  }

  /*──────── Drawer ────────*/
  Widget _buildDrawer(BuildContext context, StatisticsProvider stats) {
    final scheme = Theme.of(context).colorScheme;
    final isRtl = context.isRtl;

    // استمع لتغيّرات AuthProvider كي تنعكس الصلاحيات مباشرة
    final auth = Provider.of<AuthProvider>(context);
    return Drawer(
      width: 330,
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: isRtl ? const Radius.circular(22) : Radius.zero,
          left: isRtl ? Radius.zero : const Radius.circular(22),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const _DrawerHeader(),
            const Divider(height: 18),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  // الإحصاءات
                  _featureDrawerItem(
                    auth: auth,
                    featureKey: FeatureKeys.dashboard,
                    icon: Icons.insights_rounded,
                    title: context.tr('dashboard_title'),
                    onTap: () => Navigator.pop(context),
                  ),

                  if (auth.role?.toLowerCase() == 'owner')
                    _drawerItem(
                      icon: Icons.workspace_premium_rounded,
                      title: context.tr('dashboard_menu_my_plan'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const MyPlanScreen()),
                        );
                      },
                    ),
                  _featureDrawerItem(
                    auth: auth,
                    featureKey: FeatureKeys.clinicProfile,
                    icon: Icons.local_hospital_outlined,
                    title: context.tr('dashboard_menu_clinic_profile'),
                    requireUpdate: true,
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ClinicProfileScreen()),
                      );
                    },
                  ),

                    // المرضى
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.patientNew,
                      requireCreate: true,
                      icon: Icons.person_add_alt_1_rounded,
                      title: context.tr('dashboard_menu_new_patient'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => NewPatientScreen()),
                        );
                      },
                    ),
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.patientsList,
                      icon: Icons.people_outline_rounded,
                      title: context.tr('dashboard_menu_patients_list'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ListPatientsScreen()),
                        );
                      },
                    ),
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.patientQuestions,
                      icon: Icons.quiz_outlined,
                      title: context.tr('dashboard_menu_patient_questions'),
                      requireUpdate: true,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ComplaintTemplatesScreen()),
                        );
                      },
                    ),

                    // الموظفون
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.employees,
                      icon: Icons.groups_rounded,
                      title: context.tr('dashboard_menu_employees'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const EmployeesHomeScreen()),
                        );
                      },
                    ),

                    // العودات (ضمن شؤون الموظفين)
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.returns,
                      icon: Icons.assignment_return_outlined,
                      title: context.tr('dashboard_menu_returns'),
                      onTap: () {
                        Navigator.pop(context);
                        _showReturnsMenu(context);
                      },
                    ),

                    // حسابات الموظفين (PRO)
                    Builder(builder: (_) {
                      final allowed = _canManageEmployeeAccounts(auth) &&
                          _isFeatureAllowed(auth, FeatureKeys.employeeAccounts);
                      if (_hideDeniedTabs(auth) &&
                          !allowed &&
                          !auth.isSuperAdmin) {
                        return const SizedBox.shrink();
                      }
                      return _drawerItem(
                        icon: Icons.phone_rounded,
                        title: context.tr('dashboard_menu_employee_accounts'),
                        enabled: allowed,
                        showProBadge: !auth.isSuperAdmin && !auth.isPro,
                        onDenied: () {
                          _openMyPlanFromDrawer();
                        },
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const EmployeeAccountsScreen()),
                          );
                        },
                      );
                    }),

                    // الشؤون المالية (مدفوعات)
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.payments,
                      icon: Icons.payments_rounded,
                      title: context.tr('dashboard_menu_payments'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const PaymentsHomeScreen()),
                        );
                      },
                    ),

                    // الاشعة والمختبرات (مجمّد دائمًا)
                    _drawerItem(
                      icon: Icons.biotech_rounded,
                      title: context.tr('dashboard_menu_labs'),
                      enabled: false,
                      badgeText: context.tr('dashboard_menu_under_development'),
                      onDenied: _showUnderDevelopmentNotice,
                      onTap: () {},
                    ),

                    // الرسوم البيانية
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.charts,
                      icon: Icons.bar_chart_rounded,
                      title: context.tr('dashboard_menu_charts'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const StatisticsScreen()),
                        );
                      },
                    ),

                    // المستودع
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.repository,
                      icon: Icons.inventory_2_rounded,
                      title: context.tr('dashboard_menu_repository'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const RepositoryMenuScreen()),
                        );
                      },
                    ),

                    // الوصفات الطبية
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.prescriptions,
                      icon: Icons.menu_book_rounded,
                      title: context.tr('dashboard_menu_prescriptions'),
                      onTap: () {
                        Navigator.pop(context);
                        _showPrescriptionsMenu(context);
                      },
                    ),

                    // الدردشة (جديد)
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.chat,
                      icon: Icons.chat_bubble_outline_rounded,
                      title: context.tr('common_chat'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ChatHomeScreen()),
                        );
                      },
                    ),
                    // استخراج البيانات محليًا
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.backup,
                      icon: Icons.backup_rounded,
                      title: context.tr('dashboard_menu_backup_local'),
                      onTap: () {
                        Navigator.pop(context);
                        _exportClinicHtml();
                      },
                    ),

                    // ـــ قسم الإداري: يظهر فقط إذا وُجدت صلاحيات لأي من المفاتيح الإدارية
                    const SizedBox(height: 8),
                    Divider(color: scheme.outline.withValues(alpha: .3)),
                    const SizedBox(height: 6),
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.accounts,
                      icon: Icons.supervisor_account_rounded,
                      title: context.tr('dashboard_menu_accounts'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const UsersScreen()),
                        );
                      },
                    ),
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.auditPermissions,
                      icon: Icons.tune_rounded,
                      title: context.tr('dashboard_menu_permissions'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const PermissionsScreen()),
                        );
                      },
                    ),
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.auditLogs,
                      icon: Icons.receipt_long_rounded,
                      title: context.tr('dashboard_menu_logs'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const AuditLogsScreen()),
                        );
                      },
                    ),

                    _drawerItem(
                      icon: Icons.report_problem_outlined,
                      title: context.tr('dashboard_menu_complaints'),
                      showAlertDot: _hasComplaintReply,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ComplaintsScreen()),
                        );
                      },
                    ),
                    _drawerItem(
                      icon: Icons.help_outline_rounded,
                      title: context.tr('dashboard_menu_user_guide'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const UserGuideScreen()),
                        );
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '© 2026 ${context.tr('app_name')}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  Future<void> _logout() async {
    try {
      await context.read<AuthProvider>().signOut();
    } catch (_) {
      // تجاهل الخطأ إن وُجد
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  bool _canSeeDashboard(AuthProvider auth) {
    return _isFeatureAllowed(auth, FeatureKeys.dashboard);
  }

  bool _canUseChat(AuthProvider auth) {
    return _isFeatureAllowed(auth, FeatureKeys.chat);
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = AppFormatters.dateFormat('yyyy-MM-dd');

    return ChangeNotifierProvider(
      create: (_) => StatisticsProvider(),
      child: Consumer2<StatisticsProvider, AuthProvider>(
        builder: (context, stats, auth, _) {
          final canViewDashboard = _canSeeDashboard(auth);
          final canChat = _canUseChat(auth);
          final unreadChatsCount = context.select<ChatProvider, int>(
            (p) =>
                p.conversations.fold(0, (sum, c) => sum + (c.unreadCount ?? 0)),
          );

          return Scaffold(
            key: _scaffoldKey,
            drawerEnableOpenDragGesture: true,
            drawer: _buildDrawer(context, stats),
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
                  Text(context.tr('app_name')),
                ],
              ),
              leading: IconButton(
                tooltip: context.tr('common_menu'),
                onPressed: _openDrawer,
                icon: const Icon(Icons.menu_rounded),
              ),
              actions: [
                if (canChat)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        tooltip: context.tr('common_chat'),
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ChatHomeScreen()),
                          );
                        },
                      ),
                      if (unreadChatsCount > 0)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            constraints: const BoxConstraints(
                                minWidth: 18, minHeight: 16),
                            child: LocalizedText(
                              unreadChatsCount > 99
                                  ? '99+'
                                  : '$unreadChatsCount',
                              textAlign: TextAlign.center,
                              textDirection: ui.TextDirection.ltr,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                                height: 1.1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                IconButton(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout_rounded),
                  tooltip: context.tr('common_logout'),
                ),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      tooltip: context.tr('dashboard_reminders'),
                      icon: Image.asset(
                        stats.todayConfirmed > 0
                            ? 'assets/images/bell_icon1.png'
                            : 'assets/images/bell_icon2.png',
                        width: 22,
                        height: 22,
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ReminderScreen()),
                      ),
                    ),
                    if (stats.todayConfirmed > 0)
                      const Positioned(
                        right: 8,
                        top: 8,
                        child: CircleAvatar(
                          radius: 5,
                          backgroundColor: Colors.red,
                        ),
                      ),
                  ],
                ),
                const LanguageSwitchButton(),
                const SizedBox(width: 8),
              ],
            ),
            body: SafeArea(
              child: canViewDashboard
                  ? _buildStatsBody(context, stats, dateFmt)
                  : _buildWelcomeBody(context, auth, canChat),
            ),
          );
        },
      ),
    );
  }

  /*──────── واجهة الإحصاءات (كما كانت) ────────*/
  Widget _buildStatsBody(
      BuildContext context, StatisticsProvider stats, DateFormat dateFmt) {
    final scheme = Theme.of(context).colorScheme;

    return RefreshIndicator(
      color: scheme.primary,
      onRefresh: () async {
        await stats.refresh();
        _checkPlanExpiryNotice();
        _refreshComplaintsBadge();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_planExpirySoon) ...[
              _buildPlanExpiryBanner(),
              const SizedBox(height: 10),
            ],
            /*────────── اختيار فترة الإحصاء ──────────*/
            Row(
              children: [
                Expanded(
                  child: NeuCard(
                    onTap: () async {
                      final p = await showDatePicker(
                        context: context,
                        initialDate: stats.from,
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                        locale: AppFormatters.localeOf(context),
                        helpText: context.trRaw('اختر تاريخ البداية'),
                      );
                      if (p != null && p != stats.from) {
                        stats.setRange(from: p, to: stats.to);
                      }
                    },
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: _DateChip(
                      icon: Icons.calendar_month_rounded,
                      label: dateFmt.format(stats.from),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: NeuCard(
                    onTap: () async {
                      final p = await showDatePicker(
                        context: context,
                        initialDate: stats.to,
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                        locale: AppFormatters.localeOf(context),
                        helpText: context.trRaw('اختر تاريخ النهاية'),
                      );
                      if (p != null && p != stats.to) {
                        stats.setRange(from: stats.from, to: p);
                      }
                    },
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: _DateChip(
                      icon: Icons.event_rounded,
                      label: dateFmt.format(stats.to),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                NeuButton.flat(
                  label: context.trRaw('تحديث'),
                  icon: Icons.refresh_rounded,
                  onPressed: () async {
                    await stats.refresh();
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),

            /*────────── بطاقات الإحصاء ──────────*/
            AnimatedOpacity(
              opacity: stats.busy ? 0.4 : 1,
              duration: const Duration(milliseconds: 250),
              child: Directionality(
                textDirection: context.appUiTextDirection,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 16,
                  runSpacing: 18,
                  children: [
                    _StatCard(
                      title: 'إيرادات الفترة (قيمة الخدمات)',
                      value: stats.fmtRevenue,
                      icon: Icons.paid_outlined,
                    ),
                    _StatCard(
                      title: 'مشتريات المستودع',
                      value: stats.fmtExpense,
                      icon: Icons.local_hospital_outlined,
                    ),
                    _StatCard(
                      title: 'استهلاكات المرفق الصحي',
                      value: stats.fmtFacilityConsumptions,
                      icon: Icons.local_fire_department_outlined,
                    ),
                    _StatCard(
                      title: 'مدخلات الأطباء',
                      value: stats.fmtDoctorInputs,
                      icon: Icons.input_outlined,
                    ),
                    _StatCard(
                      title: 'مدخلات المركز الطبي',
                      value: stats.fmtTowerShare,
                      icon: Icons.account_balance_outlined,
                    ),
                    _StatCard(
                      title: 'المبالغ المتبقية على المرضى',
                      value: stats.fmtPatientsRemaining,
                      icon: Icons.receipt_long_outlined,
                    ),
                    _StatCard(
                      title: 'مبالغ السلف المصروفة',
                      value: stats.fmtLoansPaid,
                      icon: Icons.request_quote_outlined,
                    ),
                    _StatCard(
                      title: 'مبالغ الخصومات',
                      value: stats.fmtDiscounts,
                      icon: Icons.discount_outlined,
                    ),
                    _StatCard(
                      title: 'مبالغ الرواتب المصروفة',
                      value: stats.fmtSalariesPaid,
                      icon: Icons.account_balance_wallet_outlined,
                    ),
                    _StatCard(
                      title: 'صافي الربح',
                      value: stats.fmtNetProfit,
                      icon: Icons.attach_money_outlined,
                    ),
                    _StatCard(
                      title: 'نسبة الأطباء أشعة/مختبر',
                      value: stats.fmtDoctorRatios,
                      icon: Icons.percent_outlined,
                      badgeText: context.trRaw('تحت التطوير'),
                    ),
                    _StatCard(
                      title: 'مرضى الفترة',
                      value: '${stats.monthlyPatients}',
                      icon: Icons.people_outline,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ListPatientsScreen()),
                      ),
                    ),
                    _StatCard(
                      title: 'مواعيد مؤكدة اليوم',
                      value: '${stats.todayConfirmed}',
                      icon: Icons.event_available_outlined,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ReminderScreen()),
                      ),
                    ),
                    _StatCard(
                      title: 'أتت لموعدها اليوم',
                      value: '${stats.todayFollowUps}',
                      icon: Icons.event_repeat_outlined,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ReminderScreen()),
                      ),
                    ),
                    _StatCard(
                      title: 'أصناف منخفضة',
                      value: '${stats.lowStockCount}',
                      icon: Icons.inventory_2_outlined,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const RepositoryMenuScreen()),
                      ),
                    ),
                    _StatCard(
                      title: 'أصناف منتهية',
                      value: '${stats.outOfStockItems}',
                      icon: Icons.warning_amber_outlined,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /*──────── واجهة ترحيب عصرية عند منع الإحصاءات ────────*/
  Widget _buildWelcomeBody(
      BuildContext context, AuthProvider auth, bool canChat) {
    final scheme = Theme.of(context).colorScheme;
    final canPatients = _isFeatureAllowed(auth, FeatureKeys.patientsList);
    final canRepository = _isFeatureAllowed(auth, FeatureKeys.repository);
    final canChatLocal = canChat;
    final canQuestions = _isFeatureAllowed(auth, FeatureKeys.patientQuestions);
    final canEmployees = _isFeatureAllowed(auth, FeatureKeys.employees);
    final canReturns = _isFeatureAllowed(auth, FeatureKeys.returns);
    final canPayments = _isFeatureAllowed(auth, FeatureKeys.payments);
    final canCharts = _isFeatureAllowed(auth, FeatureKeys.charts);
    final canPrescriptions = _isFeatureAllowed(auth, FeatureKeys.prescriptions);
    final canClinicProfile = _isFeatureAllowed(auth, FeatureKeys.clinicProfile);
    final canEmployeeAccounts = _canManageEmployeeAccounts(auth) &&
        _isFeatureAllowed(auth, FeatureKeys.employeeAccounts);

    return FutureBuilder<bool>(
      future: _firstOpenFuture,
      builder: (context, snap) {
        final isFirstOpen =
            snap.data == true; // null تُعامل كـ false (عرض "مرحبًا بعودتك")
        final title = isFirstOpen
            ? context.tr('dashboard_no_access_welcome_title')
            : context.tr('dashboard_no_access_returning_title');
        final subtitle = isFirstOpen
            ? context.tr('dashboard_no_access_welcome_subtitle')
            : context.tr('dashboard_no_access_returning_subtitle');

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // شعار + اسم
                  NeuCard(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.asset(
                            'assets/images/logo.png',
                            width: 84,
                            height: 84,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.local_hospital_rounded,
                                size: 80,
                                color: kPrimaryColor),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          context.tr('app_name'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .9),
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              icon: const Icon(
                                  Icons.notifications_active_rounded),
                              label: Text(context.tr('dashboard_reminders')),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const ReminderScreen()),
                                );
                              },
                            ),
                            if (canClinicProfile)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.local_hospital_outlined),
                                label: Text(
                                  context.tr('dashboard_menu_clinic_profile'),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const ClinicProfileScreen()),
                                  );
                                },
                              ),
                            if (canPatients)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.people_alt_rounded),
                                label: Text(
                                  context.tr('dashboard_menu_patients_list'),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => ListPatientsScreen()),
                                  );
                                },
                              ),
                            if (canQuestions)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.quiz_outlined),
                                label: Text(
                                  context.tr('dashboard_menu_patient_questions'),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const ComplaintTemplatesScreen()),
                                  );
                                },
                              ),
                            if (canEmployees)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.groups_rounded),
                                label: Text(
                                  context.tr('dashboard_menu_employees'),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const EmployeesHomeScreen()),
                                  );
                                },
                              ),
                            if (canEmployeeAccounts)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.phone_rounded),
                                label: Text(
                                  context.tr('dashboard_menu_employee_accounts'),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const EmployeeAccountsScreen()),
                                  );
                                },
                              ),
                            if (canReturns)
                              OutlinedButton.icon(
                                icon: const Icon(
                                    Icons.assignment_return_outlined),
                                label: Text(context.tr('dashboard_menu_returns')),
                                onPressed: () => _showReturnsMenu(context),
                              ),
                            if (canPayments)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.payments_rounded),
                                label: Text(context.tr('dashboard_menu_payments')),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const PaymentsHomeScreen()),
                                  );
                                },
                              ),
                            if (canCharts)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.bar_chart_rounded),
                                label: Text(context.tr('dashboard_menu_charts')),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const StatisticsScreen()),
                                  );
                                },
                              ),
                            if (canRepository)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.inventory_2_rounded),
                                label: Text(
                                  context.tr('dashboard_menu_repository'),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const RepositoryMenuScreen()),
                                  );
                                },
                              ),
                            if (canPrescriptions)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.menu_book_rounded),
                                label: Text(
                                  context.tr('dashboard_menu_prescriptions'),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const PatientPrescriptionsScreen()),
                                  );
                                },
                              ),
                            if (canChatLocal)
                              OutlinedButton.icon(
                                icon: const Icon(
                                    Icons.chat_bubble_outline_rounded),
                                label: Text(context.tr('common_chat')),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => const ChatHomeScreen()),
                                  );
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // بطاقة معلومات صغيرة
                  NeuCard(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: kPrimaryColor.withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(Icons.info_outline,
                              color: kPrimaryColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.tr('dashboard_no_access_info'),
                            textAlign: TextAlign.start,
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: .85),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
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
  }
}

/*──────── رأس الدرج ────────*/
class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = Provider.of<AuthProvider>(context);
    final codeRaw = (auth.chatCodeSafe ?? '').trim();
    final code = codeRaw.isEmpty ? '' : ChatCodeUtils.format(codeRaw);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: NeuCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 46,
                    height: 46,
                    child: Image.asset(
                      'assets/images/logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    context.tr('app_name'),
                    textAlign: TextAlign.start,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (code.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        scheme.primary.withValues(alpha: .12),
                        scheme.secondary.withValues(alpha: .12),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: .22),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(alpha: .8),
                        blurRadius: 4,
                        offset: const Offset(-2, -2),
                      ),
                    ],
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: .35),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.phone_rounded,
                            size: 18, color: scheme.primary),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppFormatters.localizeDigits(
                            code,
                            languageCode: context.currentLocaleCode,
                          ),
                          textDirection: ui.TextDirection.ltr,
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.1,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: context.trRaw('نسخ الرقم'),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: LocalizedText('تم نسخ الرقم.')),
                          );
                        },
                        icon: Icon(
                          Icons.copy_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/*──────── عنصر بطاقة إحصاء بنمط TBIAN/Neumorphism ────────*/
class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  final String? badgeText;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    this.onTap,
    this.badgeText,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final badge = badgeText?.trim();

    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: SizedBox(
        width: 260,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    decoration: BoxDecoration(
                      color: kPrimaryColor.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Icon(icon, color: kPrimaryColor, size: 24),
                  ),
                ),
                const SizedBox(height: 12),
                LocalizedText(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .85),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                LocalizedText(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: ui.TextDirection.ltr,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            if (badge != null && badge.isNotEmpty)
              PositionedDirectional(
                top: 0,
                end: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: LocalizedText(
                    badge,
                    style: TextStyle(
                      color: scheme.error,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
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

/*──────── شارة التاريخ (زر) ────────*/
class _DateChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DateChip({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: kPrimaryColor, size: 18),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LocalizedText(
            label,
            textDirection: ui.TextDirection.ltr,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w800,
              fontSize: 14.5,
            ),
          ),
        ),
      ],
    );
  }
}
