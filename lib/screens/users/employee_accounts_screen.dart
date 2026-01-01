import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/models/employee_account_record.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/screens/subscription/my_plan_screen.dart';
import 'package:aelmamclinic/screens/users/employee_seat_payment_screen.dart';
import 'package:aelmamclinic/services/employee_seat_service.dart';
import 'package:aelmamclinic/services/nhost_employee_accounts_service.dart';
import 'package:aelmamclinic/utils/time.dart';

class EmployeeAccountsScreen extends StatefulWidget {
  const EmployeeAccountsScreen({super.key});

  @override
  State<EmployeeAccountsScreen> createState() => _EmployeeAccountsScreenState();
}

class _EmployeeAccountsScreenState extends State<EmployeeAccountsScreen> {
  final _service = NhostEmployeeAccountsService();
  final _seatService = EmployeeSeatService();
  late Future<List<EmployeeAccountRecord>> _employees;
  bool _busy = false;

  static const int _baseLimit = 5;

  @override
  void initState() {
    super.initState();
    final accountId = context.read<AuthProvider>().accountId;
    _employees = _loadEmployees(accountId);
  }

  @override
  void dispose() {
    _seatService.dispose();
    super.dispose();
  }

  bool _canAccess(AuthProvider auth) {
    if (auth.isSuperAdmin) return true;
    if (!auth.isPro) return false;
    final role = auth.role?.toLowerCase();
    return role == 'owner' || role == 'admin';
  }

  Future<List<EmployeeAccountRecord>> _loadEmployees(String? accountId) async {
    if (accountId == null || accountId.isEmpty) return [];
    return _service.listEmployees(accountId: accountId);
  }

  Future<void> _refresh() async {
    final accountId = context.read<AuthProvider>().accountId;
    setState(() => _employees = _loadEmployees(accountId));
    await _employees;
  }

  Future<Map<String, String>?> _promptCredentials({
    required String title,
    required String confirmLabel,
  }) async {
    final emailCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop({
                'email': emailCtrl.text.trim(),
                'password': passCtrl.text,
              }),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    emailCtrl.dispose();
    passCtrl.dispose();
    return result;
  }

