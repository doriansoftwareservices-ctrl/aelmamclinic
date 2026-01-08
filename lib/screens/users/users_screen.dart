// lib/screens/users/users_screen.dart
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/nhost_admin_service.dart';
import 'package:aelmamclinic/models/account_user_summary.dart';

/// شاشة إدارة حسابات الموظفين.
/// مسار القراءة الموصى به:
/// 1) RPC: list_employees_with_email  (SECURITY DEFINER)
/// 2) Fallback: Edge Function admin__list_employees
/// 3) Fallback أخير: profiles لنفس الحساب (بلا إيميل/تعطيل)
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final _adminService = NhostAdminService();
  late Future<List<Map<String, dynamic>>> _employees;
  bool _busy = false;

  bool _canAccess(AuthProvider auth) => auth.isSuperAdmin;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (_canAccess(auth)) {
      _employees = _loadEmployees(accountId);
    } else {
      _employees = Future.value(const []);
    }
  }

  Future<List<Map<String, dynamic>>> _loadEmployees(String? accountId) async {
    if (accountId == null || accountId.isEmpty) {
      dev.log('UsersScreen: no accountId found; returning empty list.');
      return [];
    }

    try {
      final summaries =
          await _adminService.listAccountUsersWithEmail(accountId: accountId);
      return summaries
          .map((AccountUserSummary s) => {
                'uid': s.userUid,
                'email': s.email,
                'disabled': s.disabled,
              })
          .toList();
    } catch (e, st) {
      dev.log('listAccountUsersWithEmail failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<void> _refresh() async {
    final auth = context.read<AuthProvider>();
    if (!_canAccess(auth)) return;
    final accountId = auth.accountId;
    setState(() => _employees = _loadEmployees(accountId));
    await _employees;
  }

  Future<void> _disableEmployee(String uid, bool disabled) async {
    final auth = context.read<AuthProvider>();
    if (!_canAccess(auth)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذه العملية مخصّصة للسوبر أدمن فقط.')),
      );
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final accountId = auth.accountId!;
      await _adminService.setEmployeeDisabled(
        accountId: accountId,
        userUid: uid,
        disabled: disabled,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(disabled ? 'تم تجميد الحساب' : 'تم تفعيل الحساب')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تغيير الحالة: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteEmployee(String uid) async {
    final auth = context.read<AuthProvider>();
    if (!_canAccess(auth)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذه العملية مخصّصة للسوبر أدمن فقط.')),
      );
      return;
    }
    if (_busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('تأكيد حذف الحساب'),
        content: const Text('سيتم حذف حساب الموظف بشكل نهائي. هل أنت متأكد؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      final accountId = auth.accountId!;
      await _adminService.deleteEmployee(accountId: accountId, userUid: uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف الحساب')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر الحذف: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy;
    final auth = context.watch<AuthProvider>();
    final accountId = auth.accountId;
    final canAccess = _canAccess(auth);

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Text('إدارة حسابات الموظفين'),
            actions: [
              if (busy)
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
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _employees,
              builder: (context, snapshot) {
                final physics = const AlwaysScrollableScrollPhysics();

                if (!canAccess) {
                  return ListView(
                    physics: physics,
                    children: const [
                      SizedBox(height: 48),
                      Center(
                        child: Text(
                          'هذه الشاشة مخصّصة للسوبر أدمن فقط.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  );
                }

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
                            'تعذّر تحميل الموظفين:\n${snapshot.error}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ),
                    ],
                  );
                }

                if (accountId == null || accountId.isEmpty) {
                  return ListView(
                    physics: physics,
                    children: const [
                      SizedBox(height: 48),
                      Center(child: Text('لا يوجد حساب محدّد لعرض الموظفين.')),
                    ],
                  );
                }

                final employees = snapshot.data ?? const [];
                if (employees.isEmpty) {
                  return ListView(
                    physics: physics,
                    children: const [
                      SizedBox(height: 48),
                      Center(
                          child: Text('لا يوجد موظفون مسجّلون لهذه العيادة.')),
                    ],
                  );
                }

                return ListView.separated(
                  physics: physics,
                  itemCount: employees.length,
                  separatorBuilder: (_, __) => const Divider(height: 0),
                  itemBuilder: (_, i) {
                    final emp = employees[i];
                    final uid = (emp['uid'] as String?) ?? '';
                    final email = (emp['email'] as String?)?.trim();
                    final disabled = emp['disabled'] == true;

                    return ListTile(
                      key: ValueKey(uid),
                      leading: Icon(
                        disabled
                            ? Icons.pause_circle_filled_rounded
                            : Icons.verified_user_rounded,
                        color: disabled ? Colors.orange : Colors.green,
                      ),
                      title: Text(
                          email?.isNotEmpty == true ? email! : 'بدون بريد'),
                      subtitle: Text(disabled ? 'مجمّد' : 'نشط'),
                      trailing: PopupMenuButton(
                        enabled: !busy,
                        onSelected: (value) async {
                          switch (value) {
                            case 'toggle':
                              await _disableEmployee(uid, !disabled);
                              break;
                            case 'delete':
                              await _deleteEmployee(uid);
                              break;
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text('تجميد/إلغاء التجميد'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('حذف الحساب'),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),

        // طبقة انشغال خفيفة أعلى الواجهة أثناء العمليات الحرجة
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
}
