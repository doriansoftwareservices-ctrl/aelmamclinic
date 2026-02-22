// lib/screens/patients/edit_patient_screen.dart
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';
import 'package:provider/provider.dart';
import 'dart:ui' as ui show TextDirection;

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/core/validators.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/models/attachment.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'list_patients_screen.dart';
import 'duplicate_patients_screen.dart';

class EditPatientScreen extends StatefulWidget {
  final Patient patient;
  const EditPatientScreen({super.key, required this.patient});

  @override
  State<EditPatientScreen> createState() => _EditPatientScreenState();
}

class _EditPatientScreenState extends State<EditPatientScreen> {
  // Controllers
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _diagnosisCtrl = TextEditingController(); // اسم خدمة نصية (للطبيب)
  final _manualCostCtrl = TextEditingController(); // تكلفة الخدمة اليدوية
  final _doctorCtrl = TextEditingController();
  final _paidCtrl = TextEditingController();
  final _remainingCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _totalCtrl = TextEditingController(text: '0.00'); // إجمالي الخدمات

  // Date / Time
  DateTime _registerDate = DateTime.now();
  TimeOfDay _registerTime = TimeOfDay.now();

  // Service selection (UI تعرض عربي؛ التخزين Code)
  String? _selectedServiceTypeAr; // "الأشعة" / "المختبر" / "طبيب"
  List<Map<String, dynamic>> _availableServices = [];
  final List<PatientService> _selectedServices = [];

  // Doctor selection
  int? _selectedDoctorId;
  String? _selectedDoctorName;
  List<Doctor>? _cachedDoctors;
  Doctor? _linkedDoctor;

  // Inventory usages
  List<Map<String, dynamic>> _invTypes = [];
  List<Map<String, dynamic>> _invItems = [];
  List<Map<String, dynamic>> _existingUsages = [];
  final List<Map<String, dynamic>> _newUsages = [];
  final List<int> _deletedUsageIds = [];

  // Attachments
  Future<List<Attachment>> _attachmentsFuture =
      Future<List<Attachment>>.value(const []);
  final List<Attachment> _newAttachments = [];
  final List<Attachment> _deletedAttachments = [];

  final _formKey = GlobalKey<FormState>();
  final _dtOnly = DateFormat('yyyy-MM-dd');
  bool _doctorRestricted = false;
  bool _saving = false;

  // ── Helpers العامة ──
  double _parseDouble(String s) {
    final v = s.trim().replaceAll(',', '.');
    return double.tryParse(v) ?? 0.0;
  }

  // ── Helpers: تحويل نوع الخدمة بين الكود والعرض العربي ──
  String? _codeToLabel(String? code) {
    switch (code) {
      case 'radiology':
        return 'الأشعة';
      case 'lab':
        return 'المختبر';
      case 'doctor':
        return 'طبيب';
    }
    return null;
  }

