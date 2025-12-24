// lib/screens/admin/admin_dashboard_screen.dart
import 'package:flutter/material.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/models/clinic.dart';
import 'package:aelmamclinic/models/complaint.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/payment_plan_stat.dart';
import 'package:aelmamclinic/models/payment_stat.dart';
import 'package:aelmamclinic/models/payment_time_stat.dart';
import 'package:aelmamclinic/models/provisioning_result.dart';
import 'package:aelmamclinic/models/subscription_request.dart';
import 'package:aelmamclinic/services/admin_billing_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';
import 'package:aelmamclinic/services/nhost_admin_service.dart';
import 'package:provider/provider.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/*──────── شاشات للتنقّل ────────*/
import 'package:aelmamclinic/screens/statistics/statistics_overview_screen.dart';
import 'package:aelmamclinic/screens/auth/login_screen.dart';
import 'package:aelmamclinic/screens/chat/chat_admin_inbox_screen.dart'; // ⬅️ شاشة دردشة السوبر أدمن
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
    with SingleTickerProviderStateMixin {
  // ---------- Services & Controllers ----------
  final NhostAdminService _authService = NhostAdminService();
  final AdminBillingService _billingService = AdminBillingService();
  final NhostStorageService _storageService = NhostStorageService();

  // عيادات
  List<Clinic> _clinics = [];
  bool _loadingClinics = true;

  // تبويبات
  late final TabController _tabController;
  int _sectionIndex = 0;

  // اشتراكات ودفع وشكاوى
  List<SubscriptionRequest> _subscriptionRequests = [];
  bool _loadingRequests = false;

  List<PaymentMethod> _paymentMethods = [];
  bool _loadingPaymentMethods = false;

  List<Complaint> _complaints = [];
  bool _loadingComplaints = false;

  List<PaymentStat> _paymentStats = [];
  bool _loadingStats = false;
  List<PaymentPlanStat> _paymentPlanStats = [];
  List<PaymentTimeStat> _paymentMonthlyStats = [];
  List<PaymentTimeStat> _paymentDailyStats = [];

  int _statsMode = 0; // 0=methods, 1=plans, 2=monthly, 3=daily

  // -------- إنشاء حساب عيادة رئيسية --------
  final TextEditingController _clinicNameCtrl = TextEditingController();
  final TextEditingController _ownerEmailCtrl = TextEditingController();
  final TextEditingController _ownerPassCtrl = TextEditingController();

  // -------- إنشاء حساب موظف --------
  Clinic? _selectedClinic;
  final TextEditingController _staffEmailCtrl = TextEditingController();
  final TextEditingController _staffPassCtrl = TextEditingController();
  String? _createStaffPlanError;

  // حالة انشغال عامة لمنع النقرات المكررة
  bool _busy = false;

  // ---------- Lifecycle ----------
  @override
  void initState() {
    super.initState();

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
    });

    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      // حدّث القائمة كلما فتحنا تبويب "موظف جديد" أو "إدارة العيادات"
      if (_tabController.index == 1 || _tabController.index == 2) {
        _fetchClinics();
      }
    });
    _fetchClinics();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _clinicNameCtrl.dispose();
    _ownerEmailCtrl.dispose();
    _ownerPassCtrl.dispose();
    _staffEmailCtrl.dispose();
    _staffPassCtrl.dispose();
    _storageService.dispose();
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

  Future<void> _openProof(SubscriptionRequest req) async {
    final proofId = req.proofUrl ?? '';
    if (proofId.isEmpty) {
      _snack('لا يوجد إثبات دفع لهذا الطلب.');
      return;
    }
    final signed = await _storageService.createSignedUrl(proofId);
    final url = signed ?? _storageService.publicFileUrl(proofId);
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _snack('رابط الإثبات غير صالح.');
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _showProvisioningOutcome({
    required String successMessage,
    required ProvisioningResult result,
  }) {
    final lines = <String>[successMessage];
    final details = <String>[];
    final accountId = result.accountId;
    final userUid = result.userUid;
    final role = result.role;
    if (accountId != null && accountId.isNotEmpty) {
      details.add('الحساب: $accountId');
    }
    if (userUid != null && userUid.isNotEmpty) {
      details.add('المستخدم: $userUid');
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
      final rows = await _billingService.fetchSubscriptionRequests();
      if (!mounted) return;
      setState(() {
        _subscriptionRequests = rows;
        _loadingRequests = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRequests = false);
      _snack('تعذّر تحميل طلبات الاشتراك: $e');
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
      final rows = await _billingService.fetchComplaints();
      if (!mounted) return;
      setState(() {
        _complaints = rows;
        _loadingComplaints = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingComplaints = false);
      _snack('تعذّر تحميل الشكاوى: $e');
    }
  }

  Future<void> _fetchPaymentStats() async {
    try {
      setState(() => _loadingStats = true);
      final rows = await _billingService.fetchPaymentStats();
      final byPlan = await _billingService.fetchPaymentStatsByPlan();
      final byMonth = await _billingService.fetchPaymentStatsByMonth();
      final byDay = await _billingService.fetchPaymentStatsByDay();
      if (!mounted) return;
      setState(() {
        _paymentStats = rows;
        _paymentPlanStats = byPlan;
        _paymentMonthlyStats = byMonth;
        _paymentDailyStats = byDay;
        _loadingStats = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingStats = false);
      _snack('تعذّر تحميل الإحصاءات: $e');
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
    if (pass.length < 6) {
      _snack('الحد الأدنى لكلمة المرور هو 6 أحرف');
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
    if ((_selectedClinic?.planCode ?? 'free').toLowerCase() == 'free') {
      setState(
        () => _createStaffPlanError =
            'لا يمكن إضافة موظفين لخطة FREE. قم بترقية الخطة أولاً.',
      );
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
    if (pass.length < 6) {
      _snack('الحد الأدنى لكلمة المرور هو 6 أحرف');
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
      );
      _staffEmailCtrl.clear();
      _staffPassCtrl.clear();
      if (mounted) {
        setState(() => _createStaffPlanError = null);
      }
    } catch (e) {
      _snack('خطأ في الإنشاء: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

    return Stack(
      children: [
        Scaffold(
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
                const Text('لوحة تحكّم المشرف العام'),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'تحديث',
                onPressed: _refreshCurrentSection,
                icon: const Icon(Icons.refresh),
              ),
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
                  child: Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _sectionIndex,
                        onDestinationSelected: (index) async {
                          setState(() => _sectionIndex = index);
                          await _refreshCurrentSection();
                        },
                        labelType: NavigationRailLabelType.all,
                        destinations: const [
                          NavigationRailDestination(
                            icon: Icon(Icons.local_hospital_outlined),
                            label: Text('العيادات'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.chat_bubble_outline),
                            label: Text('الدردشات'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.workspace_premium_rounded),
                            label: Text('الاشتراكات'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.account_balance_rounded),
                            label: Text('طرق الدفع'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.report_problem_rounded),
                            label: Text('الشكاوى'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.analytics_rounded),
                            label: Text('الإحصاءات'),
                          ),
                        ],
                      ),
                      const VerticalDivider(width: 18),
                      Expanded(child: _buildSectionBody(scheme)),
                    ],
                  ),
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
    switch (_sectionIndex) {
      case 0:
        await _fetchClinics();
        break;
      case 1:
        // chat screen handles its own loading
        break;
      case 2:
        await _fetchSubscriptionRequests();
        break;
      case 3:
        await _fetchPaymentMethods();
        break;
      case 4:
        await _fetchComplaints();
        break;
      case 5:
        await _fetchPaymentStats();
        break;
    }
  }

  Widget _buildSectionBody(ColorScheme scheme) {
    switch (_sectionIndex) {
      case 0:
        return _buildClinicsSection(scheme);
      case 1:
        return const ChatAdminInboxScreen();
      case 2:
        return _buildSubscriptionRequestsSection();
      case 3:
        return _buildPaymentMethodsSection(scheme);
      case 4:
        return _buildComplaintsSection(scheme);
      case 5:
        return _buildPaymentStatsSection(scheme);
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
    if (_loadingRequests) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_subscriptionRequests.isEmpty) {
      return const Center(child: Text('لا توجد طلبات اشتراك حاليًا'));
    }
    return ListView(
      children: _subscriptionRequests.map((req) {
        final ref = (req.referenceText ?? '').trim();
        final sender = (req.senderName ?? '').trim();
        return NeuCard(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          padding: const EdgeInsets.all(12),
          child: ListTile(
            title: Text(
              'خطة: ${req.planCode} • ${req.amount.toStringAsFixed(0)}\$',
            ),
            subtitle: Text(
              [
                'الحساب: ${req.accountId}',
                'الحالة: ${req.status}',
                if (ref.isNotEmpty) 'المرجع: $ref',
                if (sender.isNotEmpty) 'الاسم المحوّل: $sender',
              ].join('\n'),
            ),
            trailing: req.status == 'pending'
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'عرض الإثبات',
                        icon: const Icon(Icons.receipt_long_rounded),
                        onPressed: () => _openProof(req),
                      ),
                      const SizedBox(width: 6),
                      NeuButton.primary(
                        label: 'اعتماد',
                        onPressed: () async {
                          final note =
                              await _askDecisionNote('ملاحظة الاعتماد');
                          await _billingService.approveRequest(
                            req.id,
                            note: note,
                          );
                          await _fetchSubscriptionRequests();
                          await _fetchPaymentStats();
                        },
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'رفض',
                        icon: const Icon(Icons.cancel_outlined),
                        onPressed: () async {
                          final note = await _askDecisionNote('سبب الرفض');
                          await _billingService.rejectRequest(
                            req.id,
                            note: note,
                          );
                          await _fetchSubscriptionRequests();
                        },
                      ),
                    ],
                  )
                : IconButton(
                    tooltip: 'عرض الإثبات',
                    icon: const Icon(Icons.receipt_long_rounded),
                    onPressed: () => _openProof(req),
                  ),
          ),
        );
      }).toList(),
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
                decoration: const InputDecoration(labelText: 'رقم الحساب البنكي'),
              ),
              TextField(
                controller: logoCtrl,
                decoration: const InputDecoration(labelText: 'رابط شعار الشركة'),
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
    return ListView(
      children: _complaints.map((c) {
        return NeuCard(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          padding: const EdgeInsets.all(12),
          child: ListTile(
            title: Text(c.subject ?? 'شكوى'),
            subtitle: Text('${c.message}\nالحالة: ${c.status}'),
            trailing: PopupMenuButton<String>(
              onSelected: (v) async {
                await _billingService.updateComplaintStatus(id: c.id, status: v);
                await _fetchComplaints();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'open', child: Text('مفتوحة')),
                PopupMenuItem(value: 'in_progress', child: Text('قيد المعالجة')),
                PopupMenuItem(value: 'closed', child: Text('مغلقة')),
              ],
            ),
          ),
        );
      }).toList(),
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
    if (!hasAny) {
      return const Center(child: Text('لا توجد بيانات مالية بعد'));
    }

    final modeLabels = ['وسائل الدفع', 'حسب الباقة', 'شهري', 'يومي'];
    Widget listBody;

    if (_statsMode == 1) {
      listBody = ListView(
        children: _paymentPlanStats.map((s) {
          return NeuCard(
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            padding: const EdgeInsets.all(12),
            child: ListTile(
              title: Text(s.planCode?.toUpperCase() ?? 'غير محدد'),
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
      listBody = ListView(
        children: _paymentMonthlyStats.map((s) {
          final label =
              s.period == null ? 'غير محدد' : fmt.format(s.period!);
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
      listBody = ListView(
        children: _paymentDailyStats.map((s) {
          final label =
              s.period == null ? 'غير محدد' : fmt.format(s.period!);
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
      listBody = ListView(
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
        const SizedBox(height: 6),
        Expanded(child: listBody),
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
                  items: _clinics
                      .map(
                        (c) => DropdownMenuItem(
                          value: c,
                          child: Text(c.name),
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
          final planCode = (clinic.planCode ?? 'free').toUpperCase();
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
