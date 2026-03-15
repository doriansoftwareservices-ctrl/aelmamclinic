// lib/screens/repository/purchases_consumptions/view_pc_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class ViewPCScreen extends StatelessWidget {
  const ViewPCScreen({super.key});
  static const routeName = '/repository/pc/view';

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const LocalizedText('المشتريات والاستهلاكات',
              style: TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: DecoratedBox(
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
          child: (repo.types.isEmpty && repo.orphanItems.isEmpty)
              ? const Center(child: LocalizedText('لا بيانات بعد.'))
              : ListView(
                  padding: kScreenPadding,
                  children: [
                    _permissionBanner(context, auth),
                    for (final type in repo.types)
                      Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                        elevation: 2,
                        child: _TypeSection(type: type),
                      ),
                    if (repo.orphanItems.isNotEmpty)
                      Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                        elevation: 2,
                        child: _OrphanSection(items: repo.orphanItems),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _permissionBanner(BuildContext context, AuthProvider auth) {
    if (auth.isOwnerOrAdmin || auth.isSuperAdmin) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.tertiary.withValues(alpha: .4)),
      ),
      child: const LocalizedText('تنبيه: بعض البيانات قد تكون مخفية حسب صلاحيات الحساب.',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _TypeSection extends StatelessWidget {
  final ItemType type;
  const _TypeSection({required this.type});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = context.watch<RepositoryProvider>().itemsOf(type.id!);

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Icon(Icons.category_outlined, color: scheme.primary),
      title: Text(type.name,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: items.isEmpty
          ? const [
              Padding(padding: EdgeInsets.all(8), child: LocalizedText('— لا أصناف —'))
            ]
          : items.map((it) => _ItemTile(item: it)).toList(),
    );
  }
}

class _ItemTile extends StatelessWidget {
  final Item item;
  const _ItemTile({required this.item});

  Future<Map<String, dynamic>?> _fetchLastConsumption() async {
    try {
      final db = await RepositoryService.instance.database;
      final args = <Object?>[item.id];
      final acc = await DBService.instance
          .accountFilterClause(db, Consumption.table, alias: 'c', args: args);
      final result = await db.rawQuery('''
        SELECT c.quantity, c.date
          FROM ${Consumption.table} c
         WHERE c.itemId = ?
           AND ifnull(c.isDeleted,0)=0
           $acc
      ORDER BY date DESC
         LIMIT 1
      ''', args);
      return result.isEmpty ? null : result.first;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Map<String, dynamic>?>(
      future: _fetchLastConsumption(),
      builder: (ctx, snap) {
        Widget subtitle;
        if (snap.connectionState != ConnectionState.done) {
          subtitle = const LocalizedText('جارٍ التحقق من آخر استهلاك…');
        } else if (snap.data == null) {
          subtitle = const LocalizedText('لم يُستخدم بعد');
        } else {
          final q = (snap.data!['quantity'] as num).toInt();
          final dt = DateTime.parse(snap.data!['date'] as String);
          subtitle = LocalizedText('آخر استهلاك: ${DateFormat('yyyy-MM-dd – HH:mm').format(dt)}  •  الكمية: $q',
          );
        }

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          elevation: 1,
          child: ListTile(
            title: Text(item.name,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: subtitle,
            trailing: Icon(
              context.isRtl ? Icons.chevron_left : Icons.chevron_right,
              color: scheme.primary,
            ),
            onTap: () => Navigator.push(
              ctx,
              MaterialPageRoute(
                  builder: (_) => _ItemConsumptionsPage(item: item)),
            ),
          ),
        );
      },
    );
  }
}

class _OrphanSection extends StatelessWidget {
  final List<Item> items;
  const _OrphanSection({required this.items});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Icon(Icons.report_gmailerrorred, color: scheme.error),
      title: const LocalizedText('أصناف بدون نوع',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: items.isEmpty
          ? const [
              Padding(padding: EdgeInsets.all(8), child: LocalizedText('— لا أصناف —'))
            ]
          : items.map((it) => _ItemTile(item: it)).toList(),
    );
  }
}

class _ItemConsumptionsPage extends StatefulWidget {
  final Item item;
  const _ItemConsumptionsPage({required this.item});

  @override
  State<_ItemConsumptionsPage> createState() => _ItemConsumptionsPageState();
}

class _ItemConsumptionsPageState extends State<_ItemConsumptionsPage> {
  late Future<List<_ConsumptionDetail>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_ConsumptionDetail>> _load() async {
    final db = await RepositoryService.instance.database;
    final args = <Object?>[widget.item.id];
    final cAcc = await DBService.instance
        .accountFilterClause(db, Consumption.table, alias: 'c', args: args);
    final pAcc = await DBService.instance
        .accountFilterClause(db, 'patients', alias: 'p', args: args);
    final rows = await db.rawQuery('''
      SELECT c.id, c.quantity, c.date, c.patientId, p.name AS patient_name
        FROM ${Consumption.table} c
   LEFT JOIN patients p ON p.id = c.patientId
       WHERE c.itemId = ?
         AND ifnull(c.isDeleted,0)=0
         $cAcc$pAcc
    ORDER BY c.date DESC
    ''', args);
    return rows
        .map((m) => _ConsumptionDetail(
              id: (m['id'] as num).toInt(),
              quantity: (m['quantity'] as num).toInt(),
              consumedAt: DateTime.parse(m['date'] as String),
              patientName:
                  (m['patient_name'] as String?) ?? 'مريض: ${m['patientId']}',
            ))
        .toList();
  }

  Future<void> _editQuantity(_ConsumptionDetail d) async {
    final ctrl = TextEditingController(text: d.quantity.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          title: const LocalizedText('تعديل الكمية'),
          content: TextField(
            controller: ctrl,
            decoration: InputDecoration(labelText: context.trRaw('الكمية الجديدة')),
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const LocalizedText('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: LocalizedText('حفظ',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary)),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final newQty = int.tryParse(ctrl.text);
    if (newQty == null || newQty <= 0 || newQty == d.quantity) return;

    final diff = newQty - d.quantity;
    final dbService = DBService.instance;
    try {
      await dbService.runQueuedWrite(() async {
        await dbService.runWithDbRetry(() async {
          final db = await RepositoryService.instance.database;
          await db.transaction((txn) async {
            final itemRows = await txn.query(
              Item.table,
              columns: const ['stock', 'price'],
              where: 'id = ?',
              whereArgs: [widget.item.id],
              limit: 1,
            );
            if (itemRows.isEmpty) {
              throw StateError('الصنف غير موجود');
            }
            final currentStock =
                (itemRows.first['stock'] as num?)?.toInt() ?? 0;
            final unitPrice =
                (itemRows.first['price'] as num?)?.toDouble() ?? 0.0;
            final nextStock = currentStock - diff;
            if (nextStock < 0) {
              throw StateError('الكمية تتجاوز المخزون المتاح');
            }
            await txn.update(
              Consumption.table,
              {'quantity': newQty, 'amount': unitPrice * newQty},
              where: 'id = ?',
              whereArgs: [d.id],
            );
            await txn.update(
              Item.table,
              {'stock': nextStock},
              where: 'id = ?',
              whereArgs: [widget.item.id],
            );
          });
        });
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذّر التعديل: $e')),
      );
      return;
    }

    await DBService.instance.notifyTableChanged(Consumption.table);
    await DBService.instance.notifyTableChanged(Item.table);

    if (!mounted) return;
    setState(() => _future = _load());
    context.read<RepositoryProvider>().bootstrap();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LocalizedText('تم تحديث الكمية بنجاح')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Text(widget.item.name,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: DecoratedBox(
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
          child: FutureBuilder<List<_ConsumptionDetail>>(
            future: _future,
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final list = snap.data ?? [];
              if (list.isEmpty) {
                return const Center(
                    child: LocalizedText('لا استهلاكات مسجلة لهذا الصنف.'));
              }
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final d = list[i];
                  return Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    elevation: 1,
                    child: ListTile(
                      leading: Icon(Icons.medical_services_outlined,
                          color: scheme.primary),
                      title: LocalizedText('الكمية: ${d.quantity}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        '${DateFormat('yyyy-MM-dd – HH:mm').format(d.consumedAt)}  •  ${d.patientName}',
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.edit_outlined,
                            color: scheme.primary),
                        onPressed: () => _editQuantity(d),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ConsumptionDetail {
  final int id;
  final int quantity;
  final DateTime consumedAt;
  final String patientName;

  _ConsumptionDetail({
    required this.id,
    required this.quantity,
    required this.consumedAt,
    required this.patientName,
  });
}
