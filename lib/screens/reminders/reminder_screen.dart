// lib/screens/reminders/reminder_screen.dart
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aelmamclinic/utils/toast_utils.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class ReminderScreen extends StatefulWidget {
  const ReminderScreen({super.key});

  @override
  State<ReminderScreen> createState() => _ReminderScreenState();
}

class _ReminderScreenState extends State<ReminderScreen> {
  final _searchCtrl = TextEditingController();
  DateFormat get _dateTime => AppFormatters.dateFormat('yyyy-MM-dd HH:mm');
  DateFormat get _dateOnly => AppFormatters.dateFormat('yyyy-MM-dd');

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
              const LocalizedText('تذكيرات اليوم'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: context.trRaw('تحديث'),
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _refresh,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'mark_all_seen') _markAll(true);
                if (v == 'mark_all_unseen') _markAll(false);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'mark_all_seen',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.check_circle),
                    title: LocalizedText('تحديد الكل كـ حضر'),
                  ),
                ),
                PopupMenuItem(
                  value: 'mark_all_unseen',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.radio_button_unchecked),
                    title: LocalizedText('إلغاء تحديد الكل'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NeuCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.event_available_rounded,
                            color: kPrimaryColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            LocalizedText('تاريخ اليوم: $todayStr',
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w900,
                                fontSize: 15.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            LocalizedText('الإجمالي: ${_filtered.length} • غير مُشاهَد: ${_filtered.where((e) => !e.isAttended).length}',
                              style: TextStyle(
                                color: scheme.onSurface.withValues(alpha: .7),
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                NeuCard(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: NeuField(
                          controller: _searchCtrl,
                          labelText: context.trRaw('بحث بالاسم / الهاتف / الحالة'),
                          prefix: const Icon(Icons.search_rounded),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        children: [
                          LocalizedText('غير مُشاهَد',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color:
                                  scheme.onSurface.withValues(alpha: .7),
                            ),
                          ),
                          Switch(
                            value: _onlyUnseen,
                            onChanged: (v) {
                              setState(() => _onlyUnseen = v);
                              _applyFilter();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _filtered.isEmpty
                          ? Center(
                              child: LocalizedText('لا توجد تذكيرات لليوم',
                                style: TextStyle(
                                  color:
                                      scheme.onSurface.withValues(alpha: .6),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _filtered.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (_, i) {
                                final r = _filtered[i];
                                return _ReminderCard(
                                  entry: r,
                                  dateTimeFmt: _dateTime,
                                  onToggleSeen: () => _toggleSeen(r),
                                  onCall: () => _call(r.phoneNumber),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReminderCard extends StatelessWidget {
  final ReturnEntry entry;
  final DateFormat dateTimeFmt;
  final VoidCallback onToggleSeen;
  final VoidCallback onCall;

  const _ReminderCard({
    required this.entry,
    required this.dateTimeFmt,
    required this.onToggleSeen,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final attended = entry.isAttended;
    final dateStr = dateTimeFmt.format(entry.date.toLocal());

    return NeuCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: attended
                  ? Colors.green.withValues(alpha: .12)
                  : Colors.orange.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(10),
            child: Icon(
              attended ? Icons.check_circle_outline : Icons.schedule_rounded,
              color: attended ? Colors.green : Colors.orange,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  entry.patientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w900,
                    fontSize: 15.5,
                  ),
                ),
                const SizedBox(height: 4),
                LocalizedText('موعد العَود: $dateStr',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .7),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 4),
                LocalizedText('الحالة: ${entry.diagnosis.isEmpty ? '—' : entry.diagnosis}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .7),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            children: [
              IconButton(
                tooltip: context.trRaw('اتصال'),
                icon: const Icon(Icons.phone),
                color: kPrimaryColor,
                onPressed: onCall,
              ),
              IconButton(
                tooltip: attended ? 'إلغاء الحضور' : 'تحديد كـ حضر',
                icon: Icon(attended
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked),
                color: kPrimaryColor,
                onPressed: onToggleSeen,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
