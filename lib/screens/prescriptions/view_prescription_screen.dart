// lib/screens/prescriptions/view_prescription_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/prescription.dart';
import 'package:aelmamclinic/models/prescription_item.dart';
import 'package:aelmamclinic/models/drug.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/prescription_pdf_service.dart';

/* تصميم TBIAN */
import 'package:aelmamclinic/core/neumorphism.dart';

class ViewPrescriptionScreen extends StatefulWidget {
  final int prescriptionId; // رقم الوصفة

  const ViewPrescriptionScreen({super.key, required this.prescriptionId});

  @override
  State<ViewPrescriptionScreen> createState() => _ViewPrescriptionScreenState();
}

class _ViewPrescriptionScreenState extends State<ViewPrescriptionScreen> {
  late Future<_LoadedData> _loader;

  @override
  void initState() {
    super.initState();
    _loader = _fetchAll();
  }

  /*────────────────── تحميل بيانات الوصفة كاملة ──────────────────*/
  Future<_LoadedData> _fetchAll() async {
    final db = await DBService.instance.database;

    // رأس الوصفة
    final presRow = (await db.query(
      'prescriptions',
      where: 'id = ?',
      whereArgs: [widget.prescriptionId],
      limit: 1,
    ))
        .first;
    final pres = Prescription.fromMap(presRow);

    // المريض
    final patientRow = (await db.query(
      'patients',
      where: 'id = ?',
      whereArgs: [pres.patientId],
      limit: 1,
    ))
        .first;
    final patient = Patient.fromMap(patientRow);

    // الطبيب (قد يكون null)
    Doctor? doctor;
    if (pres.doctorId != null) {
      final docRows = await db.query(
        'doctors',
        where: 'id = ?',
        whereArgs: [pres.doctorId],
        limit: 1,
      );
      if (docRows.isNotEmpty) doctor = Doctor.fromMap(docRows.first);
    }

    // عناصر الوصفة + تفاصيل الدواء
    final itemsRows = await db.query(
      'prescription_items',
      where: 'prescriptionId = ?',
      whereArgs: [pres.id],
      orderBy: 'id ASC',
    );

    final items = <PrescriptionItem>[];
    final drugs = <int, Drug>{};

    for (final it in itemsRows) {
      items.add(PrescriptionItem.fromMap(it));
      final dId = it['drugId'] as int;
      drugs[dId] ??= Drug.fromMap(
          (await db.query('drugs', where: 'id = ?', whereArgs: [dId])).first);
    }

    return _LoadedData(
      prescription: pres,
      patient: patient,
      doctor: doctor,
      items: items,
      drugs: drugs,
    );
  }

  /*────────────────── مشاركة PDF ──────────────────*/
  Future<void> _exportPdf(_LoadedData data) async {
    final itemsMapped = data.items
        .map<Map<String, dynamic>>((pi) => {
              'drug': data.drugs[pi.drugId]!,
              'days': pi.days,
              'times': pi.timesPerDay,
            })
        .toList();

    await PrescriptionPdfService.sharePdf(
      patient: data.patient,
      doctor: data.doctor,
      items: itemsMapped,
      recordDate: data.prescription.recordDate,
    );
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
          title: const Text('تفاصيل الوصفة'),
          elevation: 4,
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
          child: FutureBuilder<_LoadedData>(
            future: _loader,
            builder: (_, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snap.data!;
              final dateStr =
                  DateFormat('yyyy-MM-dd').format(data.prescription.recordDate);

              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: _InfoRow(
                        icon: Icons.person,
                        label: 'المريض',
                        value: data.patient.name,
                      ),
                    ),
                    const SizedBox(height: 10),
                    NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: _InfoRow(
                        icon: Icons.cake_outlined,
                        label: 'العمر',
                        value: data.patient.age.toString(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: _InfoRow(
                        icon: Icons.event,
                        label: 'التاريخ',
                        value: dateStr,
                      ),
                    ),
                    if (data.doctor != null) ...[
                      const SizedBox(height: 10),
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: _InfoRow(
                          icon: Icons.local_hospital,
                          label: 'الطبيب',
                          value: 'د/${data.doctor!.name}',
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'الأدوية',
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .85),
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: data.items.isEmpty
                          ? Center(
                              child: Text('لا توجد أدوية',
                                  style: TextStyle(
                                      color: scheme.onSurface
                                          .withValues(alpha: .6))),
                            )
                          : ListView.separated(
                              itemCount: data.items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, i) {
                                final it = data.items[i];
                                final drug = data.drugs[it.drugId]!;
                                return NeuCard(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10),
                                  child: Row(
                                    children: [
                                      Container(
                                        decoration: BoxDecoration(
                                          color: scheme.primary
                                              .withValues(alpha: .10),
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        padding: const EdgeInsets.all(10),
                                        child: Icon(Icons.medication_outlined,
                                            color: scheme.primary, size: 22),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              drug.name,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'أيام: ${it.days}  •  مرات/يوم: ${it.timesPerDay}',
                                              style: TextStyle(
                                                color: scheme.onSurface
                                                    .withValues(alpha: .7),
                                                fontSize: 13.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('تصدير PDF'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: scheme.primary,
                          foregroundColor: scheme.onPrimary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(25),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => _exportPdf(data),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/*──────── صف معلومات صغير بنمط TBIAN/Neumorphism ────────*/
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: scheme.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .85),
                    fontWeight: FontWeight.w800,
                  )),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 13.5,
                  )),
            ],
          ),
        ),
      ],
    );
  }
}

/*──────────────────── نموذج البيانات المجمع ────────────────────*/
class _LoadedData {
  final Prescription prescription;
  final Patient patient;
  final Doctor? doctor;
  final List<PrescriptionItem> items;
  final Map<int, Drug> drugs; // drugId → Drug

  _LoadedData({
    required this.prescription,
    required this.patient,
    required this.doctor,
    required this.items,
    required this.drugs,
  });
}
