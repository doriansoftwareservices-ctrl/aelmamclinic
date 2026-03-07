// lib/screens/admin/admin_dashboard_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/models/admin_account_member.dart';
import 'package:aelmamclinic/models/admin_account_member_count.dart';
import 'package:aelmamclinic/models/clinic.dart';
import 'package:aelmamclinic/models/complaint.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/payment_plan_stat.dart';
import 'package:aelmamclinic/models/payment_stat.dart';
import 'package:aelmamclinic/models/payment_time_stat.dart';
import 'package:aelmamclinic/models/provisioning_result.dart';
import 'package:aelmamclinic/models/super_admin_account.dart';
import 'package:aelmamclinic/models/subscription_request.dart';
import 'package:aelmamclinic/models/employee_seat_request.dart';
import 'package:aelmamclinic/services/admin_account_members_service.dart';
import 'package:aelmamclinic/services/admin_billing_service.dart';
import 'package:aelmamclinic/services/employee_seat_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';
import 'package:aelmamclinic/services/nhost_admin_service.dart';
import 'package:aelmamclinic/services/super_admin_accounts_service.dart';
import 'package:aelmamclinic/services/admin_insights_service.dart';
import 'package:aelmamclinic/services/export_service.dart';
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:aelmamclinic/utils/chat_code_utils.dart';
import 'package:provider/provider.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aelmamclinic/models/admin_system_health.dart';
import 'package:aelmamclinic/models/admin_action_log.dart';
import 'package:aelmamclinic/models/admin_usage_metrics.dart';
import 'package:aelmamclinic/models/admin_risk_alert.dart';
import 'package:aelmamclinic/models/admin_audit_activity.dart';
import 'package:aelmamclinic/models/admin_audit_actor.dart';
import 'package:aelmamclinic/models/admin_usage_daily.dart';

/*──────── شاشات للتنقّل ────────*/
import 'package:aelmamclinic/screens/statistics/statistics_overview_screen.dart';
import 'package:aelmamclinic/screens/auth/login_screen.dart';
import 'package:aelmamclinic/screens/chat/chat_admin_inbox_screen.dart'; // ⬅️ شاشة دردشة السوبر أدمن
import 'package:aelmamclinic/screens/admin/support_ratings_screen.dart';
import 'package:intl/intl.dart';

