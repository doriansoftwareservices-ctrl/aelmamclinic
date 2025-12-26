// lib/services/doctors_services_list_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/*── البيانات ─*/
import 'db_service.dart';
import 'package:aelmamclinic/models/doctor.dart';

/*── شاشة التفاصيل ─*/
import 'doctor_services_detail_screen.dart';

class DoctorsServicesListScreen extends StatefulWidget {
  const DoctorsServicesListScreen({super.key});

  @override
  State<DoctorsServicesListScreen> createState() =>
      _DoctorsServicesListScreenState();
}

class _DoctorsServicesListScreenState extends State<DoctorsServicesListScreen> {
  final _searchController = TextEditingController();

  bool _loading = true;
  String? _error;

  List<Doctor> _allDoctors = [];
  List<Doctor> _filteredDoctors = [];

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

  /*────────────────── البيانات ──────────────────*/
  Future<void> _loadDoctors() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final doctors = await DBService.instance.getAllDoctors();
      setState(() {
        _allDoctors = doctors;
        _filteredDoctors = doctors;
      });
    } catch (e) {
      setState(() => _error = 'فشل تحميل الأطباء: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filterDoctors() {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() => _filteredDoctors = List.of(_allDoctors));
      return;
    }
    setState(() {
      _filteredDoctors = _allDoctors.where((doc) {
        final name = (doc.name).toLowerCase();
        final spec = (doc.specialization).toLowerCase();
        final phone = (doc.phoneNumber).toLowerCase();
        return name.contains(q) || spec.contains(q) || phone.contains(q);
      }).toList();
    });
  }

  /*──────── بناء محتوى الجسم بدون if/else داخل القوائم ────────*/
  List<Widget> _buildBodyContent(ColorScheme scheme) {
    if (_loading) {
      return const [
        SizedBox(height: 100),
        Center(child: CircularProgressIndicator()),
      ];
    }
    if (_error != null) {
      return [
        _ErrorCard(message: _error!, onRetry: _loadDoctors),
      ];
    }
    if (_filteredDoctors.isEmpty) {
      return const [
        SizedBox(height: 80),
        Center(
          child: Text(
            'لا توجد نتائج',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ];
    }

    return [
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 6, bottom: 8),
        child: Text(
          'الأطباء: ${_filteredDoctors.length}',
          style: TextStyle(
            color: scheme.onSurface.withValues(alpha: .6),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),

      // القائمة (Neumorphism)
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: _filteredDoctors.map((doctor) {
          return SizedBox(
            width: 520,
            child: NeuCard(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: kPrimaryColor.withValues(alpha: .12),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Image.asset(
                        'assets/images/doctor.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.person, color: kPrimaryColor),
                      ),
                    ),
                  ),
                ),
                title: Text(
                  'د/ ${doctor.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  doctor.specialization,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(color: scheme.onSurface.withValues(alpha: .75)),
                ),
                trailing: const Icon(Icons.chevron_left_rounded),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          DoctorServicesDetailScreen(doctor: doctor),
                    ),
                  ).then((_) => _loadDoctors());
                },
              ),
            ),
          );
        }).toList(),
      ),
    ];
  }

  /*────────────────── الواجهة ──────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loadDoctors,
            ),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            color: scheme.primary,
            onRefresh: _loadDoctors,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                /*──────── رأس الصفحة ────────*/
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.medical_services_rounded,
                            color: kPrimaryColor, size: 22),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'خدمات الأطباء',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                /*──────── شريط البحث (TBIAN) ────────*/
                TSearchField(
                  controller: _searchController,
                  hint: 'ابحث عن الطبيب (الاسم/التخصص/الهاتف)…',
                  onChanged: (_) => _filterDoctors(),
                  onClear: () {
                    _searchController.clear();
                    _filterDoctors();
                  },
                ),

                const SizedBox(height: 12),

                // بقية المحتوى حسب الحالة
                ..._buildBodyContent(scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/*──────── بطاقة خطأ بنمط TBIAN ────────*/
class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
            label: const Text('إعادة المحاولة',
                style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: scheme.error,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}
