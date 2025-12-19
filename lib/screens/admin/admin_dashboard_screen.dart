// lib/screens/admin/admin_dashboard_screen.dart
import 'package:flutter/material.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/services/nhost_admin_service.dart';
import 'package:aelmamclinic/models/clinic.dart';
import 'package:aelmamclinic/models/provisioning_result.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:provider/provider.dart';

/*──────── شاشات للتنقّل ────────*/
import 'package:aelmamclinic/screens/statistics/statistics_overview_screen.dart';
import 'package:aelmamclinic/screens/auth/login_screen.dart';
import 'package:aelmamclinic/screens/chat/chat_admin_inbox_screen.dart'; // ⬅️ شاشة دردشة السوبر أدمن

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
  final NhostAdminService _adminService = NhostAdminService();

  // عيادات
  List<Clinic> _clinics = [];
  bool _loadingClinics = true;

  // تبويبات
  late final TabController _tabController;

  // -------- إنشاء حساب عيادة رئيسية --------
  final TextEditingController _clinicNameCtrl = TextEditingController();
  final TextEditingController _ownerEmailCtrl = TextEditingController();
  final TextEditingController _ownerPassCtrl = TextEditingController();

  // -------- إنشاء حساب موظف --------
  Clinic? _selectedClinic;
  final TextEditingController _staffEmailCtrl = TextEditingController();
  final TextEditingController _staffPassCtrl = TextEditingController();

  // حالة انشغال عامة لمنع النقرات المكررة
  bool _busy = false;

  // ---------- Lifecycle ----------
  @override
  void initState() {
    super.initState();

    // حارس وصول: إن لم يكن المستخدم سوبر أدمن، لا يسمح بالبقاء هنا
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      final isSuper = _adminService.isSuperAdmin || auth.isSuperAdmin;
      if (!isSuper) {
        if (!mounted) return;
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
    final data = await _adminService.fetchClinics();
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
      final result = await _adminService.createClinicAccount(
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
      final result = await _adminService.createEmployeeAccount(
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
      await _adminService.freezeClinic(clinic.id, !clinic.isFrozen);
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
      await _adminService.deleteClinic(clinic.id);
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

  /// فتح شاشة دردشة السوبر أدمن
  void _openSuperAdminChat() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ChatAdminInboxScreen()),
    );
  }

  /// تسجيل الخروج وإرجاع المستخدم إلى شاشة تسجيل الدخول
  Future<void> _logout() async {
    try {
      await _adminService.signOut();
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
                onPressed: _loadingClinics ? null : _fetchClinics,
                icon: const Icon(Icons.refresh),
              ),
              TextButton.icon(
                onPressed: _openSuperAdminChat,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('الدردشة'),
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
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(52),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TabBar(
                  controller: _tabController,
                  labelColor: scheme.onSurface,
                  unselectedLabelColor: scheme.onSurface.withValues(alpha: .6),
                  indicatorColor: kPrimaryColor,
                  indicatorWeight: 3,
                  tabs: const [
                    Tab(icon: Icon(Icons.add_business), text: 'عيادة جديدة'),
                    Tab(icon: Icon(Icons.person_add_alt_1), text: 'موظف جديد'),
                    Tab(
                        icon: Icon(Icons.manage_accounts),
                        text: 'إدارة العيادات'),
                  ],
                ),
              ),
            ),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: AbsorbPointer(
                absorbing: _busy, // تعطيل كل الواجهات أثناء العمليات الحرجة
                child: Opacity(
                  opacity: _busy ? 0.7 : 1,
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildCreateClinicTab(),
                      _buildCreateEmployeeTab(),
                      _buildManageClinicsTab(),
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
                  const Text('اختر العيادة',
                      style: TextStyle(fontWeight: FontWeight.w700)),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: DropdownButtonFormField<Clinic>(
                  value: _selectedClinic,
                  decoration: const InputDecoration(border: InputBorder.none),
                  items: _clinics
                      .map((c) =>
                          DropdownMenuItem(value: c, child: Text(c.name)))
                      .toList(),
                  onChanged: (c) => setState(() => _selectedClinic = c),
                  icon: const Icon(Icons.expand_more_rounded),
                ),
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _staffEmailCtrl,
                labelText: 'بريد الموظف',
                keyboardType: TextInputType.emailAddress,
                prefix: const Icon(Icons.alternate_email_rounded),
              ),
              const SizedBox(height: 12),
              NeuField(
                controller: _staffPassCtrl,
                labelText: 'كلمة مرور الموظف',
                obscureText: true,
                prefix: const Icon(Icons.lock_outline_rounded),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: NeuButton.primary(
                  label: 'إنشاء الموظف',
                  onPressed: _createStaffAccount,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: const Text('لا توجد عيادات مسجّلة.',
                    textAlign: TextAlign.center),
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
                  'مجمّدة: ${clinic.isFrozen ? "نعم" : "لا"} | الإنشاء: ${clinic.createdAt.toLocal()}',
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
                      child: Text(clinic.isFrozen ? 'إلغاء التجميد' : 'تجميد'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('حذف', style: TextStyle(color: Colors.red)),
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