/// شاشة لوحة التحكّم للمشرف العام (super-admin) بتصميم TBIAN.
/// - تعتمد على Theme.of(context).colorScheme و kPrimaryColor.
/// - تستخدم مكوّنات النيومورفيزم: NeuCard / NeuButton / NeuField.
/// - زر تحديث صريح + تحديث تلقائي عند فتح تبويبات الموظفين/الإدارة.
/// - تتحقّق أن الزائر سوبر أدمن، وإلا تُعيده للواجهة الرئيسية.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static String get _rootSuperAdminEmail =>
      NhostConfig.rootSuperAdminEmail.toLowerCase().trim();
  static const Map<String, String> _tabLabels = {
    'clinics': 'العيادات',
    'chats': 'الدردشات',
    'support_ratings': 'تقييمات الخدمة',
    'subscriptions': 'الاشتراكات',
    'payments': 'طرق الدفع',
    'complaints': 'الشكاوى',
    'stats': 'الإحصاءات',
    'members': 'الأعضاء',
    'superadmins': 'حسابات السوبر أدمن',
  };
  static final List<String> _baseAdminTabs = _tabLabels.keys
      .where((k) => k != 'superadmins')
      .toList(growable: false);
  static const Map<String, IconData> _tabIcons = {
    'clinics': Icons.local_hospital_outlined,
    'chats': Icons.chat_bubble_outline,
    'support_ratings': Icons.support_agent_rounded,
    'subscriptions': Icons.workspace_premium_rounded,
    'payments': Icons.account_balance_rounded,
    'complaints': Icons.report_problem_rounded,
    'stats': Icons.analytics_rounded,
    'members': Icons.groups_rounded,
    'superadmins': Icons.security_rounded,
  };

  // ---------- Services & Controllers ----------
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final NhostAdminService _authService = NhostAdminService();
  final AdminBillingService _billingService = AdminBillingService();
  final EmployeeSeatService _seatService = EmployeeSeatService();
  final NhostStorageService _storageService = NhostStorageService();
  final SuperAdminAccountsService _superAdminService =
      SuperAdminAccountsService();
  final AdminAccountMembersService _membersService =
      AdminAccountMembersService();
  final AdminInsightsService _insightsService = AdminInsightsService();

  // عيادات
  List<Clinic> _clinics = [];
  bool _loadingClinics = true;

  // تبويبات
  late final TabController _tabController;
  int _sectionIndex = 0;
  List<String> _visibleSectionKeys = List.of(_baseAdminTabs);
  List<String> _allowedAdminTabs = List.of(_baseAdminTabs);
  bool _loadingAdminTabs = true;
  String? _tabsError;
  Timer? _pendingPollTimer;
  bool _isRootCached = false;

  // اشتراكات ودفع وشكاوى
  List<SubscriptionRequest> _subscriptionRequests = [];
  bool _loadingRequests = false;
  int _lastSubscriptionPending = 0;
  final ScrollController _subsScroll = ScrollController();
  bool _subsHasMore = true;
  bool _subsLoadingMore = false;
  int _subsOffset = 0;
  static const int _subsPageSize = 80;

  List<EmployeeSeatRequest> _seatRequests = [];
  bool _loadingSeatRequests = false;
  bool _loadingSeatPrice = false;
  double? _seatDefaultPrice;
  int _lastSeatPending = 0;
  String _seatFilter = 'submitted'; // submitted | awaiting_payment | approved | rejected | all

  List<PaymentMethod> _paymentMethods = [];
  bool _loadingPaymentMethods = false;

  List<Complaint> _complaints = [];
  bool _loadingComplaints = false;
  int _lastComplaintPending = 0;
  final ScrollController _complaintsScroll = ScrollController();
  bool _complaintsHasMore = true;
  bool _complaintsLoadingMore = false;
  int _complaintsOffset = 0;
  static const int _complaintsPageSize = 80;

  List<PaymentStat> _paymentStats = [];
  bool _loadingStats = false;
  bool _loadingExtraSeatRevenue = false;
  double _extraSeatRevenue = 0;
  double _monthlySubRevenue = 0;
  double _annualSubRevenue = 0;
  late final PageController _revenueController =
      PageController(viewportFraction: 0.78, initialPage: 1);
  double _revenuePage = 1.0;
  Timer? _revenueAutoTimer;
  static const int _revenueCardCount = 3;
  late final PageController _membersSummaryController =
      PageController(viewportFraction: 0.88, initialPage: 0);
  double _membersSummaryPage = 0.0;
  Timer? _membersSummaryTimer;
  static const int _membersSummaryCardCount = 5;
  List<PaymentPlanStat> _paymentPlanStats = [];
  List<PaymentTimeStat> _paymentMonthlyStats = [];
  List<PaymentTimeStat> _paymentDailyStats = [];

  int _statsMode = 0; // 0=methods, 1=plans, 2=monthly, 3=daily

  // صحة النظام + سجل الأوامر
  AdminSystemHealth? _systemHealth;
  bool _loadingSystemHealth = false;
  List<AdminActionLog> _adminActionLogs = [];
  bool _loadingActionLogs = false;
  bool _loadingMoreActionLogs = false;
  bool _actionLogsHasMore = true;
  int _actionLogsOffset = 0;
  static const int _actionLogsPageSize = 50;

  // تقارير المرحلة 3 (مخاطر/استخدام/تدقيق)
  AdminUsageMetrics? _usageMetrics;
  bool _loadingUsageMetrics = false;
  List<AdminRiskAlert> _riskAlerts = [];
  bool _loadingRiskAlerts = false;
  List<AdminAuditActivity> _auditDaily = [];
  bool _loadingAuditDaily = false;
  List<AdminAuditActor> _auditTopActors = [];
  bool _loadingAuditTopActors = false;
  List<AdminUsageDaily> _usageDaily = [];
  bool _loadingUsageDaily = false;

  // أعضاء الحسابات
  List<AdminAccountMemberCount> _memberCounts = [];
  List<AdminAccountMember> _accountMembers = [];
  bool _loadingMemberCounts = false;
  bool _loadingAccountMembers = false;
  String? _membersAccountId;
  bool _membersOnlyActive = true;
  final ScrollController _membersScroll = ScrollController();
  bool _membersHasMore = true;
  bool _membersLoadingMore = false;
  int _membersOffset = 0;
  static const int _membersPageSize = 100;

  // -------- إنشاء حساب عيادة رئيسية --------
  final TextEditingController _clinicNameCtrl = TextEditingController();
  final TextEditingController _ownerEmailCtrl = TextEditingController();
  final TextEditingController _ownerPassCtrl = TextEditingController();

  // -------- إنشاء حساب موظف --------
  Clinic? _selectedClinic;
  final TextEditingController _staffEmailCtrl = TextEditingController();
  final TextEditingController _staffPassCtrl = TextEditingController();
  String? _createStaffPlanError;

  // -------- حسابات السوبر أدمن --------
  final TextEditingController _superAdminEmailCtrl = TextEditingController();
  final TextEditingController _superAdminPassCtrl = TextEditingController();
  List<SuperAdminAccount> _superAdminAccounts = [];
  List<String> _newSuperAdminTabs = List.of(_baseAdminTabs);
  bool _loadingSuperAdmins = false;
  bool _creatingSuperAdmin = false;

  // حالة انشغال عامة لمنع النقرات المكررة
  bool _busy = false;

  // ---------- Lifecycle ----------
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _revenueController.addListener(() {
      final page = _revenueController.page;
      if (page == null) return;
      if (!mounted) return;
      setState(() => _revenuePage = page);
    });
    _membersSummaryController.addListener(() {
      final page = _membersSummaryController.page;
      if (page == null) return;
      if (!mounted) return;
      setState(() => _membersSummaryPage = page);
    });
    _startRevenueAutoPlay();
    _startMembersSummaryAutoPlay();
    _membersScroll.addListener(() {
      if (_activeSectionKey != 'members') return;
      if (_membersLoadingMore || !_membersHasMore) return;
      if (!_membersScroll.hasClients) return;
      final pos = _membersScroll.position;
      if (pos.pixels >= pos.maxScrollExtent - 300) {
        _loadMoreMembers();
      }
    });
    _subsScroll.addListener(() {
      if (_activeSectionKey != 'subscriptions') return;
      if (_subsLoadingMore || !_subsHasMore) return;
      if (!_subsScroll.hasClients) return;
      final pos = _subsScroll.position;
      if (pos.pixels >= pos.maxScrollExtent - 300) {
        _loadMoreSubscriptionRequests();
      }
    });
    _complaintsScroll.addListener(() {
      if (_activeSectionKey != 'complaints') return;
      if (_complaintsLoadingMore || !_complaintsHasMore) return;
      if (!_complaintsScroll.hasClients) return;
      final pos = _complaintsScroll.position;
      if (pos.pixels >= pos.maxScrollExtent - 300) {
        _loadMoreComplaints();
      }
    });

    // حارس وصول: إن لم يكن المستخدم سوبر أدمن، لا يسمح بالبقاء هنا
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final auth = context.read<AuthProvider>();
      if (!auth.isSuperAdmin) {
        await auth.refreshAndValidateCurrentUser();
      }
      if (!mounted) return;
      if (!auth.isSuperAdmin) {
        Navigator.of(context).pushReplacementNamed('/');
        return;
      }
      _isRootCached = _computeIsRoot(auth.email);
    });

    final auth = context.read<AuthProvider>();
    _isRootCached = _computeIsRoot(auth.email);
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      // حدّث القائمة كلما فتحنا تبويب "موظف جديد" أو "إدارة العيادات"
      if (_tabController.index == 1 || _tabController.index == 2) {
        _fetchClinics();
      }
    });
    if (auth.isSuperAdmin) {
      _loadAdminTabs();
      _fetchClinics();
      _fetchSubscriptionRequests();
      _fetchSeatRequests();
      _pendingPollTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (_activeSectionKey != 'subscriptions') return;
        await _fetchSubscriptionRequests();
        await _fetchSeatRequests();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_pendingPollTimer == null && mounted) {
        _pendingPollTimer =
            Timer.periodic(const Duration(seconds: 30), (_) async {
          if (_activeSectionKey != 'subscriptions') return;
          await _fetchSubscriptionRequests();
          await _fetchSeatRequests();
        });
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _pendingPollTimer?.cancel();
      _pendingPollTimer = null;
    }
  }

  @override
  void dispose() {
    _pendingPollTimer?.cancel();
    _revenueAutoTimer?.cancel();
    _revenueAutoTimer = null;
    _membersSummaryTimer?.cancel();
    _membersSummaryTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    _revenueController.dispose();
    _membersSummaryController.dispose();
    _membersScroll.dispose();
    _subsScroll.dispose();
    _complaintsScroll.dispose();
    _tabController.dispose();
    _clinicNameCtrl.dispose();
    _ownerEmailCtrl.dispose();
    _ownerPassCtrl.dispose();
    _staffEmailCtrl.dispose();
    _staffPassCtrl.dispose();
    _superAdminEmailCtrl.dispose();
    _superAdminPassCtrl.dispose();
    _storageService.dispose();
    _seatService.dispose();
    _superAdminService.dispose();
    super.dispose();
  }

  // ---------- Helpers ----------
  bool _looksLikeEmail(String s) {
    final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return re.hasMatch(s);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  bool _computeIsRoot(String? email) {
    if (email == null) return false;
    return email.toLowerCase().trim() == _rootSuperAdminEmail;
  }

  void _startRevenueAutoPlay() {
    _revenueAutoTimer?.cancel();
    _revenueAutoTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (!_revenueController.hasClients) return;
      final current =
          _revenueController.page?.round() ?? _revenueController.initialPage;
      final next = (current + 1) % _revenueCardCount;
      _revenueController.animateToPage(
        next,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _startMembersSummaryAutoPlay() {
    _membersSummaryTimer?.cancel();
    _membersSummaryTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted) return;
      if (!_membersSummaryController.hasClients) return;
      final current =
          _membersSummaryController.page?.round() ?? _membersSummaryController.initialPage;
      final next = (current + 1) % _membersSummaryCardCount;
      _membersSummaryController.animateToPage(
        next,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
      );
    });
  }

  String get _activeSectionKey {
    if (_visibleSectionKeys.isEmpty) return '';
    if (_sectionIndex < 0 || _sectionIndex >= _visibleSectionKeys.length) {
      return _visibleSectionKeys.first;
    }
    return _visibleSectionKeys[_sectionIndex];
  }

  void _rebuildVisibleSections() {
    final keys = <String>[];
    if (_isRootCached) {
      keys.addAll(_baseAdminTabs);
      keys.add('superadmins');
    } else {
      keys.addAll(_allowedAdminTabs);
    }
    _visibleSectionKeys = keys;
    if (_sectionIndex >= _visibleSectionKeys.length) {
      _sectionIndex = 0;
    }
  }

  Future<void> _loadAdminTabs() async {
    _loadingAdminTabs = true;
    _tabsError = null;
    try {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      _isRootCached = _computeIsRoot(auth.email);
      if (_isRootCached) {
        _allowedAdminTabs = List.of(_baseAdminTabs);
      } else {
        var tabs = await _superAdminService.fetchMyAllowedTabs();
        // Retry once if auth/session was not fully ready.
        if (tabs.isEmpty) {
          await auth.refreshAndValidateCurrentUser();
          tabs = await _superAdminService.fetchMyAllowedTabs();
        }
        _allowedAdminTabs = tabs.where(_baseAdminTabs.contains).toList();
        if (_allowedAdminTabs.isEmpty) {
          _tabsError = 'تعذّر تحميل التبويبات أو لم يتم تحديد تبويبات للحساب.';
        }
      }
    } catch (e) {
      if (_isRootCached) {
        // Root keeps full access even if the fetch fails.
        _allowedAdminTabs = List.of(_baseAdminTabs);
      } else {
        // Fail-closed for non-root to avoid showing tabs without confirmation.
        _allowedAdminTabs = const [];
      }
      _tabsError = kDebugMode
          ? 'تعذّر تحميل التبويبات: $e'
          : 'تعذّر تحميل التبويبات. يرجى إعادة المحاولة.';
    } finally {
      if (!mounted) return;
      _rebuildVisibleSections();
      setState(() => _loadingAdminTabs = false);
    }
  }

  int get _pendingSubscriptionCount =>
      _subscriptionRequests.where((r) => r.status == 'pending').length;
  int get _pendingSeatCount =>
      _seatRequests.where((r) => r.status == 'submitted').length;
  int get _pendingComplaintCount => _complaints
      .where((c) => (c.status.isEmpty || c.status == 'open' || c.status == 'in_progress'))
      .length;

  Widget _navIconWithBadge(IconData icon, int count) {
    if (count <= 0) return Icon(icon);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        Positioned(
          right: -4,
          top: -4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDrawerHeader() {
    return DrawerHeader(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Row(
        children: [
          Image.asset(
            'assets/images/logo.png',
            height: 28,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'لوحة تحكّم المشرف العام',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerItem({
    required int index,
    required String label,
    required Widget icon,
  }) {
    final selected = _sectionIndex == index;
    return ListTile(
      leading: icon,
      title: Text(label),
      selected: selected,
      onTap: () async {
        if (_sectionIndex != index) {
          setState(() => _sectionIndex = index);
          await _refreshCurrentSection();
        }
        if (!mounted) return;
        Navigator.of(context).pop();
      },
    );
  }

  Widget _sectionIcon(String key) {
    switch (key) {
      case 'subscriptions':
        return _navIconWithBadge(
          Icons.workspace_premium_rounded,
          _pendingSubscriptionCount + _pendingSeatCount,
        );
      case 'complaints':
        return _navIconWithBadge(
          Icons.report_problem_rounded,
          _pendingComplaintCount,
        );
      default:
        return Icon(_tabIcons[key] ?? Icons.dashboard_outlined);
    }
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _buildDrawerHeader(),
            if (_loadingAdminTabs)
              const ListTile(
                leading: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text('تحميل التبويبات...'),
              )
            else if (_visibleSectionKeys.isEmpty)
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded),
                title: Text(_tabsError ?? 'لا توجد تبويبات متاحة.'),
              )
            else
              ..._visibleSectionKeys.asMap().entries.map((entry) {
                final index = entry.key;
                final key = entry.value;
                final label = _tabLabels[key] ?? key;
                return _buildDrawerItem(
                  index: index,
                  label: label,
                  icon: _sectionIcon(key),
                );
              }),
          ],
        ),
      ),
    );
  }

  Future<String?> _askDecisionNote(String title) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'ملاحظة (اختياري)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('تخطي'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<double?> _askSeatPrice(double current) async {
    final ctrl = TextEditingController(
      text: current > 0 ? current.toStringAsFixed(0) : '',
    );
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تحديد سعر المقعد'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'السعر بالدولار',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(ctrl.text.trim());
              Navigator.of(ctx).pop(value);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<Map<String, String?>?> _askComplaintReply({
    required String title,
  }) async {
    final replyCtrl = TextEditingController();
    String status = 'in_progress';
    final result = await showDialog<Map<String, String?>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: replyCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'اكتب رد الإدارة هنا',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: status,
              decoration: const InputDecoration(
                labelText: 'تحديث الحالة',
              ),
              items: const [
                DropdownMenuItem(value: 'open', child: Text('مفتوحة')),
                DropdownMenuItem(
                    value: 'in_progress', child: Text('قيد المعالجة')),
                DropdownMenuItem(value: 'closed', child: Text('مغلقة')),
              ],
              onChanged: (value) {
                if (value == null) return;
                status = value;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop({
              'reply': replyCtrl.text.trim(),
              'status': status,
            }),
            child: const Text('إرسال الرد'),
          ),
        ],
      ),
    );
    replyCtrl.dispose();
    return result;
  }

  Future<void> _openProof(SubscriptionRequest req) async {
    final proofId = req.proofUrl ?? '';
    await _openStorageProof(
      value: proofId,
      title: 'إثبات الدفع',
      emptyMessage: 'لا يوجد إثبات دفع لهذا الطلب.',
    );
  }

  Future<void> _openSeatProof(String fileId) async {
    await _openStorageProof(
      value: fileId,
      title: 'وصل الدفع',
      emptyMessage: 'لا يوجد وصل مرفق.',
    );
  }

  Future<void> _openStorageProof({
    required String value,
    required String title,
    required String emptyMessage,
  }) async {
    final raw = value.trim();
    if (raw.isEmpty) {
      _snack(emptyMessage);
      return;
    }

    // 1) Data URL مباشرة
    if (raw.startsWith('data:')) {
      final dataBytes = _decodeDataUrl(raw);
      if (dataBytes != null) {
        _showProofDialogBytes(title: title, bytes: dataBytes);
        return;
      }
    }

    String? signedUrl;
    Uint8List? bytes;

    // 2) storage://bucket/path
    if (raw.startsWith('storage://')) {
      final rest = raw.substring('storage://'.length);
      final idx = rest.indexOf('/');
      if (idx > 0 && idx < rest.length - 1) {
        final bucket = rest.substring(0, idx);
        final path = rest.substring(idx + 1);
        signedUrl =
            await _storageService.resolveSignedUrlForPath(bucket: bucket, path: path);
      }
    } else if (raw.startsWith('http://') || raw.startsWith('https://')) {
      // 3) رابط مباشر (قد يحتوي fileId)
      signedUrl = await _storageService.resolveSignedUrlFromUrl(raw) ?? raw;
    } else {
      // 4) يفترض أنه fileId
      signedUrl = await _storageService.createAdminSignedUrl(raw);
      if (signedUrl == null || signedUrl.isEmpty) {
        signedUrl = await _storageService.createSignedUrl(raw);
      }
    }

    if (signedUrl == null || signedUrl.isEmpty) {
      // محاولة تحميل مباشر بالجلسة الحالية
      final fileId = _storageService.extractFileIdFromUrl(raw) ??
          (_looksLikeUuid(raw) ? raw : null);
      if (fileId != null) {
        try {
          bytes = Uint8List.fromList(await _storageService.downloadFile(fileId));
        } catch (_) {}
      }
    }

    if (bytes != null) {
      _showProofDialogBytes(title: title, bytes: bytes);
      return;
    }
    if (signedUrl != null && signedUrl.isNotEmpty) {
      _showProofDialog(title: title, url: signedUrl);
      return;
    }
    _snack('تعذر عرض الصورة.');
  }

  bool _looksLikeUuid(String v) {
    final re = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return re.hasMatch(v.trim());
  }

  void _showProofDialog({
    required String title,
    required String url,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          height: 520,
          child: InteractiveViewer(
            child: Image.network(
              url,
              fit: BoxFit.contain,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return const Center(child: CircularProgressIndicator());
              },
              errorBuilder: (context, error, stackTrace) {
                return const Center(
                  child: Text('تعذر عرض الصورة.'),
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إغلاق'),
          ),
          FilledButton(
            onPressed: () async {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('فتح في المتصفح'),
          ),
        ],
      ),
    );
  }

  Uint8List? _decodeDataUrl(String value) {
    if (!value.startsWith('data:')) return null;
    final parts = value.split(',');
    if (parts.length < 2) return null;
    try {
      return base64Decode(parts.sublist(1).join(','));
    } catch (_) {
      return null;
    }
  }

  void _showProofDialogBytes({
    required String title,
    required Uint8List bytes,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          height: 520,
          child: InteractiveViewer(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  void _showProvisioningOutcome({
    required String successMessage,
    required ProvisioningResult result,
    String? displayEmail,
    String? displayName,
  }) {
    final lines = <String>[successMessage];
    final details = <String>[];
    final role = result.role;
    if (displayName != null && displayName.trim().isNotEmpty) {
      details.add('الاسم: ${displayName.trim()}');
    }
    if (displayEmail != null && displayEmail.trim().isNotEmpty) {
      details.add('البريد: ${displayEmail.trim()}');
    }
    if (role.isNotEmpty) {
      details.add('الدور: $role');
    }
    if (details.isNotEmpty) {
      lines.add(details.join(' • '));
    }
    if (result.warnings.isNotEmpty) {
      lines.addAll(result.warnings.map((w) => '⚠️ $w'));
    }
    _snack(lines.join('\n'));
  }

  // ---------- Data ----------
  Future<void> _fetchClinics() async {
    try {
      setState(() => _loadingClinics = true);
      final data = await _authService.fetchClinics();
      if (!mounted) return;
      setState(() {
        _clinics = data;
        // لو يوجد عيادة واحدة فقط ولم يكن هناك اختيار سابق — اخترها تلقائياً
        if (_clinics.length == 1) {
          _selectedClinic ??= _clinics.first;
        } else if (_selectedClinic != null &&
            !_clinics.any((c) => c.id == _selectedClinic!.id)) {
          // إن كانت العيادة المختارة لم تعد موجودة، أزل الاختيار
          _selectedClinic = null;
        }
        _loadingClinics = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingClinics = false);
      _snack('تعذّر تحميل العيادات: $e');
    }
  }

  Future<void> _fetchSubscriptionRequests() async {
    try {
      setState(() => _loadingRequests = true);
      _subsOffset = 0;
      _subsHasMore = true;
      _subscriptionRequests = [];
      await _loadMoreSubscriptionRequests(resetLoading: true);
      if (!mounted) return;
      final pending = _subscriptionRequests
          .where((r) => r.status == 'pending')
          .length;
      if (pending > _lastSubscriptionPending && _lastSubscriptionPending > 0) {
        _snack('طلبات اشتراك جديدة بانتظار الاعتماد.');
      }
      _lastSubscriptionPending = pending;
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRequests = false);
      _snack('تعذّر تحميل طلبات الاشتراك: $e');
    }
  }

  Future<void> _loadMoreSubscriptionRequests({bool resetLoading = false}) async {
    if (_subsLoadingMore || !_subsHasMore) return;
    _subsLoadingMore = true;
    if (resetLoading) {
      setState(() => _loadingRequests = true);
    }
    try {
      final rows = await _billingService.fetchSubscriptionRequestsPage(
        limit: _subsPageSize,
        offset: _subsOffset,
      );
      if (!mounted) return;
      setState(() {
        _subscriptionRequests.addAll(rows);
        _subsOffset += rows.length;
        _subsHasMore = rows.length >= _subsPageSize;
        _loadingRequests = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRequests = false);
      _snack('تعذّر تحميل طلبات الاشتراك: $e');
    } finally {
      _subsLoadingMore = false;
    }
  }

  Future<void> _fetchSeatRequests() async {
    try {
      setState(() => _loadingSeatRequests = true);
      final rows = await _seatService.fetchSeatRequests();
      await _fetchSeatPrice();
      if (!mounted) return;
      final pending =
          rows.where((r) => r.status == 'submitted').length;
      setState(() {
        _seatRequests = rows;
        _loadingSeatRequests = false;
      });
      if (pending > _lastSeatPending && _lastSeatPending > 0) {
        _snack('طلبات موظفين جديدة بانتظار المراجعة.');
      }
      _lastSeatPending = pending;
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingSeatRequests = false);
      _snack('تعذّر تحميل طلبات الموظفين: $e');
    }
  }

  Future<void> _fetchExtraSeatRevenue() async {
    try {
      setState(() => _loadingExtraSeatRevenue = true);
      final totals = await _billingService.fetchPlanRevenueTotals();
      final monthly = _pickPlanRevenue(totals, (code) => code.contains('month'));
      final annual = _pickPlanRevenue(
        totals,
        (code) => code.contains('year') || code.contains('annual'),
      );
      final extra = totals['extra_seat'] ?? 0.0;
      if (!mounted) return;
      setState(() {
        _monthlySubRevenue = monthly;
        _annualSubRevenue = annual;
        _extraSeatRevenue = extra;
        _loadingExtraSeatRevenue = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingExtraSeatRevenue = false);
      _snack('تعذّر تحميل دخل المقاعد الإضافية: $e');
    }
  }

  double _pickPlanRevenue(
    Map<String, double> totals,
    bool Function(String code) test,
  ) {
    double sum = 0.0;
    for (final entry in totals.entries) {
      if (test(entry.key)) sum += entry.value;
    }
    return sum;
  }

  Future<void> _fetchSeatPrice() async {
    try {
      setState(() => _loadingSeatPrice = true);
      final price = await _seatService.fetchDefaultSeatPrice();
      if (!mounted) return;
      setState(() {
        _seatDefaultPrice = price;
        _loadingSeatPrice = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingSeatPrice = false);
      _snack('تعذّر تحميل سعر المقعد الافتراضي: $e');
    }
  }

  Future<void> _fetchPaymentMethods() async {
    try {
      setState(() => _loadingPaymentMethods = true);
      final rows = await _billingService.fetchPaymentMethods();
      if (!mounted) return;
      setState(() {
        _paymentMethods = rows;
        _loadingPaymentMethods = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingPaymentMethods = false);
      _snack('تعذّر تحميل وسائل الدفع: $e');
    }
  }

  Future<void> _fetchComplaints() async {
    try {
      setState(() => _loadingComplaints = true);
      _complaintsOffset = 0;
      _complaintsHasMore = true;
      _complaints = [];
      await _loadMoreComplaints(resetLoading: true);
      if (!mounted) return;
      final pending = _pendingComplaintCount;
      if (pending > _lastComplaintPending && _lastComplaintPending > 0) {
        _snack('شكاوى جديدة بانتظار المراجعة.');
      }
      _lastComplaintPending = pending;
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingComplaints = false);
      _snack('تعذّر تحميل الشكاوى: $e');
    }
  }

  Future<void> _loadMoreComplaints({bool resetLoading = false}) async {
    if (_complaintsLoadingMore || !_complaintsHasMore) return;
    _complaintsLoadingMore = true;
    if (resetLoading) {
      setState(() => _loadingComplaints = true);
    }
    try {
      final rows = await _billingService.fetchComplaintsPage(
        limit: _complaintsPageSize,
        offset: _complaintsOffset,
      );
      if (!mounted) return;
      setState(() {
        _complaints.addAll(rows);
        _complaintsOffset += rows.length;
        _complaintsHasMore = rows.length >= _complaintsPageSize;
        _loadingComplaints = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingComplaints = false);
      _snack('تعذّر تحميل الشكاوى: $e');
    } finally {
      _complaintsLoadingMore = false;
    }
  }

  Future<void> _fetchPaymentStats() async {
    try {
      setState(() => _loadingStats = true);
      final bundle = await _billingService.fetchPaymentStatsBundle();
      if (!mounted) return;
      setState(() {
        _paymentStats = bundle.methods;
        _paymentPlanStats = bundle.plans;
        _paymentMonthlyStats = bundle.monthly;
        _paymentDailyStats = bundle.daily;
        _loadingStats = false;
      });
      await _fetchExtraSeatRevenue();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingStats = false);
      _snack('تعذّر تحميل الإحصاءات: $e');
    }
  }

  Future<void> _fetchSystemHealth() async {
    if (!mounted) return;
    setState(() => _loadingSystemHealth = true);
    try {
      final health = await _insightsService.fetchSystemHealth();
      if (!mounted) return;
      setState(() {
        _systemHealth = health;
        _loadingSystemHealth = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingSystemHealth = false);
      _snack('تعذّر تحميل صحة النظام: $e');
    }
  }

  Future<void> _fetchActionLogs({bool reset = true}) async {
    if (!mounted) return;
    if (reset) {
      setState(() {
        _loadingActionLogs = true;
        _actionLogsOffset = 0;
        _actionLogsHasMore = true;
      });
    } else {
      if (_loadingMoreActionLogs || !_actionLogsHasMore) return;
      setState(() => _loadingMoreActionLogs = true);
    }
    try {
      final logs = await _insightsService.fetchActionLogs(
        limit: _actionLogsPageSize,
        offset: _actionLogsOffset,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _adminActionLogs = logs;
          _loadingActionLogs = false;
        } else {
          _adminActionLogs = [..._adminActionLogs, ...logs];
          _loadingMoreActionLogs = false;
        }
        _actionLogsOffset += logs.length;
        if (logs.length < _actionLogsPageSize) {
          _actionLogsHasMore = false;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingActionLogs = false;
        _loadingMoreActionLogs = false;
      });
      _snack('تعذّر تحميل سجل الأوامر: $e');
    }
  }

  Future<void> _fetchUsageMetrics() async {
    if (!mounted) return;
    setState(() => _loadingUsageMetrics = true);
    try {
      final metrics = await _insightsService.fetchUsageMetrics();
      if (!mounted) return;
      setState(() {
        _usageMetrics = metrics;
        _loadingUsageMetrics = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingUsageMetrics = false);
      _snack('تعذّر تحميل مؤشرات الاستخدام: $e');
    }
  }

  Future<void> _fetchRiskAlerts() async {
    if (!mounted) return;
    setState(() => _loadingRiskAlerts = true);
    try {
      final alerts = await _insightsService.fetchRiskAlerts();
      if (!mounted) return;
      setState(() {
        _riskAlerts = alerts;
        _loadingRiskAlerts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRiskAlerts = false);
      _snack('تعذّر تحميل التنبيهات: $e');
    }
  }

  Future<void> _fetchAuditDaily() async {
    if (!mounted) return;
    setState(() => _loadingAuditDaily = true);
    try {
      final rows = await _insightsService.fetchAuditActivityDaily(limit: 60);
      if (!mounted) return;
      setState(() {
        _auditDaily = rows;
        _loadingAuditDaily = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingAuditDaily = false);
      _snack('تعذّر تحميل ملخص التدقيق: $e');
    }
  }

  Future<void> _fetchAuditTopActors() async {
    if (!mounted) return;
    setState(() => _loadingAuditTopActors = true);
    try {
      final rows = await _insightsService.fetchAuditTopActors(limit: 15);
      if (!mounted) return;
      setState(() {
        _auditTopActors = rows;
        _loadingAuditTopActors = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingAuditTopActors = false);
      _snack('تعذّر تحميل أكثر الحسابات نشاطًا: $e');
    }
  }

  Future<void> _fetchUsageDaily() async {
    if (!mounted) return;
    setState(() => _loadingUsageDaily = true);
    try {
      final rows = await _insightsService.fetchUsageDaily(limit: 30);
      if (!mounted) return;
      setState(() {
        _usageDaily = rows;
        _loadingUsageDaily = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingUsageDaily = false);
      _snack('تعذّر تحميل حركة الاستخدام اليومية: $e');
    }
  }

  Future<void> _fetchMemberCounts() async {
    try {
      setState(() => _loadingMemberCounts = true);
      final rows = await _membersService.fetchMemberCounts(
          onlyActive: _membersOnlyActive);
      if (!mounted) return;
      setState(() {
        _memberCounts = rows;
        _loadingMemberCounts = false;
        if (_membersAccountId != null &&
            rows.every((r) => r.accountId != _membersAccountId)) {
          _membersAccountId = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMemberCounts = false);
      _snack('تعذّر تحميل إحصاءات الأعضاء: $e');
    }
  }

  Future<void> _fetchAccountMembers({String? accountId}) async {
    try {
      setState(() => _loadingAccountMembers = true);
      _membersOffset = 0;
      _membersHasMore = true;
      _accountMembers = [];
      await _loadMoreMembers(resetLoading: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingAccountMembers = false);
      _snack('تعذّر تحميل قائمة الأعضاء: $e');
    }
  }

  Future<void> _loadMoreMembers({bool resetLoading = false}) async {
    if (_membersLoadingMore || !_membersHasMore) return;
    _membersLoadingMore = true;
    if (resetLoading) {
      setState(() => _loadingAccountMembers = true);
    }
    try {
      final rows = await _membersService.fetchMembersPage(
        accountId: _membersAccountId,
        onlyActive: _membersOnlyActive,
        limit: _membersPageSize,
        offset: _membersOffset,
      );
      if (!mounted) return;
      setState(() {
        _accountMembers.addAll(rows);
        _membersOffset += rows.length;
        _membersHasMore = rows.length >= _membersPageSize;
        _loadingAccountMembers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingAccountMembers = false);
      _snack('تعذّر تحميل قائمة الأعضاء: $e');
    } finally {
      _membersLoadingMore = false;
    }
  }

  // ---------- Actions ----------
  Future<void> _createClinicAccount() async {
    if (_busy) return;
    final name = _clinicNameCtrl.text.trim();
    final email = _ownerEmailCtrl.text.trim();
    final pass = _ownerPassCtrl.text;

    if (name.isEmpty || email.isEmpty || pass.isEmpty) {
      _snack('املأ جميع الحقول من فضلك');
      return;
    }
    if (!_looksLikeEmail(email)) {
      _snack('صيغة البريد غير صحيحة');
      return;
    }
    if (pass.length < 9) {
      _snack('الحد الأدنى لكلمة المرور هو 9 أحرف');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final result = await _authService.createClinicAccount(
        clinicName: name,
        ownerEmail: email,
        ownerPassword: pass,
      );
      _showProvisioningOutcome(
        successMessage: '✅ تم إنشاء العيادة وحساب المالك',
        result: result,
        displayName: name,
        displayEmail: email,
      );
      _clinicNameCtrl.clear();
      _ownerEmailCtrl.clear();
      _ownerPassCtrl.clear();

      // حدّث القائمة وانتقل لتبويب الإدارة
      await _fetchClinics();
      if (mounted) _tabController.animateTo(2);
    } catch (e) {
      _snack('خطأ في الإنشاء: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createStaffAccount() async {
    if (_busy) return;
    if (_selectedClinic == null) {
      _snack('اختر عيادة أولًا');
      return;
    }
    final email = _staffEmailCtrl.text.trim();
    final pass = _staffPassCtrl.text;

    if (email.isEmpty || pass.isEmpty) {
      _snack('املأ جميع الحقول من فضلك');
      return;
    }
    if (!_looksLikeEmail(email)) {
      _snack('صيغة البريد غير صحيحة');
      return;
    }
    if (pass.length < 9) {
      _snack('الحد الأدنى لكلمة المرور هو 9 أحرف');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final result = await _authService.createEmployeeAccount(
        clinicId: _selectedClinic!.id,
        email: email,
        password: pass,
      );
      _showProvisioningOutcome(
        successMessage: '✅ تم إنشاء حساب الموظف',
        result: result,
        displayName: _selectedClinic?.name,
        displayEmail: email,
      );
      _staffEmailCtrl.clear();
      _staffPassCtrl.clear();
      if (mounted) {
        setState(() => _createStaffPlanError = null);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _createStaffPlanError = _mapCreateStaffError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _mapCreateStaffError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('plan is free')) {
      return 'خطة العيادة FREE: لا يمكن إضافة موظفين حتى تتم الترقية.';
    }
    if (msg.contains('seat_payment_required') ||
        msg.contains('seat payment')) {
      return 'تجاوزت الحد المجاني. يرجى اعتماد طلب مقعد إضافي لهذا الموظف.';
    }
    if (msg.contains('forbidden')) {
      return 'لا تملك صلاحية تنفيذ هذه العملية.';
    }
    if (msg.contains('account not found')) {
      return 'تعذّر العثور على حساب العيادة.';
    }
    if (msg.contains('email is required') || msg.contains('missing fields')) {
      return 'يرجى إدخال البريد وكلمة المرور.';
    }
    if (msg.contains('auth user not found')) {
      return 'تعذّر إنشاء المستخدم في المصادقة، حاول مرة أخرى.';
    }
    return 'تعذّر إنشاء الموظف: $error';
  }

  Future<void> _toggleFreeze(Clinic clinic) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _authService.freezeClinic(clinic.id, !clinic.isFrozen);
      _snack(clinic.isFrozen ? 'تم تفعيل العيادة' : 'تم تجميد العيادة');
      await _fetchClinics();
    } catch (e) {
      _snack('تعذّر تغيير الحالة: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteClinic(Clinic clinic) async {
    if (_busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('تأكيد حذف العيادة'),
          content: Text('سيتم حذف العيادة "${clinic.name}" وجميع بياناتها!'),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              child: const Text('حذف'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      await _authService.deleteClinic(clinic.id);
      _snack('🗑️ تم حذف العيادة');
      await _fetchClinics();
    } catch (e) {
      _snack('تعذّر الحذف: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// الانتقال السريع إلى شاشة الإحصاءات
  void _skipToStatistics() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const StatisticsOverviewScreen()),
    );
  }

  /// تسجيل الخروج وإرجاع المستخدم إلى شاشة تسجيل الدخول
  Future<void> _logout() async {
    try {
      await _authService.signOut();
    } catch (_) {/* تجاهل */}
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = Provider.of<AuthProvider>(context, listen: true);
    if (!auth.isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('لوحة تحكّم المشرف العام'),
          actions: [
            TextButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text('تسجيل الخروج'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'هذه الشاشة مخصّصة للسوبر أدمن فقط.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Scaffold(
          key: _scaffoldKey,
          drawer: _buildDrawer(),
          appBar: AppBar(
            centerTitle: true,
            leading: IconButton(
              tooltip: 'القائمة',
              onPressed: _openDrawer,
              icon: const Icon(Icons.menu_rounded),
            ),
            title: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 140) {
                  return const Text(
                    'لوحة تحكّم المشرف العام',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                }
                return Row(
                  children: [
                    Image.asset(
                      'assets/images/logo.png',
                      height: 24,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'لوحة تحكّم المشرف العام',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                );
              },
            ),
            actions: [
              IconButton(
                tooltip: 'تحديث',
                onPressed: _refreshCurrentSection,
                icon: const Icon(Icons.refresh),
              ),
              if (_visibleSectionKeys.contains('stats'))
                TextButton.icon(
                  onPressed: _skipToStatistics,
                  icon: const Icon(Icons.skip_next),
                  label: const Text('تخطي'),
                ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: _logout,
                icon: const Icon(Icons.logout),
                label: const Text('تسجيل الخروج'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: AbsorbPointer(
                absorbing: _busy, // تعطيل كل الواجهات أثناء العمليات الحرجة
                child: Opacity(
                  opacity: _busy ? 0.7 : 1,
                  child: _buildSectionBody(scheme),
                ),
              ),
            ),
          ),
        ),

        // طبقة انشغال خفيفة أثناء الطلبات الحرجة
        if (_busy)
          IgnorePointer(
            ignoring: true,
            child: Container(
              color: Colors.black12,
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.only(top: 6),
              child: const LinearProgressIndicator(minHeight: 3),
            ),
          ),
      ],
    );
  }

  Future<void> _refreshCurrentSection() async {
    if (_activeSectionKey.isEmpty) return;
    switch (_activeSectionKey) {
      case 'clinics':
        await _fetchClinics();
        break;
      case 'chats':
        break;
      case 'support_ratings':
        break;
      case 'subscriptions':
        await _fetchSubscriptionRequests();
        await _fetchSeatRequests();
        break;
      case 'payments':
        await _fetchPaymentMethods();
        break;
      case 'complaints':
        await _fetchComplaints();
        break;
      case 'stats':
        await _fetchPaymentStats();
        await _fetchExtraSeatRevenue();
        await _fetchSystemHealth();
        await _fetchActionLogs();
        await _fetchUsageMetrics();
        await _fetchRiskAlerts();
        await _fetchAuditDaily();
        await _fetchAuditTopActors();
        await _fetchUsageDaily();
        break;
      case 'members':
        await _fetchMemberCounts();
        await _fetchAccountMembers(accountId: _membersAccountId);
        break;
      case 'superadmins':
        await _fetchSuperAdmins();
        break;
    }
  }

  Widget _buildSectionBody(ColorScheme scheme) {
    if (_activeSectionKey.isEmpty) {
      return Center(
        child: Text(
          _tabsError ?? 'لا توجد تبويبات متاحة لهذا الحساب.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.error),
        ),
      );
    }
    switch (_activeSectionKey) {
      case 'clinics':
        return _buildClinicsSection(scheme);
      case 'chats':
        return const ChatAdminInboxScreen();
      case 'support_ratings':
        return const SupportRatingsScreen();
      case 'subscriptions':
        return SizedBox.expand(child: _buildSubscriptionRequestsSection());
      case 'payments':
        return _buildPaymentMethodsSection(scheme);
      case 'complaints':
        return _buildComplaintsSection(scheme);
      case 'stats':
        return _buildPaymentStatsSection(scheme);
      case 'members':
        return _buildAccountMembersSection(scheme);
      case 'superadmins':
        return _buildSuperAdminAccountsSection(scheme);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildClinicsSection(ColorScheme scheme) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: scheme.onSurface,
          unselectedLabelColor: scheme.onSurface.withValues(alpha: .6),
          indicatorColor: kPrimaryColor,
          indicatorWeight: 3,
          tabs: const [
            Tab(icon: Icon(Icons.add_business), text: 'عيادة جديدة'),
            Tab(icon: Icon(Icons.person_add_alt_1), text: 'موظف جديد'),
            Tab(icon: Icon(Icons.manage_accounts), text: 'إدارة العيادات'),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildCreateClinicTab(),
              _buildCreateEmployeeTab(),
              _buildManageClinicsTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSubscriptionRequestsSection() {
    final pending =
        _subscriptionRequests.where((r) => r.status == 'pending').length;
    final approved =
        _subscriptionRequests.where((r) => r.status == 'approved').length;
    final rejected =
        _subscriptionRequests.where((r) => r.status == 'rejected').length;
    final totalAmount = _subscriptionRequests.fold<double>(
      0,
      (sum, r) => sum + (r.amount.isFinite ? r.amount : 0),
    );
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          NeuCard(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.workspace_premium_rounded),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'إدارة الاشتراكات',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await _fetchSubscriptionRequests();
                    await _fetchSeatRequests();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('تحديث'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statChip('قيد المراجعة', pending),
                _statChip('تم الاعتماد', approved),
                _statChip('مرفوضة', rejected),
                _statChip('إجمالي المبالغ', totalAmount.toInt()),
                _statChip('طلبات الموظفين', _pendingSeatCount),
              ],
            ),
          ),
          TabBar(
            labelColor: Theme.of(context).colorScheme.onSurface,
            unselectedLabelColor:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: .6),
            indicatorColor: kPrimaryColor,
            indicatorWeight: 3,
            tabs: const [
              Tab(
                  icon: Icon(Icons.workspace_premium_rounded),
                  text: 'اشتراكات'),
              Tab(icon: Icon(Icons.badge_rounded), text: 'طلبات الموظفين'),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: TabBarView(
              children: [
                _buildSubscriptionRequestsList(),
                _buildSeatRequestsSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuperAdminAccountsSection(ColorScheme scheme) {
    if (!_isRootCached) {
      return Center(
        child: Text(
          'هذه الشاشة متاحة للحساب الجذري فقط.',
          style: TextStyle(color: scheme.error),
        ),
      );
    }
    return Column(
      children: [
        NeuCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'إضافة سوبر أدمن',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _superAdminEmailCtrl,
                labelText: 'البريد الإلكتروني',
                keyboardType: TextInputType.emailAddress,
                prefix: const Icon(Icons.alternate_email_rounded),
                onChanged: (_) {},
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _superAdminPassCtrl,
                labelText: 'كلمة المرور',
                obscureText: true,
                prefix: const Icon(Icons.lock_outline_rounded),
                onChanged: (_) {},
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _newSuperAdminTabs
                    .map((key) => Chip(label: Text(_tabLabels[key] ?? key)))
                    .toList(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  NeuButton.flat(
                    label: 'تعديل التبويبات',
                    icon: Icons.tune_rounded,
                    onPressed: () async {
                      final selected = await _pickTabsDialog(
                        title: 'تبويبات السوبر أدمن',
                        initial: _newSuperAdminTabs,
                      );
                      if (selected == null) return;
                      setState(() => _newSuperAdminTabs = selected);
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: NeuButton.primary(
                        label: _creatingSuperAdmin ? 'جارٍ الإنشاء...' : 'إنشاء',
                        icon: Icons.person_add_alt_1,
                        onPressed: _creatingSuperAdmin ? null : _createSuperAdmin,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildSuperAdminAccountsList(scheme)),
      ],
    );
  }

  Widget _buildSuperAdminAccountsList(ColorScheme scheme) {
    if (_loadingSuperAdmins) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_superAdminAccounts.isEmpty) {
      return const Center(child: Text('لا توجد حسابات سوبر أدمن.'));
    }
    return ListView.builder(
      itemCount: _superAdminAccounts.length,
      itemBuilder: (context, index) {
        final account = _superAdminAccounts[index];
        final isRoot = _isRootEmail(account.email);
        final statusText = account.disabled ? 'مجمّد' : 'نشط';
        final statusColor = account.disabled ? scheme.error : scheme.primary;
        final created = account.createdAt;
        final createdLabel =
            created == null ? '' : DateFormat('yyyy/MM/dd').format(created);
        return NeuCard(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      account.email.isEmpty
                          ? 'بلا بريد'
                          : account.email,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (createdLabel.isNotEmpty)
                    Text(
                      createdLabel,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .6),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'الحالة: $statusText',
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!account.hasUser)
                    Text(
                      'غير مرتبط بحساب بعد',
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .6),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: account.allowedTabs
                    .map((key) => Chip(label: Text(_tabLabels[key] ?? key)))
                    .toList(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  NeuButton.flat(
                    label: 'التبويبات',
                    icon: Icons.tune_rounded,
                    onPressed: isRoot
                        ? null
                        : () => _editSuperAdminTabs(account),
                  ),
                  const SizedBox(width: 8),
                  NeuButton.flat(
                    label: 'كلمة المرور',
                    icon: Icons.password_rounded,
                    onPressed: isRoot
                        ? null
                        : () => _resetSuperAdminPassword(account),
                  ),
                  const SizedBox(width: 8),
                  NeuButton.flat(
                    label: account.disabled ? 'تفعيل' : 'تجميد',
                    icon: account.disabled
                        ? Icons.lock_open_rounded
                        : Icons.lock_outline_rounded,
                    onPressed:
                        isRoot ? null : () => _toggleSuperAdminDisabled(account),
                  ),
                  const Spacer(),
                  NeuButton.flat(
                    label: 'حذف',
                    icon: Icons.delete_outline_rounded,
                    onPressed: isRoot ? null : () => _deleteSuperAdmin(account),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statChip(
    String label,
    int value, {
    VoidCallback? onTap,
    bool selected = false,
    bool expand = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final chip = InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: NeuCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: selected ? scheme.primary : scheme.onSurface,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: .7),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
    if (!expand) return chip;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 140),
      child: chip,
    );
  }

  int _sumMemberCounts(int Function(AdminAccountMemberCount row) getter) {
    return _memberCounts.fold(0, (sum, row) => sum + getter(row));
  }

  String _roleLabel(String role) {
    switch (role.toLowerCase()) {
      case 'owner':
        return 'مالك';
      case 'admin':
        return 'مدير';
      case 'employee':
        return 'موظف';
      case 'superadmin':
        return 'سوبر أدمن';
      default:
        return role.isEmpty ? 'غير محدد' : role;
    }
  }

  bool _isRootEmail(String? email) {
    if (email == null) return false;
    return email.toLowerCase().trim() == _rootSuperAdminEmail;
  }

  Future<void> _fetchSuperAdmins() async {
    if (!_isRootCached) return;
    setState(() => _loadingSuperAdmins = true);
    try {
      final rows = await _superAdminService.fetchSuperAdmins();
      _superAdminAccounts = rows;
    } catch (e) {
      _snack('تعذّر تحميل حسابات السوبر أدمن: $e');
    } finally {
      if (mounted) setState(() => _loadingSuperAdmins = false);
    }
  }

  Future<void> _createSuperAdmin() async {
    if (_creatingSuperAdmin) return;
    final email = _superAdminEmailCtrl.text.trim().toLowerCase();
    final pass = _superAdminPassCtrl.text.trim();
    if (!_looksLikeEmail(email)) {
      _snack('يرجى إدخال بريد صحيح.');
      return;
    }
    if (pass.length < 9) {
      _snack('كلمة المرور يجب ألا تقل عن 9 أحرف.');
      return;
    }
    setState(() => _creatingSuperAdmin = true);
    try {
      final res = await _superAdminService.createSuperAdmin(
        email: email,
        password: pass,
        allowedTabs: _newSuperAdminTabs.isEmpty
            ? List.of(_baseAdminTabs)
            : _newSuperAdminTabs,
      );
      if (res['ok'] == true) {
        _superAdminEmailCtrl.clear();
        _superAdminPassCtrl.clear();
        _newSuperAdminTabs = List.of(_baseAdminTabs);
        await _fetchSuperAdmins();
        _snack('تم إنشاء حساب سوبر أدمن.');
      } else {
        _snack('تعذّر الإنشاء: ${res['error'] ?? 'خطأ غير معروف'}');
      }
    } catch (e) {
      _snack('تعذّر الإنشاء: $e');
    } finally {
      if (mounted) setState(() => _creatingSuperAdmin = false);
    }
  }

  Future<void> _toggleSuperAdminDisabled(SuperAdminAccount account) async {
    if (_isRootEmail(account.email)) {
      _snack('لا يمكن تعطيل الحساب الجذري.');
      return;
    }
    final target = !account.disabled;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(target ? 'تجميد الحساب؟' : 'تفعيل الحساب؟'),
        content: Text(
          target
              ? 'سيتم تعطيل الحساب: ${account.email}'
              : 'سيتم تفعيل الحساب: ${account.email}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _superAdminService.setDisabled(
        email: account.email,
        disabled: target,
      );
      await _fetchSuperAdmins();
      _snack(target ? 'تم تجميد الحساب.' : 'تم تفعيل الحساب.');
    } catch (e) {
      _snack('تعذّر تحديث الحالة: $e');
    }
  }

  Future<void> _deleteSuperAdmin(SuperAdminAccount account) async {
    if (_isRootEmail(account.email)) {
      _snack('لا يمكن حذف الحساب الجذري.');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف حساب سوبر أدمن'),
        content: Text('هل تريد حذف الحساب: ${account.email} ؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _superAdminService.deleteSuperAdmin(email: account.email);
      await _fetchSuperAdmins();
      _snack('تم حذف الحساب.');
    } catch (e) {
      _snack('تعذّر الحذف: $e');
    }
  }

  Future<void> _editSuperAdminTabs(SuperAdminAccount account) async {
    if (account.userUid.isEmpty) {
      _snack('الحساب غير مرتبط بمستخدم بعد.');
      return;
    }
    final initial = account.allowedTabs
        .where(_baseAdminTabs.contains)
        .toList(growable: false);
    final selected = await _pickTabsDialog(
      title: 'تبويبات لوحة التحكم',
      initial: initial.isEmpty ? List.of(_baseAdminTabs) : initial,
    );
    if (selected == null) return;
    try {
      await _superAdminService.setAllowedTabs(
        userUid: account.userUid,
        allowedTabs: selected,
      );
      await _fetchSuperAdmins();
      _snack('تم تحديث التبويبات.');
    } catch (e) {
      _snack('تعذّر تحديث التبويبات: $e');
    }
  }

  Future<void> _resetSuperAdminPassword(SuperAdminAccount account) async {
    if (_isRootEmail(account.email)) {
      _snack('لا يمكن تغيير كلمة مرور الحساب الجذري.');
      return;
    }
    final ctrl = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تغيير كلمة المرور'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'كلمة المرور الجديدة',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    final pass = ctrl.text.trim();
    ctrl.dispose();
    if (confirm != true) return;
    if (pass.length < 9) {
      _snack('كلمة المرور يجب ألا تقل عن 9 أحرف.');
      return;
    }
    try {
      await _superAdminService.resetSuperAdminPassword(
        email: account.email,
        newPassword: pass,
      );
      _snack('تم تغيير كلمة المرور.');
    } catch (e) {
      _snack('تعذّر تغيير كلمة المرور: $e');
    }
  }

  Future<List<String>?> _pickTabsDialog({
    required String title,
    required List<String> initial,
  }) async {
    final selected = initial.toSet();
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 360,
                child: ListView(
                  shrinkWrap: true,
                  children: _baseAdminTabs.map((key) {
                    final label = _tabLabels[key] ?? key;
                    return CheckboxListTile(
                      value: selected.contains(key),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            selected.add(key);
                          } else {
                            selected.remove(key);
                          }
                          if (selected.isEmpty) {
                            selected.add(key);
                          }
                        });
                      },
                      title: Text(label),
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(selected.toList()),
                  child: const Text('حفظ'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSubscriptionRequestsList() {
    final scheme = Theme.of(context).colorScheme;
    if (_loadingRequests) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_subscriptionRequests.isEmpty) {
      return const Center(child: Text('لا توجد طلبات اشتراك حاليًا'));
    }
    return ListView.builder(
      controller: _subsScroll,
      itemCount: _subscriptionRequests.length + (_subsHasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _subscriptionRequests.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: _subsLoadingMore
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: _loadMoreSubscriptionRequests,
                      child: const Text('تحميل المزيد'),
                    ),
            ),
          );
        }
        final req = _subscriptionRequests[index];
        final ref = (req.referenceText ?? '').trim();
        final sender = (req.senderName ?? '').trim();
        final clinic = (req.clinicName ?? '').trim();
        final amount = req.amount.isFinite ? req.amount : 0.0;
        final planLabel =
            _planLabelFromCode(req.planCode.isNotEmpty ? req.planCode : null);
        final created = req.createdAt == null
            ? ''
            : DateFormat('yyyy-MM-dd HH:mm')
                .format(req.createdAt!.toLocal());
        return NeuCard(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      'الخطة: $planLabel',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _statusChipSmall(req.status, scheme),
                  const Spacer(),
                  Text(
                    '\$${amount.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  if (clinic.isNotEmpty) _metaPill('العيادة', clinic, scheme),
                  if (sender.isNotEmpty) _metaPill('المحوّل', sender, scheme),
                  if (ref.isNotEmpty) _metaPill('المرجع', ref, scheme),
                  if (created.isNotEmpty) _metaPill('التاريخ', created, scheme),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _openProof(req),
                      icon: const Icon(Icons.receipt_long_rounded),
                      label: const Text('الإثبات'),
                    ),
                    if (req.status == 'pending')
                      FilledButton.icon(
                        onPressed: () async {
                          final note =
                              await _askDecisionNote('ملاحظة الاعتماد');
                          try {
                            await _billingService.approveRequest(
                              req.id,
                              note: note,
                            );
                            await _fetchSubscriptionRequests();
                            await _fetchPaymentStats();
                          } catch (e) {
                            final msg =
                                e.toString().replaceFirst('Exception: ', '');
                            _snack('تعذر اعتماد الطلب: $msg');
                          }
                        },
                        icon: const Icon(Icons.check_circle_rounded),
                        label: const Text('اعتماد'),
                      ),
                    if (req.status == 'pending')
                      OutlinedButton.icon(
                        onPressed: () async {
                          final note = await _askDecisionNote('سبب الرفض');
                          try {
                            await _billingService.rejectRequest(
                              req.id,
                              note: note,
                            );
                            await _fetchSubscriptionRequests();
                          } catch (e) {
                            final msg =
                                e.toString().replaceFirst('Exception: ', '');
                            _snack('تعذر رفض الطلب: $msg');
                          }
                        },
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('رفض'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statusChipSmall(String status, ColorScheme scheme) {
    final s = status.trim().toLowerCase();
    Color color;
    String label;
    switch (s) {
      case 'approved':
        color = Colors.green;
        label = 'معتمد';
        break;
      case 'rejected':
        color = Colors.redAccent;
        label = 'مرفوض';
        break;
      case 'pending':
      default:
        color = Colors.orange;
        label = 'قيد المراجعة';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11.5,
        ),
      ),
    );
  }

  Widget _metaPill(String label, String value, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.8),
          fontWeight: FontWeight.w600,
          fontSize: 11.5,
        ),
      ),
    );
  }

  Widget _buildSeatRequestsSection() {
    if (_loadingSeatRequests) {
      return const Center(child: CircularProgressIndicator());
    }
    final all = _seatRequests;
    final filtered = _seatFilter == 'all'
        ? all
        : all.where((r) => r.status == _seatFilter).toList();
    final submittedCount =
        all.where((r) => r.status == 'submitted').length;
    final awaitingCount =
        all.where((r) => r.status == 'awaiting_payment').length;
    final approvedCount =
        all.where((r) => r.status == 'approved').length;
    final rejectedCount =
        all.where((r) => r.status == 'rejected').length;
    final totalAmount = all.fold<double>(
      0,
      (sum, r) => sum + (r.priceUsd > 0 ? r.priceUsd : 0),
    );
    final children = <Widget>[
      _buildSeatDefaultPriceCard(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _statChip('الكل', all.length,
                onTap: () => setState(() {
                      _seatFilter = 'all';
                    }),
                selected: _seatFilter == 'all',
                expand: false),
            _statChip('بانتظار الدفع', awaitingCount,
                onTap: () => setState(() {
                      _seatFilter = 'awaiting_payment';
                    }),
                selected: _seatFilter == 'awaiting_payment',
                expand: false),
            _statChip('قيد المراجعة', submittedCount,
                onTap: () => setState(() {
                      _seatFilter = 'submitted';
                    }),
                selected: _seatFilter == 'submitted',
                expand: false),
            _statChip('معتمد', approvedCount, onTap: () => setState(() {
                  _seatFilter = 'approved';
                }), selected: _seatFilter == 'approved', expand: false),
            _statChip('مرفوض', rejectedCount, onTap: () => setState(() {
                  _seatFilter = 'rejected';
                }), selected: _seatFilter == 'rejected', expand: false),
          ],
        ),
      ),
      NeuCard(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.receipt_long_rounded, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'إجمالي قيمة طلبات المقاعد الإضافية',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '\$${totalAmount.toStringAsFixed(0)}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
      if (filtered.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: Text('لا توجد طلبات موظفين إضافيين حاليًا')),
        ),
      ...filtered.map((req) {
        final status = req.status;
        final note = req.adminNote?.trim() ?? '';
        final priceLabel =
            req.priceUsd > 0 ? '\$${req.priceUsd.toStringAsFixed(0)}' : '—';
        final hasReceipt = (req.receiptFileId ?? '').trim().isNotEmpty;
        return NeuCard(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          padding: const EdgeInsets.all(12),
          child: ListTile(
            title: Text('موظف: ${req.employeeEmail}'),
            subtitle: Text(
              [
                'المبلغ: $priceLabel',
                'الحالة: $status',
                if (note.isNotEmpty) 'ملاحظة: $note',
              ].join('\n'),
            ),
            trailing: status == 'submitted'
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'عرض الوصل',
                            icon: const Icon(Icons.receipt_long_rounded),
                            onPressed: hasReceipt
                                ? () async {
                                    await _openSeatProof(
                                        req.receiptFileId ?? '');
                                  }
                                : null,
                          ),
                          const SizedBox(width: 6),
                          NeuButton.primary(
                            label: 'اعتماد',
                            onPressed: () async {
                              final note =
                                  await _askDecisionNote('ملاحظة الاعتماد');
                              await _seatService.reviewSeatRequest(
                                requestId: req.id,
                                approve: true,
                                note: note,
                              );
                              await _fetchSeatRequests();
                            },
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            tooltip: 'رفض',
                            icon: const Icon(Icons.cancel_outlined),
                            onPressed: () async {
                              final note = await _askDecisionNote('سبب الرفض');
                              await _seatService.reviewSeatRequest(
                                requestId: req.id,
                                approve: false,
                                note: note,
                              );
                              await _fetchSeatRequests();
                            },
                          ),
                        ],
                      ),
                    ),
                  )
                : status == 'awaiting_payment'
                    ? IconButton(
                        tooltip: 'تحديد السعر',
                        icon: const Icon(Icons.edit_rounded),
                        onPressed: () async {
                          final next = await _askSeatPrice(req.priceUsd);
                          if (next == null) return;
                          await _seatService.updateSeatPrice(
                            requestId: req.id,
                            priceUsd: next,
                          );
                          await _fetchSeatRequests();
                        },
                      )
                    : IconButton(
                        tooltip: 'عرض الوصل',
                        icon: const Icon(Icons.receipt_long_rounded),
                        onPressed: hasReceipt
                            ? () async {
                                await _openSeatProof(
                                    req.receiptFileId ?? '');
                              }
                            : null,
                      ),
          ),
        );
      }).toList(),
    ];
    return ListView(children: children);
  }

  Widget _buildSeatDefaultPriceCard() {
    final price = _seatDefaultPrice;
    final label =
        price == null ? 'غير متاح' : '\$${price.toStringAsFixed(0)}';
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: ListTile(
        title: const Text('سعر المقعد الإضافي الافتراضي'),
        subtitle:
            _loadingSeatPrice ? const Text('جاري التحميل...') : Text(label),
        trailing: NeuButton.primary(
          label: 'تعديل السعر',
          onPressed: _loadingSeatPrice
              ? null
              : () async {
                  final current = price ?? 0;
                  final next = await _askSeatPrice(current);
                  if (next == null) return;
                  await _seatService.setDefaultSeatPrice(priceUsd: next);
                  await _fetchSeatPrice();
                },
        ),
      ),
    );
  }

  Widget _buildPaymentMethodsSection(ColorScheme scheme) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: NeuButton.primary(
            label: 'إضافة وسيلة دفع',
            onPressed: _openPaymentMethodDialog,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loadingPaymentMethods
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: _paymentMethods.map((m) {
                    return NeuCard(
                      margin: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 4,
                      ),
                      padding: const EdgeInsets.all(12),
                      child: ListTile(
                        leading: m.logoUrl == null || m.logoUrl!.isEmpty
                            ? const Icon(Icons.account_balance_rounded)
                            : Image.network(
                                m.logoUrl!,
                                width: 40,
                                height: 40,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.account_balance_rounded),
                              ),
                        title: Text(m.name),
                        subtitle: Text('الحساب: ${m.bankAccount}'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'delete') {
                              await _billingService.deletePaymentMethod(m.id);
                              await _fetchPaymentMethods();
                            } else if (v == 'edit') {
                              await _openPaymentMethodDialog(method: m);
                              await _fetchPaymentMethods();
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('تعديل')),
                            PopupMenuItem(value: 'delete', child: Text('حذف')),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  Future<void> _openPaymentMethodDialog({PaymentMethod? method}) async {
    final nameCtrl = TextEditingController(text: method?.name ?? '');
    final bankCtrl = TextEditingController(text: method?.bankAccount ?? '');
    final logoCtrl = TextEditingController(text: method?.logoUrl ?? '');
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(method == null ? 'إضافة وسيلة دفع' : 'تعديل وسيلة دفع'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'اسم الخدمة'),
              ),
              TextField(
                controller: bankCtrl,
                decoration:
                    const InputDecoration(labelText: 'رقم الحساب البنكي'),
              ),
              TextField(
                controller: logoCtrl,
                decoration:
                    const InputDecoration(labelText: 'رابط شعار الشركة'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
    if (result == true) {
      if (method == null) {
        await _billingService.createPaymentMethod(
          name: nameCtrl.text.trim(),
          bankAccount: bankCtrl.text.trim(),
          logoUrl: logoCtrl.text.trim().isEmpty ? null : logoCtrl.text.trim(),
        );
      } else {
        await _billingService.updatePaymentMethod(
          id: method.id,
          name: nameCtrl.text.trim(),
          bankAccount: bankCtrl.text.trim(),
          logoUrl: logoCtrl.text.trim().isEmpty ? null : logoCtrl.text.trim(),
          isActive: true,
        );
      }
    }
    nameCtrl.dispose();
    bankCtrl.dispose();
    logoCtrl.dispose();
  }

  Widget _buildComplaintsSection(ColorScheme scheme) {
    if (_loadingComplaints) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_complaints.isEmpty) {
      return const Center(child: Text('لا توجد شكاوى حالياً'));
    }
    return ListView.builder(
      controller: _complaintsScroll,
      itemCount: _complaints.length + (_complaintsHasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _complaints.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: _complaintsLoadingMore
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: _loadMoreComplaints,
                      child: const Text('تحميل المزيد'),
                    ),
            ),
          );
        }
        final c = _complaints[index];
        final reply = c.replyMessage?.trim() ?? '';
        return NeuCard(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          padding: const EdgeInsets.all(12),
          child: ListTile(
            title: Text(c.subject ?? 'شكوى'),
            subtitle: Text(
              reply.isEmpty
                  ? '${c.message}\nالحالة: ${c.status}'
                  : '${c.message}\nالحالة: ${c.status}\nرد الإدارة: $reply',
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'reply') {
                  final result = await _askComplaintReply(
                    title: 'رد على الشكوى',
                  );
                  final replyText = result?['reply']?.trim() ?? '';
                  if (replyText.isEmpty) return;
                  await _billingService.replyToComplaint(
                    id: c.id,
                    replyMessage: replyText,
                    status: result?['status'],
                  );
                  await _fetchComplaints();
                  return;
                }
                await _billingService.updateComplaintStatus(
                  id: c.id,
                  status: v,
                );
                await _fetchComplaints();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'reply',
                  child: Text('رد على الشكوى'),
                ),
                PopupMenuItem(value: 'open', child: Text('مفتوحة')),
                PopupMenuItem(
                    value: 'in_progress', child: Text('قيد المعالجة')),
                PopupMenuItem(value: 'closed', child: Text('مغلقة')),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAccountMembersSection(ColorScheme scheme) {
    final ownersTotal = _sumMemberCounts((r) => r.ownersCount);
    final adminsTotal = _sumMemberCounts((r) => r.adminsCount);
    final employeesTotal = _sumMemberCounts((r) => r.employeesCount);
    final membersTotal = _sumMemberCounts((r) => r.totalMembers);
    final accountsTotal = _memberCounts.length;

    return ListView(
      controller: _membersScroll,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      children: [
        NeuCard(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.groups_rounded),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'إدارة أعضاء الحسابات',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  await _fetchMemberCounts();
                  await _fetchAccountMembers(accountId: _membersAccountId);
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('تحديث'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        NeuCard(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              DropdownButtonFormField<String?>(
                initialValue: _membersAccountId,
                decoration: const InputDecoration(
                  labelText: 'الحساب',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('جميع الحسابات'),
                  ),
                  ..._memberCounts.map(
                    (row) => DropdownMenuItem<String?>(
                      value: row.accountId,
                      child: Text(
                        row.accountName.isEmpty
                            ? row.accountId
                            : row.accountName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (value) async {
                  setState(() => _membersAccountId = value);
                  await _fetchAccountMembers(accountId: value);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('النشط فقط'),
                  const SizedBox(width: 8),
                  Switch(
                    value: _membersOnlyActive,
                    onChanged: (value) async {
                      setState(() => _membersOnlyActive = value);
                      await _fetchMemberCounts();
                      await _fetchAccountMembers(accountId: _membersAccountId);
                    },
                  ),
                  const Spacer(),
                  Text(
                    'الحسابات: $accountsTotal',
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: .7),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildMembersSummaryCarousel(
          scheme,
          ownersTotal: ownersTotal,
          adminsTotal: adminsTotal,
          employeesTotal: employeesTotal,
          membersTotal: membersTotal,
          accountsTotal: accountsTotal,
        ),
        const SizedBox(height: 10),
        _buildMemberCountsCard(scheme),
        const SizedBox(height: 12),
        _buildMembersListCard(scheme),
      ],
    );
  }

  Widget _buildMembersSummaryCarousel(
    ColorScheme scheme, {
    required int ownersTotal,
    required int adminsTotal,
    required int employeesTotal,
    required int membersTotal,
    required int accountsTotal,
  }) {
    final items = <_RevenueCardData>[
      _RevenueCardData(
        title: 'إجمالي الحسابات',
        subtitle: 'عدد العيادات المرتبطة',
        amount: accountsTotal.toDouble(),
        icon: Icons.business_rounded,
        gradient: [const Color(0xFF0E6A83), const Color(0xFF3CB1AA)],
      ),
      _RevenueCardData(
        title: 'إجمالي الملاك',
        subtitle: 'عدد الملاك',
        amount: ownersTotal.toDouble(),
        icon: Icons.verified_user_rounded,
        gradient: [const Color(0xFF1B4F72), const Color(0xFF2E86C1)],
      ),
      _RevenueCardData(
        title: 'إجمالي المدراء',
        subtitle: 'عدد المدراء',
        amount: adminsTotal.toDouble(),
        icon: Icons.manage_accounts_rounded,
        gradient: [const Color(0xFF6C3483), const Color(0xFF9B59B6)],
      ),
      _RevenueCardData(
        title: 'إجمالي الموظفين',
        subtitle: 'عدد الموظفين',
        amount: employeesTotal.toDouble(),
        icon: Icons.badge_rounded,
        gradient: [const Color(0xFF0B5345), const Color(0xFF1ABC9C)],
      ),
      _RevenueCardData(
        title: 'إجمالي الأعضاء',
        subtitle: 'جميع الحسابات',
        amount: membersTotal.toDouble(),
        icon: Icons.groups_rounded,
        gradient: [const Color(0xFF7D3C98), const Color(0xFFBB8FCE)],
      ),
    ];

    return Column(
      children: [
        SizedBox(
          height: 140,
          child: PageView.builder(
            controller: _membersSummaryController,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final delta = (index - _membersSummaryPage).clamp(-1.0, 1.0);
              final scale = 0.92 + (1 - delta.abs()) * 0.08;
              return AnimatedBuilder(
                animation: _membersSummaryController,
                builder: (context, child) {
                  return Transform.scale(scale: scale, child: child);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: LinearGradient(
                        colors: item.gradient,
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: item.gradient.first.withValues(alpha: 0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(item.icon, color: Colors.white),
                              ),
                              const Spacer(),
                              Text(
                                item.amount.toStringAsFixed(0),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            item.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.subtitle,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(items.length, (i) {
            final active = i == _membersSummaryPage.round();
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: active ? 18 : 8,
              height: 6,
              decoration: BoxDecoration(
                color: active ? scheme.primary : Colors.black12,
                borderRadius: BorderRadius.circular(99),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildMemberCountsCard(ColorScheme scheme) {
    if (_loadingMemberCounts) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_memberCounts.isEmpty) {
      return const Center(child: Text('لا توجد بيانات للحسابات'));
    }
    final muted = scheme.onSurface.withValues(alpha: .6);
    return NeuCard(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('الحساب')),
            DataColumn(label: Text('مالك')),
            DataColumn(label: Text('مدير')),
            DataColumn(label: Text('موظف')),
            DataColumn(label: Text('الإجمالي')),
          ],
          rows: _memberCounts.map((row) {
            return DataRow(
              cells: [
                DataCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(row.accountName.isEmpty
                          ? row.accountId
                          : row.accountName),
                      if (row.accountName.isNotEmpty)
                        Text(
                          row.accountId,
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                    ],
                  ),
                ),
                DataCell(Text('${row.ownersCount}')),
                DataCell(Text('${row.adminsCount}')),
                DataCell(Text('${row.employeesCount}')),
                DataCell(Text('${row.totalMembers}')),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildMembersListCard(ColorScheme scheme) {
    return NeuCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'الأعضاء (${_accountMembers.length})',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          if (_loadingAccountMembers && _accountMembers.isEmpty)
            const Center(child: CircularProgressIndicator())
          else if (_accountMembers.isEmpty)
            const Text('لا توجد حسابات مطابقة للفلترة الحالية.')
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount:
                  _accountMembers.length + (_membersHasMore ? 1 : 0),
              separatorBuilder: (_, __) => const Divider(height: 18),
              itemBuilder: (_, index) {
                if (index >= _accountMembers.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: _membersLoadingMore
                          ? const CircularProgressIndicator()
                          : TextButton(
                              onPressed: _loadMoreMembers,
                              child: const Text('تحميل المزيد'),
                            ),
                    ),
                  );
                }
                final row = _accountMembers[index];
                final title = row.email.isEmpty ? 'بدون بريد' : row.email;
                final roleLabel = _roleLabel(row.role);
                final statusLabel = row.disabled ? 'معطل' : 'نشط';
                final created = row.createdAt == null
                    ? ''
                    : DateFormat('yyyy-MM-dd').format(row.createdAt!);
                final codeRaw = (row.chatCode ?? '').trim();
                final code = codeRaw.isEmpty
                    ? ''
                    : ChatCodeUtils.format(codeRaw);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(title),
                  subtitle: Text(
                    [
                      if (_membersAccountId == null)
                        'الحساب: ${row.accountName}',
                      if (code.isNotEmpty) 'الرقم: $code',
                      'الدور: $roleLabel',
                      'الحالة: $statusLabel',
                      if (created.isNotEmpty) 'تاريخ الإضافة: $created',
                    ].where((e) => e.isNotEmpty).join(' • '),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildPaymentStatsSection(ColorScheme scheme) {
    if (_loadingStats) {
      return const Center(child: CircularProgressIndicator());
    }
    final hasAny = _paymentStats.isNotEmpty ||
        _paymentPlanStats.isNotEmpty ||
        _paymentMonthlyStats.isNotEmpty ||
        _paymentDailyStats.isNotEmpty;
    if (!hasAny &&
        !_loadingExtraSeatRevenue &&
        _extraSeatRevenue <= 0 &&
        _monthlySubRevenue <= 0 &&
        _annualSubRevenue <= 0) {
      return const Center(child: Text('لا توجد بيانات مالية بعد'));
    }

    final modeLabels = ['وسائل الدفع', 'حسب الباقة', 'شهري', 'يومي'];
    Widget listBody;

    if (_statsMode == 1) {
      listBody = Column(
        children: _paymentPlanStats.map((s) {
          final planLabel = _planLabelFromCode(s.planCode);
          return NeuCard(
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            padding: const EdgeInsets.all(12),
            child: ListTile(
              title: Text(planLabel),
              subtitle: Text('المدفوعات: ${s.paymentsCount}'),
              trailing: Text(
                '\$${s.totalAmount.toStringAsFixed(0)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          );
        }).toList(),
      );
    } else if (_statsMode == 2) {
      final fmt = DateFormat('yyyy-MM');
      listBody = Column(
        children: _paymentMonthlyStats.map((s) {
          final label = s.period == null ? 'غير محدد' : fmt.format(s.period!);
          return NeuCard(
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            padding: const EdgeInsets.all(12),
            child: ListTile(
              title: Text(label),
              subtitle: Text('المدفوعات: ${s.paymentsCount}'),
              trailing: Text(
                '\$${s.totalAmount.toStringAsFixed(0)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          );
        }).toList(),
      );
    } else if (_statsMode == 3) {
      final fmt = DateFormat('yyyy-MM-dd');
      listBody = Column(
        children: _paymentDailyStats.map((s) {
          final label = s.period == null ? 'غير محدد' : fmt.format(s.period!);
          return NeuCard(
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            padding: const EdgeInsets.all(12),
            child: ListTile(
              title: Text(label),
              subtitle: Text('المدفوعات: ${s.paymentsCount}'),
              trailing: Text(
                '\$${s.totalAmount.toStringAsFixed(0)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          );
        }).toList(),
      );
    } else {
      listBody = Column(
        children: _paymentStats.map((s) {
          return NeuCard(
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            padding: const EdgeInsets.all(12),
            child: ListTile(
              title: Text(s.paymentMethodName ?? 'غير محدد'),
              subtitle: Text('المدفوعات: ${s.paymentsCount}'),
              trailing: Text(
                '\$${s.totalAmount.toStringAsFixed(0)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          );
        }).toList(),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      children: [
        _buildStatsHeader(scheme),
        const SizedBox(height: 8),
        _buildRevenueCarousel(scheme),
        const SizedBox(height: 10),
        _buildSystemHealthCard(scheme),
        _buildRiskAlertsCard(scheme),
        _buildUsageMetricsCard(scheme),
        _buildAdminActionLogsPreview(scheme),
        _buildAuditDailyCard(scheme),
        _buildAuditTopActorsCard(scheme),
        _buildUsageDailyCard(scheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ToggleButtons(
              isSelected: List.generate(
                modeLabels.length,
                (i) => i == _statsMode,
              ),
              onPressed: (i) => setState(() => _statsMode = i),
              borderRadius: BorderRadius.circular(12),
              children: modeLabels
                  .map((label) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(label),
                      ))
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 6),
        listBody,
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildStatsHeader(ColorScheme scheme) {
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.analytics_rounded),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'لوحة الإحصاءات',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await _fetchPaymentStats();
              await _fetchExtraSeatRevenue();
              await _fetchSystemHealth();
              await _fetchUsageMetrics();
              await _fetchRiskAlerts();
              await _fetchAuditDaily();
              await _fetchAuditTopActors();
              await _fetchUsageDaily();
              await _fetchActionLogs(reset: true);
            },
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('تحديث الكل'),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemHealthCard(ColorScheme scheme) {
    if (_loadingSystemHealth) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    final h = _systemHealth;
    if (h == null) return const SizedBox.shrink();
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'صحة النظام',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'تحديث',
                onPressed: _fetchSystemHealth,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _statPill('ملفات التخزين', h.storageFiles.toString(), scheme),
              _statPill('مرفقات الدردشة', h.chatAttachments.toString(), scheme),
              _statPill('طلبات الاشتراك المعلّقة',
                  h.pendingSubscriptions.toString(), scheme),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'آخر تحديث: ${DateFormat('yyyy-MM-dd HH:mm').format(h.serverTime.toLocal())}',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminActionLogsPreview(ColorScheme scheme) {
    if (_loadingActionLogs) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    if (_adminActionLogs.isEmpty) return const SizedBox.shrink();
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'آخر أوامر السوبر أدمن',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: _openActionLogsSheet,
                child: const Text('عرض الكل'),
              ),
              IconButton(
                tooltip: 'تحديث',
                onPressed: () => _fetchActionLogs(reset: true),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ..._adminActionLogs.take(5).map((log) {
            final when = DateFormat('yyyy-MM-dd HH:mm')
                .format(log.createdAt.toLocal());
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '• ${log.action} • ${log.entityType} • $when',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .75),
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRiskAlertsCard(ColorScheme scheme) {
    if (_loadingRiskAlerts) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    if (_riskAlerts.isEmpty) return const SizedBox.shrink();
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'تنبيهات المخاطر',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          ..._riskAlerts.map((alert) {
            final color = _riskColor(alert.severity, scheme);
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withValues(alpha: .35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_rounded, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${alert.title} (${alert.count})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if ((alert.hint ?? '').isNotEmpty)
                          Text(
                            alert.hint!,
                            style: TextStyle(
                              color:
                                  scheme.onSurface.withValues(alpha: .7),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildUsageMetricsCard(ColorScheme scheme) {
    if (_loadingUsageMetrics) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    final m = _usageMetrics;
    if (m == null) return const SizedBox.shrink();
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'مؤشرات الاستخدام',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'تحديث',
                onPressed: _fetchUsageMetrics,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _statPill('الحسابات', m.accounts.toString(), scheme),
              _statPill('مستخدمي الحسابات', m.accountUsers.toString(), scheme),
              _statPill('رسائل 30 يوم', m.chatMessages30d.toString(), scheme),
              _statPill('مرفقات الدردشة', m.chatAttachments.toString(), scheme),
              _statPill('أحداث تدقيق 7 أيام', m.auditEvents7d.toString(), scheme),
              if (m.activeUsers30d != null)
                _statPill('نشطون 30 يوم', m.activeUsers30d.toString(), scheme),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'آخر تحديث: ${DateFormat('yyyy-MM-dd HH:mm').format(m.serverTime.toLocal())}',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditDailyCard(ColorScheme scheme) {
    if (_loadingAuditDaily) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    if (_auditDaily.isEmpty) return const SizedBox.shrink();
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ملخص التدقيق اليومي',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: _exportAuditDaily,
                icon: const Icon(Icons.download_rounded),
                label: const Text('تصدير'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ..._auditDaily.take(6).map((row) {
            final day = DateFormat('yyyy-MM-dd').format(row.day.toLocal());
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                '• $day • ${row.tableName} • ${row.op} • ${row.events}',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .75),
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildAuditTopActorsCard(ColorScheme scheme) {
    if (_loadingAuditTopActors) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    if (_auditTopActors.isEmpty) return const SizedBox.shrink();
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'أكثر الحسابات نشاطًا (تدقيق)',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: _exportAuditTopActors,
                icon: const Icon(Icons.download_rounded),
                label: const Text('تصدير'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ..._auditTopActors.take(6).map((row) {
            final label = (row.actorEmail ?? '').trim();
            final when = row.lastAt == null
                ? ''
                : DateFormat('yyyy-MM-dd').format(row.lastAt!.toLocal());
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                '• ${label.isEmpty ? 'غير معروف' : label} • ${row.events} • $when',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .75),
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildUsageDailyCard(ColorScheme scheme) {
    if (_loadingUsageDaily) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: LinearProgressIndicator(minHeight: 3),
      );
    }
    if (_usageDaily.isEmpty) return const SizedBox.shrink();
    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'حركة الاستخدام اليومية (آخر 30 يوم)',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          ..._usageDaily.take(6).map((row) {
            final day = DateFormat('yyyy-MM-dd').format(row.day.toLocal());
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                '• $day • رسائل ${row.messages} • مرفقات ${row.attachments}',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .75),
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Color _riskColor(String severity, ColorScheme scheme) {
    switch (severity) {
      case 'high':
        return Colors.redAccent;
      case 'medium':
        return Colors.orange;
      case 'low':
      default:
        return scheme.primary;
    }
  }

  void _openActionLogsSheet() {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.55,
          builder: (sheetCtx, controller) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Text(
                          'سجل أوامر السوبر أدمن',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _exportActionLogs,
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('تصدير'),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: _adminActionLogs.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _adminActionLogs.length) {
                          if (_loadingMoreActionLogs) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child:
                                  Center(child: CircularProgressIndicator()),
                            );
                          }
                          if (!_actionLogsHasMore) {
                            return const SizedBox(height: 24);
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 8, horizontal: 16),
                            child: ElevatedButton(
                              onPressed: () => _fetchActionLogs(reset: false),
                              child: const Text('تحميل المزيد'),
                            ),
                          );
                        }
                        final log = _adminActionLogs[index];
                        return _buildActionLogTile(log, Theme.of(context));
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildActionLogTile(AdminActionLog log, ThemeData theme) {
    final when =
        DateFormat('yyyy-MM-dd HH:mm').format(log.createdAt.toLocal());
    final actor = (log.actorEmail ?? '').trim();
    return ListTile(
      leading: const Icon(Icons.receipt_long_rounded),
      title: Text(
        log.action,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        [
          if (log.entityType.isNotEmpty) log.entityType,
          if (actor.isNotEmpty) actor,
          when,
        ].join(' • '),
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: .7),
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
        ),
      ),
      trailing: log.entityId == null
          ? null
          : Text(
              log.entityId!,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: .6),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
      onTap: log.details == null ? null : () => _showActionLogDetails(log),
    );
  }

  void _showActionLogDetails(AdminActionLog log) {
    final details = log.details;
    if (details == null) return;
    final pretty = const JsonEncoder.withIndent('  ').convert(details);
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('تفاصيل الأمر'),
          content: SingleChildScrollView(
            child: Text(pretty, textDirection: ui.TextDirection.ltr),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportActionLogs() async {
    try {
      final bytes =
          await ExportService.exportAdminActionLogsToExcel(_adminActionLogs);
      final ts = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await saveFileBytes(bytes, 'admin_action_logs_$ts.xlsx');
      _snack('تم تصدير السجلات بنجاح');
    } catch (e) {
      _snack('تعذّر تصدير السجلات: $e');
    }
  }

  Future<void> _exportAuditDaily() async {
    try {
      final bytes =
          await ExportService.exportAdminAuditActivityDailyToExcel(_auditDaily);
      final ts = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await saveFileBytes(bytes, 'admin_audit_daily_$ts.xlsx');
      _snack('تم تصدير ملخص التدقيق');
    } catch (e) {
      _snack('تعذّر تصدير ملخص التدقيق: $e');
    }
  }

  Future<void> _exportAuditTopActors() async {
    try {
      final bytes = await ExportService.exportAdminAuditTopActorsToExcel(
          _auditTopActors);
      final ts = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await saveFileBytes(bytes, 'admin_audit_top_actors_$ts.xlsx');
      _snack('تم تصدير أكثر الحسابات نشاطًا');
    } catch (e) {
      _snack('تعذّر تصدير أكثر الحسابات نشاطًا: $e');
    }
  }

  Widget _statPill(String label, String value, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: .2)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }

  String _planLabelFromCode(String? rawCode) {
    final code = (rawCode ?? '').toLowerCase().trim();
    switch (code) {
      case 'free':
        return 'مجانية';
      case 'month':
        return 'شهرية';
      case 'month_plus':
        return 'شهرية بلس';
      case 'month_pro':
        return 'شهرية برو';
      case 'year':
        return 'سنوية';
      case 'year_plus':
        return 'سنوية بلس';
      case 'year_pro':
        return 'سنوية برو';
      case 'extra_seat':
        return 'مقاعد إضافية';
      default:
        return rawCode?.toUpperCase() ?? 'غير محدد';
    }
  }

  Widget _buildRevenueCarousel(ColorScheme scheme) {
    final items = <_RevenueCardData>[
      _RevenueCardData(
        title: 'إجمالي دخل الاشتراكات السنوية',
        subtitle: 'الاشتراكات السنوية',
        amount: _annualSubRevenue,
        icon: Icons.auto_awesome_rounded,
        gradient: [
          const Color(0xFF0B6E99),
          const Color(0xFF2BB2A0),
        ],
      ),
      _RevenueCardData(
        title: 'إجمالي دخل الاشتراكات الشهرية',
        subtitle: 'الاشتراكات الشهرية',
        amount: _monthlySubRevenue,
        icon: Icons.calendar_month_rounded,
        gradient: [
          const Color(0xFF1C4FB6),
          const Color(0xFF6A8CFF),
        ],
      ),
      _RevenueCardData(
        title: 'إجمالي دخل المقاعد الإضافية',
        subtitle: 'رسوم المقاعد الإضافية',
        amount: _extraSeatRevenue,
        icon: Icons.group_add_rounded,
        gradient: [
          const Color(0xFF7A3E9D),
          const Color(0xFFB062C7),
        ],
      ),
    ];

    return Column(
      children: [
        SizedBox(
          height: 160,
          child: PageView.builder(
            controller: _revenueController,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final delta = (index - _revenuePage).clamp(-1.0, 1.0);
              final scale = 0.9 + (1 - delta.abs()) * 0.1;
              return AnimatedBuilder(
                animation: _revenueController,
                builder: (context, child) {
                  return Transform.scale(scale: scale, child: child);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: LinearGradient(
                        colors: item.gradient,
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: item.gradient.first.withValues(alpha: 0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(item.icon, color: Colors.white),
                              ),
                              const Spacer(),
                              Text(
                                _loadingExtraSeatRevenue
                                    ? '—'
                                    : '\$${item.amount.toStringAsFixed(0)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            item.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _loadingExtraSeatRevenue
                                ? 'جاري التحميل...'
                                : item.subtitle,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(items.length, (i) {
            final active = i == _revenuePage.round();
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: active ? 18 : 8,
              height: 6,
              decoration: BoxDecoration(
                color: active ? scheme.primary : Colors.black12,
                borderRadius: BorderRadius.circular(99),
              ),
            );
          }),
        ),
      ],
    );
  }

  // -------- Tabs --------
  Widget _buildCreateClinicTab() {
    return ListView(
      children: [
        NeuCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NeuField(
                controller: _clinicNameCtrl,
                labelText: 'اسم العيادة',
                prefix: const Icon(Icons.local_hospital_outlined),
                onChanged: (_) {},
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _ownerEmailCtrl,
                labelText: 'بريد المالك',
                keyboardType: TextInputType.emailAddress,
                prefix: const Icon(Icons.alternate_email_rounded),
                onChanged: (_) {},
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _ownerPassCtrl,
                labelText: 'كلمة مرور المالك',
                obscureText: true,
                prefix: const Icon(Icons.lock_outline_rounded),
                onChanged: (_) {},
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: NeuButton.primary(
                  label: 'إنشاء العيادة',
                  onPressed: _createClinicAccount,
                  icon: Icons.save_rounded,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCreateEmployeeTab() {
    final scheme = Theme.of(context).colorScheme;
    final planCode = (_selectedClinic?.planCode ?? 'free').toLowerCase();
    final planIsFree = planCode == 'free';

    return ListView(
      children: [
        NeuCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'اختر العيادة',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    tooltip: 'تحديث القائمة',
                    onPressed: _fetchClinics,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              // Dropdown داخل NeuCard ليتماشى بصريًا
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(kRadius),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: .9),
                      offset: const Offset(-6, -6),
                      blurRadius: 12,
                    ),
                    BoxShadow(
                      color: const Color(0xFFCFD8DC).withValues(alpha: .6),
                      offset: const Offset(6, 6),
                      blurRadius: 14,
                    ),
                  ],
                  border: Border.all(color: scheme.outlineVariant),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                child: DropdownButtonFormField<Clinic>(
                  initialValue: _selectedClinic,
                  decoration: const InputDecoration(border: InputBorder.none),
                  isExpanded: true,
                  items: _clinics
                      .map(
                        (c) => DropdownMenuItem(
                          value: c,
                          child: SizedBox(
                            width: double.infinity,
                            child: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  selectedItemBuilder: (ctx) => _clinics
                      .map(
                        (c) => Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (c) => setState(() {
                    _selectedClinic = c;
                    _createStaffPlanError = null;
                  }),
                  icon: const Icon(Icons.expand_more_rounded),
                ),
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _staffEmailCtrl,
                labelText: 'بريد الموظف',
                keyboardType: TextInputType.emailAddress,
                prefix: const Icon(Icons.alternate_email_rounded),
                enabled: !planIsFree,
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _staffPassCtrl,
                labelText: 'كلمة مرور الموظف',
                obscureText: true,
                prefix: const Icon(Icons.lock_outline_rounded),
                enabled: !planIsFree,
              ),
              if (planIsFree) ...[
                const SizedBox(height: 8),
                Text(
                  'خطة العيادة FREE: لا يمكن إضافة موظفين حتى تتم الترقية.',
                  style: TextStyle(color: scheme.error),
                ),
              ],
              if (_createStaffPlanError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _createStaffPlanError!,
                  style: TextStyle(color: scheme.error),
                ),
              ],
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: NeuButton.primary(
                  label: 'إنشاء الموظف',
                  onPressed: planIsFree ? null : _createStaffAccount,
                  icon: Icons.person_add_alt_1_rounded,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildManageClinicsTab() {
    final scheme = Theme.of(context).colorScheme;

    if (_loadingClinics) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_clinics.isEmpty) {
      return RefreshIndicator(
        color: kPrimaryColor,
        onRefresh: _fetchClinics,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 24),
            Center(
              child: NeuCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                child: const Text(
                  'لا توجد عيادات مسجّلة.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: kPrimaryColor,
      onRefresh: _fetchClinics,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _clinics.length,
        itemBuilder: (_, i) {
          final clinic = _clinics[i];
          final planCode = _planLabelFromCode(clinic.planCode);
          final planStatus = (clinic.planStatus ?? 'active').toLowerCase();
          final planEnd = clinic.planEndAt;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: NeuCard(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: ListTile(
                leading: Container(
                  decoration: BoxDecoration(
                    color: kPrimaryColor.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    clinic.isFrozen
                        ? Icons.lock_rounded
                        : Icons.local_hospital_rounded,
                    color: kPrimaryColor,
                  ),
                ),
                title: Text(
                  clinic.name,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  [
                    'الخطة: $planCode',
                    'الحالة: $planStatus',
                    if (planEnd != null) 'الانتهاء: ${planEnd.toLocal()}',
                    'مجمّدة: ${clinic.isFrozen ? "نعم" : "لا"}',
                    'الإنشاء: ${clinic.createdAt.toLocal()}',
                  ].join(' | '),
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .7),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (value) {
                    switch (value) {
                      case 'freeze':
                        _toggleFreeze(clinic);
                        break;
                      case 'delete':
                        _deleteClinic(clinic);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      value: 'freeze',
                      child: Text(
                        clinic.isFrozen ? 'إلغاء التجميد' : 'تجميد',
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Text(
                        'حذف',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RevenueCardData {
  final String title;
  final String subtitle;
  final double amount;
  final IconData icon;
  final List<Color> gradient;

  const _RevenueCardData({
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.icon,
    required this.gradient,
  });
}
