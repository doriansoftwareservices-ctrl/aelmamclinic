// lib/screens/reminders/reminder_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aelmamclinic/utils/toast_utils.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/services/db_service.dart';

class ReminderScreen extends StatefulWidget {
  const ReminderScreen({super.key});

  @override
  State<ReminderScreen> createState() => _ReminderScreenState();
}

class _ReminderScreenState extends State<ReminderScreen> {
  final _searchCtrl = TextEditingController();
  final _dateTime = DateFormat('yyyy-MM-dd HH:mm');
  final _dateOnly = DateFormat('yyyy-MM-dd');

  List<ReturnEntry> _todayReturns = [];
  List<ReturnEntry> _filtered = [];

  bool _onlyUnseen = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_applyFilter);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _loadTodayReturns();
    _applyFilter();
  }

  /*──────── إحضار عودات تاريخ اليوم فقط ────────*/
  Future<void> _loadTodayReturns() async {
    setState(() => _loading = true);
    try {
      final all = await DBService.instance.getAllReturns();
      final now = DateTime.now();
      bool sameDay(DateTime a, DateTime b) =>
          a.year == b.year && a.month == b.month && a.day == b.day;
      _todayReturns = all.where((r) => sameDay(r.date, now)).toList()
        ..sort((a, b) => a.date.compareTo(b.date)); // الأقدم أولاً
    } catch (e) {
      await ToastUtils.show('فشل تحميل التذكيرات: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /*──────── تصفية (بحث + غير المُشاهَد فقط) ────────*/
  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _todayReturns.where((r) {
        final attended = r.isAttended;
        if (_onlyUnseen && attended) return false;

        final name = r.patientName.toLowerCase();
        final diag = r.diagnosis.toLowerCase();
        final phone = r.phoneNumber.toLowerCase();
        final txt = '$name $diag $phone';
        return q.isEmpty ? true : txt.contains(q);
      }).toList();
    });
  }

  Future<void> _refresh() async {
    await _loadTodayReturns();
    _applyFilter();
  }

  Future<void> _toggleSeen(ReturnEntry r) async {
    final id = r.id;
    if (id == null) return;
    await DBService.instance.setReturnAttended(id, !r.isAttended);
    await _loadTodayReturns();
    _applyFilter();
  }

  Future<void> _markAll(bool attended) async {
    final ids = _todayReturns.map((e) => e.id).whereType<int>().toList();
    await DBService.instance.setReturnsAttendedBulk(ids, attended);
    await _loadTodayReturns();
    _applyFilter();
  }

  Future<void> _call(String? phone) async {
    final p = (phone ?? '').trim();
    if (p.isEmpty) {
      await ToastUtils.show('لا يوجد رقم هاتف');
      return;
    }
    final uri = Uri(scheme: 'tel', path: p);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      await ToastUtils.show('لا يمكن إجراء المكالمة');
    }
  }

  /*──────────────────────────── UI ────────────────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final todayStr = _dateOnly.format(DateTime.now());

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('تذكيرات اليوم'),
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [scheme.primaryContainer, scheme.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _refresh,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'mark_all_seen') {
                  _markAll(true);
                }
                if (v == 'mark_all_unseen') {
                  _markAll(false);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'mark_all_seen',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.check_circle),
                    title: Text('تحديد الكل كـ حضر'),
                  ),
                ),
                PopupMenuItem(
                  value: 'mark_all_unseen',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.radio_button_unchecked),
                    title: Text('إلغاء تحديد الكل'),
                  ),
                ),
              ],
            ),
          ],
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
              // شريط علوي: بحث + فلاتر
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: InputDecoration(
                          hintText: 'ابحث باسم المريض / الهاتف / الحالة',
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
                    const SizedBox(width: 8),
                    Tooltip(
                      message: 'غير الحاضرين فقط',
                      child: FilterChip(
                        selected: _onlyUnseen,
                        onSelected: (v) {
                          setState(() => _onlyUnseen = v);
                          _applyFilter();
                        },
                        label: const Text('لم يحضر'),
                        showCheckmark: false,
                        selectedColor: scheme.primary.withValues(alpha: .15),
                        labelStyle: TextStyle(
                          color:
                              _onlyUnseen ? scheme.primary : scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                        side: BorderSide(
                            color: scheme.primary.withValues(alpha: .4)),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 6),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    children: [
                      Icon(Icons.event_available,
                          size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text('تاريخ اليوم: $todayStr',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .7),
                            fontWeight: FontWeight.w600,
                          )),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        color: scheme.primary,
                        onRefresh: _refresh,
                        child: _filtered.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 140),
                                  Center(
                                      child:
                                          Text('لا توجد عودات مستحقة اليوم')),
                                ],
                              )
                            : ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 8, 12, 16),
                                itemCount: _filtered.length,
                                itemBuilder: (ctx, i) {
                                  final r = _filtered[i];
                                  final attended = r.isAttended;
                                  final dateStr =
                                      _dateTime.format(r.date.toLocal());

                                  return Card(
                                    elevation: 2,
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 12),
                                      leading: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          CircleAvatar(
                                            radius: 24,
                                            backgroundColor:
                                                scheme.primaryContainer,
                                            child: Icon(Icons.person,
                                                color: scheme.primary),
                                          ),
                                          if (!attended)
                                            Positioned(
                                              right: -2,
                                              top: -2,
                                              child: CircleAvatar(
                                                radius: 6,
                                                backgroundColor:
                                                    Colors.redAccent,
                                              ),
                                            ),
                                        ],
                                      ),
                                      title: Text(
                                        r.patientName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800),
                                      ),
                                      subtitle: Text(
                                        'الحالة: ${r.diagnosis.isEmpty ? '—' : r.diagnosis}\nموعد العَود: $dateStr',
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: .75),
                                        ),
                                      ),
                                      trailing: Wrap(
                                        spacing: 4,
                                        children: [
                                          IconButton(
                                            tooltip: 'اتصال',
                                            icon: const Icon(Icons.phone),
                                            color: scheme.primary,
                                            onPressed: () =>
                                                _call(r.phoneNumber),
                                          ),
                                          IconButton(
                                            tooltip: attended
                                                ? 'إلغاء الحضور'
                                                : 'تحديد كـ حضر',
                                            icon: Icon(attended
                                                ? Icons.check_circle
                                                : Icons.radio_button_unchecked),
                                            color: scheme.primary,
                                            onPressed: () => _toggleSeen(r),
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
