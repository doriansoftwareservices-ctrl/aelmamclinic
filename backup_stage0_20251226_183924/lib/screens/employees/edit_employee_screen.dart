// lib/screens/employees/edit_employee_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/validators.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/services/db_service.dart';

class EditEmployeeScreen extends StatefulWidget {
  final int empId;

  const EditEmployeeScreen({super.key, required this.empId});

  @override
  State<EditEmployeeScreen> createState() => _EditEmployeeScreenState();
}

class _EditEmployeeScreenState extends State<EditEmployeeScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameCtrl = TextEditingController();
  final _identityCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _jobTitleCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _maritalStatusCtrl = TextEditingController();
  final _basicSalaryCtrl = TextEditingController();
  final _finalSalaryCtrl = TextEditingController();

  bool _isDoctor = false;
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadEmployeeData();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _identityCtrl.dispose();
    _phoneCtrl.dispose();
    _jobTitleCtrl.dispose();
    _addressCtrl.dispose();
    _maritalStatusCtrl.dispose();
    _basicSalaryCtrl.dispose();
    _finalSalaryCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadEmployeeData() async {
    setState(() => _loading = true);
    try {
      final emp = await DBService.instance.getEmployeeById(widget.empId);
      if (!mounted) return;
      if (emp == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الموظف غير موجود')),
        );
        Navigator.pop(context);
        return;
      }

      _nameCtrl.text = (emp['name'] ?? '').toString();
      _identityCtrl.text = (emp['identityNumber'] ?? '').toString();
      _phoneCtrl.text = (emp['phoneNumber'] ?? '').toString();
      _jobTitleCtrl.text = (emp['jobTitle'] ?? '').toString();
      _addressCtrl.text = (emp['address'] ?? '').toString();
      _maritalStatusCtrl.text = (emp['maritalStatus'] ?? '').toString();
      _basicSalaryCtrl.text = (emp['basicSalary'] ?? '').toString();
      _finalSalaryCtrl.text = (emp['finalSalary'] ?? '').toString();
      _isDoctor = (emp['isDoctor'] ?? 0) == 1;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تحميل البيانات: $e')),
      );
      Navigator.pop(context);
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _normalizeSalaryInputs() {
    String cleanNum(String s) {
      final latin = Formatters.arabicToEnglishDigits(s);
      return latin.replaceAll(RegExp(r'[^0-9\.]'), '');
    }

    _basicSalaryCtrl.text = cleanNum(_basicSalaryCtrl.text);
    _finalSalaryCtrl.text = cleanNum(_finalSalaryCtrl.text);
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    _normalizeSalaryInputs();
    final basicStr = Formatters.arabicToEnglishDigits(_basicSalaryCtrl.text);
    final finalStr = Formatters.arabicToEnglishDigits(_finalSalaryCtrl.text);

    final basic = double.tryParse(basicStr) ?? 0.0;
    final fin =
        (finalStr.trim().isEmpty) ? basic : (double.tryParse(finalStr) ?? 0.0);

    final updated = <String, dynamic>{
      'name': _nameCtrl.text.trim(),
      'identityNumber': _identityCtrl.text.trim(),
      'jobTitle': _jobTitleCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'maritalStatus': _maritalStatusCtrl.text.trim(),
      'basicSalary': basic,
      'finalSalary': fin,
      'isDoctor': _isDoctor ? 1 : 0,
      // الهاتف غير قابل للتعديل هنا — لذا لا نحدّثه في employee لتفادي اللبس.
    };

    try {
      await DBService.instance.updateEmployee(widget.empId, updated);

      // مزامنة بطاقة الطبيب المرتبط (إن وُجد) عبر employeeId
      await DBService.instance.updateDoctorByEmployeeId(widget.empId, {
        'name': _nameCtrl.text.trim(),
        'specialization': _jobTitleCtrl.text.trim(),
        'phoneNumber': _phoneCtrl.text.trim(), // للاتساق مع سجل الطبيب
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تحديث بيانات الموظف بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء التحديث: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
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
              tooltip: 'حفظ',
              icon: const Icon(Icons.save_rounded),
              onPressed: (_loading || _saving) ? null : _saveChanges,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Stack(
                  children: [
                    SingleChildScrollView(
                      padding: kScreenPadding,
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // بطاقة رأس
                            NeuCard(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      color:
                                          kPrimaryColor.withValues(alpha: .10),
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
                                          _nameCtrl.text.trim().isEmpty
                                              ? '—'
                                              : _nameCtrl.text.trim(),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _jobTitleCtrl.text.trim().isEmpty
                                              ? '—'
                                              : _jobTitleCtrl.text.trim(),
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

                            // الحقول
                            NeuField(
                              enabled: !_saving,
                              controller: _nameCtrl,
                              hintText: 'اسم الموظف',
                              prefix: const Icon(Icons.person_rounded),
                              validator: (v) => Validators.required(v,
                                  fieldName: 'اسم الموظف'),
                            ),
                            const SizedBox(height: 12),

                            NeuField(
                              enabled: !_saving,
                              controller: _identityCtrl,
                              hintText: 'رقم الهوية (اختياري)',
                              prefix: const Icon(Icons.credit_card_rounded),
                              validator: (v) => Validators.nationalId(v,
                                  fieldName: 'رقم الهوية'),
                            ),
                            const SizedBox(height: 12),

                            // رقم الهاتف — للعرض فقط (غير قابل للتعديل هنا)
                            NeuField(
                              enabled: false,
                              controller: _phoneCtrl,
                              hintText: 'رقم الهاتف',
                              keyboardType: TextInputType.phone,
                              prefix: const Icon(Icons.call_rounded),
                            ),
                            const SizedBox(height: 12),

                            NeuField(
                              enabled: !_saving,
                              controller: _jobTitleCtrl,
                              hintText: 'المسمى الوظيفي / الصفة',
                              prefix: const Icon(Icons.work_outline_rounded),
                            ),
                            const SizedBox(height: 12),

                            NeuField(
                              enabled: !_saving,
                              controller: _addressCtrl,
                              hintText: 'العنوان / السكن',
                              prefix: const Icon(Icons.home_work_outlined),
                            ),
                            const SizedBox(height: 12),

                            NeuField(
                              enabled: !_saving,
                              controller: _maritalStatusCtrl,
                              hintText: 'الحالة الاجتماعية',
                              prefix: const Icon(Icons.family_restroom_rounded),
                            ),
                            const SizedBox(height: 12),

                            NeuField(
                              enabled: !_saving,
                              controller: _basicSalaryCtrl,
                              hintText: 'الراتب الأساسي',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              prefix: const Icon(Icons.payments_outlined),
                              onChanged: (v) {
                                final latin =
                                    Formatters.arabicToEnglishDigits(v);
                                if ((_finalSalaryCtrl.text.trim().isEmpty) &&
                                    latin.isNotEmpty) {
                                  _finalSalaryCtrl.text = latin;
                                }
                              },
                            ),
                            const SizedBox(height: 12),

                            NeuField(
                              enabled: !_saving,
                              controller: _finalSalaryCtrl,
                              hintText: 'الراتب النهائي مع البدل',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              prefix: const Icon(
                                  Icons.account_balance_wallet_outlined),
                            ),
                            const SizedBox(height: 8),

                            // حالة الموظف
                            NeuCard(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              child: SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  'هل الموظف طبيب؟',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                value: _isDoctor,
                                onChanged: _saving
                                    ? null
                                    : (v) => setState(() => _isDoctor = v),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // أزرار الإجراء
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: _saving ? null : _saveChanges,
                                    icon: const Icon(Icons.save_rounded),
                                    label: Text(_saving
                                        ? 'جارٍ الحفظ…'
                                        : 'حفظ التعديلات'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _saving
                                        ? null
                                        : () => Navigator.pop(context),
                                    icon: const Icon(Icons.arrow_back_rounded),
                                    label: const Text('رجوع'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_saving)
                      const Align(
                        alignment: Alignment.topCenter,
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
