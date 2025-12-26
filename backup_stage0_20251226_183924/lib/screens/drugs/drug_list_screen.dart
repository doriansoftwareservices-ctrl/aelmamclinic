// lib/screens/drugs/drug_list_screen.dart
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/models/drug.dart';
import 'new_drug_screen.dart';

class DrugListScreen extends StatefulWidget {
  const DrugListScreen({super.key});

  @override
  State<DrugListScreen> createState() => _DrugListScreenState();
}

class _DrugListScreenState extends State<DrugListScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  List<Drug> _allDrugs = [];
  List<Drug> _filteredDrugs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDrugs();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_applyFilter);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDrugs() async {
    setState(() => _loading = true);
    try {
      // ✅ اجلب عبر DBService (يُفلتر isDeleted=0)
      final list = await DBService.instance.getAllDrugs();
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      setState(() {
        _allDrugs = list;
        _filteredDrugs = list;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredDrugs = List.of(_allDrugs);
      } else {
        _filteredDrugs =
            _allDrugs.where((d) => d.name.toLowerCase().contains(q)).toList();
      }
    });
  }

  Future<void> _openNewDrug([Drug? d]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => NewDrugScreen(initialDrug: d)),
    );
    // إعادة التحميل + دفع احتياطي لو صار تعديل
    if (changed == true) {
      try {
        await DBService.instance.onLocalChange?.call('drugs');
      } catch (_) {}
      await _loadDrugs();
    }
  }

  Future<void> _deleteDrug(int id) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text(
            'سيتم حذف الدواء (حذف منطقي) وإرسال التغيير للسحابة. تأكيد؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius)),
      ),
    );
    if (ok != true) return;

    try {
      // ✅ حذف منطقي + إشعار مزامنة
      await DBService.instance.deleteDrug(id);
      try {
        await DBService.instance.onLocalChange?.call('drugs');
      } catch (_) {}
      await _loadDrugs();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف الدواء ودفع التغيير للسحابة')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('لا يمكن الحذف: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.medication_rounded),
              SizedBox(width: 8),
              Text('إدارة الأدوية'),
            ],
          ),
          // ✅ تمت إزالة الأزرار (تحديث، دفع الآن، تشخيص)
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openNewDrug(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('إضافة'),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              children: [
                // بحث
                NeuField(
                  controller: _searchCtrl,
                  hintText: 'بحث باسم الدواء…',
                  prefix: const Icon(Icons.search_rounded),
                  suffix: (_searchCtrl.text.isEmpty)
                      ? null
                      : IconButton(
                          tooltip: 'مسح',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _searchCtrl.clear();
                            _applyFilter();
                          },
                        ),
                ),
                const SizedBox(height: 12),

                // بطاقة عدّاد بسيطة
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Text('الإجمالي: ',
                          style: TextStyle(fontWeight: FontWeight.w900)),
                      Text('${_allDrugs.length}',
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                      const SizedBox(width: 16),
                      Text(
                        'الظاهر: ${_filteredDrugs.length}',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: .75),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // القائمة
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _filteredDrugs.isEmpty
                          ? Center(
                              child: Text(
                                'لا توجد بيانات',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: .6),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _loadDrugs,
                              child: ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: _filteredDrugs.length,
                                itemBuilder: (_, i) {
                                  final d = _filteredDrugs[i];
                                  return NeuCard(
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 6),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 6),
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 8),
                                      leading: Container(
                                        decoration: BoxDecoration(
                                          color: kPrimaryColor.withValues(
                                              alpha: .10),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        padding: const EdgeInsets.all(10),
                                        child: const Icon(
                                          Icons.medication_outlined,
                                          color: kPrimaryColor,
                                        ),
                                      ),
                                      title: Text(d.name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800)),
                                      subtitle: (d.notes?.isNotEmpty ?? false)
                                          ? Text(
                                              d.notes!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: .75),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            )
                                          : null,
                                      trailing: PopupMenuButton<String>(
                                        icon:
                                            const Icon(Icons.more_vert_rounded),
                                        onSelected: (v) {
                                          if (v == 'edit') {
                                            _openNewDrug(d);
                                          } else if (v == 'del') {
                                            _deleteDrug(d.id!);
                                          }
                                        },
                                        itemBuilder: (ctx) => [
                                          PopupMenuItem(
                                            value: 'edit',
                                            child: Row(
                                              children: [
                                                Icon(Icons.edit_rounded,
                                                    size: 20,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary),
                                                const SizedBox(width: 8),
                                                const Text('تعديل'),
                                              ],
                                            ),
                                          ),
                                          const PopupMenuItem(
                                            value: 'del',
                                            child: Row(
                                              children: [
                                                Icon(Icons.delete_rounded,
                                                    size: 20,
                                                    color: Colors.red),
                                                SizedBox(width: 8),
                                                Text('حذف'),
                                              ],
                                            ),
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
      ),
    );
  }
}
