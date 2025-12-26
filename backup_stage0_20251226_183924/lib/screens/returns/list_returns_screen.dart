// lib/screens/returns/list_returns_screen.dart
import 'dart:io';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/export_service.dart';
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/providers/appointment_provider.dart';
import 'package:aelmamclinic/screens/reminders/reminder_screen.dart';
import 'package:aelmamclinic/services/notification_service.dart';
import 'view_returns_screen.dart';

class ListReturnsScreen extends StatefulWidget {
  const ListReturnsScreen({super.key});

  @override
  State<ListReturnsScreen> createState() => _ListReturnsScreenState();
}

class _ListReturnsScreenState extends State<ListReturnsScreen> {
  List<ReturnEntry> _returns = [];
  List<ReturnEntry> _filteredReturns = [];
  final TextEditingController _searchController = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;

  final _dateOnly = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _requestNotificationPermission();
    tz_data.initializeTimeZones();
    _loadReturns();
    _searchController.addListener(_applyFilters);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /*────────────────── الأذونات ──────────────────*/
  Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.status;
    if (status.isDenied || status.isRestricted) {
      final result = await Permission.notification.request();
      if (result.isDenied) {
        Fluttertoast.showToast(
          msg: 'هذا التطبيق يحتاج إلى إذن الإشعارات لتذكيرك بمواعيد العودات.',
          toastLength: Toast.LENGTH_LONG,
          gravity: ToastGravity.BOTTOM,
        );
      }
      if (result.isPermanentlyDenied) {
        Fluttertoast.showToast(
          msg: 'يرجى تمكين الإشعارات من إعدادات التطبيق.',
          toastLength: Toast.LENGTH_LONG,
          gravity: ToastGravity.BOTTOM,
        );
        openAppSettings();
      }
    }
  }

  /*────────────────── تحميل البيانات ──────────────────*/
  Future<void> _loadReturns() async {
    try {
      final data = await DBService.instance.getAllReturns();
      setState(() {
        _returns = data;
        _filteredReturns = data;
      });
      Provider.of<AppointmentProvider>(context, listen: false)
          .loadAppointments();
    } catch (e) {
      Fluttertoast.showToast(msg: 'فشل في تحميل العودات: $e');
    }
  }

  /*────────────────── اختيار التواريخ ──────────────────*/
  Future<void> _pickStartDate() async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: scheme.copyWith(primary: kPrimaryColor),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _startDate = picked);
  }

  Future<void> _pickEndDate() async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: scheme.copyWith(primary: kPrimaryColor),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _endDate = picked);
  }

  void _resetDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _applyFilters();
  }

  /*────────────────── تطبيق الفلاتر ──────────────────*/
  void _applyFilters() {
    final query = _searchController.text.toLowerCase().trim();
    final List<ReturnEntry> tmp = _returns.where((r) {
      final match = r.patientName.toLowerCase().contains(query) ||
          r.phoneNumber.toLowerCase().contains(query) ||
          r.doctor.toLowerCase().contains(query);
      bool inRange = true;
      if (_startDate != null) {
        inRange = r.date.isAfter(_startDate!.subtract(const Duration(days: 1)));
      }
      if (_endDate != null && inRange) {
        inRange = r.date.isBefore(_endDate!.add(const Duration(days: 1)));
      }
      return match && inRange;
    }).toList();
    setState(() => _filteredReturns = tmp);
  }

  /*────────────────── حذف ──────────────────*/
  Future<void> _deleteReturn(int? id) async {
    if (id == null) {
      Fluttertoast.showToast(msg: 'معرف العودة غير صالح.');
      return;
    }
    try {
      await NotificationService().cancelNotification(id % 1000000);
      final res = await DBService.instance.deleteReturn(id);
      if (res > 0) {
        Fluttertoast.showToast(msg: 'تم حذف العودة بنجاح.');
        await _loadReturns();
      } else {
        Fluttertoast.showToast(msg: 'لم يتم العثور على العودة لحذفها.');
      }
      Provider.of<AppointmentProvider>(context, listen: false)
          .loadAppointments();
    } catch (e) {
      Fluttertoast.showToast(msg: 'فشل في حذف العودة: $e');
    }
  }

  /*────────────────── تصدير / مشاركة ──────────────────*/
  Future<void> _shareFile() async {
    if (_filteredReturns.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد عودات للمشاركة')),
      );
      return;
    }
    try {
      final bytes = await ExportService.exportReturnsToExcel(_filteredReturns);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/كشف-العودات.xlsx');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'كشف العودات المحفوظ',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء المشاركة: $e')),
      );
    }
  }

  Future<void> _downloadFile() async {
    if (_filteredReturns.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد عودات للتنزيل')),
      );
      return;
    }
    try {
      final bytes = await ExportService.exportReturnsToExcel(_filteredReturns);
      await saveExcelFile(bytes, 'كشف-العودات.xlsx');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء التنزيل: $e')),
      );
    }
  }

  /*────────────────── اتصال هاتفى ──────────────────*/
  Future<void> _makePhoneCall(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      Fluttertoast.showToast(msg: 'لا يمكن إجراء المكالمة');
    }
  }

  @override
  Widget build(BuildContext context) {
    /* ─── شرط الجرس: عودات بتاريخ اليوم بالضبط ─── */
    final today = DateTime.now();
    bool isSameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    final hasDue = _filteredReturns.any((r) => isSameDay(r.date, today));

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Consumer<AppointmentProvider>(
        builder: (ctx, appt, child) {
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
              actions: [
                IconButton(
                  icon: const Icon(Icons.share),
                  tooltip: 'مشاركة العودات كملف Excel',
                  onPressed: _shareFile,
                ),
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'تنزيل العودات كملف Excel',
                  onPressed: _downloadFile,
                ),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      tooltip: 'التذكيرات',
                      icon: Image.asset(
                        hasDue
                            ? 'assets/images/bell_icon1.png'
                            : 'assets/images/bell_icon2.png',
                        width: 22,
                        height: 22,
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ReminderScreen()),
                        );
                      },
                    ),
                    if (hasDue)
                      const Positioned(
                        right: 8,
                        top: 8,
                        child: CircleAvatar(
                          radius: 5,
                          backgroundColor: Colors.red,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  // شريط البحث بنمط TBIAN
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: TSearchField(
                      controller: _searchController,
                      hint: 'ابحث عن اسم المريض أو رقم الهاتف أو الطبيب…',
                      onChanged: (_) => _applyFilters(),
                      onClear: () {
                        _searchController.clear();
                        _applyFilters();
                      },
                    ),
                  ),
                  const SizedBox(height: 10),

                  // فلاتر التاريخ + أزرار
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TDateButton(
                            icon: Icons.calendar_month_rounded,
                            label: _startDate == null
                                ? 'من تاريخ'
                                : _dateOnly.format(_startDate!),
                            onTap: _pickStartDate,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TDateButton(
                            icon: Icons.event_rounded,
                            label: _endDate == null
                                ? 'إلى تاريخ'
                                : _dateOnly.format(_endDate!),
                            onTap: _pickEndDate,
                          ),
                        ),
                        const SizedBox(width: 10),
                        NeuButton.flat(
                          icon: Icons.refresh_rounded,
                          label: 'عرض',
                          onPressed: _applyFilters,
                        ),
                        const SizedBox(width: 10),
                        TOutlinedButton(
                          icon: Icons.clear_all_rounded,
                          label: 'مسح',
                          onPressed: (_startDate == null && _endDate == null)
                              ? null
                              : _resetDates,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // القائمة
                  Expanded(
                    child: RefreshIndicator(
                      color: Theme.of(context).colorScheme.primary,
                      onRefresh: _loadReturns,
                      child: _filteredReturns.isEmpty
                          ? const Center(child: Text('لا توجد عودات لعرضها'))
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              itemCount: _filteredReturns.length,
                              itemBuilder: (ctx, i) {
                                final r = _filteredReturns[i];
                                final formatted = DateFormat('yyyy-MM-dd HH:mm')
                                    .format(r.date.toLocal());
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: NeuCard(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 8),
                                    child: InkWell(
                                      borderRadius:
                                          BorderRadius.circular(kRadius),
                                      onTap: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => ViewReturnScreen(
                                                returnEntry: r),
                                          ),
                                        );
                                      },
                                      child: ListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 4),
                                        leading: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: const SizedBox(
                                            width: 44,
                                            height: 44,
                                            child: Image(
                                              image: AssetImage(
                                                  'assets/images/patient.png'),
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          r.patientName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800),
                                        ),
                                        subtitle: Text(
                                          'الحالة: ${r.diagnosis}\nتاريخ ووقت العود: $formatted',
                                          style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: .75),
                                            height: 1.25,
                                          ),
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              tooltip: 'اتصال',
                                              icon: const Icon(Icons.phone),
                                              color: kPrimaryColor,
                                              onPressed: () {
                                                if (r.phoneNumber.isNotEmpty) {
                                                  _makePhoneCall(r.phoneNumber);
                                                } else {
                                                  Fluttertoast.showToast(
                                                      msg: 'لا يوجد رقم هاتف');
                                                }
                                              },
                                            ),
                                            IconButton(
                                              tooltip: 'حذف',
                                              icon: const Icon(
                                                  Icons.delete_outline),
                                              color: Colors.red.shade700,
                                              onPressed: () =>
                                                  _deleteReturn(r.id),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),

                  // شريط سفلي للإجراءات السريعة (مشاركة/تنزيل)
                  NeuCard(
                    margin: EdgeInsets.zero,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: SafeArea(
                      top: false,
                      child: Row(
                        children: [
                          Expanded(
                            child: TOutlinedButton(
                              icon: Icons.share,
                              label: 'مشاركة Excel',
                              onPressed: _shareFile,
                            ),
                          ),
                          const SizedBox(width: 10),
                          NeuButton.flat(
                            icon: Icons.download_rounded,
                            label: 'تنزيل Excel',
                            onPressed: _downloadFile,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
