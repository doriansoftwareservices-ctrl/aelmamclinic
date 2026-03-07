// lib/screens/admin/support_ratings_screen.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/support_rating_entry.dart';
import 'package:aelmamclinic/services/admin_account_members_service.dart';
import 'package:aelmamclinic/services/support_ratings_service.dart';
import 'package:aelmamclinic/utils/chat_code_utils.dart';

class SupportRatingsScreen extends StatefulWidget {
  const SupportRatingsScreen({super.key});

  @override
  State<SupportRatingsScreen> createState() => _SupportRatingsScreenState();
}

class _SupportRatingsScreenState extends State<SupportRatingsScreen> {
  final _dateFmt = DateFormat('yyyy-MM-dd');
  final _monthFmt = DateFormat('yyyy-MM');
  DateTimeRange? _range;
  bool _loading = true;
  String? _error;

  List<SupportRatingEntry> _ratings = [];
  double _avg = 0.0;
  int _count = 0;
  double _satisfaction = 0.0;
  Map<String, int> _stars = {};
  Map<String, double> _monthlyAvg = {};
  Map<String, int> _monthlyCount = {};
  Map<String, String> _accountLabelById = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final from = DateTime(now.year - 1, now.month, 1);
    _range = DateTimeRange(start: from, end: now);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await SupportRatingsService.instance.fetchRatings(
        from: _range?.start,
        to: _range?.end,
      );
      final labels = await _loadAccountLabels(list);
      _recalculate(list);
      setState(() {
        _ratings = list;
        _accountLabelById = labels;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'تعذّر تحميل التقييمات: $e';
        _loading = false;
      });
    }
  }

  Future<Map<String, String>> _loadAccountLabels(
    List<SupportRatingEntry> list,
  ) async {
    final ids = list
        .map((e) => e.accountId ?? '')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return {};
    try {
      final service = AdminAccountMembersService();
      final owners = await service.fetchOwnerMembersByAccountIds(ids);
      final out = <String, String>{};
      owners.forEach((accountId, owner) {
        final name = owner.accountName.trim();
        final codeRaw = (owner.chatCode ?? '').trim();
        final code =
            codeRaw.isEmpty ? '' : ' — الرقم: ${ChatCodeUtils.format(codeRaw)}';
        final label = (name.isNotEmpty ? name : accountId) + code;
        out[accountId] = label;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  void _recalculate(List<SupportRatingEntry> list) {
    if (list.isEmpty) {
      _avg = 0;
      _count = 0;
      _satisfaction = 0;
      _stars = {'1': 0, '2': 0, '3': 0, '4': 0, '5': 0};
      _monthlyAvg = {};
      _monthlyCount = {};
      return;
    }

    final stars = <String, int>{'1': 0, '2': 0, '3': 0, '4': 0, '5': 0};
    final monthSum = <String, double>{};
    final monthCount = <String, int>{};
    var sum = 0.0;
    var satisfied = 0;

    for (final r in list) {
      sum += r.rating.toDouble();
      if (r.rating >= 4) satisfied += 1;
      final key = r.rating.toString();
      stars[key] = (stars[key] ?? 0) + 1;

      final monthKey = _monthFmt.format(r.submittedAt.toLocal());
      monthSum[monthKey] = (monthSum[monthKey] ?? 0) + r.rating.toDouble();
      monthCount[monthKey] = (monthCount[monthKey] ?? 0) + 1;
    }

    final avg = sum / list.length;
    final satisfaction = (satisfied / list.length) * 100;

    final monthlyAvg = <String, double>{};
    monthSum.forEach((key, value) {
      final count = monthCount[key] ?? 1;
      monthlyAvg[key] = value / count;
    });

    final sortedKeys = monthlyAvg.keys.toList()..sort();
    _monthlyAvg = {for (final k in sortedKeys) k: monthlyAvg[k] ?? 0};
    _monthlyCount = {for (final k in sortedKeys) k: monthCount[k] ?? 0};
    _avg = avg;
    _count = list.length;
    _satisfaction = satisfaction;
    _stars = stars;
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final initial = _range ?? DateTimeRange(
      start: DateTime(now.year - 1, now.month, 1),
      end: now,
    );
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: initial,
    );
    if (result == null) return;
    setState(() => _range = result);
    await _load();
  }

  List<_ChartData> _mapToData(Map<String, double> map) {
    final keys = map.keys.toList()..sort();
    return keys.map((k) => _ChartData(k, map[k] ?? 0)).toList();
  }

  List<_ChartData> _mapToDataInt(Map<String, int> map) {
    final keys = map.keys.toList()..sort();
    return keys.map((k) => _ChartData(k, (map[k] ?? 0).toDouble())).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rangeLabel = _range == null
        ? 'كل الفترة'
        : '${_dateFmt.format(_range!.start)} → ${_dateFmt.format(_range!.end)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.support_agent_rounded, color: kPrimaryColor),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'تقييمات خدمة العملاء',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: _pickRange,
                icon: const Icon(Icons.date_range_rounded),
                label: Text(rangeLabel),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'تحديث',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    )
                  : _buildBody(context),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _KpiCard(
              item: _KpiItem(
                title: 'عدد التقييمات',
                value: _count.toString(),
                icon: Icons.rate_review_rounded,
                color: scheme.primary,
              ),
            ),
            _KpiCard(
              item: _KpiItem(
                title: 'المتوسط العام',
                value: _avg.toStringAsFixed(2),
                icon: Icons.star_rounded,
                color: Colors.amber.shade700,
              ),
            ),
            _KpiCard(
              item: _KpiItem(
                title: 'نسبة الرضا (4+)',
                value: '${_satisfaction.toStringAsFixed(1)}%',
                icon: Icons.thumb_up_alt_rounded,
                color: Colors.green.shade600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _BarChart(
          data: _mapToData(_monthlyAvg),
          title: 'متوسط التقييم الشهري',
          accent: kPrimaryColor,
          emptyMessage: 'لا توجد بيانات شهرية كافية',
        ),
        const SizedBox(height: 12),
        _BarChart(
          data: _mapToDataInt(_monthlyCount),
          title: 'عدد التقييمات الشهري',
          accent: Colors.teal,
          emptyMessage: 'لا توجد بيانات شهرية كافية',
        ),
        const SizedBox(height: 12),
        _BarChart(
          data: _mapToDataInt(_stars),
          title: 'توزيع النجوم',
          accent: Colors.orange.shade600,
          emptyMessage: 'لا توجد تقييمات بعد',
        ),
        const SizedBox(height: 12),
        _buildRatingsList(context),
      ],
    );
  }

  Widget _buildRatingsList(BuildContext context) {
    if (_ratings.isEmpty) {
      return const _EmptyCard(message: 'لا توجد تقييمات ضمن الفترة المحددة');
    }
    return NeuCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'أحدث التقييمات',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ..._ratings.take(40).map((r) {
            final stars = '★' * r.rating + '☆' * (5 - r.rating);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        stars,
                        style: const TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_dateFmt.format(r.submittedAt.toLocal())),
                      const Spacer(),
                      Text(
                        _accountLabelById[r.accountId ?? ''] ??
                            r.accountId ??
                            '—',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                  if (r.note != null && r.note!.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(r.note!),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _KpiItem {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  _KpiItem({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });
}

class _KpiCard extends StatelessWidget {
  final _KpiItem item;

  const _KpiCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: NeuCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: item.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(item.icon, color: item.color, size: 20),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              style: TextStyle(
                fontSize: 12,
                color:
                    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartData {
  final String label;
  final double value;

  _ChartData(this.label, this.value);
}

class _BarChart extends StatelessWidget {
  final List<_ChartData> data;
  final String title;
  final Color accent;
  final String emptyMessage;

  const _BarChart({
    required this.data,
    required this.title,
    required this.accent,
    required this.emptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return _EmptyCard(message: emptyMessage);
    }
    final chartWidth = math.max(280.0, 70.0 * data.length);
    final tooltip = TooltipBehavior(enable: true, canShowMarker: true);
    final zoomPan = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableSelectionZooming: true,
      zoomMode: ZoomMode.x,
      maximumZoomLevel: 0.02,
    );
    final trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: chartWidth,
        height: 280,
        child: SfCartesianChart(
          title: ChartTitle(text: title),
          enableAxisAnimation: false,
          plotAreaBorderWidth: 0,
          primaryXAxis: CategoryAxis(labelRotation: 45),
          primaryYAxis: NumericAxis(),
          tooltipBehavior: tooltip,
          zoomPanBehavior: zoomPan,
          trackballBehavior: trackball,
          series: <ColumnSeries<_ChartData, String>>[
            ColumnSeries<_ChartData, String>(
              dataSource: data,
              xValueMapper: (d, _) => d.label,
              yValueMapper: (d, _) => d.value,
              color: accent,
              animationDuration: 0,
              dataLabelSettings: const DataLabelSettings(isVisible: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String message;

  const _EmptyCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Icon(Icons.bar_chart_outlined,
              size: 36, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
