// lib/screens/employees/new_employee_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/validators.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/models/account_user_summary.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/nhost_admin_service.dart';
import 'package:aelmamclinic/widgets/user_account_picker_dialog.dart';

class NewEmployeeScreen extends StatefulWidget {
  const NewEmployeeScreen({super.key});

  @override
  State<NewEmployeeScreen> createState() => _NewEmployeeScreenState();
}

class _NewEmployeeScreenState extends State<NewEmployeeScreen> {
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
  bool _saving = false;
  bool _loadingAccounts = false;
  final NhostAdminService _adminService = NhostAdminService();
  List<AccountUserSummary> _availableAccounts = const [];
  AccountUserSummary? _selectedAccount;
  String? _selectedUserUid;
  String? _selectedUserEmail;
  bool _selectedAccountDisabled = false;
  bool _linkAccount = false;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAvailableAccounts();
    });
  }

  void _normalizeSalaryInputs() {
    String cleanNum(String s) {
      final latin = Formatters.arabicToEnglishDigits(s);
      return latin.replaceAll(RegExp(r'[^0-9\.]'), '');
    }

    _basicSalaryCtrl.text = cleanNum(_basicSalaryCtrl.text);
    _finalSalaryCtrl.text = cleanNum(_finalSalaryCtrl.text);
  }

  Future<void> _openAccountPicker() async {
    final exclude = await DBService.instance.getLinkedUserUids();
    if (_selectedUserUid != null && _selectedUserUid!.isNotEmpty) {
      exclude.remove(_selectedUserUid);
    }

    final selection = await showDialog<UserAccountSelection>(
      context: context,
      builder: (_) => UserAccountPickerDialog(
        excludeUserUids: exclude,
        initialUserUid: _selectedUserUid,
      ),
    );

    if (selection == null) return;

    if (!mounted) return;
    setState(() {
      _selectedUserUid = selection.uid;
      _selectedUserEmail =
          selection.email.isEmpty ? selection.uid : selection.email;
      _selectedAccountDisabled = selection.disabled;
      _selectedAccount = AccountUserSummary(
        userUid: selection.uid,
        email: selection.email,
        disabled: selection.disabled,
      );
    });
  }

  Future<void> _saveEmployee() async {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _saving = true);

    // تطبيع الأرقام العربية قبل التحويل
    _normalizeSalaryInputs();
    final basicStr = Formatters.arabicToEnglishDigits(_basicSalaryCtrl.text);
    final finalStr = Formatters.arabicToEnglishDigits(_finalSalaryCtrl.text);

    // إن لم يُدخل المستخدم الراتب النهائي، اعتبره مساويًا للأساسي
    final basic = double.tryParse(basicStr) ?? 0.0;
    final fin =
        (finalStr.trim().isEmpty) ? basic : (double.tryParse(finalStr) ?? 0.0);

    final data = <String, dynamic>{
      'name': _nameCtrl.text.trim(),
      'identityNumber': _identityCtrl.text.trim(),
      'phoneNumber': _phoneCtrl.text.trim(),
      'jobTitle': _jobTitleCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'maritalStatus': _maritalStatusCtrl.text.trim(),
      'basicSalary': basic,
      'finalSalary': fin,
      'isDoctor': _isDoctor ? 1 : 0, // ✅ متوافقة مع SQLite (0/1)
    };

    if (_linkAccount && _selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى اختيار حساب الموظف أولًا.')),
      );
      if (mounted) setState(() => _saving = false);
      return;
    }
    if (_selectedAccountDisabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذا الحساب مجمّد حالياً.')),
      );
      if (mounted) setState(() => _saving = false);
      return;
    }
    data['userUid'] = _selectedAccount?.userUid;

    try {
      await DBService.instance.insertEmployee(data);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إنشاء الموظف بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _loadAvailableAccounts() async {
    final accountId = context.read<AuthProvider>().accountId;
    if (accountId == null || accountId.isEmpty) {
      return;
    }
    setState(() => _loadingAccounts = true);
    try {
      final accounts = await _adminService.listAccountUsersWithEmail(
        accountId: accountId,
        includeDisabled: false,
      );
      final linkedEmployees = await DBService.instance.getEmployeeUserUids();
      final filtered =
          accounts.where((a) => !linkedEmployees.contains(a.userUid)).toList();
      if (!mounted) return;
      setState(() {
        _availableAccounts = filtered;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تحميل حسابات الموظفين: $e')),
      );
    } finally {
      if (mounted) setState(() => _loadingAccounts = false);
    }
  }

  Future<void> _pickAccount() async {
    if (_loadingAccounts) return;
    if (_availableAccounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('لا يوجد حسابات متاحة غير مرتبطة بموظفين.')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<AccountUserSummary>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('اختر حساب الموظف',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _loadAvailableAccounts();
                    },
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _availableAccounts.length,
                    itemBuilder: (context, index) {
                      final acc = _availableAccounts[index];
                      return ListTile(
                        title: Text(acc.email.isEmpty ? acc.userUid : acc.email,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: acc.email.isEmpty
                            ? Text(acc.userUid,
                                style:
                                    TextStyle(color: scheme.onSurfaceVariant))
                            : Text(acc.userUid,
                                style:
                                    TextStyle(color: scheme.onSurfaceVariant)),
                        trailing: const Icon(Icons.chevron_left_rounded),
                        onTap: () => Navigator.pop(ctx, acc),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (chosen != null && mounted) {
      setState(() {
        _selectedAccount = chosen;
        _selectedUserUid = chosen.userUid;
        _selectedUserEmail =
            chosen.email.isEmpty ? chosen.userUid : chosen.email;
        _selectedAccountDisabled = chosen.disabled;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.read<AuthProvider>();

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
              onPressed: _saving ? null : _saveEmployee,
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: kScreenPadding,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // عنوان الشاشة
                      Text(
                        'إنشاء موظف جديد',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // بطاقة: البيانات الأساسية
                      NeuCard(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Row(
                              children: const [
                                Icon(Icons.badge_rounded, color: kPrimaryColor),
                                SizedBox(width: 8),
                                Text('البيانات الأساسية',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w900)),
                              ],
                            ),
                            const SizedBox(height: 10),
                            NeuField(
                              controller: _nameCtrl,
                              hintText: 'اسم الموظف',
                              prefix: const Icon(Icons.person_rounded),
                              validator: (v) => Validators.required(v,
                                  fieldName: 'اسم الموظف'),
                            ),
                            const SizedBox(height: 12),
                            NeuField(
                              controller: _identityCtrl,
                              hintText: 'رقم الهوية (اختياري)',
                              prefix: const Icon(Icons.credit_card_rounded),
                              validator: (v) => Validators.nationalId(v,
                                  fieldName: 'رقم الهوية'),
                            ),
                            const SizedBox(height: 12),
                            NeuField(
                              controller: _phoneCtrl,
                              hintText: 'رقم الهاتف',
                              keyboardType: TextInputType.phone,
                              prefix: const Icon(Icons.call_rounded),
                              validator: (v) => Validators.phone(v),
                            ),
                            const SizedBox(height: 12),
                            NeuField(
                              controller: _jobTitleCtrl,
                              hintText: 'المسمى الوظيفي / الصفة',
                              prefix: const Icon(Icons.work_outline_rounded),
                            ),
                            const SizedBox(height: 12),
                            NeuField(
                              controller: _addressCtrl,
                              hintText: 'العنوان / السكن',
                              prefix: const Icon(Icons.home_rounded),
                            ),
                            const SizedBox(height: 12),
                            NeuField(
                              controller: _maritalStatusCtrl,
                              hintText: 'الحالة الاجتماعية',
                              prefix: const Icon(Icons.family_restroom_rounded),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Column(
                          children: [
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'ربط الموظف بحساب دخول',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              subtitle: const Text(
                                'يمكن تركه بدون حساب عند الحاجة.',
                              ),
                              value: _linkAccount,
                              onChanged: (v) => setState(() {
                                _linkAccount = v;
                                if (!v) {
                                  _selectedUserUid = null;
                                  _selectedUserEmail = null;
                                  _selectedAccountDisabled = false;
                                  _selectedAccount = null;
                                }
                              }),
                            ),
                            if (_linkAccount) ...[
                              const Divider(height: 12),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Container(
                                  decoration: BoxDecoration(
                                    color: kPrimaryColor.withValues(alpha: .10),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.all(10),
                                  child: const Icon(
                                    Icons.alternate_email_rounded,
                                    color: kPrimaryColor,
                                  ),
                                ),
                                title: Text(
                                  _selectedUserEmail ?? 'اختيار حساب',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800),
                                ),
                                subtitle: Text(
                                  _selectedUserEmail == null
                                      ? 'اضغط لاختيار حساب لربطه بالموظف'
                                      : _selectedAccountDisabled
                                          ? '⚠️ الحساب المحدد معطّل'
                                          : 'سيُربط بالمعرّف ${_selectedUserUid ?? ''}',
                                  style: TextStyle(
                                    color:
                                        scheme.onSurface.withValues(alpha: .65),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: const Icon(Icons.search_rounded),
                                onTap: _openAccountPicker,
                              ),
                              if ((auth.uid ?? '').isNotEmpty)
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: TextButton.icon(
                                    onPressed: () {
                                      setState(() {
                                        _selectedUserUid = auth.uid;
                                        _selectedUserEmail =
                                            (auth.email ?? '').isEmpty
                                                ? auth.uid
                                                : auth.email;
                                        _selectedAccountDisabled = false;
                                        _selectedAccount = AccountUserSummary(
                                          userUid: auth.uid!,
                                          email: auth.email ?? '',
                                          disabled: false,
                                        );
                                      });
                                    },
                                    icon: const Icon(Icons.person_rounded),
                                    label: const Text('ربط حسابي'),
                                  ),
                                ),
                              if (_loadingAccounts)
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: LinearProgressIndicator(minHeight: 2),
                                ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // بطاقة: الرواتب
                      NeuCard(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Row(
                              children: const [
                                Icon(Icons.attach_money_rounded,
                                    color: kPrimaryColor),
                                SizedBox(width: 8),
                                Text('الرواتب',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w900)),
                              ],
                            ),
                            const SizedBox(height: 10),
                            NeuField(
                              controller: _basicSalaryCtrl,
                              hintText: 'الراتب الأساسي',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              prefix: const Icon(Icons.payments_rounded),
                              onChanged: (v) {
                                final latin =
                                    Formatters.arabicToEnglishDigits(v);
                                if ((_finalSalaryCtrl.text.trim().isEmpty) &&
                                    latin.isNotEmpty) {
                                  _finalSalaryCtrl.text = latin;
                                }
                              },
                            ),
                            const SizedBox(height: 10),
                            NeuField(
                              controller: _finalSalaryCtrl,
                              hintText: 'الراتب النهائي مع البدل',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              prefix: const Icon(Icons.request_quote_rounded),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      if (_linkAccount) ...[
                        NeuCard(
                          onTap: _pickAccount,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              decoration: BoxDecoration(
                                color: kPrimaryColor.withValues(alpha: .10),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: const Icon(Icons.account_circle_rounded,
                                  color: kPrimaryColor),
                            ),
                            title: Text(
                              _selectedAccount == null
                                  ? 'ربط حساب من القائمة'
                                  : (_selectedAccount!.email.isNotEmpty
                                      ? _selectedAccount!.email
                                      : _selectedAccount!.userUid),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            subtitle: Text(
                              _loadingAccounts
                                  ? 'جارٍ تحميل الحسابات…'
                                  : _availableAccounts.isEmpty
                                      ? 'لا توجد حسابات موظفين متاحة للربط'
                                      : 'اضغط لاختيار حساب مرتبط بهذا الموظف',
                              style: TextStyle(
                                color: scheme.onSurface.withValues(alpha: .6),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: _loadingAccounts
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.chevron_left_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // بطاقة: طبيب؟
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('هل الموظف طبيب؟',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          value: _isDoctor,
                          onChanged: (v) {
                            setState(() {
                              _isDoctor = v;
                            });
                            if (!v) {
                              _loadAvailableAccounts();
                            }
                          },
                        ),
                      ),

                      const SizedBox(height: 20),

                      // أزرار الإجراءات
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _saving ? null : _saveEmployee,
                              icon: const Icon(Icons.save_rounded),
                              label: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _saving ? null : () => Navigator.pop(context),
                              icon: const Icon(Icons.arrow_back_rounded),
                              label: const Text('إلغاء'),
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
