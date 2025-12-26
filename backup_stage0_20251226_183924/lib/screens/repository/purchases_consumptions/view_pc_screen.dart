// lib/screens/repository/purchases_consumptions/view_pc_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/services/db_service.dart';

/*──────── ألوان TBIAN الموحدة ────────*/
const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

class ViewPCScreen extends StatelessWidget {
  const ViewPCScreen({super.key});
  static const routeName = '/repository/pc/view';

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('المشتريات والاستهلاكات',
              style: TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [lightAccentColor, accentColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [veryLightBg, Colors.white, veryLightBg],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: repo.types.isEmpty
              ? const Center(child: Text('لا بيانات بعد.'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: repo.types.length,
                  itemBuilder: (ctx, i) => Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    elevation: 2,
                    child: _TypeSection(type: repo.types[i]),
                  ),
                ),
        ),
      ),
    );
  }
}

class _TypeSection extends StatelessWidget {
  final ItemType type;
  const _TypeSection({required this.type});

  @override
  Widget build(BuildContext context) {
    final items = context.watch<RepositoryProvider>().itemsOf(type.id!);

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: const Icon(Icons.category_outlined, color: accentColor),
      title: Text(type.name,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: items.isEmpty
          ? const [
              Padding(padding: EdgeInsets.all(8), child: Text('— لا أصناف —'))
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
      final result = await db.rawQuery('''
        SELECT quantity, date
          FROM ${Consumption.table}
         WHERE itemId = ?
      ORDER BY date DESC
         LIMIT 1
      ''', [item.id]);
      return result.isEmpty ? null : result.first;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _fetchLastConsumption(),
      builder: (ctx, snap) {
        Widget subtitle;
        if (snap.connectionState != ConnectionState.done) {
          subtitle = const Text('جارٍ التحقق من آخر استهلاك…');
        } else if (snap.data == null) {
          subtitle = const Text('لم يُستخدم بعد');
        } else {
          final q = (snap.data!['quantity'] as num).toInt();
          final dt = DateTime.parse(snap.data!['date'] as String);
          subtitle = Text(
            'آخر استهلاك: ${DateFormat('yyyy-MM-dd – HH:mm').format(dt)}  •  الكمية: $q',
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
            trailing: const Icon(Icons.chevron_right, color: accentColor),
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
    final rows = await db.rawQuery('''
      SELECT c.id, c.quantity, c.date, c.patientId, p.name AS patient_name
        FROM ${Consumption.table} c
   LEFT JOIN patients p ON p.id = c.patientId
       WHERE c.itemId = ?
    ORDER BY c.date DESC
    ''', [widget.item.id]);
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
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تعديل الكمية'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'الكمية الجديدة'),
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: accentColor),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final newQty = int.tryParse(ctrl.text);
    if (newQty == null || newQty <= 0 || newQty == d.quantity) return;

    final diff = newQty - d.quantity;
    final db = await RepositoryService.instance.database;
    await db.transaction((txn) async {
      await txn.update(
        Consumption.table,
        {'quantity': newQty},
        where: 'id = ?',
        whereArgs: [d.id],
      );
      await txn.rawUpdate(
        'UPDATE ${Item.table} SET stock = stock - ? WHERE id = ?',
        [diff, widget.item.id],
      );
    });

    await DBService.instance.notifyTableChanged(Consumption.table);
    await DBService.instance.notifyTableChanged(Item.table);

    if (!mounted) return;
    setState(() => _future = _load());
    context.read<RepositoryProvider>().bootstrap();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تحديث الكمية بنجاح')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Text(widget.item.name,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [lightAccentColor, accentColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [veryLightBg, Colors.white, veryLightBg],
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
                    child: Text('لا استهلاكات مسجلة لهذا الصنف.'));
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
                      leading: const Icon(Icons.medical_services_outlined,
                          color: accentColor),
                      title: Text('الكمية: ${d.quantity}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        '${DateFormat('yyyy-MM-dd – HH:mm').format(d.consumedAt)}  •  ${d.patientName}',
                      ),
                      trailing: IconButton(
                        icon:
                            const Icon(Icons.edit_outlined, color: accentColor),
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
