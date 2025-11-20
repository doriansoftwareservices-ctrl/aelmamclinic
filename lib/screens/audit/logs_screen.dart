// lib/screens/audit/logs_screen.dart
//
// شاشة عرض سجلات التدقيق Audit Logs (قراءة فقط).
// - القراءة متاحة لمالك الحساب فقط بحسب RLS.
// - فلاتر: المدة الزمنية، نوع العملية (insert/update/delete),
//   اسم الجدول، وبريد المنفّذ.
// - ترقيم (pagination) عبر range(offset, limit).
// - عرض التفاصيل (diff / before / after) في BottomSheet منسّق.

import 'dart:ui' as ui show TextDirection;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/core/features.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';

class AuditLogsScreen extends StatefulWidget {
  const AuditLogsScreen({super.key});

  @override
  State<AuditLogsScreen> createState() => _AuditLogsScreenState();
}

class _AuditLogsScreenState extends State<AuditLogsScreen> {
  final _client = Supabase.instance.client;

  // --- الفلاتر ---
  DateTime? _from;
  DateTime? _to;
  String _op = 'all'; // all | insert | update | delete
  final _tableCtrl = TextEditingController();
  final _actorCtrl = TextEditingController();

  // --- البيانات ---
  final _items = <_AuditLogEntry>[];
  bool _loading = false;
  bool _initialLoaded = false;
  bool _hasMore = true;
  int _offset = 0;
  static const _pageSize = 30;

