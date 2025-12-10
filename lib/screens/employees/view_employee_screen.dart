// lib/screens/employees/view_employee_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:url_launcher/url_launcher.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'edit_employee_screen.dart';

class ViewEmployeeScreen extends StatefulWidget {
  final int empId;

  const ViewEmployeeScreen({super.key, required this.empId});

  @override
  State<ViewEmployeeScreen> createState() => _ViewEmployeeScreenState();
}

class _ViewEmployeeScreenState extends State<ViewEmployeeScreen> {
  Map<String, dynamic>? _employee;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadEmployee();
  }

  Future<void> _loadEmployee() async {
    setState(() => _loading = true);
    final data = await DBService.instance.getEmployeeById(widget.empId);
    if (!mounted) return;
    setState(() {
      _employee = data;
      _loading = false;
    });
  }

  String _asString(dynamic v) => (v ?? '').toString();
  String _dashIfEmpty(String s) => s.trim().isEmpty ? '—' : s;

  String _fmtDoctor(dynamic value) {
    final status = (value is int ? value : int.tryParse('$value') ?? 0);
    return status == 1 ? 'طبيب' : 'غير طبيب';
  }

  String _fmtMoney(dynamic v) {
    if (v is num) return v.toStringAsFixed(2);
    final d = double.tryParse('$v') ?? 0.0;
    return d.toStringAsFixed(2);
  }

  Future<void> _call(String phone) async {
    final p = phone.trim();
    if (p.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد رقم هاتف')),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: p);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يمكن إجراء المكالمة')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.badge_rounded),
              SizedBox(width: 8),
              Text('بيانات الموظف'),
            ],
          ),
        ),
        floatingActionButton: _employee == null
            ? null
            : FloatingActionButton.extended(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EditEmployeeScreen(empId: widget.empId),
                    ),
                  );
                  await _loadEmployee();
                },
                icon: const Icon(Icons.edit_rounded),
                label: const Text('تعديل'),
              ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_employee == null)
                    ? Center(
                        child: Text(
                          'لم يتم العثور على الموظف',
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: .6),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          // بطاقة عنوانية
                          NeuCard(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: kPrimaryColor.withValues(alpha: .10),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  padding: const EdgeInsets.all(14),
                                  child: const Icon(
                                    Icons.person_outline_rounded,
                                    color: kPrimaryColor,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _dashIfEmpty(
                                            _asString(_employee!['name'])),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _dashIfEmpty(
                                            _asString(_employee!['jobTitle'])),
                                        style: TextStyle(
                                          color: cs.onSurface
                                              .withValues(alpha: .7),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // التفاصيل
                          Expanded(
                            child: ListView(
                              children: [
                                _InfoRow(
                                  icon: Icons.credit_card_rounded,
                                  label: 'رقم الهوية',
                                  value: _dashIfEmpty(
                                      _asString(_employee!['identityNumber'])),
                                ),
                                const SizedBox(height: 8),
                                _InfoRow(
                                  icon: Icons.phone_rounded,
                                  label: 'رقم الهاتف',
                                  value: _dashIfEmpty(
                                      _asString(_employee!['phoneNumber'])),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: 'نسخ',
                                        icon: const Icon(Icons.copy_rounded),
                                        onPressed: () {
                                          final phone = _asString(
                                              _employee!['phoneNumber']);
                                          if (phone.trim().isEmpty) return;
                                          Clipboard.setData(
                                              ClipboardData(text: phone));
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                                content:
                                                    Text('تم نسخ رقم الهاتف')),
                                          );
                                        },
                                      ),
                                      IconButton(
                                        tooltip: 'اتصال',
                                        icon: const Icon(Icons.call_rounded),
                                        onPressed: () => _call(_asString(
                                            _employee!['phoneNumber'])),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _InfoRow(
                                  icon: Icons.home_work_outlined,
                                  label: 'السكن',
                                  value: _dashIfEmpty(
                                      _asString(_employee!['address'])),
                                ),
                                const SizedBox(height: 8),
                                _InfoRow(
                                  icon: Icons.family_restroom_rounded,
                                  label: 'الحالة الاجتماعية',
                                  value: _dashIfEmpty(
                                      _asString(_employee!['maritalStatus'])),
                                ),
                                const SizedBox(height: 8),
                                _InfoRow(
                                  icon: Icons.payments_outlined,
                                  label: 'الراتب الأساسي',
                                  value: _fmtMoney(_employee!['basicSalary']),
                                ),
                                const SizedBox(height: 8),
                                _InfoRow(
                                  icon: Icons.account_balance_wallet_outlined,
                                  label: 'الراتب النهائي مع البدل',
                                  value: _fmtMoney(_employee!['finalSalary']),
                                ),
                                const SizedBox(height: 8),
                                _InfoRow(
                                  icon: Icons.local_hospital_outlined,
                                  label: 'حالة الموظف',
                                  value: _fmtDoctor(_employee!['isDoctor']),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: kPrimaryColor),
        ),
        title: Text(
          label,
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: .7),
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        trailing: trailing,
      ),
    );
  }
}
