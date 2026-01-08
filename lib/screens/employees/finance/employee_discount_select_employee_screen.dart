// lib/screens/employees/finance/employee_discount_select_employee_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'employee_discount_create_screen.dart';
import 'employee_discounts_of_employee_screen.dart';
import 'finance_access_guard.dart';

class EmployeeDiscountSelectEmployeeScreen extends StatefulWidget {
  /// true = إنشاء خصم جديد, false = استعراض الخصومات
  final bool isCreateMode;

  const EmployeeDiscountSelectEmployeeScreen({
    super.key,
    required this.isCreateMode,
  });

  @override
  State<EmployeeDiscountSelectEmployeeScreen> createState() =>
      _EmployeeDiscountSelectEmployeeScreenState();
}

class _EmployeeDiscountSelectEmployeeScreenState
    extends State<EmployeeDiscountSelectEmployeeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  List<Map<String, dynamic>> _allEmployees = [];
  List<Map<String, dynamic>> _filteredEmployees = [];

  bool _loading = true;
  String? _loadError;

  Timer? _debounce;

  String get _screenTitle => widget.isCreateMode
      ? 'اختر الموظف (خصم جديد)'
      : 'اختر الموظف (استعراض الخصومات)';

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadEmployees() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final data = await DBService.instance.getAllEmployees();
      // فرز افتراضي: بالاسم (تطبيع عربي)
      data.sort((a, b) {
        final an = Formatters.normalizeForSearch('${a['name'] ?? ''}');
        final bn = Formatters.normalizeForSearch('${b['name'] ?? ''}');
        return an.compareTo(bn);
      });
      if (!mounted) return;
      setState(() {
        _allEmployees = data;
        _filteredEmployees = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'تعذر تحميل الموظفين: $e';
      });
    }
  }

  void _onSearchChanged() {
    // تقليل الضغط على UI عبر Debounce خفيف
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _filterEmployees);
  }

  /// فلترة تدعم العربية (إزالة التشكيل/تطبيع الأرقام) + تطبيع رقم الهاتف
  void _filterEmployees() {
    final raw = _searchController.text;
    if (raw.isEmpty) {
      setState(() => _filteredEmployees = List.of(_allEmployees));
      return;
    }
    final qNorm = Formatters.normalizeForSearch(raw);
    final qPhone = Formatters.normalizePhone(raw);

    final next = _allEmployees.where((emp) {
      String name = '${emp['name'] ?? ''}';
      String identity = '${emp['identityNumber'] ?? ''}';
      String phone = '${emp['phoneNumber'] ?? ''}';
      String jobTitle = '${emp['jobTitle'] ?? ''}';

      final nameN = Formatters.normalizeForSearch(name);
      final idN = Formatters.normalizeForSearch(identity);
      final jobN = Formatters.normalizeForSearch(jobTitle);
      final phoneN = Formatters.normalizePhone(phone);

      final hitText =
          nameN.contains(qNorm) || idN.contains(qNorm) || jobN.contains(qNorm);

      final hitPhone = qPhone.isNotEmpty && phoneN.contains(qPhone);

      return hitText || hitPhone;
    }).toList();

    // إبقاء الفرز ثابتاً بعد الفلترة
    next.sort((a, b) {
      final an = Formatters.normalizeForSearch('${a['name'] ?? ''}');
      final bn = Formatters.normalizeForSearch('${b['name'] ?? ''}');
      return an.compareTo(bn);
    });

    setState(() => _filteredEmployees = next);
  }

  void _onEmployeeSelected(int empId) {
    final next = widget.isCreateMode
        ? EmployeeDiscountCreateScreen(empId: empId)
        : EmployeeDiscountsOfEmployeeScreen(empId: empId);
    Navigator.push(context, MaterialPageRoute(builder: (_) => next));
  }

  String _avatarText(String name) {
    final s = name.trim();
    if (s.isEmpty) return '—';
    // تعمل مع العربية واللاتينية
    return s.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return FinanceAccessGuard(
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.badge_rounded),
              const SizedBox(width: 8),
              Text(_screenTitle),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'مسح البحث',
              onPressed: () {
                if (_searchController.text.isEmpty) return;
                _searchController.clear();
                _filterEmployees();
                _searchFocus.requestFocus();
              },
              icon: const Icon(Icons.clear_all_rounded),
            ),
            IconButton(
              tooltip: 'تحديث',
              onPressed: _loadEmployees,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              children: [
                // بطاقة رأس بسيطة (mode chip)
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          widget.isCreateMode
                              ? Icons.add_circle_outline_rounded
                              : Icons.history_rounded,
                          color: kPrimaryColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.isCreateMode
                              ? 'اختر الموظف لإنشاء خصم جديد'
                              : 'اختر الموظف لاستعراض الخصومات',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // حقل البحث (نيومورفيزم) مع زر مسح سريع
                NeuField(
                  controller: _searchController,
                  hintText: 'ابحث بالاسم/الهاتف/الصفة…',
                  prefix: const Icon(Icons.search_rounded),
                  suffix: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح',
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _searchController.clear();
                            _filterEmployees();
                            _searchFocus.requestFocus();
                          },
                        ),
                ),
                const SizedBox(height: 10),

                // عداد نتائج
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _loading
                        ? 'جاري التحميل…'
                        : (_loadError != null
                            ? 'خطأ في التحميل'
                            : 'النتائج: ${_filteredEmployees.length}'),
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: .65),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // القائمة + سحب للتحديث + حالات فارغة/خطأ
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : (_loadError != null)
                          ? _ErrorView(
                              message: _loadError!, onRetry: _loadEmployees)
                          : RefreshIndicator(
                              color: cs.primary,
                              onRefresh: _loadEmployees,
                              child: _filteredEmployees.isEmpty
                                  ? _EmptyView(
                                      isCreateMode: widget.isCreateMode,
                                      onRefreshTap: _loadEmployees,
                                    )
                                  : ListView.separated(
                                      physics:
                                          const AlwaysScrollableScrollPhysics(),
                                      itemCount: _filteredEmployees.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (ctx, i) {
                                        final emp = _filteredEmployees[i];
                                        final empId = emp['id'] as int;
                                        final name =
                                            (emp['name'] ?? '').toString();
                                        final jobTitle =
                                            (emp['jobTitle'] ?? '').toString();
                                        final isDoctor =
                                            (emp['isDoctor'] ?? 0) == 1;

                                        return NeuCard(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                          child: ListTile(
                                            contentPadding: EdgeInsets.zero,
                                            leading: CircleAvatar(
                                              radius: 22,
                                              backgroundColor: kPrimaryColor
                                                  .withValues(alpha: .12),
                                              child: Text(
                                                _avatarText(name),
                                                style: const TextStyle(
                                                  color: kPrimaryColor,
                                                  fontWeight: FontWeight.w900,
                                                ),
                                              ),
                                            ),
                                            title: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    name.isEmpty ? '—' : name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                if (isDoctor)
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 8,
                                                        vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: kPrimaryColor
                                                          .withValues(
                                                              alpha: .10),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              100),
                                                    ),
                                                    child: const Text(
                                                      'طبيب',
                                                      style: TextStyle(
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: kPrimaryColor,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            subtitle: Text(
                                              jobTitle.isEmpty ? '—' : jobTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: cs.onSurface
                                                    .withValues(alpha: .7),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            trailing: const Icon(
                                              Icons.chevron_left_rounded,
                                            ),
                                            onTap: () =>
                                                _onEmployeeSelected(empId),
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
      ),
    );
  }
}

/*──────── حالات واجهة مساعدة ─────────*/

class _EmptyView extends StatelessWidget {
  final bool isCreateMode;
  final VoidCallback onRefreshTap;

  const _EmptyView({
    required this.isCreateMode,
    required this.onRefreshTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          isCreateMode ? Icons.person_search_rounded : Icons.history_rounded,
          size: 48,
          color: cs.onSurface.withValues(alpha: .35),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'لا توجد نتائج',
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: .6),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: onRefreshTap,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('تحديث'),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: NeuCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: cs.error),
              const SizedBox(height: 8),
              Text(
                'حدث خطأ',
                style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: .75),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('حاول مجدداً'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
