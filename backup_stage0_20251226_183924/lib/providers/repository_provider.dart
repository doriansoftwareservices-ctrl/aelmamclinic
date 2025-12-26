// lib/providers/repository_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/services/repository_service.dart';

/* ربط مباشر مع الـ DB + Sync */
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/sync_service.dart';

/// ‎ChangeNotifier‎ يغلِّف منطق المستودع ويُحدِّث الشارات (badges)
/// في الواجهة الرئيسيّة فور تغيُّر حالة المخزون أو التنبيهات.
///
/// ✅ تحديثات حيّة:
/// - يشترك في DBService.changes ويُحدِّث القوائم/الشارات تلقائيًا مع Debounce.
/// - يدعم ربط الدفع المؤجّل عبر attachSync(sync) → DB.bindSyncPush(sync.pushFor).
class RepositoryProvider extends ChangeNotifier {
  RepositoryProvider({
    RepositoryService? service,
    DBService? db,
    Duration changeDebounce = const Duration(milliseconds: 250),
  })  : _service = service ?? RepositoryService.instance,
        _db = db ?? DBService.instance,
        _changeDebounce = changeDebounce {
    _listenDbChanges();
  }

  final RepositoryService _service;
  final DBService _db;

  final Duration _changeDebounce;
  StreamSubscription<String>? _dbSub;
  Timer? _debounceTimer;
  bool _refreshBusy = false;

  /* ─── البيانات المجمَّعة في الذاكرة ─── */
  List<ItemType> _types = [];
  final Map<int, List<Item>> _itemsByType = {}; // key = typeId
  List<Item> _lowStock = []; // الأصناف منخفضة المخزون
  bool _hasLowStockAlerts = false;

  /* ─── getters للويدجتات ─── */
  List<ItemType> get types => _types;
  List<Item> itemsOf(int typeId) => _itemsByType[typeId] ?? [];
  List<Item> get lowStockItems => _lowStock;
  bool get hasLowStockBadge => _hasLowStockAlerts;

  /// مطلوب لبعض الشاشات القديمة بنفس الاسم:
  bool get hasPendingAlerts => _hasLowStockAlerts;

  /// 🆕 جميع الأصناف من كافة الأنواع
  List<Item> get allItems =>
      _itemsByType.values.expand((list) => list).toList();

  /* ─── ربط المزامنة (اختياري) ─── */
  /// اربط الدفع المؤجّل لكل جدول بدون استيراد دائري.
  /// يعادل: DBService.instance.bindSyncPush(sync.pushFor)
  void attachSync(SyncService sync) {
    _db.bindSyncPush(sync.pushFor);
  }

  /* ─── عمليات التهيئة ─── */
  Future<void> loadAllData() => bootstrap();
  Future<void> bootstrap() async => _refreshAll();
  Future<void> loadAlerts() async => _checkAlerts();

  /* ─── CRUD: نوع الصنف ─── */
  Future<void> addType(String name) async {
    final newType = await _service.createItemType(name);
    _types.add(newType);
    _itemsByType[newType.id!] = [];
    notifyListeners();
  }

  /* ─── CRUD: الأصناف ─── */
  Future<void> addItem({
    required int typeId,
    required String name,
    required double price,
    required int initialStock,
  }) async {
    final item = await _service.createItem(
      typeId: typeId,
      name: name,
      price: price,
      initialStock: initialStock,
    );
    _itemsByType[typeId]?.add(item);
    await _checkAlerts();
    notifyListeners();
  }

  Future<void> updateItem(Item updated) async {
    await _service.updateItem(updated);
    final list = _itemsByType[updated.typeId];
    if (list != null) {
      final idx = list.indexWhere((e) => e.id == updated.id);
      if (idx != -1) list[idx] = updated;
    }
    await _checkAlerts();
    notifyListeners();
  }

  Future<void> deleteItem(Item item) async {
    await _service.deleteItem(item.id!);
    _itemsByType[item.typeId]?.removeWhere((e) => e.id == item.id);
    await _checkAlerts();
    notifyListeners();
  }

  /* ─── المشتريات ─── */
  Future<void> addPurchase({
    required int itemId,
    required int quantity,
    required double unitPrice,
  }) async {
    await _service.createPurchase(
      itemId: itemId,
      quantity: quantity,
      unitPrice: unitPrice,
    );
    await _refreshItem(itemId);
  }

  /* ─── الاستهلاكات ─── */

  /// استهلاك مرتبط بمريض (الشاشات القديمة)
  Future<void> consumeForPatient({
    required int patientId,
    required int itemId,
    required int quantity,
  }) async {
    await _service.recordConsumption(
      patientId: patientId.toString(),
      itemId: itemId,
      quantity: quantity,
    );
    await _refreshItem(itemId);
  }

  /// استهلاك مباشر بدون ربط بمريض
  Future<void> consumeItem({
    required int itemId,
    required int quantity,
  }) async {
    await _service.recordConsumption(
      patientId: null,
      itemId: itemId,
      quantity: quantity,
    );
    await _refreshItem(itemId);
  }

  /* ─── تنبيهات المخزون ─── */
  Future<void> setAlert({
    required int itemId,
    required double threshold,
  }) async {
    await _service.setAlert(itemId: itemId, threshold: threshold);
    await _checkAlerts();
  }

  /* ─── داخليّات ─── */
  Future<void> _refreshAll() async {
    if (_refreshBusy) return;
    _refreshBusy = true;
    try {
      _types = await _service.fetchItemTypes();
      _itemsByType.clear();
      for (final t in _types) {
        _itemsByType[t.id!] = await _service.fetchItemsByType(t.id!);
      }
      await _checkAlerts(notify: false);
      notifyListeners();
    } finally {
      _refreshBusy = false;
    }
  }

  Future<void> _refreshItem(int itemId) async {
    final item = await _service.fetchItem(itemId);
    if (item == null) return;
    final list = _itemsByType[item.typeId];
    if (list != null) {
      final idx = list.indexWhere((e) => e.id == item.id);
      if (idx != -1) {
        list[idx] = item;
      } else {
        // لو كان العنصر غير موجود محليًا ضمن نوعه لأي سبب:
        list.add(item);
      }
    }
    await _checkAlerts();
    notifyListeners();
  }

  Future<void> _checkAlerts({bool notify = true}) async {
    _hasLowStockAlerts = await _service.anyLowStockAlert();
    _lowStock = _hasLowStockAlerts ? await _service.fetchLowStockItems() : [];
    if (notify) notifyListeners();
  }

  /* ─── تدفّق التحديثات الحيّة من قاعدة البيانات ─── */
  static const Set<String> _interestingTables = {
    'items',
    'item_types',
    'purchases',
    'consumptions',
    'alert_settings',
  };

  void _listenDbChanges() {
    _dbSub?.cancel();
    _dbSub = _db.changes.listen((table) {
      if (_interestingTables.contains(table)) {
        _debounceTimer?.cancel();
        _debounceTimer = Timer(_changeDebounce, () {
          // تغييرات المخزون والتنبيهات تؤثّر على الشارات واللوائح:
          _refreshAll();
        });
      }
    });
  }

  /// تحديث فوري يدوي (مثلاً عند سحب-لتحديث)
  Future<void> refreshNow() => _refreshAll();

  @override
  void dispose() {
    _dbSub?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }
}
