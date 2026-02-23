// lib/services/repository_service.dart

import 'package:sqflite/sqflite.dart';

import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/purchase.dart';
import 'package:aelmamclinic/models/consumption.dart'; // ← أضفنا هذا السطر
import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/utils/notifications_helper.dart';

/// طبقة الأعمال للمستودع.
/// تعتمد على DBService للوصول إلى SQLite، وعلى NotificationsHelper
/// لإرسال تنبيهات النظام عند انخفاض المخزون.
class RepositoryService {
  RepositoryService._();
  static final RepositoryService instance = RepositoryService._();

  /*────────── موارد داخليّة ──────────*/
  final DBService _db = DBService.instance;
  final NotificationsHelper _notifier = NotificationsHelper.instance;

  /*──────── منفذ عام إلى قاعدة البيانات ────────*/
  Future<Database> get database async => _db.database;
  DBService get db => _db;

  /*────────── جلب البيانات ──────────*/
  Future<List<ItemType>> fetchItemTypes() async {
    return _db.getAllItemTypes();
  }

  Future<List<Item>> fetchItemsByType(int typeId) async {
    final items = await _db.getAllItems();
    final filtered = items.where((i) => i.typeId == typeId).toList();
    filtered.sort((a, b) => a.name.compareTo(b.name));
    return filtered;
  }

