// lib/screens/doctors/list_doctors_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/export_service.dart';
import 'package:aelmamclinic/screens/doctors/edit_doctor_screen.dart';
import 'package:aelmamclinic/screens/doctors/view_doctor_screen.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class ListDoctorsScreen extends StatefulWidget {
  const ListDoctorsScreen({super.key});

  @override
  State<ListDoctorsScreen> createState() => _ListDoctorsScreenState();
}

class _ListDoctorsScreenState extends State<ListDoctorsScreen> {
  List<Doctor> _doctors = [];
  List<Doctor> _filteredDoctors = [];
  final TextEditingController _searchController = TextEditingController();
  static const int _pageSize = 50;
  int _visibleCount = 0;

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
    final doctorsList = await DBService.instance.getAllDoctors();
    if (!mounted) return;
    setState(() {
      _doctors = doctorsList;
      _filteredDoctors = doctorsList;
      _visibleCount =
          _filteredDoctors.length < _pageSize ? _filteredDoctors.length : _pageSize;
    });
  }

  void _filterDoctors() {
    final q = _searchController.text.toLowerCase().trim();
    setState(() {
      _filteredDoctors = _doctors.where((d) {
        return d.name.toLowerCase().contains(q) ||
            d.specialization.toLowerCase().contains(q) ||
            d.phoneNumber.toLowerCase().contains(q);
      }).toList();
      _visibleCount =
          _filteredDoctors.length < _pageSize ? _filteredDoctors.length : _pageSize;
    });
  }

  Future<void> _deleteDoctor(int doctorId) async {
    await DBService.instance.deleteDoctor(doctorId);
    _loadDoctors();
  }

  void _makePhoneCall(String phoneNumber) async {
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('لا يمكن إجراء المكالمة')),
      );
    }
  }

  Future<void> _shareDoctorsFile() async {
    if (_filteredDoctors.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('لا توجد بيانات للمشاركة')),
      );
      return;
    }
    try {
      final bytes = await ExportService.exportDoctorsToExcel(_filteredDoctors);
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/قائمة-الأطباء.xlsx');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'قائمة الأطباء',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('حدث خطأ أثناء المشاركة: $e')),
      );
    }
  }

  Future<void> _downloadDoctorsFile() async {
    if (_filteredDoctors.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('لا توجد بيانات للتنزيل')),
      );
      return;
    }
    try {
      final bytes = await ExportService.exportDoctorsToExcel(_filteredDoctors);
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/قائمة-الأطباء.xlsx';
      await File(path).writeAsBytes(bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تم التنزيل إلى: $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('حدث خطأ أثناء التنزيل: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visibleDoctors = _filteredDoctors.take(_visibleCount).toList();
    final hasMore = _visibleCount < _filteredDoctors.length;

    return Directionality(
      textDirection: Directionality.of(context),
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
              const LocalizedText('قائمة الأطباء'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: context.trRaw('مشاركة'),
              onPressed: _shareDoctorsFile,
              icon: const Icon(Icons.ios_share_rounded),
            ),
            IconButton(
              tooltip: context.trRaw('تنزيل'),
              onPressed: _downloadDoctorsFile,
              icon: const Icon(Icons.download_rounded),
            ),
          ],
        ),
        body: Padding(
          padding: kScreenPadding,
          child: Column(
            children: [
              // شريط البحث بنمط TBIAN
              NeuField(
                controller: _searchController,
                hintText: context.trRaw('ابحث عن طبيب…'),
                prefix: const Icon(Icons.search_rounded),
              ),
              const SizedBox(height: 12),

              Expanded(
                child: _filteredDoctors.isEmpty
                    ? Center(
                        child: LocalizedText('لا توجد نتائج',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .6),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: visibleDoctors.length + (hasMore ? 1 : 0),
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          if (index >= visibleDoctors.length) {
                            return Center(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.expand_more_rounded),
                                label: LocalizedText('تحميل المزيد (${_visibleCount}/${_filteredDoctors.length})',
                                ),
                                onPressed: () {
                                  setState(() {
                                    _visibleCount =
                                        (_visibleCount + _pageSize).clamp(
                                      0,
                                      _filteredDoctors.length,
                                    );
                                  });
                                },
                              ),
                            );
                          }
                          final d = visibleDoctors[index];

                          return NeuCard(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ViewDoctorScreen(doctor: d),
                                  ),
                                );
                              },
                              leading: Container(
                                decoration: BoxDecoration(
                                  color: kPrimaryColor.withValues(
                                    alpha: .10,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.all(10),
                                child: const Icon(
                                  Icons.medical_information_rounded,
                                  size: 24,
                                  color: kPrimaryColor,
                                ),
                              ),
                              title: LocalizedText('د/ ${d.name}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              subtitle: Text(
                                d.specialization,
                                style: TextStyle(
                                  color: scheme.onSurface.withValues(
                                    alpha: .65,
                                  ),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              trailing: PopupMenuButton<String>(
                                tooltip: context.trRaw('خيارات'),
                                itemBuilder: (ctx) => [
                                  PopupMenuItem(
                                    value: 'call',
                                    child: Row(
                                      children: const [
                                        Icon(Icons.phone_rounded, size: 20),
                                        SizedBox(width: 8),
                                        LocalizedText('اتصال'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: const [
                                        Icon(Icons.edit_rounded, size: 20),
                                        SizedBox(width: 8),
                                        LocalizedText('تعديل'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: const [
                                        Icon(
                                          Icons.delete_rounded,
                                          size: 20,
                                          color: Colors.red,
                                        ),
                                        SizedBox(width: 8),
                                        LocalizedText('حذف'),
                                      ],
                                    ),
                                  ),
                                ],
                                onSelected: (value) {
                                  switch (value) {
                                    case 'call':
                                      if (d.phoneNumber.isNotEmpty) {
                                        _makePhoneCall(d.phoneNumber);
                                      } else {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: LocalizedText('لا يوجد رقم هاتف'),
                                          ),
                                        );
                                      }
                                      break;
                                    case 'edit':
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              EditDoctorScreen(doctor: d),
                                        ),
                                      ).then((_) => _loadDoctors());
                                      break;
                                    case 'delete':
                                      _deleteDoctor(d.id!);
                                      break;
                                  }
                                },
                              ),
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
