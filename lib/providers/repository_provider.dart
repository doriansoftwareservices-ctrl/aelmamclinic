// lib/providers/repository_provider.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/inventory_health_report.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/utils/app_observability.dart';

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
  String? _boundAccountId;
  String? _queuedAuthAccountId;
  Future<void>? _authChangeDrain;
  bool _disposed = false;
  bool _pendingTypesRefresh = false;
  bool _pendingItemsRefresh = false;
  bool _pendingAlertsRefresh = false;
  bool _refreshRequestedWhileBusy = false;

  /* ─── البيانات المجمَّعة في الذاكرة ─── */
  List<ItemType> _types = [];
  final Map<int, List<Item>> _itemsByType = {}; // key = typeId
  List<Item> _orphanItems = []; // أصناف بدون نوع
  List<Item> _lowStock = []; // الأصناف منخفضة المخزون
  bool _hasLowStockAlerts = false;

  /* ─── getters للويدجتات ─── */
  List<ItemType> get types => _types;
  List<Item> itemsOf(int typeId) => _itemsByType[typeId] ?? [];
  List<Item> get orphanItems => _orphanItems;
  List<Item> get lowStockItems => _lowStock;
  bool get hasLowStockBadge => _hasLowStockAlerts;

  /// مطلوب لبعض الشاشات القديمة بنفس الاسم:
  bool get hasPendingAlerts => _hasLowStockAlerts;

  /// 🆕 جميع الأصناف من كافة الأنواع
  List<Item> get allItems =>
      _itemsByType.values.expand((list) => list).toList() + _orphanItems;

  /* ─── ربط المزامنة (اختياري) ─── */
  /// اربط الدفع المؤجّل لكل جدول بدون استيراد دائري.
  /// يعادل: DBService.instance.bindSyncPush(sync.pushFor)
  void attachSync(SyncService sync) {
    _db.bindSyncPush(sync.pushFor);
  }

  /// استدعِها عند تغيّر حساب المستخدم (تسجيل دخول/خروج).
  Future<void> onAuthChanged(String? accountId) async {
    final trimmed = accountId?.trim();
    if (trimmed == _boundAccountId) return;
    _boundAccountId = trimmed;

    if (trimmed == null || trimmed.isEmpty) {
      // نظّف الذاكرة حتى لا تختلط بيانات حسابين
      _types = [];
      _itemsByType.clear();
      _orphanItems = [];
      _lowStock = [];
      _hasLowStockAlerts = false;
      notifyListeners();
      return;
    }

    // تأكد من ملء account_id للبيانات القديمة (قبل تفعيل عمود الحساب).
    await _db.backfillAccountForTables(const [
      'item_types',
      'items',
      'purchases',
      'consumptions',
      'alert_settings',
    ], trimmed);

    // إعادة تحميل بيانات المستودع للحساب الحالي
    await _refreshSnapshot(
      refreshTypes: true,
      refreshItems: true,
      refreshAlerts: true,
    );
  }

  void scheduleAuthChange(String? accountId) {
    _queuedAuthAccountId = accountId?.trim();
    if (_authChangeDrain != null) return;
    _authChangeDrain = Future.microtask(_drainAuthChanges);
  }

  /* ─── عمليات التهيئة ─── */
  Future<void> loadAllData() => bootstrap();
  Future<void> bootstrap() async => _refreshSnapshot(
        refreshTypes: true,
        refreshItems: true,
        refreshAlerts: true,
      );
  Future<void> loadAlerts() async => _checkAlerts();

  Future<InventoryRepairReport> repairInventoryIntegrity({
    bool backup = true,
  }) async {
    return _service.repairInventoryIntegrity(backup: backup);
  }

  Future<InventoryHealthReport> fetchHealthReport() async {
    return _service.fetchInventoryHealth();
  }

  /* ─── CRUD: نوع الصنف ─── */
  Future<void> addType(String name) async {
    final newType = await _service.createItemType(name);
    final idx = _types.indexWhere((t) => t.id == newType.id);
    if (idx >= 0) {
      _types[idx] = newType;
    } else {
      _types.add(newType);
    }
    _itemsByType.putIfAbsent(newType.id!, () => []);
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
    final list = _itemsByType.putIfAbsent(typeId, () => []);
    final idx = list.indexWhere((e) => e.id == item.id);
    if (idx >= 0) {
      list[idx] = item;
    } else {
      list.add(item);
    }
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
  Future<void> _drainAuthChanges() async {
    do {
      final next = _queuedAuthAccountId;
      _queuedAuthAccountId = null;
      if (_disposed) {
        _authChangeDrain = null;
        return;
      }
      try {
        await onAuthChanged(next);
      } catch (e, st) {
        AppObservability.warn(
          scope: 'REPO',
          code: ObsCode.repoAuthChangeFailed,
          message: 'repository auth change reconciliation failed',
          flowId: AppObservability.newFlowId('repo_auth_change'),
          context: {
            'accountId': next,
          },
          error: e,
          stackTrace: st,
        );
      }
    } while (_queuedAuthAccountId != null && !_disposed);
    _authChangeDrain = null;
  }

  Future<void> _refreshSnapshot({
    bool refreshTypes = true,
    bool refreshItems = true,
    bool refreshAlerts = true,
  }) async {
    if (_refreshBusy) {
      _refreshRequestedWhileBusy = true;
      _pendingTypesRefresh = _pendingTypesRefresh || refreshTypes;
      _pendingItemsRefresh = _pendingItemsRefresh || refreshItems;
      _pendingAlertsRefresh = _pendingAlertsRefresh || refreshAlerts;
      return;
    }
    _refreshBusy = true;
    try {
      final accountId = await _db.currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) {
        if (_types.isNotEmpty || _itemsByType.isNotEmpty || _orphanItems.isNotEmpty) {
          return;
        }
      }

      final snapshot = await _service.fetchSnapshot(
        includeTypes: refreshTypes,
        includeItems: refreshItems,
        includeAlerts: refreshAlerts,
      );

      if (refreshTypes) {
        final dedup = <String, ItemType>{};
        for (final t in snapshot.types) {
          final nameKey = t.name.trim().toLowerCase();
          final key = t.id != null ? 'id:${t.id}' : 'name:$nameKey';
          if (!dedup.containsKey(key)) {
            dedup[key] = t;
          }
        }
        _types = dedup.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
      }

      if (refreshItems) {
        _itemsByType.clear();
        _orphanItems = [];
        for (final t in _types) {
          if (t.id != null) {
            _itemsByType[t.id!] = <Item>[];
          }
        }
        for (final item in snapshot.items) {
          final list = _itemsByType[item.typeId];
          if (list != null) {
            list.add(item);
          } else {
            _orphanItems.add(item);
          }
        }
        for (final entry in _itemsByType.entries) {
          entry.value.sort((a, b) => a.name.compareTo(b.name));
        }
        _orphanItems.sort((a, b) => a.name.compareTo(b.name));
      }

      if (refreshAlerts) {
        _hasLowStockAlerts = snapshot.hasLowStockAlerts;
        _lowStock = snapshot.lowStockItems;
      }

      notifyListeners();
    } catch (e, st) {
      AppObservability.warn(
        scope: 'REPO',
        code: ObsCode.repoRefreshFailed,
        message: 'repository snapshot refresh failed',
        flowId: AppObservability.newFlowId('repo_refresh'),
        context: {
          'refreshTypes': refreshTypes,
          'refreshItems': refreshItems,
          'refreshAlerts': refreshAlerts,
        },
        error: e,
        stackTrace: st,
      );
    } finally {
      _refreshBusy = false;
      if (_refreshRequestedWhileBusy && !_disposed) {
        _refreshRequestedWhileBusy = false;
        final refreshTypesNext = _pendingTypesRefresh;
        final refreshItemsNext = _pendingItemsRefresh;
        final refreshAlertsNext = _pendingAlertsRefresh;
        _pendingTypesRefresh = false;
        _pendingItemsRefresh = false;
        _pendingAlertsRefresh = false;
        unawaited(_refreshSnapshot(
          refreshTypes: refreshTypesNext,
          refreshItems: refreshItemsNext,
          refreshAlerts: refreshAlertsNext,
        ));
      }
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
    if (list == null) {
      final idx = _orphanItems.indexWhere((e) => e.id == item.id);
      if (idx >= 0) {
        _orphanItems[idx] = item;
      } else {
        _orphanItems.add(item);
        _orphanItems.sort((a, b) => a.name.compareTo(b.name));
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
          _pendingTypesRefresh =
              _pendingTypesRefresh || table == 'item_types';
          _pendingItemsRefresh =
              _pendingItemsRefresh ||
              table == 'item_types' ||
              table == 'items' ||
              table == 'purchases' ||
              table == 'consumptions';
          _pendingAlertsRefresh = true;
          _debounceTimer?.cancel();
          _debounceTimer = Timer(_changeDebounce, () {
            final refreshTypes = _pendingTypesRefresh;
            final refreshItems = _pendingItemsRefresh;
            final refreshAlerts = _pendingAlertsRefresh;
            _pendingTypesRefresh = false;
            _pendingItemsRefresh = false;
            _pendingAlertsRefresh = false;
            if (_refreshBusy) {
              _refreshRequestedWhileBusy = true;
              _pendingTypesRefresh = _pendingTypesRefresh || refreshTypes;
              _pendingItemsRefresh = _pendingItemsRefresh || refreshItems;
              _pendingAlertsRefresh = _pendingAlertsRefresh || refreshAlerts;
              return;
            }
            unawaited(_refreshSnapshot(
              refreshTypes: refreshTypes,
              refreshItems: refreshItems,
              refreshAlerts: refreshAlerts,
            ));
          });
        }
      });
  }

  /// تحديث فوري يدوي (مثلاً عند سحب-لتحديث)
  Future<void> refreshNow() => _refreshSnapshot(
        refreshTypes: true,
        refreshItems: true,
        refreshAlerts: true,
      );

  @override
  void dispose() {
    _disposed = true;
    _dbSub?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }
}