  Future<Item?> fetchItem(int id) async {
    final db = await _db.database;
    final maps = await db.query(
      Item.table,
      where: 'id = ? AND ifnull(isDeleted, 0) = 0',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : Item.fromMap(maps.first);
  }

  /*──────── إنشاء / تحديث / حذف ────────*/
  Future<ItemType> createItemType(String name) async {
    final sanitized = name.trim();
    if (sanitized.isEmpty) {
      throw ArgumentError('اسم نوع الصنف فارغ');
    }
    final type = ItemType(name: sanitized);
    final id = await _db.insertItemType(type);
    return type.copyWith(id: id);
  }

  Future<Item> createItem({
    required int typeId,
    required String name,
    required double price,
    required int initialStock,
  }) async {
    final sanitized = name.trim();
    if (sanitized.isEmpty) {
      throw ArgumentError('اسم الصنف فارغ');
    }
    if (price.isNaN || price < 0) {
      throw ArgumentError('السعر غير صالح');
    }
    if (initialStock < 0) {
      throw ArgumentError('الكمية غير صالحة');
    }
    final item = Item(
      typeId: typeId,
      name: sanitized,
      price: price,
      stock: initialStock,
    );
    final id = await _db.insertItem(item);
    return item.copyWith(id: id);
  }

  Future<void> updateItem(Item item) async {
    await _db.updateItem(item);
  }

  Future<void> deleteItem(int id) async {
    final db = await _db.database;
    final existingAlert = await db.query(
      AlertSetting.table,
      where: 'item_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existingAlert.isNotEmpty) {
      final alert = AlertSetting.fromMap(existingAlert.first);
      if (alert.id != null) {
        await _db.deleteAlert(alert.id!);
      } else {
        await db.delete(
          AlertSetting.table,
          where: 'item_id = ?',
          whereArgs: [id],
        );
        await _db.notifyTableChanged(AlertSetting.table);
      }
    }

    await _db.deleteItem(id);
  }

  /*────────── مشتريات ──────────*/
  Future<void> createPurchase({
    required int itemId,
    required int quantity,
    required double unitPrice,
  }) async {
    if (quantity <= 0) {
      throw ArgumentError('الكمية غير صالحة');
    }
    if (unitPrice.isNaN || unitPrice < 0) {
      throw ArgumentError('سعر الوحدة غير صالح');
    }
    final item = await fetchItem(itemId);
    if (item == null) {
      throw StateError('Item $itemId not found when creating purchase');
    }

    final purchase = Purchase(
      itemId: itemId,
      quantity: quantity,
      unitPrice: unitPrice,
    );

    final db = await _db.database;
    await db.transaction((txn) async {
      final data =
          await _db.prepareInsert(Purchase.table, purchase.toMap(), executor: txn);
      await txn.insert(Purchase.table, data);
      final updatedItem = item.copyWith(stock: item.stock + quantity);
      await txn.update(
        Item.table,
        updatedItem.toMap(),
        where: 'id = ?',
        whereArgs: [itemId],
      );
    });
    await _db.notifyTableChanged(Purchase.table);
    await _db.notifyTableChanged(Item.table);

    await _evaluateAlertForItem(itemId);
  }

  /*────────── استهلاك (مرتبط بمريض أو عام) ──────────*/
  Future<void> recordConsumption({
    required int itemId,
    required int quantity,
    String? patientId,
  }) async {
    if (quantity <= 0) {
      throw ArgumentError('الكمية غير صالحة');
    }
    final item = await fetchItem(itemId);
    if (item == null) {
      throw StateError('Item $itemId not found when recording consumption');
    }
    if (item.stock - quantity < 0) {
      throw StateError('الكمية تتجاوز المخزون المتاح');
    }

    final unitPrice = item.price;
    final consumption = Consumption(
      patientId: patientId,
      itemId: itemId.toString(),
      quantity: quantity,
      amount: unitPrice * quantity,
      date: DateTime.now(),
    );

    final db = await _db.database;
    await db.transaction((txn) async {
      final data = await _db.prepareInsert(
        Consumption.table,
        consumption.toMap(),
        executor: txn,
      );
      await txn.insert(Consumption.table, data);
      final updatedItem = item.copyWith(stock: item.stock - quantity);
      await txn.update(
        Item.table,
        updatedItem.toMap(),
        where: 'id = ?',
        whereArgs: [itemId],
      );
    });
    await _db.notifyTableChanged(Consumption.table);
    await _db.notifyTableChanged(Item.table);

    await _evaluateAlertForItem(itemId);
  }

  /*────────── تنبيه انخفاض المخزون ──────────*/
  Future<void> setAlert({
    required int itemId,
    required double threshold,
  }) async {
    final db = await _db.database;

    final existing = await db.query(
      AlertSetting.table,
      where: 'item_id = ?',
      whereArgs: [itemId],
      limit: 1,
    );

    if (existing.isEmpty) {
      final alert = AlertSetting(
        itemId: itemId,
        threshold: threshold,
        isEnabled: true,
      );
      await _db.insertAlert(alert);
    } else {
      final alert = AlertSetting.fromMap(existing.first)
          .copyWith(threshold: threshold, isEnabled: true);
      if (alert.id != null) {
        await _db.updateAlert(alert);
      } else {
        await db.update(
          AlertSetting.table,
          {
            'threshold': threshold,
            'is_enabled': 1,
          },
          where: 'item_id = ?',
          whereArgs: [itemId],
        );
        await _db.notifyTableChanged(AlertSetting.table);
      }
    }

    await _evaluateAlertForItem(itemId);
  }

  /*────────── فحص وتنفيذ التنبيه ──────────*/
  Future<void> _evaluateAlertForItem(int itemId) async {
    final db = await _db.database;
    final item = await fetchItem(itemId);
    if (item == null) return;

    final maps = await db.query(
      AlertSetting.table,
      where: 'item_id = ? AND is_enabled = 1',
      whereArgs: [itemId],
      limit: 1,
    );
    if (maps.isEmpty) return;
    final alert = AlertSetting.fromMap(maps.first);

    if (item.stock <= alert.threshold) {
      final today = DateTime.now();
      final last = alert.lastTriggered;

      final triggeredToday = last != null &&
          last.year == today.year &&
          last.month == today.month &&
          last.day == today.day;

      if (!triggeredToday) {
        // إرسال إشعار
        await _notifier.triggerLowStock(item);

        // تحديث last_triggered
        final updatedAlert = alert.copyWith(lastTriggered: today);
        if (updatedAlert.id != null) {
          await _db.updateAlert(updatedAlert);
        } else {
          await db.update(
            AlertSetting.table,
            {'last_triggered': today.toIso8601String()},
            where: 'item_id = ?',
            whereArgs: [itemId],
          );
          await _db.notifyTableChanged(AlertSetting.table);
        }
      }
    }
  }

  /*────────── الأصناف منخفضة المخزون ──────────*/
  Future<List<Item>> fetchLowStockItems() async {
    return _db.getLowStockItems();
  }

  /*────────── تحقُّق سريع للشارة ──────────*/
  Future<bool> anyLowStockAlert() async {
    return _db.hasLowStockAlert();
  }
}
