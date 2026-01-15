// lib/screens/complaints/complaints_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/services/db_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class ComplaintsScreen extends StatefulWidget {
  const ComplaintsScreen({super.key});

  @override
  State<ComplaintsScreen> createState() => _ComplaintsScreenState();
}

class _ComplaintsScreenState extends State<ComplaintsScreen> {
  List<Map<String, dynamic>> _complaints = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /*──────────────── تحميل الشكاوى ────────────────*/
  Future<void> _load() async {
    final db = await DBService.instance.database;
    try {
      await db.update(
        'complaints',
        {'replySeen': 1},
        where:
            "(IFNULL(replyMessage, '') != '' OR IFNULL(reply_message, '') != '')",
      );
      DBService.instance.emitPassiveChange('complaints');
    } catch (_) {}
    final rows = await db.query(
      'complaints',
      orderBy: 'createdAt DESC',
    );
    setState(() => _complaints = rows);
  }

  /*──────────────── إضافة / تعديل شكوى ───────────*/
  Future<void> _openDialog({Map<String, dynamic>? initial}) async {
    final titleCtrl = TextEditingController(
      text: (initial?['subject'] ?? initial?['title'] ?? '').toString(),
    );
    final descCtrl = TextEditingController(
      text: (initial?['message'] ?? initial?['description'] ?? '').toString(),
    );
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(initial == null ? 'إضافة شكوى' : 'تعديل شكوى'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius)),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NeuField(
                  controller: titleCtrl,
                  labelText: 'العنوان',
                  prefix: const Icon(Icons.flag_outlined),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'أدخل العنوان' : null,
                ),
                const SizedBox(height: 10),
                NeuField(
                  controller: descCtrl,
                  labelText: 'الوصف',
                  maxLines: 3,
                  prefix: const Icon(Icons.description_outlined),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;

    final db = await DBService.instance.database;
    final nowIso = DateTime.now().toIso8601String();

    if (initial == null) {
      await db.insert('complaints', {
        'title': titleCtrl.text.trim(),
        'description': descCtrl.text.trim(),
        'subject': titleCtrl.text.trim(),
        'message': descCtrl.text.trim(),
        'status': 'open',
        'createdAt': nowIso,
      });
    } else {
      await db.update(
        'complaints',
        {
          'title': titleCtrl.text.trim(),
          'description': descCtrl.text.trim(),
          'subject': titleCtrl.text.trim(),
          'message': descCtrl.text.trim(),
        },
        where: 'id = ?',
        whereArgs: [initial['id']],
      );
    }

    await _load();
  }

  /*──────────────── تغيير الحالة ────────────────*/
  Future<void> _toggleStatus(Map<String, dynamic> c) async {
    final db = await DBService.instance.database;
    final newStatus = c['status'] == 'open' ? 'closed' : 'open';
    await db.update(
      'complaints',
      {'status': newStatus},
      where: 'id = ?',
      whereArgs: [c['id']],
    );
    await _load();
  }

  /*──────────────── حذف ─────────────────────────*/
  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('تأكيد الحذف'),
          content: const Text('سيتم حذف الشكوى نهائياً، هل أنت متأكد؟'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;

    final db = await DBService.instance.database;
    await db.delete('complaints', where: 'id = ?', whereArgs: [id]);
    await _load();
  }

  Widget _statusChip(bool isClosed) {
    final color = isClosed ? Colors.green : Colors.orange;
    final label = isClosed ? 'مغلقة' : 'مفتوحة';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.shade700,
          fontWeight: FontWeight.w800,
          fontSize: 12.5,
        ),
      ),
    );
  }

  /*──────────────────────────── UI ────────────────────────────*/
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final dense = width < 420;

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
            const Text('الشكاوي والأعطال'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openDialog(),
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: Column(
            children: [
              // رأس لطيف
              NeuCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(Icons.report_problem,
                          color: kPrimaryColor, size: 26),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'سجل الشكاوى والأعطال',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // القائمة
              Expanded(
                child: _complaints.isEmpty
                    ? Center(
                        child: NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.inbox_rounded, size: 40),
                              SizedBox(height: 10),
                              Text('لا توجد شكاوى مسجّلة',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _complaints.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final c = _complaints[i];
                            final dateStr = DateFormat('yyyy-MM-dd').format(
                                DateTime.parse(c['createdAt'] as String));
                            final isClosed = c['status'] == 'closed';
                            final replyText =
                                ((c['replyMessage'] ?? c['reply_message']) ??
                                        '')
                                    .toString()
                                    .trim();
                            final hasReply = replyText.isNotEmpty;

                            return NeuCard(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: ListTile(
                                dense: dense,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  isClosed
                                      ? Icons.check_circle
                                      : Icons.report_problem,
                                  color:
                                      isClosed ? Colors.green : Colors.orange,
                                ),
                                title: Text(
                                  (c['subject'] ?? c['title'] ?? 'شكوى')
                                      .toString(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w900),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    hasReply
                                        ? '$dateStr • يوجد رد'
                                        : '$dateStr • الحالة:',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                isThreeLine: hasReply,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _statusChip(isClosed),
                                    const SizedBox(width: 6),
                                    PopupMenuButton<String>(
                                      onSelected: (v) {
                                        switch (v) {
                                          case 'toggle':
                                            _toggleStatus(c);
                                            break;
                                          case 'viewReply':
                                            final replyText =
                                                (c['replyMessage'] ??
                                                        c['reply_message'])
                                                    ?.toString()
                                                    .trim();
                                            if (replyText == null ||
                                                replyText.isEmpty) {
                                              return;
                                            }
                                            showDialog<void>(
                                              context: context,
                                              builder: (ctx) => AlertDialog(
                                                title:
                                                    const Text('رد الإدارة'),
                                                content: Text(replyText),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.of(ctx)
                                                            .pop(),
                                                    child: const Text('إغلاق'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            break;
                                          case 'edit':
                                            _openDialog(initial: c);
                                            break;
                                          case 'delete':
                                            _delete(c['id'] as int);
                                            break;
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        PopupMenuItem(
                                          value: 'toggle',
                                          child: ListTile(
                                            leading: Icon(isClosed
                                                ? Icons.undo
                                                : Icons.done_all),
                                            title: Text(
                                              isClosed
                                                  ? 'إعادة فتح'
                                                  : 'إغلاق الشكوى',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w700),
                                            ),
                                          ),
                                        ),
                                        if (hasReply)
                                          PopupMenuItem(
                                            value: 'viewReply',
                                            child: ListTile(
                                              leading:
                                                  const Icon(Icons.reply_all),
                                              title: const Text('عرض الرد',
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700)),
                                            ),
                                          ),
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: ListTile(
                                            leading: Icon(Icons.edit),
                                            title: Text('تعديل',
                                                style: TextStyle(
                                                    fontWeight:
                                                        FontWeight.w700)),
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: ListTile(
                                            leading: Icon(Icons.delete,
                                                color: Colors.red),
                                            title: Text('حذف',
                                                style: TextStyle(
                                                    fontWeight:
                                                        FontWeight.w700)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                onTap: hasReply
                                    ? () {
                                        showDialog<void>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('رد الإدارة'),
                                            content: Text(replyText),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(ctx).pop(),
                                                child: const Text('إغلاق'),
                                              ),
                                            ],
                                          ),
                                        );
                                      }
                                    : null,
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
