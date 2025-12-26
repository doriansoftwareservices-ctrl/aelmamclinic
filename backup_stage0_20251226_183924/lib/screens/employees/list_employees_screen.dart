// lib/screens/employees/list_employees_screen.dart
import 'dart:io';
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/export_service.dart';
import 'package:aelmamclinic/screens/employees/view_employee_screen.dart';
import 'package:aelmamclinic/screens/employees/edit_employee_screen.dart';
import 'package:aelmamclinic/screens/employees/new_employee_screen.dart';

class ListEmployeesScreen extends StatefulWidget {
  const ListEmployeesScreen({super.key});

  @override
  State<ListEmployeesScreen> createState() => _ListEmployeesScreenState();
}

class _ListEmployeesScreenState extends State<ListEmployeesScreen> {
  List<Map<String, dynamic>> _allEmployees = [];
  List<Map<String, dynamic>> _filteredEmployees = [];
  final _searchController = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _searchController.addListener(_filterEmployees);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterEmployees);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEmployees() async {
    setState(() => _loading = true);
    try {
      final data = await DBService.instance.getAllEmployees();
      if (!mounted) return;
      setState(() {
        _allEmployees = data;
        _filteredEmployees = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تحميل الموظفين: $e')),
      );
    }
  }

  void _filterEmployees() {
    final q = _searchController.text.trim().toLowerCase();
    setState(() {
      _filteredEmployees = _allEmployees.where((emp) {
        final name = (emp['name'] ?? '').toString().toLowerCase();
        final identity = (emp['identityNumber'] ?? '').toString().toLowerCase();
        final phone = (emp['phoneNumber'] ?? '').toString().toLowerCase();
        final jobTitle = (emp['jobTitle'] ?? '').toString().toLowerCase();
        return name.contains(q) ||
            identity.contains(q) ||
            phone.contains(q) ||
            jobTitle.contains(q);
      }).toList();
    });
  }

  Future<void> _makePhoneCall(String phoneNumber) async {
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يمكن إجراء المكالمة')),
      );
    }
  }

  Future<void> _shareEmployeesExcel() async {
    if (_filteredEmployees.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للمشاركة')),
      );
      return;
    }
    try {
      final bytes =
          await ExportService.exportEmployeesToExcel(_filteredEmployees);
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/قائمة-الموظفين.xlsx';
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'قائمة الموظفين المحفوظة',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ أثناء المشاركة: $e')),
      );
    }
  }

  Future<void> _downloadEmployeesExcel() async {
    if (_filteredEmployees.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للتنزيل')),
      );
      return;
    }
    try {
      final bytes =
          await ExportService.exportEmployeesToExcel(_filteredEmployees);
      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/قائمة-الموظفين.xlsx';
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم التنزيل إلى: $filePath')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ أثناء التنزيل: $e')),
      );
    }
  }

  Future<void> _deleteEmployee(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('سيتم حذف الموظف نهائيًا، هل أنت متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_rounded),
            label: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await DBService.instance.deleteEmployee(id);
      await _loadEmployees();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر الحذف: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
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
          actions: [
            IconButton(
              tooltip: 'مشاركة Excel',
              icon: const Icon(Icons.share_rounded),
              onPressed: _shareEmployeesExcel,
            ),
            IconButton(
              tooltip: 'تنزيل Excel',
              icon: const Icon(Icons.download_rounded),
              onPressed: _downloadEmployeesExcel,
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NewEmployeeScreen()),
            ).then((_) => _loadEmployees());
          },
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('إضافة موظف'),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // عنوان الصفحة
                Text(
                  'قائمة الموظفين',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),

                // شريط البحث بنمط TBIAN
                TSearchField(
                  controller: _searchController,
                  hint: 'ابحث عن الموظف (اسم/هوية/هاتف/صفة)',
                  onChanged: (_) => _filterEmployees(),
                  onClear: () {
                    _searchController.clear();
                    _filterEmployees();
                  },
                ),
                const SizedBox(height: 10),

                // عدّاد النتائج
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'النتائج: ${_filteredEmployees.length}',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: .65),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // القائمة مع سحب للتحديث
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                          color: cs.primary,
                          onRefresh: _loadEmployees,
                          child: _filteredEmployees.isEmpty
                              ? ListView(
                                  children: [
                                    const SizedBox(height: 120),
                                    Center(
                                      child: Text(
                                        'لا توجد نتائج',
                                        style: TextStyle(
                                          color: cs.onSurface
                                              .withValues(alpha: .6),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : ListView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  itemCount: _filteredEmployees.length,
                                  itemBuilder: (ctx, index) {
                                    final emp = _filteredEmployees[index];
                                    final id = emp['id'] as int;
                                    final name = (emp['name'] ?? '').toString();
                                    final jobTitle =
                                        (emp['jobTitle'] ?? '').toString();
                                    final phone =
                                        (emp['phoneNumber'] ?? '').toString();
                                    final isDoctor =
                                        (emp['isDoctor'] ?? 0) == 1;

                                    return NeuCard(
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                      child: ListTile(
                                        onTap: () async {
                                          await Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  ViewEmployeeScreen(empId: id),
                                            ),
                                          );
                                          await _loadEmployees();
                                        },
                                        leading: Container(
                                          decoration: BoxDecoration(
                                            color: kPrimaryColor.withValues(
                                              alpha: .10,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          padding: const EdgeInsets.all(10),
                                          child: Icon(
                                            isDoctor
                                                ? Icons
                                                    .medical_information_rounded
                                                : Icons.person_outline_rounded,
                                            color: kPrimaryColor,
                                          ),
                                        ),
                                        title: Text(
                                          name.isEmpty ? '—' : name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        subtitle: Text(
                                          jobTitle.isEmpty
                                              ? (phone.isEmpty ? '—' : phone)
                                              : jobTitle,
                                          style: TextStyle(
                                            color: cs.onSurface.withValues(
                                              alpha: .7,
                                            ),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        trailing: PopupMenuButton<String>(
                                          icon: const Icon(
                                            Icons.more_vert_rounded,
                                          ),
                                          onSelected: (value) async {
                                            switch (value) {
                                              case 'call':
                                                if (phone.isNotEmpty) {
                                                  await _makePhoneCall(phone);
                                                } else {
                                                  if (!mounted) return;
                                                  ScaffoldMessenger.of(context)
                                                      .showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        'لا يوجد رقم هاتف للموظف',
                                                      ),
                                                    ),
                                                  );
                                                }
                                                break;
                                              case 'edit':
                                                await Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        EditEmployeeScreen(
                                                      empId: id,
                                                    ),
                                                  ),
                                                );
                                                await _loadEmployees();
                                                break;
                                              case 'delete':
                                                await _deleteEmployee(id);
                                                break;
                                            }
                                          },
                                          itemBuilder: (_) => [
                                            PopupMenuItem(
                                              value: 'call',
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.phone_rounded,
                                                    size: 20,
                                                    color: cs.primary,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  const Text('اتصال'),
                                                ],
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: 'edit',
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.edit_rounded,
                                                    size: 20,
                                                    color: cs.primary,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  const Text('تعديل'),
                                                ],
                                              ),
                                            ),
                                            const PopupMenuItem(
                                              value: 'delete',
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.delete_rounded,
                                                    size: 20,
                                                    color: Colors.red,
                                                  ),
                                                  SizedBox(width: 8),
                                                  Text('حذف'),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
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
