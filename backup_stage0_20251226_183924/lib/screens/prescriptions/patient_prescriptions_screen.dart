// lib/screens/prescriptions/patient_prescriptions_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/core/formatters.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/prescription.dart';
import 'package:aelmamclinic/services/db_service.dart';

import 'new_prescription_screen.dart';
import 'view_prescription_screen.dart';

class PatientPrescriptionsScreen extends StatefulWidget {
  const PatientPrescriptionsScreen({super.key});

  @override
  State<PatientPrescriptionsScreen> createState() =>
      _PatientPrescriptionsScreenState();
}

class _PatientPrescriptionsScreenState
    extends State<PatientPrescriptionsScreen> {
  final _searchCtrl = TextEditingController();

  /// قائمة المرضى الموحَّدة بعد إزالة التكرار (مُمثّل كل مجموعة)
  List<Patient> _patients = [];
  List<Patient> _filteredPatients = [];

  /// تجميع المرضى حسب مفتاح موحّد (هاتف مُطبّع أو معرّف فريد بدون هاتف)
  final Map<String, List<Patient>> _patientsByKey = {};

  /// مجموعة العناصر الممدّدة (بالمفتاح بدلاً من id لتفادي null)
  final Set<String> _expandedKeys = {};

  bool _loading = true;

  final _dateOnly = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _loadPatients();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_filter);
    _searchCtrl.dispose();
    super.dispose();
  }

  String _makeKey(Patient p) {
    final phone = Formatters.normalizePhone(p.phoneNumber);
    return phone.isEmpty ? 'ID:${p.id ?? p.hashCode}' : phone;
  }

  /*──────────────── تحميل المرضى ────────────────*/
  Future<void> _loadPatients() async {
    setState(() {
      _loading = true;
      _expandedKeys.clear();
    });

    final list = await DBService.instance.getAllPatients();

    // تجميع حسب هاتف مُطبّع أو مفتاح فريد لمن لا يملك هاتف
    final grouped = <String, List<Patient>>{};
    for (final p in list) {
      final key = _makeKey(p);
      grouped.putIfAbsent(key, () => []).add(p);
    }

    // رتب كل مجموعة داخلياً (الأحدث أولاً) ثم خذ ممثلاً عنها
    grouped.updateAll((_, grp) {
      final g = [...grp]
        ..sort((a, b) => b.registerDate.compareTo(a.registerDate));
      return g;
    });
    final reps = <Patient>[];
    grouped.forEach((_, grp) => reps.add(grp.first));
    reps.sort((a, b) => b.registerDate.compareTo(a.registerDate));

    setState(() {
      _patientsByKey
        ..clear()
        ..addAll(grouped);
      _patients = reps;
      _filteredPatients = reps;
      _loading = false;
    });
  }

  /*──────────────── فلترة البحث ────────────────*/
  void _filter() {
    final raw = _searchCtrl.text;
    final q = Formatters.normalizeForSearch(raw);
    setState(() {
      _filteredPatients = _patients.where((p) {
        final nameN = Formatters.normalizeForSearch(p.name);
        final phoneN = Formatters.normalizeForSearch(p.phoneNumber);
        return nameN.contains(q) || phoneN.contains(q);
      }).toList();
    });
  }

  /*──────────────── جلب وصفات مريض بحسب المفتاح ─────────────*/
  Future<List<Prescription>> _getPrescriptionsByKey(String key) async {
    final reps = _patientsByKey[key] ?? const <Patient>[];
    if (reps.isEmpty) return [];
    final ids = reps.where((p) => p.id != null).map((p) => p.id!).toList();
    if (ids.isEmpty) return [];

    final db = await DBService.instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'prescriptions',
      where: 'patientId IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'recordDate DESC',
    );
    return rows.map((m) => Prescription.fromMap(m)).toList();
  }

  /*──────────────────────────── UI ────────────────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('اختر المريض - الوصفات'),
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [scheme.primaryContainer, scheme.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.surfaceContainerHigh,
                scheme.surface,
                scheme.surfaceContainerHigh
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Column(
            children: [
              // بحث
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'بحث عن اسم أو رقم هاتف',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: scheme.surface,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(25),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              // القائمة
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        color: scheme.primary,
                        onRefresh: _loadPatients,
                        child: _filteredPatients.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 140),
                                  Center(child: Text('لا توجد نتائج')),
                                ],
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: _filteredPatients.length,
                                itemBuilder: (_, i) {
                                  final rep = _filteredPatients[i];
                                  final key = _makeKey(rep);
                                  final exp = _expandedKeys.contains(key);
                                  final repsList = _patientsByKey[key] ?? [rep];
                                  final phoneRaw = rep.phoneNumber;
                                  final phoneShown =
                                      Formatters.normalizePhone(phoneRaw)
                                              .isEmpty
                                          ? 'بدون هاتف'
                                          : phoneRaw;
                                  final regDate =
                                      _dateOnly.format(rep.registerDate);

                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    elevation: 2,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14)),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 6),
                                      child: Column(
                                        children: [
                                          ListTile(
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 6),
                                            leading: CircleAvatar(
                                              radius: 22,
                                              backgroundColor:
                                                  scheme.primaryContainer,
                                              child: Icon(Icons.person,
                                                  color: scheme.primary),
                                            ),
                                            title: Text(
                                              rep.name,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w800),
                                            ),
                                            subtitle: Text(
                                              '$regDate  •  $phoneShown',
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: .7),
                                              ),
                                            ),
                                            trailing: IconButton(
                                              icon: Icon(
                                                exp
                                                    ? Icons.expand_less
                                                    : Icons.expand_more,
                                                color: scheme.primary,
                                              ),
                                              onPressed: () => setState(() {
                                                exp
                                                    ? _expandedKeys.remove(key)
                                                    : _expandedKeys.add(key);
                                              }),
                                            ),
                                            onTap: () => setState(() {
                                              exp
                                                  ? _expandedKeys.remove(key)
                                                  : _expandedKeys.add(key);
                                            }),
                                          ),
                                          AnimatedCrossFade(
                                            firstChild: const SizedBox.shrink(),
                                            secondChild: Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      12, 0, 12, 12),
                                              child: FutureBuilder<
                                                  List<Prescription>>(
                                                future:
                                                    _getPrescriptionsByKey(key),
                                                builder: (_, snap) {
                                                  if (snap.connectionState ==
                                                      ConnectionState.waiting) {
                                                    return const Padding(
                                                      padding:
                                                          EdgeInsets.all(8),
                                                      child:
                                                          LinearProgressIndicator(),
                                                    );
                                                  }
                                                  final pres = snap.data ??
                                                      const <Prescription>[];

                                                  return Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .stretch,
                                                    children: [
                                                      ElevatedButton.icon(
                                                        style: ElevatedButton
                                                            .styleFrom(
                                                          backgroundColor:
                                                              scheme.primary,
                                                          foregroundColor:
                                                              scheme.onPrimary,
                                                          shape:
                                                              RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        25),
                                                          ),
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  vertical: 10),
                                                        ),
                                                        icon: const Icon(
                                                            Icons.add),
                                                        label: const Text(
                                                            'إضافة وصفة'),
                                                        onPressed: () async {
                                                          final repPatient =
                                                              repsList.first;
                                                          await Navigator.push(
                                                            context,
                                                            MaterialPageRoute(
                                                              builder: (_) =>
                                                                  NewPrescriptionScreen(
                                                                patient:
                                                                    repPatient,
                                                              ),
                                                            ),
                                                          );
                                                          await _loadPatients();
                                                        },
                                                      ),
                                                      const SizedBox(height: 8),
                                                      if (pres.isEmpty)
                                                        const Text(
                                                          'لا توجد وصفات سابقة',
                                                          style: TextStyle(
                                                              color:
                                                                  Colors.grey),
                                                          textAlign:
                                                              TextAlign.center,
                                                        )
                                                      else
                                                        ListView.separated(
                                                          shrinkWrap: true,
                                                          physics:
                                                              const NeverScrollableScrollPhysics(),
                                                          itemCount:
                                                              pres.length,
                                                          separatorBuilder: (_,
                                                                  __) =>
                                                              const Divider(
                                                                  height: .5,
                                                                  thickness:
                                                                      .5),
                                                          itemBuilder: (_, k) {
                                                            final pr = pres[k];
                                                            final dateStr =
                                                                _dateOnly.format(
                                                                    pr.recordDate);
                                                            return ListTile(
                                                              leading:
                                                                  Container(
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color: scheme
                                                                      .primary
                                                                      .withValues(
                                                                          alpha:
                                                                              .10),
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              12),
                                                                ),
                                                                padding:
                                                                    const EdgeInsets
                                                                        .all(8),
                                                                child: Icon(
                                                                  Icons
                                                                      .description_outlined,
                                                                  color: scheme
                                                                      .primary,
                                                                  size: 20,
                                                                ),
                                                              ),
                                                              title: Text(
                                                                'وصفة $dateStr',
                                                                style:
                                                                    const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                ),
                                                              ),
                                                              trailing:
                                                                  const Icon(Icons
                                                                      .chevron_left_rounded),
                                                              onTap: () =>
                                                                  Navigator
                                                                      .push(
                                                                context,
                                                                MaterialPageRoute(
                                                                  builder: (_) =>
                                                                      ViewPrescriptionScreen(
                                                                    prescriptionId:
                                                                        pr.id!,
                                                                  ),
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                    ],
                                                  );
                                                },
                                              ),
                                            ),
                                            crossFadeState: exp
                                                ? CrossFadeState.showSecond
                                                : CrossFadeState.showFirst,
                                            duration: const Duration(
                                                milliseconds: 200),
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
    );
  }
}
