// lib/screens/patients/new_patient_screen.dart
// نمط TBIAN: Neumorphism + RTL + Widgets موحّدة + دقّة محاسبية
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:mime/mime.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/validators.dart';
import 'package:aelmamclinic/core/formatters.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';

import 'package:aelmamclinic/models/attachment.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_service.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'list_patients_screen.dart';
import 'duplicate_patients_screen.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class NewPatientScreen extends StatefulWidget {
  final String? initialName;
  final String? initialPhone;
  const NewPatientScreen({
    super.key,
    this.initialName,
    this.initialPhone,
  });

  @override
  State<NewPatientScreen> createState() => _NewPatientScreenState();
}

class _NewPatientScreenState extends State<NewPatientScreen> {
  // === Controllers ===
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _diagnosisCtrl = TextEditingController(); // نص خدمة للطبيب (اختياري)
  final _doctorCtrl = TextEditingController();
  final _paidCtrl = TextEditingController(); // مبلغ مدفوع
  final _remainingCtrl = TextEditingController(); // يُحسب تلقائياً
  final _notesCtrl = TextEditingController();
  final _collateralCtrl = TextEditingController(); // رهن/ضمان اختياري
  final _manualCostCtrl = TextEditingController(); // تكلفة الخدمة اليدوية
  final _totalCtrl = TextEditingController(text: '0.00');

  // === Date / Time ===
  DateTime _registerDate = DateTime.now();
  TimeOfDay _registerTime = TimeOfDay.now();

  // === Service selection ===
  String? _selectedServiceType; // "الأشعة" / "المختبر" / "طبيب"
  List<Map<String, dynamic>> _availableServices = [];
  final List<PatientService> _selectedServices = [];

  // === Doctor selection ===
  int? _selectedDoctorId;
  String? _selectedDoctorName;
  List<Doctor>? _cachedDoctors;
  Doctor? _linkedDoctor;

  // === Inventory usage ===
  List<Map<String, dynamic>> _invTypes = [];
  List<Map<String, dynamic>> _invItems = [];
  final List<Map<String, dynamic>> _invUsages = [];

  // === Attachments ===
  final List<PlatformFile> _pickedFiles = [];

  final _formKey = GlobalKey<FormState>();