  final _dateFmt = DateFormat('yyyy-MM-dd');
  final _dateTimeFmt = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    // افتراضيًا: أسبوع ماضي → اليوم
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = _to!.subtract(const Duration(days: 7));
  }

  @override
  void dispose() {
    _tableCtrl.dispose();
    _actorCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool reset = true}) async {
    final auth = context.read<AuthProvider>();
    final accId = auth.accountId;
    if (accId == null || accId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد حساب فعّال لعرض السجلات.')),
        );
      }
      return;
    }

    if (reset) {
      _items.clear();
      _offset = 0;
      _hasMore = true;
    }
    if (!_hasMore) return;

    setState(() => _loading = true);
    try {
      // لاحظ: dynamic لتفادي تعارض الأنواع بين Transform/Filter builders
      dynamic q = _client
          .from('audit_logs')
          .select(
        'id, account_id, actor_uid, actor_email, table_name, op, row_pk, before_row, after_row, diff, created_at',
      );

      q = q.eq('account_id', accId);

      if (_op != 'all') {
        q = q.eq('op', _op);
      }

      if (_from != null) {
        final start = DateTime(_from!.year, _from!.month, _from!.day);
        q = q.gte('created_at', start.toIso8601String());
      }
      if (_to != null) {
        final end = DateTime(_to!.year, _to!.month, _to!.day)
            .add(const Duration(days: 1));
        q = q.lt('created_at', end.toIso8601String());
      }

      if (_tableCtrl.text.trim().isNotEmpty) {
        q = q.ilike('table_name', '%${_tableCtrl.text.trim()}%');
      }

      if (_actorCtrl.text.trim().isNotEmpty) {
        final s = _actorCtrl.text.trim();
        final uuidLike = RegExp(
          r'^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$',
        ).hasMatch(s);
        q = uuidLike ? q.eq('actor_uid', s) : q.ilike('actor_email', '%$s%');
      }

      q = q.order('created_at', ascending: false);

      // الترقيم
      final from = _offset;
      final to = _offset + _pageSize - 1;
      final rows = await q.range(from, to);

      final list = (rows as List)
          .map((e) => _AuditLogEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      setState(() {
        _items.addAll(list);
        _offset += list.length;
        _hasMore = list.length == _pageSize;
        _initialLoaded = true;
      });
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحميل السجلات (${e.code ?? e.message}).')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('حدث خطأ غير متوقع: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickFrom() async {
    final init = _from ?? DateTime.now().subtract(const Duration(days: 7));
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      locale: const Locale('ar', ''),
      helpText: 'اختر تاريخ البداية',
    );
    if (picked != null) {
      setState(() => _from = picked);
    }
  }

  Future<void> _pickTo() async {
    final init = _to ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      locale: const Locale('ar', ''),
      helpText: 'اختر تاريخ النهاية',
    );
    if (picked != null) {
      setState(() => _to = picked);
    }
  }

  void _showDetails(_AuditLogEntry e) {
    final scheme = Theme.of(context).colorScheme;

    String prettyJson(Object? v) {
      try {
        if (v == null) return 'null';
        if (v is String) return v;
        final enc = const JsonEncoder.withIndent('  ');
        return enc.convert(v);
      } catch (_) {
        return '$v';
      }
    }

    Color opColor(String op) {
      switch (op) {
        case 'insert':
          return Colors.green.shade600;
        case 'update':
          return Colors.blue.shade600;
        case 'delete':
          return Colors.red.shade600;
        default:
          return scheme.primary;
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          minChildSize: 0.5,
          builder: (_, controller) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
              child: Directionality(
                textDirection: ui.TextDirection.ltr,
                child: ListView(
                  controller: controller,
                  children: [
                    Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: opColor(e.op).withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          child: Text(
                            e.op.toUpperCase(),
                            style: TextStyle(
                              color: opColor(e.op),
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${e.tableName} • ${e.rowPk ?? '-'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'المنفّذ: ${e.actorEmail ?? e.actorUid ?? 'غير معروف'}',
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _dateTimeFmt.format(e.createdAt),
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .6),
                      ),
                    ),
                    const SizedBox(height: 14),

                    if (e.op == 'update') ...[
                      _JsonBlock(
                        title: 'Diff — الحقول المتغيّرة',
                        jsonString: prettyJson(e.diff),
                      ),
                      const SizedBox(height: 12),
                    ],

                    _JsonBlock(
                      title: 'قبل التعديل',
                      jsonString: prettyJson(e.beforeRow),
                    ),
                    const SizedBox(height: 12),
                    _JsonBlock(
                      title: 'بعد التعديل',
                      jsonString: prettyJson(e.afterRow),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final canView = auth.isSuperAdmin ||
        (auth.role ?? '') == 'owner' ||
        auth.featureAllowed(FeatureKeys.auditLogs);

    return Directionality(
      textDirection: ui.TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('سجلات التدقيق'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            child: !canView
                ? _buildAccessDeniedCard(scheme)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // --- شريط الفلاتر ---
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _buildFromPicker(scheme),
                          _buildToPicker(scheme),
                          _buildOperationDropdown(),
                          _buildTableFilter(),
                          _buildActorFilter(),
                          FilledButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _refresh(reset: true),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('تحديث'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: RefreshIndicator(
                          color: scheme.primary,
                          onRefresh: () => _refresh(reset: true),
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              if (n.metrics.pixels >=
                                      n.metrics.maxScrollExtent - 200 &&
                                  !_loading &&
                                  _hasMore) {
                                _refresh(reset: false);
                              }
                              return false;
                            },
                            child: _buildList(),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildFromPicker(ColorScheme scheme) {
    return SizedBox(
      width: 220,
      child: NeuCard(
        onTap: _pickFrom,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(8),
              child:
                  const Icon(Icons.calendar_month_rounded, color: kPrimaryColor, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _from == null ? 'منذ البداية' : _dateFmt.format(_from!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToPicker(ColorScheme scheme) {
    return SizedBox(
      width: 220,
      child: NeuCard(
        onTap: _pickTo,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(8),
              child: const Icon(Icons.event_rounded, color: kPrimaryColor, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _to == null ? 'حتى اليوم' : _dateFmt.format(_to!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOperationDropdown() {
    return SizedBox(
      width: 180,
      child: NeuCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            value: _op,
            items: const [
              DropdownMenuItem(value: 'all', child: Text('كل العمليات')),
              DropdownMenuItem(value: 'insert', child: Text('INSERT')),
              DropdownMenuItem(value: 'update', child: Text('UPDATE')),
              DropdownMenuItem(value: 'delete', child: Text('DELETE')),
            ],
            onChanged: (v) => setState(() => _op = v ?? 'all'),
          ),
        ),
      ),
    );
  }

  Widget _buildTableFilter() {
    return SizedBox(
      width: 220,
      child: NeuCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: TextField(
          controller: _tableCtrl,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: 'اسم الجدول…',
            prefixIcon: Icon(Icons.table_chart_outlined),
          ),
          onSubmitted: (_) => _refresh(reset: true),
        ),
      ),
    );
  }

  Widget _buildActorFilter() {
    return SizedBox(
      width: 250,
      child: NeuCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: TextField(
          controller: _actorCtrl,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: 'بريد المنفّذ أو UID…',
            prefixIcon: Icon(Icons.person_search_outlined),
          ),
          onSubmitted: (_) => _refresh(reset: true),
        ),
      ),
    );
  }

  Widget _buildAccessDeniedCard(ColorScheme scheme) {
    return Center(
      child: NeuCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded, color: scheme.error, size: 32),
            const SizedBox(height: 12),
            const Text(
              'لا تملك صلاحية عرض سجلات التدقيق.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'اطلب من المالك أو السوبر أدمن منحك صلاحية "audit.logs".',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (!_initialLoaded && !_loading) {
      // تحميل أولي تلقائي عند أول بناء
      Future.microtask(() => _refresh(reset: true));
    }

    if (_items.isEmpty) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(
        child: Text(
          'لا توجد سجلات مطابقة للفلتر الحالي.',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length + 1, // +1 لمؤشّر المزيد
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == _items.length) {
          if (_loading) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (!_hasMore) {
            return const SizedBox(height: 20);
          }
          return const SizedBox.shrink();
        }

        final e = _items[index];
        return _AuditLogTile(
          entry: e,
          dateTimeFmt: _dateTimeFmt,
          onTap: () => _showDetails(e),
        );
      },
    );
  }
}

/*──────────────────────── نموذج البيانات ────────────────────────*/
class _AuditLogEntry {
  final int id;
  final String accountId;
  final String tableName;
  final String op; // insert | update | delete
  final String? rowPk;
  final String? actorUid;
  final String? actorEmail;
  final Map<String, dynamic>? beforeRow;
  final Map<String, dynamic>? afterRow;
  final Map<String, dynamic>? diff;
  final DateTime createdAt;

  _AuditLogEntry({
    required this.id,
    required this.accountId,
    required this.tableName,
    required this.op,
    required this.rowPk,
    required this.actorUid,
    required this.actorEmail,
    required this.beforeRow,
    required this.afterRow,
    required this.diff,
    required this.createdAt,
  });

  factory _AuditLogEntry.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic>? asMap(dynamic v) {
      if (v == null) return null;
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
      if (v is String) {
        try {
          final d = jsonDecode(v);
          if (d is Map) return Map<String, dynamic>.from(d);
        } catch (_) {}
      }
      return null;
    }

    return _AuditLogEntry(
      id: (j['id'] as num).toInt(),
      accountId: j['account_id']?.toString() ?? '',
      tableName: j['table_name']?.toString() ?? '',
      op: j['op']?.toString() ?? '',
      rowPk: j['row_pk']?.toString(),
      actorUid: j['actor_uid']?.toString(),
      actorEmail: j['actor_email']?.toString(),
      beforeRow: asMap(j['before_row']),
      afterRow: asMap(j['after_row']),
      diff: asMap(j['diff']),
      createdAt:
      DateTime.tryParse(j['created_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/*────────────────────── عنصر بطاقة/سطر السجل ─────────────────────*/
class _AuditLogTile extends StatelessWidget {
  final _AuditLogEntry entry;
  final DateFormat dateTimeFmt;
  final VoidCallback onTap;

  const _AuditLogTile({
    required this.entry,
    required this.dateTimeFmt,
    required this.onTap,
  });

  Color _opColor(String op, ColorScheme scheme) {
    switch (op) {
      case 'insert':
        return Colors.green.shade600;
      case 'update':
        return Colors.blue.shade600;
      case 'delete':
        return Colors.red.shade600;
      default:
        return scheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: _opColor(entry.op, scheme).withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(10),
            child: Icon(
              entry.op == 'insert'
                  ? Icons.add_circle_outline
                  : entry.op == 'update'
                  ? Icons.change_circle_outlined
                  : Icons.delete_outline,
              color: _opColor(entry.op, scheme),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${entry.tableName} • ${entry.rowPk ?? '-'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w900,
                    fontSize: 15.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'المنفّذ: ${entry.actorEmail ?? entry.actorUid ?? 'غير معروف'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: _opColor(entry.op, scheme).withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  entry.op.toUpperCase(),
                  style: TextStyle(
                    color: _opColor(entry.op, scheme),
                    fontWeight: FontWeight.w900,
                    fontSize: 11.5,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                dateTimeFmt.format(entry.createdAt),
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .6),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/*──────────────────────── كتلة عرض JSON منسّقة ───────────────────────*/
class _JsonBlock extends StatelessWidget {
  final String title;
  final String jsonString;

  const _JsonBlock({
    required this.title,
    required this.jsonString,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .85),
              fontWeight: FontWeight.w900,
              fontSize: 14.5,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              jsonString,
              textDirection: ui.TextDirection.ltr,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: scheme.onSurface.withValues(alpha: .95),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
