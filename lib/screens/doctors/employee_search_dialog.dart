// lib/screens/doctors/employee_search_dialog.dart
import 'package:flutter/material.dart';
import 'package:aelmamclinic/services/db_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class EmployeeSearchDialog extends StatefulWidget {
  const EmployeeSearchDialog({super.key});

  @override
  State<EmployeeSearchDialog> createState() => _EmployeeSearchDialogState();
}

class _EmployeeSearchDialogState extends State<EmployeeSearchDialog> {
  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _filteredEmployees = [];
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _searchController.addListener(_filterEmployees);
  }

  Future<void> _loadEmployees() async {
    final employees = await DBService.instance.getAllEmployees();
    setState(() {
      _employees = employees;
      _filteredEmployees = employees;
    });
  }

  void _filterEmployees() {
    final q = _searchController.text.toLowerCase().trim();
    setState(() {
      _filteredEmployees = _employees.where((e) {
        final name = (e['name'] ?? '').toString().toLowerCase();
        final job =
            (e['jobTitle'] ?? '').toString().toLowerCase(); // التخصص/المسمى
        return name.contains(q) || job.contains(q);
      }).toList();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterEmployees);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        backgroundColor: scheme.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // رأس بسيط
                Row(
                  children: [
                    Image.asset(
                      'assets/images/logo.png',
                      height: 28,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'اختيار موظف',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'إغلاق',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    )
                  ],
                ),
                const SizedBox(height: 12),

                // حقل البحث (نيومورفيزم)
                NeuField(
                  controller: _searchController,
                  hintText: 'ابحث عن اسم أو تخصص',
                  prefix: const Icon(Icons.search_rounded),
                ),

                const SizedBox(height: 12),

                // القائمة ضمن بطاقة نيومورفيزم
                Expanded(
                  child: _filteredEmployees.isEmpty
                      ? Center(
                          child: Text(
                            'لا يوجد بيانات',
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: .6),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          child: ListView.separated(
                            itemBuilder: (context, index) {
                              final e = _filteredEmployees[index];
                              final name = (e['name'] ?? '').toString();
                              final job = (e['jobTitle'] ?? '').toString();

                              return ListTile(
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                leading: Container(
                                  decoration: BoxDecoration(
                                    color: kPrimaryColor.withValues(alpha: .10),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.all(8),
                                  child: Icon(Icons.badge_rounded,
                                      color: kPrimaryColor),
                                ),
                                title: Text(
                                  name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800),
                                ),
                                subtitle: Text(
                                  job.isEmpty ? '—' : job,
                                  style: TextStyle(
                                    color:
                                        scheme.onSurface.withValues(alpha: .65),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing:
                                    const Icon(Icons.chevron_left_rounded),
                                onTap: () => Navigator.of(context).pop(e),
                              );
                            },
                            separatorBuilder: (_, __) =>
                                const Divider(height: 8),
                            itemCount: _filteredEmployees.length,
                          ),
                        ),
                ),

                const SizedBox(height: 10),

                // أزرار سفلية
                Row(
                  children: [
                    NeuButton.flat(
                      label: 'إلغاء',
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    NeuButton.primary(
                      label: 'تحديد لاحقًا',
                      icon: Icons.schedule_rounded,
                      onPressed: () => Navigator.pop(context, null),
                    ),
                  ],
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}
