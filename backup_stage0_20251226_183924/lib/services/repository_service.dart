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
    final db = await _db.database;
    final maps = await db.query(
      Item.table,
      where: 'type_id = ? AND ifnull(isDeleted, 0) = 0',
      whereArgs: [typeId],
      orderBy: 'name',
    );
    return maps.map(Item.fromMap).toList();
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
    final item = Item(
      typeId: typeId,
      name: name,
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
    final item = await fetchItem(itemId);
    if (item == null) {
      throw StateError('Item $itemId not found when creating purchase');
    }

    final purchase = Purchase(
      itemId: itemId,
      quantity: quantity,
      unitPrice: unitPrice,
    );

    await _db.insertPurchase(purchase);

    final updatedItem = item.copyWith(stock: item.stock + quantity);
    await _db.updateItem(updatedItem);

    await _evaluateAlertForItem(itemId);
  }

  /*────────── استهلاك (مرتبط بمريض أو عام) ──────────*/
  Future<void> recordConsumption({
    required int itemId,
    required int quantity,
    String? patientId,
  }) async {
    final item = await fetchItem(itemId);
    if (item == null) {
      throw StateError('Item $itemId not found when recording consumption');
    }

    final unitPrice = item.price;
    final consumption = Consumption(
      patientId: patientId,
      itemId: itemId.toString(),
      quantity: quantity,
      amount: unitPrice * quantity,
      date: DateTime.now(),
    );

    await _db.insertConsumption(consumption);

    final updatedItem = item.copyWith(stock: item.stock - quantity);
    await _db.updateItem(updatedItem);

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
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT i.*
      FROM ${Item.table}         AS i
      JOIN ${AlertSetting.table} AS a ON a.item_id = i.id
      WHERE a.is_enabled = 1
        AND i.stock     <= a.threshold
        AND ifnull(i.isDeleted, 0) = 0
      ORDER BY i.stock ASC
    ''');
    return rows.map(Item.fromMap).toList();
  }

  /*────────── تحقُّق سريع للشارة ──────────*/
  Future<bool> anyLowStockAlert() async {
    final db = await _db.database;
    final result = await db.rawQuery('''
      SELECT 1
      FROM ${AlertSetting.table} AS a
      JOIN ${Item.table}         AS i ON i.id = a.item_id
      WHERE a.is_enabled = 1
        AND i.stock     <= a.threshold
        AND ifnull(i.isDeleted, 0) = 0
      LIMIT 1
    ''');
    return result.isNotEmpty;
  }
}