  String _mapServerError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('seat_limit_reached')) {
      return 'وصلت إلى الحد الأقصى للمقاعد المجانية.';
    }
    if (msg.contains('seat_limit_not_reached')) {
      return 'لا تزال لديك مقاعد مجانية متاحة.';
    }
    if (msg.contains('plan is free') || msg.contains('plan is')) {
      return 'هذه الميزة متاحة لخطط PRO فقط.';
    }
    if (msg.contains('cannot_add_self')) {
      return 'لا يمكنك إضافة نفسك كموظف.';
    }
    if (msg.contains('employee_already_active')) {
      return 'هذا المستخدم مرتبط بالفعل كموظف نشط.';
    }
    if (msg.contains('request_already_exists')) {
      return 'تم إنشاء طلب لهذا الموظف مسبقًا.';
    }
    if (msg.contains('missing fields')) {
      return 'يرجى إدخال البريد وكلمة المرور.';
    }
    return 'تعذّر تنفيذ العملية: $error';
  }

  Future<void> _addEmployeeWithinLimit() async {
    final creds = await _promptCredentials(
      title: 'إضافة موظف جديد',
      confirmLabel: 'إنشاء الحساب',
    );
    if (creds == null) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _seatService.createEmployeeWithinLimit(
        email: creds['email'] ?? '',
        password: creds['password'] ?? '',
      );
      if (res['ok'] == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إنشاء حساب الموظف بنجاح.')),
        );
        await _refresh();
        return;
      }
      throw Exception(res['error'] ?? 'failed');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_mapServerError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestExtraEmployee() async {
    final creds = await _promptCredentials(
      title: 'طلب إضافة حساب موظف',
      confirmLabel: 'إنشاء الحساب',
    );
    if (creds == null) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _seatService.requestExtraEmployee(
        email: creds['email'] ?? '',
        password: creds['password'] ?? '',
      );
      if (res['ok'] == true) {
        final uid = res['user_uid']?.toString() ?? '';
        if (uid.isEmpty) {
          throw Exception('missing_user_uid');
        }
        final request =
            await _seatService.fetchLatestSeatRequest(employeeUserUid: uid);
        if (request == null) {
          throw Exception('request_not_found');
        }
        final requestId = request['id']?.toString() ?? '';
        if (requestId.isEmpty) {
          throw Exception('request_not_found');
        }
        if (!mounted) return;
        final proceed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => EmployeeSeatPaymentScreen(
              requestId: requestId,
              employeeEmail: creds['email'] ?? '',
            ),
          ),
        );
        if (proceed == true) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم إرسال الطلب للمراجعة.')),
          );
        }
        await _refresh();
        return;
      }
      throw Exception(res['error'] ?? 'failed');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_mapServerError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _roleLabel(String role) {
    switch (role.toLowerCase()) {
      case 'owner':
        return 'مالك';
      case 'admin':
        return 'مشرف';
      case 'superadmin':
        return 'سوبر أدمن';
      default:
        return 'موظف';
    }
  }

  String _statusLabel(bool disabled) => disabled ? 'مجمد' : 'نشط';

  Color _statusColor(ColorScheme scheme, bool disabled) =>
      disabled ? scheme.error : scheme.primary;

  String _fmtDate(DateTime? dt) {
    if (dt == null) return '—';
    return formatYmd(dt.toLocal());
  }

  Widget _buildLockedView(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: NeuCard(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_rounded, color: scheme.tertiary, size: 36),
              const SizedBox(height: 10),
              const Text(
                'ميزة حسابات الموظفين متاحة لباقات PRO فقط',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'قم بالترقية لإدارة حسابات موظفي العيادة.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurface.withValues(alpha: .7)),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MyPlanScreen()),
                  );
                },
                icon: const Icon(Icons.workspace_premium_rounded),
                label: const Text('الترقية إلى PRO'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoAccess(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: NeuCard(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.block_rounded, color: scheme.error, size: 34),
              const SizedBox(height: 10),
              const Text(
                'ليست لديك صلاحية لإدارة حسابات الموظفين',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'هذه الشاشة مخصصة لمالك العيادة.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurface.withValues(alpha: .7)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(
    ColorScheme scheme, {
    required int activeEmployees,
    required int totalEmployees,
  }) {
    final remaining = (_baseLimit - activeEmployees).clamp(0, _baseLimit);
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ملخص المقاعد',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _infoChip(scheme, 'الحد الأساسي', '$_baseLimit'),
              const SizedBox(width: 8),
              _infoChip(scheme, 'المستخدمون الحاليون', '$activeEmployees'),
              const SizedBox(width: 8),
              _infoChip(scheme, 'المتبقي', '$remaining'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'إجمالي الحسابات المرتبطة: $totalEmployees',
            style: TextStyle(color: scheme.onSurface.withValues(alpha: .7)),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(ColorScheme scheme, String label, String value) {
    return Expanded(
      child: NeuCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    color: scheme.primary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .7),
                  fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final canAccess = _canAccess(auth);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('حسابات الموظفين'),
          actions: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
        body: Builder(
          builder: (_) {
            if (!auth.isPro && !auth.isSuperAdmin) {
              return _buildLockedView(scheme);
            }
            if (!canAccess) {
              return _buildNoAccess(scheme);
            }
            return RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<EmployeeAccountRecord>>(
                future: _employees,
                builder: (context, snapshot) {
                  final physics = const AlwaysScrollableScrollPhysics();
                  if (snapshot.connectionState != ConnectionState.done) {
                    return ListView(
                      physics: physics,
                      children: const [
                        SizedBox(height: 48),
                        Center(child: CircularProgressIndicator()),
                      ],
                    );
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      physics: physics,
                      children: [
                        const SizedBox(height: 48),
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'تعذّر تحميل الحسابات:\n${snapshot.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        ),
                      ],
                    );
                  }

                  final employees = snapshot.data ?? const [];
                  final activeEmployees = employees
                      .where((e) =>
                          e.role.toLowerCase() == 'employee' && !e.disabled)
                      .length;

                  return ListView(
                    physics: physics,
                    padding: const EdgeInsets.all(12),
                    children: [
                      _buildSummaryCard(
                        scheme,
                        activeEmployees: activeEmployees,
                        totalEmployees: employees.length,
                      ),
                      const SizedBox(height: 12),
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'إدارة الموظفين',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 14),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              activeEmployees < _baseLimit
                                  ? 'يمكنك إضافة موظف جديد ضمن الحد المجاني.'
                                  : 'وصلت للحد الأقصى للمقاعد المجانية.',
                              style: TextStyle(
                                  color: scheme.onSurface.withValues(alpha: .7)),
                            ),
                            if (activeEmployees >= _baseLimit) ...[
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: scheme.error.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.warning_rounded,
                                        color: scheme.error),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'لديك $activeEmployees موظفين. الحد الأقصى $_baseLimit.',
                                        style: TextStyle(
                                            color: scheme.error,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _busy
                                  ? null
                                  : (activeEmployees < _baseLimit
                                      ? _addEmployeeWithinLimit
                                      : _requestExtraEmployee),
                              icon: const Icon(Icons.person_add_alt_1_rounded),
                              label: Text(activeEmployees < _baseLimit
                                  ? 'إضافة موظف'
                                  : 'طلب إضافة حساب موظف'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (employees.isEmpty)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('لا يوجد موظفون مرتبطون بالحساب.'),
                          ),
                        )
                      else
                        ...employees.map((emp) {
                          final statusColor =
                              _statusColor(scheme, emp.disabled);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: NeuCard(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  backgroundColor:
                                      statusColor.withValues(alpha: 0.15),
                                  child: Icon(
                                    emp.disabled
                                        ? Icons.lock_rounded
                                        : Icons.verified_user_rounded,
                                    color: statusColor,
                                  ),
                                ),
                                title: Text(
                                  emp.email.isEmpty ? emp.userUid : emp.email,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                                subtitle: Text(
                                  'الدور: ${_roleLabel(emp.role)} • ${_fmtDate(emp.createdAt)}',
                                  style: TextStyle(
                                      color: scheme.onSurface
                                          .withValues(alpha: .7)),
                                ),
                                trailing: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _statusLabel(emp.disabled),
                                    style: TextStyle(
                                      color: statusColor,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
