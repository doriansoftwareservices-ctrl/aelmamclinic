// lib/screens/statistics/statistics_overview_screen.dart

import 'dart:async';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/features.dart';

import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/providers/statistics_provider.dart';
import 'package:aelmamclinic/services/db_service.dart';

/*── شاشات مختلفة ───────────────────────────────────────────*/
import 'package:aelmamclinic/screens/backup_restore_screen.dart';
import 'package:aelmamclinic/screens/drugs/drug_list_screen.dart';
import 'package:aelmamclinic/screens/employees/employees_home_screen.dart';
import 'package:aelmamclinic/screens/patients/list_patients_screen.dart';
import 'package:aelmamclinic/screens/patients/new_patient_screen.dart';
import 'package:aelmamclinic/screens/payments/payments_home_screen.dart';
import 'package:aelmamclinic/screens/prescriptions/patient_prescriptions_screen.dart';
import 'package:aelmamclinic/screens/prescriptions/prescription_list_screen.dart';
import 'package:aelmamclinic/screens/reminders/reminder_screen.dart';
import 'package:aelmamclinic/screens/repository/menu/repository_menu_screen.dart';
import 'package:aelmamclinic/screens/returns/list_returns_screen.dart';
import 'package:aelmamclinic/screens/returns/new_return_screen.dart';
import 'package:aelmamclinic/screens/statistics/statistics_screen.dart';

/*── شاشة الأشعة والمختبرات ─*/
import '/services/lab_and_radiology_home_screen.dart';

/*── استيرادات لإدارة الحسابات ─*/
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/screens/users/users_screen.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

/*── شاشات التدقيق والصلاحيات (جديدة في الـ Drawer للمالك فقط) ─*/
import 'package:aelmamclinic/screens/audit/logs_screen.dart';
import 'package:aelmamclinic/screens/audit/permissions_screen.dart';

/*── شاشة الدردشة ─*/
import 'package:aelmamclinic/screens/chat/chat_home_screen.dart';
import 'package:aelmamclinic/screens/subscription/my_plan_screen.dart';

/*── لتسجيل الخروج ─*/
import 'package:aelmamclinic/screens/auth/login_screen.dart';
import 'package:aelmamclinic/screens/admin/admin_dashboard_screen.dart';

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