  String? _labelToCode(String? label) {
    switch (label) {
      case 'الأشعة':
        return 'radiology';
      case 'المختبر':
        return 'lab';
      case 'طبيب':
        return 'doctor';
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
    return name.isEmpty ? null : 'د/$name';
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final p = widget.patient;

    // تعبئة الحقول الأساسية
    _nameCtrl.text = p.name;
    _ageCtrl.text = p.age.toString();
    _phoneCtrl.text = p.phoneNumber;
    _diagnosisCtrl.text = p.diagnosis;
    _paidCtrl.text = p.paidAmount.toStringAsFixed(2);
    _remainingCtrl.text = p.remaining.toStringAsFixed(2);
    _notesCtrl.text = p.notes ?? '';

    _registerDate = p.registerDate;
    _registerTime = TimeOfDay.fromDateTime(p.registerDate);

    await _resolveDoctorAccount();
    if (_doctorRestricted && _linkedDoctor != null) {
      _selectedDoctorId = _linkedDoctor!.id;
      _selectedDoctorName = 'د/${_linkedDoctor!.name}';
    } else {
      _selectedDoctorId = p.doctorId;
      _selectedDoctorName = p.doctorName;
    }
    final initialDoctor = _selectedDoctorName;
    _doctorCtrl.text = initialDoctor == null ? '' : initialDoctor;

    await _getDoctorsForCurrentUser(forceSelection: true);

    _selectedServiceTypeAr = _codeToLabel(p.serviceType);

    // تحميل المرفقات (قد تكون معطلة على الخادم)
    try {
      _attachmentsFuture = DBService.instance.getAttachmentsByPatient(p.id!);
    } catch (_) {
      _attachmentsFuture = Future<List<Attachment>>.value(const []);
    }

    // تحميل الخدمات المحفوظة للمريض
    final svcs = await DBService.instance.getPatientServices(p.id!);
    setState(() {
      _selectedServices
        ..clear()
        ..addAll(svcs);
    });
    _recalcTotals(); // يحدث الإجمالي والمتبقي

    // تحميل أنواع/استهلاكات المستودع
    await _loadInvTypes();
    await _loadExistingConsumptions();

    // تحميل قائمة الخدمات المتاحة حسب النوع الحالي
    if (_selectedServiceTypeAr == 'الأشعة') {
      await _loadServicesByType('radiology');
    } else if (_selectedServiceTypeAr == 'المختبر') {
      await _loadServicesByType('lab');
    } else {
      setState(() => _availableServices = []);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _phoneCtrl.dispose();
    _diagnosisCtrl.dispose();
    _manualCostCtrl.dispose();
    _doctorCtrl.dispose();
    _paidCtrl.dispose();
    _remainingCtrl.dispose();
    _notesCtrl.dispose();
    _totalCtrl.dispose();
    super.dispose();
  }

  /*──────── المستودع ────────*/
  Future<void> _loadInvTypes() async {
    final db = await DBService.instance.database;
    final types = await db.query('item_types', orderBy: 'name');
    setState(() => _invTypes = types);
  }

  Future<void> _loadInvItems(int typeId) async {
    final db = await DBService.instance.database;
    final rows = await db.query(
      'items',
      where: 'type_id = ?',
      whereArgs: [typeId],
      orderBy: 'name',
    );
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
        _linkedDoctor = doctor;
        _doctorRestricted = true;
      });
    }
  }

  Future<List<Doctor>> _getDoctorsForCurrentUser(
      {bool forceSelection = false}) async {
    if (_cachedDoctors != null) return _cachedDoctors!;

    final doctors = await DBService.instance.getAllDoctors();
    final auth = context.read<AuthProvider>();
    final uid = auth.uid;
    Doctor? linked;
    if (uid != null && uid.isNotEmpty) {
      linked = await DBService.instance.getDoctorByUserUid(uid);
    }

    final result = (linked != null && linked.id != null)
        ? doctors.where((d) => d.id == linked!.id).toList()
        : doctors;

    _cachedDoctors = result;
    _linkedDoctor = linked;

    if (forceSelection && linked != null && linked.id != null && mounted) {
      final selectedName = 'د/${linked.name}';
      setState(() {
        _selectedDoctorId = linked!.id;
        _selectedDoctorName = selectedName;
        _doctorCtrl.text = selectedName;
      });
    }

    return result;
  }

  Future<void> _loadExistingConsumptions() async {
    final db = await DBService.instance.database;
    final rows = await db.query(
      'consumptions',
      where: 'patientId = ?',
      whereArgs: [widget.patient.id.toString()],
    );
    final tmp = <Map<String, dynamic>>[];
    for (final r in rows) {
      final item = (await db.query(
        'items',
        where: 'id = ?',
        whereArgs: [r['itemId']],
        limit: 1,
      ))
          .first;
      final type = (await db.query(
        'item_types',
        where: 'id = ?',
        whereArgs: [item['type_id']],
        limit: 1,
      ))
          .first;
      tmp.add({
        'consId': r['id'] as int,
        'typeId': type['id'] as int,
        'typeName': type['name'] as String,
        'itemId': item['id'] as int,
        'itemName': item['name'] as String,
        'quantity': r['quantity'] as int,
      });
    }
    setState(() => _existingUsages = tmp);
  }

  Future<void> _selectInventoryUsage() async {
    int? dlgTypeId;
    String? dlgTypeName;
    int? dlgItemId;
    String? dlgItemName;
    List<Map<String, dynamic>> dlgItems = [];
    final qtyCtrl = TextEditingController();

    final scheme = Theme.of(context).colorScheme;

    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setStateDlg) => AlertDialog(
          title: const Text('استخدام من المستودع'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<int>(
                  decoration: const InputDecoration(labelText: 'نوع الصنف'),
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
                const SizedBox(height: 12),
                if (dlgTypeId != null) ...[
                  DropdownButtonFormField<int>(
                    decoration: const InputDecoration(labelText: 'اسم الصنف'),
                    items: dlgItems
                        .map((i) => DropdownMenuItem(
                              value: i['id'] as int,
                              child: Text(i['name'] as String),
                            ))
                        .toList(),
                    onChanged: (v) {
                      dlgItemId = v;
                      dlgItemName = dlgItems
                          .firstWhere((i) => i['id'] == v)['name'] as String;
                      setStateDlg(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                if (dlgItemId != null)
                  TextField(
                    controller: qtyCtrl,
                    decoration:
                        const InputDecoration(labelText: 'الكمية المستخدمة'),
                    keyboardType: TextInputType.number,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPrimaryColor),
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
                          content: Text(
                              'الكمية المطلوبة ($q) تتجاوز المتاح في المخزون ($stock)'),
                          backgroundColor: scheme.error,
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
              child: const Text('حفظ', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (res != null) setState(() => _newUsages.add(res));
  }

  Widget _usageChip(Map<String, dynamic> u, {required bool isNew}) {
    final label =
        '${u['typeName']} > ${u['itemName']} × ${u['quantity']}${isNew ? ' (جديد)' : ''}';
    final deleted = _deletedUsageIds.contains(u['consId']);
    final bg = isNew
        ? kPrimaryColor.withValues(alpha: 0.10)
        : deleted
            ? Colors.red.shade100
            : null;

    return FilterChip(
      backgroundColor: bg,
      label: Text(label),
      onSelected: (_) {},
      onDeleted: () {
        setState(() {
          if (isNew) {
            _newUsages.remove(u);
          } else {
            final id = u['consId'] as int;
            if (_deletedUsageIds.contains(id)) {
              _deletedUsageIds.remove(id);
            } else {
              _deletedUsageIds.add(id);
            }
          }
        });
      },
    );
  }

  /*──────── المرفقات ────────*/
  Future<void> _pickAttachments() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res != null) {
      setState(() {
        _newAttachments.addAll(
            res.files.where((pf) => pf.path != null).map((pf) => Attachment(
                  id: null,
                  patientId: widget.patient.id!,
                  fileName: pf.name,
                  filePath: pf.path!,
                  mimeType:
                      lookupMimeType(pf.path!) ?? 'application/octet-stream',
                  createdAt: DateTime.now(),
                )));
      });
    }
  }

  Future<void> _openAttachment(Attachment a) async {
    if (!await File(a.filePath).exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('الملف غير موجود: ${a.fileName}')),
      );
      return;
    }
    await OpenFile.open(a.filePath);
  }

  /*──────── الخدمات والأطباء ────────*/
  Future<void> _loadServicesByType(String serviceTypeCode) async {
    final raw = await DBService.instance.getServicesByType(serviceTypeCode);
    setState(() => _availableServices = List<Map<String, dynamic>>.from(raw));
  }

  void _onServiceTypeChanged(String? arabicLabel) {
    setState(() {
      _selectedServiceTypeAr = arabicLabel;
      _selectedServices.clear();
      _doctorCtrl.clear();
      _selectedDoctorId = null;
      _selectedDoctorName = null;
      _manualCostCtrl.clear();
      _diagnosisCtrl.clear();
    });
    final code = _labelToCode(arabicLabel);
    if (code == 'radiology' || code == 'lab') {
      _loadServicesByType(code!);
    } else {
      setState(() => _availableServices = []);
    }
    _recalcTotals();
  }

  void _onSelectServiceChip(int id, String name, double cost) {
    setState(() {
      final already = _selectedServices.any((ps) => ps.serviceId == id);
      if (already) {
        _selectedServices.removeWhere((ps) => ps.serviceId == id);
      } else {
        _selectedServices.add(PatientService(
          id: null,
          patientId: widget.patient.id!,
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
        const SnackBar(content: Text('أدخل اسم الخدمة وتكلفتها (> 0)')),
      );
      return;
    }
    setState(() {
      _selectedServices.add(PatientService(
        id: null,
        patientId: widget.patient.id!,
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
    final remain = (total - paid);
    _remainingCtrl.text = (remain < 0 ? 0 : remain).toStringAsFixed(2);
    setState(() {}); // لتحديث الشريط السفلي
  }

  void _onPaidChanged(String v) {
    final total = _parseDouble(_totalCtrl.text);
    final paid = _parseDouble(v);
    _remainingCtrl.text =
        (total - paid <= 0 ? 0 : total - paid).toStringAsFixed(2);
    setState(() {});
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

  Future<void> _selectDoctorForRadLab() async {
    if (_doctorRestricted && _linkedDoctor != null) {
      setState(() {
        final selectedName = 'د/${_linkedDoctor!.name}';
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
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDlg) => AlertDialog(
          title: const Text('اختر الطبيب'),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'بحث عن الطبيب…',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setDlg(() => filtered = source
                      .where(
                          (d) => d.name.toLowerCase().contains(v.toLowerCase()))
                      .toList()),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('لا يوجد نتائج'))
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
                                title: Text('د/${d.name}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text(d.specialization),
                                trailing:
                                    const Icon(Icons.chevron_left_rounded),
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
        final selectedName = 'د/${chosen.name}';
        _selectedDoctorId = chosen.id;
        _selectedDoctorName = selectedName;
        _doctorCtrl.text = selectedName;
      });
    }
  }

  Future<void> _selectDoctorForOther() async {
    final doctors = await DBService.instance.getAllDoctors();
    List<Doctor> filtered = List.from(doctors);
    final chosen = await showDialog<Doctor>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDlg) => AlertDialog(
          title: const Text('اختر الطبيب'),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'بحث عن الطبيب…',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setDlg(() => filtered = doctors
                      .where(
                          (d) => d.name.toLowerCase().contains(v.toLowerCase()))
                      .toList()),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('لا يوجد نتائج'))
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
                                title: Text('د/${d.name}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text(d.specialization),
                                trailing:
                                    const Icon(Icons.chevron_left_rounded),
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
        _selectedDoctorId = chosen.id;
        _selectedDoctorName = 'د/${chosen.name}';
        _doctorCtrl.text = _selectedDoctorName!;
      });
    }
  }

  Future<void> _selectDoctorGeneralService() async {
    if (_selectedDoctorId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('اختر الطبيب أولاً')));
      return;
    }
    final svcs =
        await DBService.instance.getDoctorGeneralServices(_selectedDoctorId!);
    if (svcs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد خدمات عامة لهذا الطبيب')));
      return;
    }

    List<Map<String, dynamic>> filteredServices = List.from(svcs);
    final searchCtrl = TextEditingController();

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDlg) => AlertDialog(
          title: const Text('اختر خدمة الطبيب'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              children: [
                TextField(
                  controller: searchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'بحث عن الخدمة...',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setDlg(() {
                    filteredServices = svcs
                        .where((s) => (s['name'] as String)
                            .toLowerCase()
                            .contains(v.toLowerCase()))
                        .toList();
                  }),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: filteredServices.isEmpty
                      ? const Center(child: Text('لا توجد نتائج'))
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
                                subtitle: Text(
                                    'السعر: ${(s['cost'] as num).toStringAsFixed(2)}'),
                                trailing:
                                    const Icon(Icons.chevron_left_rounded),
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
          patientId: widget.patient.id!,
          serviceId: chosen['id'] as int,
          serviceName: chosen['name'] as String,
          serviceCost: (chosen['cost'] as num).toDouble(),
        ));
        _recalcTotals();
      });
    }
  }

  /*──────── التاريخ والوقت ────────*/
  String _formatRegistrationDateTime() {
    final d = _dtOnly.format(_registerDate);
    final t = _registerTime.format(context);
    return '$d  $t';
  }

  Future<void> _pickRegistrationDateTime() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _registerDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
      helpText: 'اختر التاريخ',
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

  Future<bool> _maybeWarnDuplicates(String phoneNormalized, String name) async {
    final all = await DBService.instance.getAllPatients();
    final dups = all
        .where((p) =>
            p.phoneNumber == phoneNormalized && p.id != widget.patient.id)
        .toList();
    if (dups.isEmpty) return true;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('تنبيه تكرار',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: Text(
            'هناك سجلات أخرى بنفس رقم الهاتف (${dups.length}). هل ترغب بعرضها قبل المتابعة؟'),
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
    );

    return proceed ?? false;
  }

  /*──────── حفظ ────────*/
  Future<void> _saveChanges() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;

    if (_selectedServiceTypeAr == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('اختر نوع الخدمة')));
      return;
    }
    final needsDoctor = _selectedServiceTypeAr == 'الأشعة' ||
        _selectedServiceTypeAr == 'المختبر' ||
        _selectedServiceTypeAr == 'طبيب';
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('يجب اختيار الطبيب')));
      return;
    }
    if (_selectedServices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اختر خدمة واحدة على الأقل')));
      return;
    }

    final regDT = DateTime(
      _registerDate.year,
      _registerDate.month,
      _registerDate.day,
      _registerTime.hour,
      _registerTime.minute,
    );

    final total =
        _selectedServices.fold<double>(0.0, (p, e) => p + e.serviceCost);
    final paid = _parseDouble(_paidCtrl.text);
    double remain = _parseDouble(_remainingCtrl.text);
    if ((paid + remain - total).abs() > 0.01) {
      remain = (total - paid);
    }
    if (remain < 0) remain = 0.0;

    // حساب نسب/مدخلات الطبيب
    double docShareSum = 0.0;
    double towerShareSum = 0.0;
    double docInputSum = 0.0;

    // نختار صف النسبة المطابق للطبيب الحالي فقط (إن وُجد)
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

    final typeAr = _selectedServiceTypeAr;
    if (typeAr == 'الأشعة' || typeAr == 'المختبر') {
      for (final s in _selectedServices) {
        if (_selectedDoctorId != null && s.serviceId != null) {
          final rows =
              await DBService.instance.getDoctorSharesForService(s.serviceId!);
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
    } else if (typeAr == 'طبيب') {
      for (final s in _selectedServices) {
        if (_selectedDoctorId != null && s.serviceId != null) {
          final rows =
              await DBService.instance.getDoctorSharesForService(s.serviceId!);
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

    // تطبيع الهاتف قبل الحفظ
    final normalizedPhone = Formatters.normalizePhone(_phoneCtrl.text.trim());
    final originalPhone =
        Formatters.normalizePhone(widget.patient.phoneNumber.trim());
    if (normalizedPhone != originalPhone) {
      final ok = await _maybeWarnDuplicates(
        normalizedPhone,
        _nameCtrl.text.trim(),
      );
      if (!ok) return;
    }

    final oldDoctorId = widget.patient.doctorId;
    final newDoctorId = _selectedDoctorId;
    bool reviewPending = widget.patient.doctorReviewPending;
    DateTime? reviewedAt = widget.patient.doctorReviewedAt;

    if (newDoctorId == null) {
      reviewPending = false;
      reviewedAt = null;
    } else if (oldDoctorId != newDoctorId) {
      reviewPending = true;
      reviewedAt = null;
    }

    final updated = widget.patient.copyWith(
      name: _nameCtrl.text.trim(),
      age: int.tryParse(_ageCtrl.text) ?? widget.patient.age,
      phoneNumber: normalizedPhone,
      diagnosis: _diagnosisCtrl.text.trim(),
      paidAmount: paid,
      remaining: remain,
      registerDate: regDT,
      doctorId: _selectedDoctorId,
      doctorName: _selectedDoctorName,
      notes: _notesCtrl.text.trim(),
      serviceType: _labelToCode(_selectedServiceTypeAr),
      // الحقول المجمّعة تُحسب من الخدمات
      serviceId: null,
      serviceName: null,
      serviceCost: null,
      doctorShare: docShareSum,
      towerShare: towerShareSum,
      doctorInput: docInputSum,
      doctorReviewPending: reviewPending,
      doctorReviewedAt: reviewedAt,
    );

    setState(() => _saving = true);
    try {
      final db = await DBService.instance.database;
      var touchedServices = false;
      var touchedConsumptions = false;
      var touchedItems = false;

      await db.transaction((txn) async {
        // Update patient + services (داخل معاملة واحدة)
        final data = updated.toMap();
        final nowIso = DateTime.now().toIso8601String();

        // احسب حالة المراجعة حسب تغيّر الطبيب
        final existing = await txn.query(
          'patients',
          columns: const ['doctorId'],
          where: 'id = ?',
          whereArgs: [updated.id],
          limit: 1,
        );
        final prevDoctor = existing.isNotEmpty
            ? (existing.first['doctorId'] as num?)?.toInt() ?? 0
            : 0;
        final currDoctor = updated.doctorId ?? 0;
        if (currDoctor == 0) {
          data['doctorReviewPending'] = 0;
          data['doctorReviewedAt'] = null;
        } else if (currDoctor != prevDoctor) {
          data['doctorReviewPending'] = 1;
          data['doctorReviewedAt'] = null;
        }

        await txn.update(
          'patients',
          data,
          where: 'id = ?',
          whereArgs: [updated.id],
        );

        // soft delete old services + insert new services
        await txn.update(
          PatientService.table,
          {'isDeleted': 1, 'deletedAt': nowIso},
          where: 'patientId = ?',
          whereArgs: [updated.id],
        );
        if (_selectedServices.isNotEmpty) {
          final batch = txn.batch();
          for (final s in _selectedServices) {
            batch.insert(PatientService.table, {
              'patientId': updated.id,
              'serviceId': s.serviceId,
              'serviceName': s.serviceName,
              'serviceCost': s.serviceCost,
            });
          }
          await batch.commit(noResult: true);
        }
        touchedServices = true;

        // Inventory: حذف/إضافة + تعديل الرصيد
        for (final id in _deletedUsageIds) {
          final u = _existingUsages.firstWhere((e) => e['consId'] == id);
          await txn.update(
            Consumption.table,
            {'isDeleted': 1, 'deletedAt': nowIso},
            where: 'id = ?',
            whereArgs: [id],
          );
          await txn.rawUpdate(
            'UPDATE items SET stock = stock + ? WHERE id = ?',
            [u['quantity'], u['itemId']],
          );
          touchedConsumptions = true;
          touchedItems = true;
        }

        for (final u in _newUsages) {
          double amount = 0.0;
          final itemRows = await txn.query(
            'items',
            columns: ['price'],
            where: 'id = ?',
            whereArgs: [u['itemId']],
            limit: 1,
          );
          if (itemRows.isNotEmpty) {
            amount =
                ((itemRows.first['price'] as num?)?.toDouble() ?? 0.0) *
                    (u['quantity'] as int);
          }
          await txn.insert(Consumption.table, {
            'patientId': updated.id.toString(),
            'itemId': u['itemId'].toString(),
            'quantity': u['quantity'],
            'date': regDT.toIso8601String(),
            'amount': amount,
          });
          final rows = await txn.rawUpdate(
            'UPDATE items SET stock = stock - ? WHERE id = ? AND stock >= ?',
            [u['quantity'], u['itemId'], u['quantity']],
          );
          if (rows == 0) {
            throw Exception('المخزون غير كافٍ لبعض المواد المستخدمة.');
          }
          touchedItems = true;
          touchedConsumptions = true;
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

      // Attachments
      for (final a in _deletedAttachments) {
        if (a.id != null) {
          await DBService.instance.deleteAttachment(a.id!);
        }
      }
      for (final a in _newAttachments) {
        await DBService.instance.insertAttachment(a);
      }

      if (mounted) context.read<RepositoryProvider>().loadAlerts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ التعديلات بنجاح')),
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ListPatientsScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRadLab = _selectedServiceTypeAr == 'الأشعة' ||
        _selectedServiceTypeAr == 'المختبر';
    final isDoctor = _selectedServiceTypeAr == 'طبيب';
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
            const Text('تعديل بيانات المريض'),
          ],
        ),
      ),
      body: SafeArea(
        child: Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Stack(
            children: [
              Form(
                key: _formKey,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 140),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                      TSectionHeader('بيانات المريض'),
                      NeuCard(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                        child: Column(
                          children: [
                            NeuField(
                              controller: _nameCtrl,
                              labelText: 'اسم المريض',
                              validator: (v) => Validators.required(v,
                                  fieldName: 'اسم المريض'),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: NeuField(
                                    controller: _ageCtrl,
                                    labelText: 'العمر',
                                    keyboardType: TextInputType.number,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: NeuField(
                                    controller: _phoneCtrl,
                                    labelText: 'رقم الهاتف',
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
                      TSectionHeader('استخدام من المستودع'),
                      if (_existingUsages
                              .where((u) =>
                                  !_deletedUsageIds.contains(u['consId']))
                              .isNotEmpty ||
                          _newUsages.isNotEmpty) ...[
                        NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              ..._existingUsages
                                  .where((u) =>
                                      !_deletedUsageIds.contains(u['consId']))
                                  .map((u) => _usageChip(u, isNew: false)),
                              ..._newUsages
                                  .map((u) => _usageChip(u, isNew: true)),
                            ],
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
                      TSectionHeader('المرفقات'),
                      FutureBuilder<List<Attachment>>(
                        future: _attachmentsFuture,
                        builder: (c, snap) {
                          final existing = snap.data ?? [];
                          final all = [...existing, ..._newAttachments];
                          final visible = all
                              .where((a) => !_deletedAttachments.contains(a))
                              .toList();
                          if (all.isEmpty) {
                            return TOutlinedButton(
                              icon: Icons.attach_file,
                              label: 'إضافة مرفقات',
                              onPressed: _pickAttachments,
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (visible.isNotEmpty) ...[
                                NeuCard(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: all.map((a) {
                                      final isNew = _newAttachments.contains(a);
                                      final isDeleted =
                                          _deletedAttachments.contains(a);
                                      final text = a.fileName +
                                          (isNew ? ' (جديد)' : '') +
                                          (isDeleted ? ' (محذوف)' : '');
                                      return _RemovableChip(
                                        text: text,
                                        muted: isDeleted,
                                        onTap: isDeleted
                                            ? null
                                            : () => _openAttachment(a),
                                        onDelete: () {
                                          setState(() {
                                            if (isNew) {
                                              _newAttachments.remove(a);
                                            } else if (isDeleted) {
                                              _deletedAttachments.remove(a);
                                            } else {
                                              _deletedAttachments.add(a);
                                            }
                                          });
                                        },
                                      );
                                    }).toList(),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              TOutlinedButton(
                                icon: Icons.attach_file,
                                label: 'إضافة مرفقات',
                                onPressed: _pickAttachments,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      TSectionHeader('نوع الخدمة'),
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: DropdownButtonFormField<String>(
                          initialValue: _selectedServiceTypeAr,
                          decoration: const InputDecoration(
                            labelText: 'اختر نوع الخدمة',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'الأشعة', child: Text('الأشعة')),
                            DropdownMenuItem(
                                value: 'المختبر', child: Text('المختبر')),
                            DropdownMenuItem(
                                value: 'طبيب', child: Text('طبيب')),
                          ],
                          onChanged: _onServiceTypeChanged,
                          validator: (v) =>
                              v == null ? 'اختر نوع الخدمة' : null,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (isRadLab) ...[
                        TSectionHeader('الخدمات المتاحة'),
                        _buildServicesChips(),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: _selectDoctorForRadLab,
                          child: AbsorbPointer(
                            child: NeuField(
                              controller: _doctorCtrl,
                              labelText: 'الطبيب المختص',
                              suffix: const Icon(Icons.chevron_left_rounded),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      if (isDoctor) ...[
                        TSectionHeader('عيادة الطبيب'),
                        GestureDetector(
                          onTap: _selectDoctorForOther,
                          child: AbsorbPointer(
                            child: NeuField(
                              controller: _doctorCtrl,
                              labelText: 'عيادة الطبيب',
                              suffix: const Icon(Icons.chevron_left_rounded),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        NeuCard(
                          onTap: _selectDoctorGeneralService,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          child: Row(
                            children: const [
                              Icon(Icons.add_circle_outline,
                                  color: kPrimaryColor),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text('إضافة خدمة من عيادة الطبيب',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w700)),
                              ),
                              Icon(Icons.chevron_left_rounded),
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
                                labelText: 'خدمة/حالة نصيّة',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: NeuField(
                                controller: _manualCostCtrl,
                                labelText: 'تكلفة اليدوية',
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
                      if (_selectedServices.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        TSectionHeader('الخدمات المحدّدة'),
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
                      TSectionHeader('المبالغ'),
                      NeuCard(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                        child: Column(
                          children: [
                            NeuField(
                              controller: _totalCtrl,
                              labelText: 'المجموع الكلي للخدمات',
                              enabled: false,
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: NeuField(
                                    controller: _paidCtrl,
                                    labelText: 'المبلغ المقدم',
                                    keyboardType: TextInputType.number,
                                    onChanged: _onPaidChanged,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: NeuField(
                                    controller: _remainingCtrl,
                                    labelText: 'المتبقي (يُحسب تلقائيًا)',
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
                      TSectionHeader('ملاحظات'),
                      NeuField(
                        controller: _notesCtrl,
                        labelText: 'ملاحظات',
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
              ),
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
                              Text('الإجمالي: ${_totalCtrl.text}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 4),
                              Text('المتبقي: ${_remainingCtrl.text}'),
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
                          label: _saving ? 'جارٍ الحفظ...' : 'حفظ التعديلات',
                          onPressed: _saving ? null : _saveChanges,
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
        child: const Text('لا توجد خدمات محفوظة لهذا النوع'),
      );
    }
    return Directionality(
      textDirection: ui.TextDirection.rtl,
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
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
          ),
        ),
        if (action != null)
          Text(
            action!,
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .6),
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}

class _RemovableChip extends StatelessWidget {
  final String text;
  final VoidCallback onDelete;
  final VoidCallback? onTap;
  final bool muted;
  const _RemovableChip({
    required this.text,
    required this.onDelete,
    this.onTap,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor =
        muted ? scheme.onSurface.withValues(alpha: .45) : scheme.onSurface;
    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: TextStyle(color: textColor)),
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
