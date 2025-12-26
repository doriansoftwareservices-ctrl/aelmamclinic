// lib/screens/patients/patient_picker_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/core/formatters.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/db_service.dart';

class PatientPickerScreen extends StatefulWidget {
  const PatientPickerScreen({super.key});

  /// الاستخدام:
  /// final picked = await Navigator.push<Patient?>(
  ///   context,
  ///   MaterialPageRoute(builder: (_) => const PatientPickerScreen()),
  /// );

  @override
  State<PatientPickerScreen> createState() => _PatientPickerScreenState();
}

class _PatientPickerScreenState extends State<PatientPickerScreen> {
  final _searchCtrl = TextEditingController();

  List<Patient> _patients = [];
  List<Patient> _filteredPatients = [];

  /// تجميع المرضى حسب هاتف مُطبّع أو مفتاح فريد لمن لا يملك هاتف
  final Map<String, List<Patient>> _patientsByKey = {};

  bool _loading = true;
  final _dateOnly = DateFormat('yyyy-MM-dd');
  final _dateTime = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    _loadPatients();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_applyFilter);
    _searchCtrl.dispose();
    super.dispose();
  }

  String _normPhone(String phone) => Formatters.normalizePhone(phone);

  /*──────── تحميل المرضى ────────*/
  Future<void> _loadPatients() async {
    setState(() => _loading = true);
    try {
      final list = await DBService.instance.getAllPatients();

      final grouped = <String, List<Patient>>{};
      for (final p in list) {
        final raw = p.phoneNumber.trim();
        final key = raw.isEmpty ? 'NO_PHONE_${p.id}' : _normPhone(raw);
        grouped.putIfAbsent(key, () => []).add(p);
      }

      // ترتيب داخلي لكل مجموعة (الأحدث أولًا)
      grouped.updateAll((_, grp) {
        final g = [...grp]
          ..sort((a, b) => b.registerDate.compareTo(a.registerDate));
        return g;
      });

      // الممثل = أحدث زيارة داخل كل مجموعة
      final reps = <Patient>[];
      grouped.forEach((_, grp) => reps.add(grp.first));
      reps.sort((a, b) => b.registerDate.compareTo(a.registerDate));

      setState(() {
        _patientsByKey
          ..clear()
          ..addAll(grouped);
        _patients = reps;
        _filteredPatients = reps;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل تحميل البيانات: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /*──────── فلترة البحث ────────*/
  void _applyFilter() {
    final raw = _searchCtrl.text;
    final qText = Formatters.normalizeForSearch(raw);
    final qTel = Formatters.normalizePhone(raw);

    setState(() {
      _filteredPatients = _patients.where((p) {
        final nameN = Formatters.normalizeForSearch(p.name);
        final phoneN = Formatters.normalizePhone(p.phoneNumber);
        final byName = qText.isEmpty ? true : nameN.contains(qText);
        final byPhone = qTel.isEmpty ? false : phoneN.contains(qTel);
        return byName || byPhone;
      }).toList();
    });
  }

  Future<void> _onTileTap(Patient rep) async {
    // نفس مفتاح التجميع المستخدم عند التحميل
    final hasPhone = rep.phoneNumber.trim().isNotEmpty;
    final key = hasPhone ? _normPhone(rep.phoneNumber) : 'NO_PHONE_${rep.id}';

    final repsList = _patientsByKey[key] ?? [rep];

    if (repsList.length == 1) {
      if (mounted) Navigator.pop(context, repsList.first);
      return;
    }

    // عند التعدد: BottomSheet لاختيار الزيارة (الأحدث أولًا)
    final picked = await showModalBottomSheet<Patient>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final sorted = [...repsList]
          ..sort((a, b) => b.registerDate.compareTo(a.registerDate));
        final scheme = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    'اختر زيارة لـ ${rep.name}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: sorted.length,
                      itemBuilder: (_, i) {
                        final p = sorted[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          child: ListTile(
                            leading: const Icon(Icons.event_note),
                            title: Text(_dateTime.format(p.registerDate)),
                            subtitle: Text(
                              (p.phoneNumber.trim().isEmpty)
                                  ? 'بدون هاتف'
                                  : p.phoneNumber,
                            ),
                            onTap: () => Navigator.pop(ctx, p),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (picked != null && mounted) {
      Navigator.pop(context, picked);
    }
  }

  /*────────────────────────── واجهة المستخدم ─────────────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('اختيار المريض'),
          centerTitle: true,
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
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'ابحث بالاسم أو الهاتف',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              _applyFilter();
                            },
                          ),
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
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _loadPatients,
                        color: scheme.primary,
                        child: _filteredPatients.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 160),
                                  Center(child: Text('لا توجد نتائج')),
                                ],
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: _filteredPatients.length,
                                itemBuilder: (_, i) {
                                  final rep = _filteredPatients[i];
                                  final hasPhone =
                                      rep.phoneNumber.trim().isNotEmpty;
                                  final key = hasPhone
                                      ? _normPhone(rep.phoneNumber)
                                      : 'NO_PHONE_${rep.id}';
                                  final repsList = _patientsByKey[key] ?? [rep];
                                  final regDate =
                                      _dateOnly.format(rep.registerDate);

                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    elevation: 2,
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                      leading: CircleAvatar(
                                        radius: 22,
                                        backgroundColor:
                                            scheme.primaryContainer,
                                        child: Text(
                                          rep.name.trim().isEmpty
                                              ? '—'
                                              : rep.name.characters.first
                                                  .toUpperCase(),
                                          style: TextStyle(
                                            color: scheme.primary,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      title: Text(
                                        rep.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Text(
                                        '$regDate • ${hasPhone ? rep.phoneNumber : 'بدون هاتف'}',
                                      ),
                                      trailing: (repsList.length > 1)
                                          ? Chip(
                                              label: Text(
                                                  '${repsList.length} زيارات'),
                                              backgroundColor: scheme
                                                  .primaryContainer
                                                  .withValues(alpha: .35),
                                            )
                                          : null,
                                      onTap: () => _onTileTap(rep),
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