class _StatisticsOverviewScreenState extends State<StatisticsOverviewScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final GraphQLClient _gql = NhostGraphqlService.buildClient();

  // عدّاد المحادثات غير المقروءة + مؤقّت تحديث دوري
  int _unreadChatsCount = 0;
  Timer? _unreadPollTimer;

  // حالة الترحيب لأول مرة/مرحبًا بعودتك — تُحتسب مرة واحدة ثم نحدّث التخزين
  late final Future<bool> _firstOpenFuture = _getAndMarkFirstOpenForUser();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.isSuperAdmin) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
        );
      }
    });
    final auth = context.read<AuthProvider>();
    if (auth.isSuperAdmin) {
      return;
    }
    // ابدأ بحساب العدّاد فورًا ثم حدّثه دوريًا
    _refreshUnreadChatsCount();
    _unreadPollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _refreshUnreadChatsCount();
    });
  }

  @override
  void dispose() {
    _unreadPollTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _runQuery(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _gql.query(
      QueryOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  /*────────────────── عدّاد المحادثات غير المقروءة ──────────────────*/
  Future<void> _refreshUnreadChatsCount() async {
    try {
      final uid = NhostManager.client.auth.currentUser?.id;
      if (uid == null || uid.isEmpty) {
        if (mounted) setState(() => _unreadChatsCount = 0);
        return;
      }

      // 1) المحادثات التي أشارك فيها
      final partsData = await _runQuery(
        '''
        query ChatParticipants(\$uid: uuid!) {
          chat_participants(where: {user_uid: {_eq: \$uid}}) {
            conversation_id
          }
        }
        ''',
        {'uid': uid},
      );
      final partRows =
          (partsData['chat_participants'] as List?) ?? const [];
      final convIds = partRows
          .whereType<Map>()
          .map((r) => r['conversation_id']?.toString())
          .whereType<String>()
          .toSet()
          .toList();

      if (convIds.isEmpty) {
        if (mounted) setState(() => _unreadChatsCount = 0);
        return;
      }

      // 2) آخر نشاط للمحادثات (last_msg_at) + 3) آخر قراءة لي
      final convData = await _runQuery(
        '''
        query Conversations(\$ids: [uuid!]!) {
          chat_conversations(where: {id: {_in: \$ids}}) {
            id
            last_msg_at
          }
        }
        ''',
        {'ids': convIds},
      );
      final convRows =
          (convData['chat_conversations'] as List?) ?? const [];

      final readData = await _runQuery(
        '''
        query Reads(\$uid: uuid!, \$ids: [uuid!]!) {
          chat_reads(
            where: {
              user_uid: {_eq: \$uid}
              conversation_id: {_in: \$ids}
            }
          ) {
            conversation_id
            last_read_at
          }
        }
        ''',
        {'uid': uid, 'ids': convIds},
      );
      final readRows = (readData['chat_reads'] as List?) ?? const [];

      DateTime? _parse(dynamic v) {
        if (v == null) return null;
        try {
          return DateTime.parse(v.toString()).toUtc();
        } catch (_) {
          return null;
        }
      }

      final lastByConv = <String, DateTime?>{};
      for (final r in convRows.whereType<Map>()) {
        final id = r['id']?.toString() ?? '';
        lastByConv[id] = _parse(r['last_msg_at']);
      }

      final readByConv = <String, DateTime?>{};
      for (final r in readRows.whereType<Map>()) {
        final id = r['conversation_id']?.toString() ?? '';
        readByConv[id] = _parse(r['last_read_at']);
      }

      // 4) احسب عدد المحادثات التي فيها رسالة أحدث من آخر قراءة للمستخدم
      int cnt = 0;
      for (final cid in convIds) {
        final last = lastByConv[cid];
        if (last == null) continue; // لا رسائل بعد
        final read = readByConv[cid];
        if (read == null || last.isAfter(read)) {
          cnt++;
        }
      }

      if (mounted) setState(() => _unreadChatsCount = cnt);
    } catch (_) {
      // تجاهل بهدوء؛ لا نكسر الواجهة بسبب العدّاد
    }
  }

  /*────────────────── عودات اليوم ──────────────────*/
  Future<List<ReturnEntry>> _getTodayReturns() async {
    final all = await DBService.instance.getAllReturns();
    final t = DateTime.now();
    return all
        .where((r) =>
            r.date.year == t.year &&
            r.date.month == t.month &&
            r.date.day == t.day)
        .toList();
  }

  /*────────────────── مُعرّفات التذكيرات التي عُلِّمَت كمشاهَدة اليوم ──────────────────*/
  Future<Set<int>> _getSeenIdsToday() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList('seen_reminder_ids') ?? [];
    return seen.map((e) => int.tryParse(e) ?? 0).toSet();
  }

  void _showNotAllowedSnack() {
    final auth = context.read<AuthProvider>();
    final isFree = auth.planCode == 'free' && !auth.isSuperAdmin;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isFree
            ? 'هذه الميزة متاحة في باقات PRO فقط'
            : 'ليس لديك صلاحية للوصول إلى هذه الميزة'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _handleDeniedAccess() {
    final auth = context.read<AuthProvider>();
    final isFree = auth.planCode == 'free' && !auth.isSuperAdmin;
    final isOwner = auth.role?.toLowerCase() == 'owner';
    _showNotAllowedSnack();
    if (!isFree || !isOwner) return;
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
    final canCreate =
        auth.isSuperAdmin || (auth.featureAllowed(FeatureKeys.returns) && auth.canCreate);

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
                  title: const Text('إنشاء عودة',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  trailing: const Icon(Icons.chevron_left_rounded),
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
                  title: const Text('استعراض العودات',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  trailing: const Icon(Icons.chevron_left_rounded),
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
                title: const Text('إدارة الأدوية',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                trailing: const Icon(Icons.chevron_left_rounded),
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
                title: const Text('وصفات المرضى',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                trailing: const Icon(Icons.chevron_left_rounded),
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
                title: const Text('قائمة الوصفات الطبية',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                trailing: const Icon(Icons.chevron_left_rounded),
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
    bool enabled = true,
    bool showProBadge = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isRtl = Directionality.of(context) == ui.TextDirection.rtl;

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
              Expanded(child: Text(title, style: titleStyle)),
              if (showProBadge)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.tertiary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'PRO',
                    style: TextStyle(
                      color: scheme.tertiary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          trailing: Icon(
            isRtl ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
            color: iconColor,
          ),
          onTap: enabled ? onTap : () {
            Navigator.pop(context);
            _handleDeniedAccess();
          },
        ),
      ),
    );
  }

  Widget _proLabel(String label, bool showPro, ColorScheme scheme) {
    if (!showPro) return Text(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: scheme.tertiary.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            'PRO',
            style: TextStyle(
              color: scheme.tertiary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
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

    if (!allowed && kHideDeniedTabs) {
      return const SizedBox.shrink(); // إخفاء التبويب
    }

    final showProBadge =
        !allowed && !auth.isSuperAdmin && auth.planCode == 'free';

    return _drawerItem(
      icon: icon,
      title: title,
      enabled: allowed,
      onTap: onTap,
      showProBadge: showProBadge,
    );
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

  /*──────── Drawer ────────*/
  Widget _buildDrawer(BuildContext context, StatisticsProvider stats) {
    final scheme = Theme.of(context).colorScheme;

    // استمع لتغيّرات AuthProvider كي تنعكس الصلاحيات مباشرة
    final auth = Provider.of<AuthProvider>(context);
    final canManageAccounts = _isFeatureAllowed(auth, FeatureKeys.accounts);
    final canManagePermissions =
        _isFeatureAllowed(auth, FeatureKeys.auditPermissions);
    final canViewAuditLogs = _isFeatureAllowed(auth, FeatureKeys.auditLogs);
    final showAdminSection =
        canManageAccounts || canManagePermissions || canViewAuditLogs;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Drawer(
        width: 330,
        backgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(22)),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _DrawerHeader(),
              const Divider(height: 18),
              Expanded(
                child: ListView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    // الإحصاءات
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.dashboard,
                      icon: Icons.insights_rounded,
                      title: 'لوحة الإحصاءات',
                      onTap: () => Navigator.pop(context),
                    ),

                    _drawerItem(
                      icon: Icons.workspace_premium_rounded,
                      title: 'خطتي',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const MyPlanScreen()),
                        );
                      },
                    ),

                    // المرضى
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.patientNew,
                      requireCreate: true,
                      icon: Icons.person_add_alt_1_rounded,
                      title: 'تسجيل مريض جديد',
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
                      title: 'قائمة المرضى',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ListPatientsScreen()),
                        );
                      },
                    ),

                    // العودات
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.returns,
                      icon: Icons.assignment_return_outlined,
                      title: 'العودات',
                      onTap: () {
                        Navigator.pop(context);
                        _showReturnsMenu(context);
                      },
                    ),

                    // الموظفون
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.employees,
                      icon: Icons.groups_rounded,
                      title: 'شؤون الموظفين',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const EmployeesHomeScreen()),
                        );
                      },
                    ),

                    // الشؤون المالية (مدفوعات)
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.payments,
                      icon: Icons.payments_rounded,
                      title: 'الشؤون المالية',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const PaymentsHomeScreen()),
                        );
                      },
                    ),

                    // الاشعة والمختبرات
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.labRadiology,
                      icon: Icons.biotech_rounded,
                      title: 'الأشعة والمختبرات',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  const LabAndRadiologyHomeScreen()),
                        );
                      },
                    ),

                    // الرسوم البيانية
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.charts,
                      icon: Icons.bar_chart_rounded,
                      title: 'الرسوم البيانية',
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
                      title: 'قسم المستودع',
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
                      title: 'الوصفات الطبية',
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
                      title: 'الدردشة',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ChatHomeScreen()),
                        );
                      },
                    ),

                    // النسخ الاحتياطي
                    _featureDrawerItem(
                      auth: auth,
                      featureKey: FeatureKeys.backup,
                      icon: Icons.backup_rounded,
                      title: 'النسخ الاحتياطي',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const BackupRestoreScreen()),
                        );
                      },
                    ),

                    // ـــ قسم الإداري: يظهر فقط إذا وُجدت صلاحيات لأي من المفاتيح الإدارية
                    if (showAdminSection) ...[
                      const SizedBox(height: 8),
                      Divider(color: scheme.outline.withValues(alpha: .3)),
                      const SizedBox(height: 6),
                      _featureDrawerItem(
                        auth: auth,
                        featureKey: FeatureKeys.accounts,
                        icon: Icons.supervisor_account_rounded,
                        title: 'الحسابات',
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
                        title: 'الصلاحيات',
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
                        title: 'السجلات',
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AuditLogsScreen()),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '© 2025 ElmamClinic',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.black45),
                ),
              ),
            ],
          ),
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
    final dateFmt = DateFormat('yyyy-MM-dd');

    return ChangeNotifierProvider(
      create: (_) => StatisticsProvider(),
      child: Consumer2<StatisticsProvider, AuthProvider>(
        builder: (context, stats, auth, _) {
          final canViewDashboard = _canSeeDashboard(auth);
          final canChat = _canUseChat(auth);

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
                  const Text('ELMAM CLINIC'),
                ],
              ),
              leading: IconButton(
                tooltip: 'القائمة',
                onPressed: _openDrawer,
                icon: const Icon(Icons.menu_rounded),
              ),
              actions: [
                if (canChat)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        tooltip: 'الدردشة',
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ChatHomeScreen()),
                          );
                          // حدّث العدّاد بعد العودة تحسبًا لتغيّر المقروئية
                          _refreshUnreadChatsCount();
                        },
                      ),
                      if (_unreadChatsCount > 0)
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
                            child: Text(
                              _unreadChatsCount > 99
                                  ? '99+'
                                  : '$_unreadChatsCount',
                              textAlign: TextAlign.center,
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
                  tooltip: 'تسجيل الخروج',
                ),
                FutureBuilder<List<ReturnEntry>>(
                  future: _getTodayReturns(),
                  builder: (_, snap) {
                    final has = snap.hasData && snap.data!.isNotEmpty;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        IconButton(
                          tooltip: 'التذكيرات',
                          icon: Image.asset(
                            has
                                ? 'assets/images/bell_icon1.png'
                                : 'assets/images/bell_icon2.png',
                            width: 22,
                            height: 22,
                          ),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ReminderScreen()),
                          ),
                        ),
                        if (has)
                          const Positioned(
                            right: 8,
                            top: 8,
                            child: CircleAvatar(
                              radius: 5,
                              backgroundColor: Colors.red,
                            ),
                          ),
                      ],
                    );
                  },
                ),
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
        _refreshUnreadChatsCount(); // حدّث العدّاد أيضًا عند السحب للتحديث
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                        locale: const Locale('ar', ''),
                        helpText: 'اختر تاريخ البداية',
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
                        locale: const Locale('ar', ''),
                        helpText: 'اختر تاريخ النهاية',
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
                  label: 'تحديث',
                  icon: Icons.refresh_rounded,
                  onPressed: () async {
                    await stats.refresh();
                    _refreshUnreadChatsCount();
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
                textDirection: ui.TextDirection.rtl,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 16,
                  runSpacing: 18,
                  children: [
                    _StatCard(
                      title: 'إيرادات الفترة',
                      value: stats.fmtRevenue,
                      icon: Icons.paid_outlined,
                    ),
                    _StatCard(
                      title: 'استهلاكات المركز',
                      value: stats.fmtExpense,
                      icon: Icons.local_hospital_outlined,
                    ),
                    _StatCard(
                      title: 'نسبة الأطباء أشعة/مختبر',
                      value: stats.fmtDoctorRatios,
                      icon: Icons.percent_outlined,
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
                      title: 'مرضى الفترة',
                      value: '${stats.monthlyPatients}',
                      icon: Icons.people_outline,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ListPatientsScreen()),
                      ),
                    ),
                    FutureBuilder<List<ReturnEntry>>(
                      future: _getTodayReturns(),
                      builder: (_, snap) {
                        final count = snap.hasData ? snap.data!.length : 0;
                        return _StatCard(
                          title: 'مواعيد مؤكدة اليوم',
                          value: '$count',
                          icon: Icons.event_available_outlined,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ReminderScreen()),
                          ),
                        );
                      },
                    ),
                    FutureBuilder<List<ReturnEntry>>(
                      future: _getTodayReturns(),
                      builder: (_, snap) {
                        final todayReturns =
                            snap.hasData ? snap.data! : <ReturnEntry>[];
                        return FutureBuilder<Set<int>>(
                          future: _getSeenIdsToday(),
                          builder: (_, seenSnap) {
                            final seen = seenSnap.data ?? {};
                            final count = todayReturns
                                .where((r) => seen.contains(r.id))
                                .length;
                            return _StatCard(
                              title: 'أتت لموعدها اليوم',
                              value: '$count',
                              icon: Icons.event_repeat_outlined,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const ReminderScreen()),
                              ),
                            );
                          },
                        );
                      },
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
    final showProPatients =
        !canPatients && auth.planCode == 'free' && !auth.isSuperAdmin;
    final showProRepo =
        !canRepository && auth.planCode == 'free' && !auth.isSuperAdmin;
    final showProChat =
        !canChatLocal && auth.planCode == 'free' && !auth.isSuperAdmin;

    return FutureBuilder<bool>(
      future: _firstOpenFuture,
      builder: (context, snap) {
        final isFirstOpen =
            snap.data == true; // null تُعامل كـ false (عرض "مرحبًا بعودتك")
        final title =
            isFirstOpen ? 'مرحبًا بك في ELMAM CLINIC' : 'مرحبًا بعودتك';
        final subtitle = isFirstOpen
            ? 'هذه هي زيارتك الأولى على هذا الجهاز بحسابك. قد تكون بعض الأقسام مخفية إلى أن يتم منحك الصلاحيات من الإدارة.'
            : 'تم التعرف عليك. لديك وصول محدود حسب صلاحيات الإدارة. إذا احتجت رؤية الإحصاءات، اطلب من الادارة تفعيل ميزة "لوحة الإحصاءات".';

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
                          'ELMAM CLINIC',
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
                              label: const Text('التذكيرات'),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const ReminderScreen()),
                                );
                              },
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.people_alt_rounded),
                              label: _proLabel(
                                'قائمة المرضى',
                                showProPatients,
                                scheme,
                              ),
                              onPressed: canPatients
                                  ? () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                ListPatientsScreen()),
                                      );
                                    }
                                  : _handleDeniedAccess,
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.inventory_2_rounded),
                              label: _proLabel(
                                'قسم المستودع',
                                showProRepo,
                                scheme,
                              ),
                              onPressed: canRepository
                                  ? () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const RepositoryMenuScreen()),
                                      );
                                    }
                                  : _handleDeniedAccess,
                            ),
                            if (canChat || showProChat)
                              OutlinedButton.icon(
                                icon: const Icon(
                                    Icons.chat_bubble_outline_rounded),
                                label: _proLabel(
                                  'الدردشة',
                                  showProChat,
                                  scheme,
                                ),
                                onPressed: canChatLocal
                                    ? () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  const ChatHomeScreen()),
                                        );
                                      }
                                    : _handleDeniedAccess,
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
                            'لا يمكنك مشاهدة لوحة الإحصاءات حاليًا. يتطلب ذلك منح صلاحية "لوحة الإحصاءات" من الادارة.',
                            textAlign: TextAlign.right,
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
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: NeuCard(
        padding: const EdgeInsets.all(16),
        child: Row(
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
                'ELMAM CLINIC',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
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

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: SizedBox(
        width: 260,
        child: Column(
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
            Text(
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
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: ui.TextDirection.rtl,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 20,
                fontWeight: FontWeight.w900,
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
          child: Text(
            label,
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
