// lib/screens/doctors/doctors_patients_screen.dart

import 'package:flutter/material.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'patients_by_doctor_screen.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class DoctorsPatientsScreen extends StatefulWidget {
  const DoctorsPatientsScreen({super.key});

  @override
  State<DoctorsPatientsScreen> createState() => _DoctorsPatientsScreenState();
}

class _DoctorsPatientsScreenState extends State<DoctorsPatientsScreen> {
  List<Doctor> _doctors = [];
  List<Doctor> _filteredDoctors = [];
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadDoctors();
    _searchController.addListener(_filterDoctors);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterDoctors);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadDoctors() async {
    final doctors = await DBService.instance.getAllDoctors();
    setState(() {
      _doctors = doctors;
      _filteredDoctors = doctors;
    });
  }

  void _filterDoctors() {
    final q = _searchController.text.trim().toLowerCase();
    setState(() {
      _filteredDoctors = _doctors.where((d) {
        return d.name.toLowerCase().contains(q) ||
            d.specialization.toLowerCase().contains(q) ||
            d.phoneNumber.toLowerCase().contains(q);
      }).toList();
    });
  }

  void _openDoctor(Doctor d) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PatientsByDoctorScreen(doctor: d)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
            const Text('مرضى الأطباء'),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: Column(
            children: [
              // حقل البحث (نيومورفيزم)
              NeuField(
                controller: _searchController,
                hintText: 'ابحث عن طبيب بالاسم/التخصص/الهاتف...',
                prefix: const Icon(Icons.search_rounded),
              ),
              const SizedBox(height: 12),

              // قائمة الأطباء
              Expanded(
                child: _filteredDoctors.isEmpty
                    ? Center(
                        child: NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 16),
                          child: Text(
                            'لا توجد نتائج',
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: .7),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filteredDoctors.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        padding: const EdgeInsets.only(bottom: 8),
                        itemBuilder: (context, i) {
                          final d = _filteredDoctors[i];
                          return NeuCard(
                            onTap: () => _openDoctor(d),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            child: Row(
                              children: [
                                // أيقونة/صورة يسار
                                Container(
                                  decoration: BoxDecoration(
                                    color: kPrimaryColor.withValues(alpha: .08),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.all(10),
                                  child: const Icon(
                                    Icons.person_rounded,
                                    size: 26,
                                    color: kPrimaryColor,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // نصوص
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'د/ ${d.name}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scheme.onSurface,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        d.specialization,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scheme.onSurface
                                              .withValues(alpha: .65),
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                // زر عرض (اختياري – يمكن النقر على البطاقة أيضاً)
                                NeuButton.flat(
                                  label: 'عرض',
                                  icon: Icons.open_in_new_rounded,
                                  onPressed: () => _openDoctor(d),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