  String _doctorDisplayName(String name) {
    final normalized = name
        .trim()
        .replaceFirst(RegExp(r'^(د/\s*|Dr\.\s*)', caseSensitive: false), '');
    if (normalized.isEmpty) return '';
    return context.isRtl ? 'د/$normalized' : 'Dr. $normalized';
  }
  bool _saving = false;
  bool _doctorRestricted = false;
  @override
  void initState() {
    super.initState();
    if (widget.initialName != null) _nameCtrl.text = widget.initialName!;
    if (widget.initialPhone != null) _phoneCtrl.text = widget.initialPhone!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveDoctorAccount();
    });
    _loadInvTypes();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _prefillDoctorFromAccount());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _phoneCtrl.dispose();
    _diagnosisCtrl.dispose();
    _doctorCtrl.dispose();
    _paidCtrl.dispose();
    _remainingCtrl.dispose();
    _notesCtrl.dispose();
    _collateralCtrl.dispose();
    _manualCostCtrl.dispose();
    _totalCtrl.dispose();
    super.dispose();
  }

  /*──────────────────── أدوات مساعدة ────────────────────*/
  double _parseDouble(String s) {
    // دعم الفاصلة العربية كفاصل عشري
    final v = s.trim().replaceAll(',', '.');
    return double.tryParse(v) ?? 0.0;
  }

  /*──────────────────── المستودع ────────────────────*/
  Future<void> _loadInvTypes() async {
    final types = await DBService.instance.getAllItemTypes();
    final rows = types
        .where((t) => t.id != null)
        .map((t) => {'id': t.id!, 'name': t.name})
        .toList();
    setState(() => _invTypes = rows);
  }

  Future<void> _loadInvItems(int typeId) async {
    final items = await DBService.instance.getAllItems();
    final rows = items
        .where((i) => i.typeId == typeId)
        .map((i) => {
              'id': i.id,
              'name': i.name,
              'price': i.price,
              'stock': i.stock,
            })
        .toList();
    setState(() => _invItems = rows);
  }

  Future<void> _resolveDoctorAccount() async {
    final auth = context.read<AuthProvider>();
    final uid = auth.uid;
    if (uid == null || uid.isEmpty) return;
    final doctor = await DBService.instance.getDoctorByUserUid(uid);
    if (!mounted) return;
    if (doctor != null) {
      setState(() {
        final selectedName = _doctorDisplayName(doctor.name);
        _linkedDoctor = doctor;
        _doctorRestricted = true;
        _selectedDoctorId = doctor.id;
        _selectedDoctorName = selectedName;
        _doctorCtrl.text = selectedName;
      });
    }
  }

  Future<void> _selectInventoryUsage() async {
    int? dlgTypeId;
    String? dlgTypeName;
    int? dlgItemId;
    String? dlgItemName;
    List<Map<String, dynamic>> dlgItems = [];
    final qtyCtrl = TextEditingController();

    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const LocalizedText('استخدام من المستودع',
              style: TextStyle(fontWeight: FontWeight.w800)),
          content: StatefulBuilder(
            builder: (ctx2, setStateDlg) => SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NeuCard(
                    padding: const EdgeInsets.all(10),
                    child: DropdownButtonFormField<int>(
                      decoration: InputDecoration(labelText: context.trRaw('نوع الصنف')),
                      items: _invTypes
                          .map((t) => DropdownMenuItem(
                                value: t['id'] as int,
                                child: Text(t['name'] as String),
                              ))
                          .toList(),
                      onChanged: (v) async {
                        dlgTypeId = v;
                        dlgTypeName = _invTypes
                            .firstWhere((t) => t['id'] == v)['name'] as String;
                        await _loadInvItems(v!);
                        dlgItems = _invItems;
                        dlgItemId = null;
                        dlgItemName = null;
                        setStateDlg(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (dlgTypeId != null) ...[
                    NeuCard(
                      padding: const EdgeInsets.all(10),
                      child: DropdownButtonFormField<int>(
                        decoration:
                            InputDecoration(labelText: context.trRaw('اسم الصنف')),
                        items: dlgItems
                            .map((i) => DropdownMenuItem(
                                  value: i['id'] as int,
                                  child: Text(i['name'] as String),
                                ))
                            .toList(),
                        onChanged: (v) {
                          dlgItemId = v;
                          dlgItemName =
                              dlgItems.firstWhere((i) => i['id'] == v)['name']
                                  as String;
                          setStateDlg(() {});
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (dlgItemId != null)
                    NeuField(
                      controller: qtyCtrl,
                      keyboardType: TextInputType.number,
                      labelText: context.trRaw('الكمية المستخدمة'),
                    ),
                ],
              ),
            ),
          ),
          actionsPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          actions: [
            TOutlinedButton(
              icon: Icons.close,
              label: 'إلغاء',
              onPressed: () => Navigator.pop(ctx),
            ),
            TPrimaryButton(
              icon: Icons.save_outlined,
              label: 'حفظ',
              onPressed: () async {
                final q = int.tryParse(qtyCtrl.text) ?? 0;
                if (dlgTypeId != null && dlgItemId != null && q > 0) {
                  // تحقق من الرصيد قبل الخصم
                  final db = await DBService.instance.database;
                  final row = await db.query('items',
                      where: 'id = ?', whereArgs: [dlgItemId], limit: 1);
                  final stock = (row.isNotEmpty
                      ? (row.first['stock'] as num?)?.toInt() ?? 0
                      : 0);
                  if (q > stock) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: LocalizedText('الكمية المطلوبة ($q) تتجاوز المتاح في المخزون ($stock)'),
                          backgroundColor: Theme.of(context).colorScheme.error,
                        ),
                      );
                    }
                    return;
                  }
                  Navigator.pop(ctx, {
                    'typeId': dlgTypeId,
                    'typeName': dlgTypeName,
                    'itemId': dlgItemId,
                    'itemName': dlgItemName,
                    'quantity': q,
                  });
                }
              },
            ),
          ],
        ),
      ),
    );

    if (res != null) setState(() => _invUsages.add(res));
  }

  /*──────────────────── التاريخ والوقت ────────────────────*/
  String _formatRegistrationDateTime() {
    final d = DateFormat('yyyy-MM-dd').format(_registerDate);
    final t = _registerTime.format(context);
    return '$d  $t';
  }

  Future<void> _pickRegistrationDateTime() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _registerDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
      helpText: context.trRaw('اختر تاريخ التسجيل'),
    );
    if (d != null) {
      final t =
          await showTimePicker(context: context, initialTime: _registerTime);
      if (t != null) {
        setState(() {
          _registerDate = d;
          _registerTime = t;
        });
      }
    }
  }

  /*──────────────────── الخدمات والأطباء ────────────────────*/
  Future<void> _loadServicesByType(String st) async {
    final rows = await DBService.instance.getServicesByType(st);
    setState(() => _availableServices = rows);
  }

  void _onServiceTypeChanged(String? val) {
    setState(() {
      _selectedServiceType = val;
      _selectedServices.clear();
      _totalCtrl.text = '0.00';
      _paidCtrl.clear();
      _remainingCtrl.clear();
      _diagnosisCtrl.clear();
      _manualCostCtrl.clear();
      _selectedDoctorId = null;
      _selectedDoctorName = null;

      if (val == 'الأشعة') {
        _loadServicesByType('radiology');
      } else if (val == 'المختبر') {
        _loadServicesByType('lab');
      } else {
        // "طبيب" تُدار خدماتها عبر شاشة اختيار خدمات الطبيب
        _availableServices.clear();
      }
      _recalcTotals();
    });
  }

  void _onSelectServiceChip(int id, String name, double cost) {
    final already = _selectedServices.any((ps) => ps.serviceId == id);
    setState(() {
      if (already) {
        _selectedServices.removeWhere((ps) => ps.serviceId == id);
      } else {
        _selectedServices.add(PatientService(
          id: null,
          patientId: -1,
          serviceId: id,
          serviceName: name,
          serviceCost: cost,
        ));
      }
      _recalcTotals();
    });
  }

  void _addManualDoctorService() {
    final name = _diagnosisCtrl.text.trim();
    final cost = _parseDouble(_manualCostCtrl.text);
    if (name.isEmpty || cost <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('أدخل اسم الخدمة وتكلفتها (> 0)')),
      );
      return;
    }
    setState(() {
      _selectedServices.add(PatientService(
        id: null,
        patientId: -1,
        serviceId: null,
        serviceName: name,
        serviceCost: cost,
      ));
      _diagnosisCtrl.clear();
      _manualCostCtrl.clear();
      _recalcTotals();
    });
  }

  void _recalcTotals() {
    final total =
        _selectedServices.fold<double>(0.0, (p, e) => p + e.serviceCost);
    _totalCtrl.text = total.toStringAsFixed(2);
    final paid = _parseDouble(_paidCtrl.text);
    final remain = total - paid;
    _remainingCtrl.text = (remain < 0 ? 0 : remain).toStringAsFixed(2);
    setState(() {});
  }

  Future<void> _prefillDoctorFromAccount() async {
    try {
      await _getDoctorsForCurrentUser();
    } catch (_) {}
  }

  Future<List<Doctor>> _getDoctorsForCurrentUser() async {
    if (_cachedDoctors != null) return _cachedDoctors!;

    final docs = await DBService.instance.getAllDoctors();
    final auth = context.read<AuthProvider>();
    final uid = auth.uid;
    Doctor? linked;
    if (uid != null && uid.isNotEmpty) {
      linked = await DBService.instance.getDoctorByUserUid(uid);
    }

    final List<Doctor> result;
    if (linked != null && linked.id != null) {
      final linkedDoctor = linked;
      final linkedDoctorId = linkedDoctor.id;
      result = docs.where((d) => d.id == linkedDoctorId).toList();
    } else {
      result = docs;
    }

    _cachedDoctors = result;
    _linkedDoctor = linked;

    if (linked != null && linked.id != null && mounted) {
      final linkedDoctor = linked;
      final linkedDoctorId = linkedDoctor.id;
      if (linkedDoctorId != null) {
        final selectedName = _doctorDisplayName(linkedDoctor.name);
        setState(() {
          if (_selectedDoctorId == null) {
            _selectedDoctorId = linkedDoctorId;
            _selectedDoctorName = selectedName;
            _doctorCtrl.text = selectedName;
          }
        });
      }
    }

    return result;
  }

  void _onPaidChanged(String v) {
    final total = _parseDouble(_totalCtrl.text);
    final paid = _parseDouble(v);
    final remain = total - paid;
    _remainingCtrl.text = (remain < 0 ? 0 : remain).toStringAsFixed(2);
    setState(() {});
  }

  Future<void> _selectDoctorForRadLab() async {
    if (_doctorRestricted && _linkedDoctor != null) {
      setState(() {
        final selectedName = _doctorDisplayName(_linkedDoctor!.name);
        _selectedDoctorId = _linkedDoctor!.id;
        _selectedDoctorName = selectedName;
        _doctorCtrl.text = selectedName;
      });
      return;
    }
    final doctors = await DBService.instance.getAllDoctors();
    final source = List<Doctor>.from(doctors);
    List<Doctor> filtered = List.from(source);
    final chosen = await showDialog<Doctor>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const LocalizedText('اختر الطبيب',
              style: TextStyle(fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                NeuField(
                  hintText: context.trRaw('بحث عن الطبيب…'),
                  prefix: const Icon(Icons.search),
                  onChanged: (v) {
                    filtered = source
                        .where((d) =>
                            d.name.toLowerCase().contains(v.toLowerCase()))
                        .toList();
                    (ctx as Element).markNeedsBuild();
                  },
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: LocalizedText('لا يوجد نتائج'))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (c, i) {
                            final d = filtered[i];
                            return NeuCard(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              onTap: () => Navigator.pop(ctx, d),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  _doctorDisplayName(d.name),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(d.specialization),
                                trailing: Icon(
                                  context.isRtl
                                      ? Icons.chevron_left_rounded
                                      : Icons.chevron_right_rounded,
                                ),
                                onTap: () => Navigator.pop(ctx, d),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TOutlinedButton(
                icon: Icons.close,
                label: 'إغلاق',
                onPressed: () => Navigator.pop(ctx))
          ],
        ),
      ),
    );

    if (chosen != null) {
      setState(() {
        final selectedName = _doctorDisplayName(chosen.name);
        _selectedDoctorId = chosen.id;
        _selectedDoctorName = selectedName;
        _doctorCtrl.text = selectedName;
      });
    }
  }

  Future<void> _selectDoctorForOther() async {
    // نفس الحواري للعيادات الخاصة (Doctor-type)
    await _selectDoctorForRadLab();
  }

  Future<void> _selectDoctorGeneralService() async {
    if (_selectedDoctorId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('اختر الطبيب أولاً')),
      );
      return;
    }
    final svcs =
        await DBService.instance.getDoctorGeneralServices(_selectedDoctorId!);
    if (svcs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('لا توجد خدمات عامة لهذا الطبيب')),
      );
      return;
    }

    List<Map<String, dynamic>> filteredServices = List.from(svcs);
    final searchCtrl = TextEditingController();

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const LocalizedText('اختر خدمة الطبيب',
              style: TextStyle(fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NeuField(
                  controller: searchCtrl,
                  hintText: context.trRaw('بحث عن الخدمة...'),
                  prefix: const Icon(Icons.search),
                  onChanged: (v) {
                    filteredServices = svcs
                        .where((s) => (s['name'] as String)
                            .toLowerCase()
                            .contains(v.toLowerCase()))
                        .toList();
                    (ctx as Element).markNeedsBuild();
                  },
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: filteredServices.isEmpty
                      ? const Center(child: LocalizedText('لا توجد نتائج'))
                      : ListView.builder(
                          itemCount: filteredServices.length,
                          itemBuilder: (c, i) {
                            final s = filteredServices[i];
                            return NeuCard(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              onTap: () => Navigator.pop(ctx, s),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(s['name'] as String,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                subtitle: LocalizedText('السعر: ${(s['cost'] as num).toStringAsFixed(2)}'),
                                trailing: Icon(
                                  context.isRtl
                                      ? Icons.chevron_left_rounded
                                      : Icons.chevron_right_rounded,
                                ),
                                onTap: () => Navigator.pop(ctx, s),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TOutlinedButton(
                icon: Icons.close,
                label: 'إلغاء',
                onPressed: () => Navigator.pop(ctx))
          ],
        ),
      ),
    );

    if (chosen != null) {
      setState(() {
        _selectedServices.add(PatientService(
          id: null,
          patientId: -1,
          serviceId: chosen['id'] as int,
          serviceName: chosen['name'] as String,
          serviceCost: (chosen['cost'] as num).toDouble(),
        ));
        _recalcTotals();
      });
    }
  }

  /*──────────────────── مرفقات ────────────────────*/
  Future<void> _pickAttachments() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res != null) setState(() => _pickedFiles.addAll(res.files));
  }

  String? _mapServiceTypeToCode(String? ar) {
    switch (ar) {
      case 'الأشعة':
        return 'radiology';
      case 'المختبر':
        return 'lab';
      case 'طبيب':
        return 'doctor'; // بصيغة قياسية
    }
    return null;
  }

  Future<int?> _inferDoctorIdFromServices() async {
    final ids = <int>{};
    for (final s in _selectedServices) {
      if (s.serviceId == null) continue;
      final rows =
          await DBService.instance.getDoctorSharesForService(s.serviceId!);
      for (final r in rows) {
        final did = (r['doctorId'] is int)
            ? r['doctorId'] as int
            : int.tryParse('${r['doctorId']}');
        if (did != null) ids.add(did);
      }
    }
    if (ids.length == 1) return ids.first;
    return null;
  }

  Future<String?> _doctorNameById(int id) async {
    final db = await DBService.instance.database;
    final rows = await db.query('doctors',
        columns: const ['name'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final name = (rows.first['name'] ?? '').toString().trim();
    return name.isEmpty ? null : _doctorDisplayName(name);
  }

  /*──────────────────── تحذير مكررات ────────────────────*/
  Future<bool> _maybeWarnDuplicates(String phoneNormalized, String name) async {
    final all = await DBService.instance.getAllPatients();
    final dups = all.where((p) => p.phoneNumber == phoneNormalized).toList();
    if (dups.isEmpty) return true;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const LocalizedText('تنبيه تكرار',
              style: TextStyle(fontWeight: FontWeight.w800)),
          content: LocalizedText('هناك سجلات أخرى برقم الهاتف نفسه (${dups.length}). هل ترغب بعرضها قبل المتابعة؟'),
          actions: [
            TPrimaryButton(
              icon: Icons.check_circle_outline,
              label: 'متابعة الحفظ',
              onPressed: () => Navigator.pop(ctx, true),
            ),
            TOutlinedButton(
              icon: Icons.visibility_outlined,
              label: 'عرض المكررات',
              onPressed: () {
                Navigator.pop(ctx, false);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DuplicatePatientsScreen(
                      phoneNumber: phoneNormalized,
                      patientName: name,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );

    return proceed ?? false;
  }

  /*──────────────────── حفظ ────────────────────*/
  Future<void> _savePatient() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    if (_selectedServiceType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('اختر نوع الخدمة')),
      );
      return;
    }

    // تطبيع الهاتف
    final rawPhone = _phoneCtrl.text.trim();
    final normalizedPhone = Formatters.normalizePhone(rawPhone);

    // تحقق الطبيب والخدمات
    final needsDoctor = _selectedServiceType == 'الأشعة' ||
        _selectedServiceType == 'المختبر' ||
        _selectedServiceType == 'طبيب';
    if (needsDoctor && _selectedDoctorId == null) {
      final inferred = await _inferDoctorIdFromServices();
      if (inferred != null) {
        final inferredName = await _doctorNameById(inferred);
        setState(() {
          _selectedDoctorId = inferred;
          _selectedDoctorName = inferredName ?? _selectedDoctorName;
          if (inferredName != null) _doctorCtrl.text = inferredName;
        });
      }
    }
    if (needsDoctor && _selectedDoctorId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('يجب اختيار الطبيب')),
      );
      return;
    }
    if (_selectedServices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('اختر خدمة واحدة على الأقل')),
      );
      return;
    }

    // تحذير المكررات
    final ok =
        await _maybeWarnDuplicates(normalizedPhone, _nameCtrl.text.trim());
    if (!ok) return;

    setState(() => _saving = true);

    try {
      final regDT = DateTime(
        _registerDate.year,
        _registerDate.month,
        _registerDate.day,
        _registerTime.hour,
        _registerTime.minute,
      );

      // المبالغ
      final total =
          _selectedServices.fold<double>(0.0, (p, e) => p + e.serviceCost);
      final paid = _parseDouble(_paidCtrl.text);
      double remain = _parseDouble(_remainingCtrl.text);
      if ((paid + remain - total).abs() > 0.01) remain = (total - paid);
      if (remain < 0) remain = 0.0;

      // نسب/مدخلات الطبيب
      double docShareSum = 0.0; // للأشعة/المختبر (حصة الطبيب كنسبة)
      double towerShareSum = 0.0; // حصة المركز
      double docInputSum = 0.0; // صافي مدخلات الطبيب لعيادته (Doctor-type)

      // Helper: إيجاد صف النسبة لهذا الطبيب/الخدمة تحديدًا
      Map<String, dynamic>? findDoctorShareRow(
          List<Map<String, dynamic>> rows, int doctorId) {
        for (final r in rows) {
          final did = (r['doctorId'] is int)
              ? r['doctorId'] as int
              : int.tryParse('${r['doctorId']}');
          if (did == doctorId) return r;
        }
        return null;
      }

      if (_selectedServiceType == 'الأشعة' ||
          _selectedServiceType == 'المختبر') {
        for (final s in _selectedServices) {
          if (_selectedDoctorId != null && s.serviceId != null) {
            final rows = await DBService.instance
                .getDoctorSharesForService(s.serviceId!);
            final match = findDoctorShareRow(rows, _selectedDoctorId!);
            if (match != null) {
              final pctDoc = (match['sharePercentage'] as num).toDouble();
              final pctTower =
                  (match['towerSharePercentage'] as num?)?.toDouble() ?? 0.0;
              docShareSum += s.serviceCost * pctDoc / 100.0;
              towerShareSum += s.serviceCost * pctTower / 100.0;
            }
          }
        }
      } else if (_selectedServiceType == 'طبيب') {
        for (final s in _selectedServices) {
          if (_selectedDoctorId != null && s.serviceId != null) {
            final rows = await DBService.instance
                .getDoctorSharesForService(s.serviceId!);
            final match = findDoctorShareRow(rows, _selectedDoctorId!);
            if (match != null) {
              final pctTower =
                  (match['towerSharePercentage'] as num?)?.toDouble() ?? 0.0;
              final centerShare = s.serviceCost * pctTower / 100.0;
              final doctorNet = s.serviceCost - centerShare;
              towerShareSum += centerShare;
              docInputSum += doctorNet;
            } else {
              // لا توجد نسبة محددة: كامل المبلغ للطبيب
              docInputSum += s.serviceCost;
            }
          } else {
            // خدمة يدوية للطبيب
            docInputSum += s.serviceCost;
          }
        }
      }

      final patient = Patient(
        name: _nameCtrl.text.trim(),
        age: int.tryParse(_ageCtrl.text.trim()) ?? 0,
        diagnosis: _diagnosisCtrl.text.trim(),
        paidAmount: paid,
        remaining: remain,
        registerDate: regDT,
        phoneNumber: normalizedPhone,
        doctorId: _selectedDoctorId,
        doctorName: _selectedDoctorName,
        notes: _notesCtrl.text.trim(),
        collateral: _collateralCtrl.text.trim().isEmpty
            ? null
            : _collateralCtrl.text.trim(),
        serviceType:
            _mapServiceTypeToCode(_selectedServiceType), // تخزين بصيغة قياسية
        serviceId: null,
        serviceName: null,
        serviceCost: null,
        doctorShare: docShareSum,
        towerShare: towerShareSum,
        doctorInput: docInputSum,
        doctorReviewPending: _selectedDoctorId != null,
      );

      final db = await DBService.instance.database;
      int patientId = 0;
      var touchedServices = false;
      var touchedConsumptions = false;
      var touchedItems = false;
      var touchedFinancial = false;

      await db.transaction((txn) async {
        // 1) Insert patient
        final data = await DBService.instance.prepareInsert(
          Patient.table,
          patient.toMap()..remove('id'),
          executor: txn,
        );
        if ((patient.doctorId ?? 0) != 0) {
          data['doctorReviewPending'] = 1;
          data['doctorReviewedAt'] = null;
        }
        patientId = await txn.insert(Patient.table, data);

        if (paid > 0) {
          final fData = await DBService.instance.prepareInsert(
            'financial_logs',
            {
              'transaction_type': 'PatientPayment',
              'operation': 'create',
              'amount': paid,
              'employee_id': null,
              'patient_id': patientId,
              'description':
                  'دفعة مريض: ${patient.name} (ID: $patientId)',
              'modification_details': '',
              'timestamp': regDT.toIso8601String(),
            },
            executor: txn,
          );
          await txn.insert('financial_logs', fData);
          touchedFinancial = true;
        }

        // 2) Insert services
        if (_selectedServices.isNotEmpty) {
          for (final ps in _selectedServices) {
            final data = await DBService.instance.prepareInsert(
              PatientService.table,
              {
                'patientId': patientId,
                'serviceId': ps.serviceId,
                'serviceName': ps.serviceName,
                'serviceCost': ps.serviceCost,
              },
              executor: txn,
            );
            await txn.insert(PatientService.table, data);
          }
          touchedServices = true;
        }

        // 3) Inventory usages
        for (final u in _invUsages) {
          final itemId = u['itemId'] as int;
          final qty = u['quantity'] as int;
          double amount = 0.0;
          final itemRows = await txn.query(
            'items',
            columns: ['price'],
            where: 'id = ?',
            whereArgs: [itemId],
            limit: 1,
          );
          if (itemRows.isNotEmpty) {
            amount =
                ((itemRows.first['price'] as num?)?.toDouble() ?? 0.0) * qty;
          }
          final cData = await DBService.instance.prepareInsert(
            Consumption.table,
            {
              'patientId': patientId.toString(),
              'itemId': itemId.toString(),
              'quantity': qty,
              'date': regDT.toIso8601String(),
              'amount': amount,
            },
            executor: txn,
          );
          await txn.insert(Consumption.table, cData);
          touchedConsumptions = true;

          final hasUpdatedAt =
              await DBService.instance.hasColumn(txn, 'items', 'updated_at');
          final args = <Object?>[qty, itemId, qty];
          final accClause = await DBService.instance.accountFilterClause(
            txn,
            'items',
            args: args,
          );
          final sql = hasUpdatedAt
              ? 'UPDATE items SET stock = stock - ?, updated_at = ? WHERE id = ? AND stock >= ? $accClause'
              : 'UPDATE items SET stock = stock - ? WHERE id = ? AND stock >= ? $accClause';
          if (hasUpdatedAt) {
            args.insert(1, DateTime.now().toIso8601String());
          }
          final rows = await txn.rawUpdate(sql, args);
          if (rows == 0) {
            throw Exception('المخزون غير كافٍ لبعض المواد المستخدمة.');
          }
          touchedItems = true;
        }
      });

      await DBService.instance.notifyTableChanged(Patient.table);
      if (touchedServices) {
        await DBService.instance.notifyTableChanged(PatientService.table);
      }
      if (touchedConsumptions) {
        await DBService.instance.notifyTableChanged(Consumption.table);
      }
      if (touchedItems) {
        await DBService.instance.notifyTableChanged(Item.table);
      }
      if (touchedFinancial) {
        await DBService.instance.notifyTableChanged('financial_logs');
      }

      // 4) Attachments
      for (final pf in _pickedFiles) {
        if (pf.path == null) continue;
        await DBService.instance.insertAttachment(
          Attachment(
            id: null,
            patientId: patientId,
            fileName: pf.name,
            filePath: pf.path!,
            mimeType: lookupMimeType(pf.path!) ?? 'application/octet-stream',
            createdAt: DateTime.now(),
          ),
        );
      }

      // 5) Reload alerts and notify
      if (mounted) context.read<RepositoryProvider>().loadAlerts();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('تم حفظ بيانات المريض والخدمات بنجاح')),
      );

      // 6) Navigate back to list
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ListPatientsScreen()),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _quickFillPaidAll() {
    final total = _parseDouble(_totalCtrl.text);
    _paidCtrl.text = total.toStringAsFixed(2);
    _onPaidChanged(_paidCtrl.text);
  }

  void _clearSelectedServices() {
    setState(() {
      _selectedServices.clear();
      _recalcTotals();
    });
  }

  /*──────────────────── UI ────────────────────*/
  @override
  Widget build(BuildContext context) {
    final isRadLab =
        _selectedServiceType == 'الأشعة' || _selectedServiceType == 'المختبر';
    final isDoctor = _selectedServiceType == 'طبيب';
    final dateLabel = _formatRegistrationDateTime();

    return Scaffold(
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
      ),
      body: SafeArea(
        child: Directionality(
          textDirection: Directionality.of(context),
          child: Stack(
            children: [
              // المحتوى
              Form(
                key: _formKey,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 140),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // تاريخ ووقت التسجيل
                      TSectionHeader('تاريخ ووقت التسجيل'),
                      NeuCard(
                        onTap: _pickRegistrationDateTime,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: _DateRow(
                          icon: Icons.calendar_month_rounded,
                          label: dateLabel,
                          action: 'تغيير',
                        ),
                      ),

                      const SizedBox(height: 14),

                      // بيانات المريض
                      TSectionHeader('بيانات المريض'),
                      NeuCard(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                        child: Column(
                          children: [
                            NeuField(
                              controller: _nameCtrl,
                              labelText: context.trRaw('اسم المريض'),
                              validator: (v) => Validators.required(v,
                                  fieldName: 'اسم المريض'),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: NeuField(
                                    controller: _ageCtrl,
                                    labelText: context.trRaw('العمر'),
                                    keyboardType: TextInputType.number,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: NeuField(
                                    controller: _phoneCtrl,
                                    labelText: context.trRaw('رقم الهاتف'),
                                    keyboardType: TextInputType.phone,
                                    validator: (v) => Validators.phone(v),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // استخدام المستودع
                      TSectionHeader('استخدام من المستودع'),
                      if (_invUsages.isNotEmpty) ...[
                        NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: _invUsages
                                .map((u) => _RemovableChip(
                                      text:
                                          '${u['typeName']} > ${u['itemName']} × ${u['quantity']}',
                                      onDelete: () =>
                                          setState(() => _invUsages.remove(u)),
                                    ))
                                .toList(),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      TOutlinedButton(
                        icon: Icons.inventory_2_rounded,
                        label: 'إضافة استخدام',
                        onPressed: _selectInventoryUsage,
                      ),

                      const SizedBox(height: 14),

                      // مرفقات
                      TSectionHeader('المرفقات'),
                      if (_pickedFiles.isNotEmpty) ...[
                        NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: _pickedFiles
                                .map((pf) => _RemovableChip(
                                      text: pf.name,
                                      onDelete: () => setState(
                                          () => _pickedFiles.remove(pf)),
                                    ))
                                .toList(),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      TOutlinedButton(
                        icon: Icons.attach_file,
                        label: 'إضافة مرفقات',
                        onPressed: _pickAttachments,
                      ),

                      const SizedBox(height: 14),

                      // نوع الخدمة
                      TSectionHeader('نوع الخدمة'),
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: DropdownButtonFormField<String>(
                          initialValue: _selectedServiceType,
                          decoration: InputDecoration(
                            labelText: context.trRaw('اختر نوع الخدمة'),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'الأشعة',
                              enabled: false,
                              child: Row(
                                children: [
                                  LocalizedText('الأشعة'),
                                  SizedBox(width: 8),
                                  _UnderDevBadge(),
                                ],
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'المختبر',
                              enabled: false,
                              child: Row(
                                children: [
                                  LocalizedText('المختبر'),
                                  SizedBox(width: 8),
                                  _UnderDevBadge(),
                                ],
                              ),
                            ),
                            DropdownMenuItem(
                                value: 'طبيب', child: LocalizedText('طبيب')),
                          ],
                          onChanged: _onServiceTypeChanged,
                          validator: (v) =>
                              v == null ? context.trRaw('اختر نوع الخدمة') : null,
                        ),
                      ),

                      const SizedBox(height: 14),

                      // خدمات الأشعة/المختبر + الطبيب المختص
                      if (isRadLab) ...[
                        TSectionHeader('الخدمات المتاحة'),
                        _buildServicesChips(),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: _selectDoctorForRadLab,
                          child: AbsorbPointer(
                            child: NeuField(
                              controller: _doctorCtrl,
                              labelText: context.trRaw('الطبيب المختص'),
                              suffix: Icon(
                                context.isRtl
                                    ? Icons.chevron_left_rounded
                                    : Icons.chevron_right_rounded,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],

                      // خدمات الطبيب
                      if (isDoctor) ...[
                        TSectionHeader('عيادة الطبيب'),
                        GestureDetector(
                          onTap: _selectDoctorForOther,
                          child: AbsorbPointer(
                            child: NeuField(
                              controller: _doctorCtrl,
                              labelText: context.trRaw('عيادة الطبيب'),
                              suffix: Icon(
                                context.isRtl
                                    ? Icons.chevron_left_rounded
                                    : Icons.chevron_right_rounded,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        NeuCard(
                          onTap: _selectDoctorGeneralService,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          child: Row(
                            children: [
                              const Icon(Icons.add_circle_outline,
                                  color: kPrimaryColor),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: LocalizedText('إضافة خدمة من عيادة الطبيب',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w700)),
                              ),
                              Icon(
                                context.isRtl
                                    ? Icons.chevron_left_rounded
                                    : Icons.chevron_right_rounded,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: NeuField(
                                controller: _diagnosisCtrl,
                                labelText: context.trRaw('خدمة/حالة نصيّة'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: NeuField(
                                controller: _manualCostCtrl,
                                labelText: context.trRaw('تكلفة اليدوية'),
                                keyboardType: TextInputType.number,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: NeuButton.primary(
                            icon: Icons.add,
                            label: 'إضافة إلى القائمة',
                            onPressed: _addManualDoctorService,
                          ),
                        ),
                      ],

                      // الخدمات المحددة
                      if (_selectedServices.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        TSectionHeader('الخدمات المحدَّدة'),
                        NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: _selectedServices
                                .map((ps) => _RemovableChip(
                                      text:
                                          '${ps.serviceName} • ${ps.serviceCost.toStringAsFixed(2)}',
                                      onDelete: () {
                                        setState(() {
                                          _selectedServices.remove(ps);
                                          _recalcTotals();
                                        });
                                      },
                                    ))
                                .toList(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TOutlinedButton(
                            icon: Icons.clear_all,
                            label: 'مسح القائمة',
                            onPressed: _clearSelectedServices,
                          ),
                        ),
                      ],

                      const SizedBox(height: 14),

                      // المبالغ
                      TSectionHeader('المبالغ'),
                      NeuCard(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                        child: Column(
                          children: [
                            NeuField(
                              controller: _totalCtrl,
                              labelText: context.trRaw('المجموع الكلي للخدمات'),
                              enabled: false,
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: NeuField(
                                    controller: _paidCtrl,
                                    labelText: context.trRaw('المبلغ المقدم'),
                                    keyboardType: TextInputType.number,
                                    onChanged: _onPaidChanged,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: NeuField(
                                    controller: _remainingCtrl,
                                    labelText: context.trRaw('المتبقي (يُحسب تلقائيًا)'),
                                    enabled: false,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TOutlinedButton(
                                icon: Icons.done_all_rounded,
                                label: 'اعتبار المدفوع = الإجمالي',
                                onPressed: _quickFillPaidAll,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // رهن/ضمان اختياري
                      TSectionHeader('الرهن (اختياري)'),
                      NeuField(
                        controller: _collateralCtrl,
                        labelText: context.trRaw('مثال: سيارة، ذهب، سند...'),
                        maxLines: 2,
                      ),

                      const SizedBox(height: 14),

                      // ملاحظات
                      TSectionHeader('ملاحظات'),
                      NeuField(
                        controller: _notesCtrl,
                        labelText: context.trRaw('ملاحظات'),
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
              ),

              // شريط سفلي للحفظ
              Align(
                alignment: Alignment.bottomCenter,
                child: NeuCard(
                  margin: EdgeInsets.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              LocalizedText('الإجمالي: ${_totalCtrl.text}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 4),
                              LocalizedText('المتبقي: ${_remainingCtrl.text}'),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        TOutlinedButton(
                          icon: Icons.list_alt_outlined,
                          label: 'قائمة المرضى',
                          onPressed: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const ListPatientsScreen()),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        NeuButton.primary(
                          icon: Icons.save_rounded,
                          label: _saving ? 'جارٍ الحفظ...' : 'حفظ البيانات',
                          onPressed: _saving ? null : _savePatient,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServicesChips() {
    final scheme = Theme.of(context).colorScheme;
    if (_availableServices.isEmpty) {
      return NeuCard(
        padding: const EdgeInsets.all(12),
        child: const LocalizedText('لا توجد خدمات محفوظة لهذا النوع'),
      );
    }
    return Directionality(
      textDirection: Directionality.of(context),
      child: Wrap(
        alignment: WrapAlignment.start,
        spacing: 8,
        runSpacing: 8,
        children: _availableServices.map((s) {
          final id = s['id'] as int;
          final name = s['name'] as String;
          final cost = (s['cost'] as num).toDouble();
          final sel = _selectedServices.any((ps) => ps.serviceId == id);
          return InkWell(
            onTap: () => _onSelectServiceChip(id, name, cost),
            borderRadius: BorderRadius.circular(24),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color:
                    sel ? kPrimaryColor.withValues(alpha: .10) : scheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: sel ? kPrimaryColor : scheme.outlineVariant,
                  width: sel ? 1.6 : 1.0,
                ),
                boxShadow: sel
                    ? [
                        // لمسة نيومورفيزم خفيفة عند الاختيار
                        BoxShadow(
                          color: Colors.white.withValues(alpha: .9),
                          offset: const Offset(-3, -3),
                          blurRadius: 6,
                        ),
                        BoxShadow(
                          color: const Color(0xFFCFD8DC).withValues(alpha: .6),
                          offset: const Offset(3, 3),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: sel ? kPrimaryColor : scheme.onSurface,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/*──────────────────── Widgets مساعدة ────────────────────*/
class _DateRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? action;
  const _DateRow({required this.icon, required this.label, this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: kPrimaryColor, size: 18),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LocalizedText(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
          ),
        ),
        if (action != null)
          LocalizedText(action!,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .6),
                fontWeight: FontWeight.w700,
              )),
      ],
    );
  }
}

class _RemovableChip extends StatelessWidget {
  final String text;
  final VoidCallback onDelete;
  const _RemovableChip({required this.text, required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              style: TextStyle(color: scheme.onSurface.withValues(alpha: .9))),
          const SizedBox(width: 6),
          InkWell(
            onTap: onDelete,
            child: const Icon(Icons.close, size: 18, color: Colors.red),
          ),
        ],
      ),
    );
  }
}

class _UnderDevBadge extends StatelessWidget {
  const _UnderDevBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error.withValues(alpha: .35)),
      ),
      child: LocalizedText('تحت التطوير',
        style: TextStyle(
          color: scheme.error,
          fontWeight: FontWeight.w700,
          fontSize: 10.5,
        ),
      ),
    );
  }
}
