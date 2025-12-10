// lib/services/db_parity_v3.dart
//
// AELMAM CLINIC - Local SQLite parity with Supabase (v3)
// يعمل على أندرويد وسطح المكتب. يولِّد نفس تأثير سكربت
// aelmam_parity_v3.sql الذي زوّدتني به، مع احترام قيود
// SQLite 3.10 (بدون window functions).
//
// • يضيف أعمدة المزامنة (account_id, device_id, local_id, updated_at)
// • يملأ القيم من sync_identity
// • يزيل التكرارات على (account_id,device_id,local_id)
// • يدمج التكرارات الطبيعية (drugs, items) بإعادة ربط المراجع ثم الحذف
// • ينشئ الفهارس المطابقة للسحابة
// • ينشئ Triggers لتحديث updated_at ولملء أعمدة المزامنة بعد INSERT
//
// الاستخدام:
//
//   final db = await DBService.instance.database;
//   await DBParityV3().run(
//     db,
//     accountId: currentAccountId, // اختياري
//     verbose: true,
//   );
//
// ملاحظة: هذا الملف يعتمد فقط على sqflite ولا يستورد DBService لتفادي الدوران.

import 'dart:async';
import 'package:sqflite/sqflite.dart';

class DBParityV3 {
  /// كل الجداول المتزامنة محليًا (بدون attachments لأنها محلية فقط)
  static const List<String> _tables = [
    'patients',
    'returns',
    'consumptions',
    'drugs',
    'prescriptions',
    'prescription_items',
    'complaints',
    'appointments',
    'doctors',
    'consumption_types',
    'medical_services',
    'service_doctor_share',
    'employees',
    'employees_loans',
    'employees_salaries',
    'employees_discounts',
    'items',
    'item_types',
    'purchases',
    'alert_settings',
    'financial_logs',
    'patient_services',
  ];

  /// تنفيذ السكربت بمراحل آمنة (نستمر عند أخطاء غير حرجة مثل تكرار عمود/فهرس).
  Future<void> run(
    Database db, {
    String? accountId,
    bool verbose = false,
  }) async {
    final sw = Stopwatch()..start();
    void log(Object msg) {
      if (verbose) print('[parity_v3] $msg');
    }

    // 0) PRAGMA أساسية
    await _q(db, 'PRAGMA foreign_keys = ON');
    await _q(db, 'PRAGMA journal_mode = WAL');
    await _q(db, 'PRAGMA synchronous = NORMAL');
    await _q(db, 'PRAGMA busy_timeout = 5000');
    await _q(
        db, 'PRAGMA recursive_triggers = OFF'); // نتجنب استدعاء التريجر لنفسه

    // 1) sync_identity (توليد device_id إن لم يوجد) + كتابة account_id لو مرّرتَه
    await _ensureSyncIdentity(db, accountId: accountId, verbose: verbose);

    // 2) إضافة أعمدة المزامنة (idempotent)
    await _ensureSyncColumns(db, verbose: verbose);

    // 3) تعبئة القيم الفارغة (account_id/device_id/local_id/updated_at)
    await _backfillSyncColumns(db, verbose: verbose);

    // 4) إزالة التكرارات على (account_id,device_id,local_id)
    await _dedupeAccDevLocal(db, verbose: verbose);

    // 4-bis) دمج التكرارات الطبيعية (drugs/items) بإعادة ربط المراجع قبل الحذف
    await _mergeNaturalDuplicates(db, verbose: verbose);

    // 5) فهارس مطابقة للسحابة + فهارس الطبيعة
    await _createIndexes(db, verbose: verbose);

    // 6) Triggers لتحديث updated_at ولملء أعمدة المزامنة بعد INSERT
    await _createTriggers(db, verbose: verbose);

    // 7) فحوصات نهائية (مجرد لوقات)
    final checks = await _finalChecks(db);
    if (verbose) {
      checks.forEach((k, v) => print('[parity_v3][check] $k => $v'));
    }

    log('done in ${sw.elapsed.inMilliseconds} ms');
  }

  /*──────────────────────── helpers ────────────────────────*/

  Future<void> _q(Database db, String sql, [List<Object?>? args]) async {
    try {
      await db.rawQuery(sql, args);
    } catch (_) {
      // نتجاهل
    }
  }

  Future<void> _exec(Database db, String sql, [List<Object?>? args]) async {
    try {
      await db.execute(sql, args);
    } catch (_) {
      // نتجاهل
    }
  }

  Future<void> _execOn(DatabaseExecutor ex, String sql,
      [List<Object?>? args]) async {
    try {
      await ex.execute(sql, args);
    } catch (_) {
      // نتجاهل
    }
  }

  Future<void> _ensureSyncIdentity(
    Database db, {
    String? accountId,
    bool verbose = false,
  }) async {
    await _exec(db, '''
      CREATE TABLE IF NOT EXISTS sync_identity(
        account_id TEXT,
        device_id  TEXT
      )
    ''');

    // أدخل صفًا بديهيًا إن لم يوجد
    await _exec(db, '''
      INSERT INTO sync_identity(account_id,device_id)
      SELECT NULL, lower(hex(randomblob(16)))
      WHERE NOT EXISTS(SELECT 1 FROM sync_identity)
    ''');

    if (accountId != null) {
      await _exec(db, 'UPDATE sync_identity SET account_id = ?', [accountId]);
      if (verbose) print('[parity_v3] account_id => $accountId');
    }
  }

  Future<void> _ensureSyncColumns(Database db, {bool verbose = false}) async {
    for (final t in _tables) {
      // SQLite 3.10 لا يدعم IF NOT EXISTS للعمود؛ نحاول ونُهمل خطأ "duplicate column"
      await _exec(db, 'ALTER TABLE $t ADD COLUMN account_id TEXT');
      await _exec(db, 'ALTER TABLE $t ADD COLUMN device_id  TEXT');
      await _exec(db, 'ALTER TABLE $t ADD COLUMN local_id   INTEGER');
      await _exec(db, 'ALTER TABLE $t ADD COLUMN updated_at TEXT');
      if (verbose) print('[parity_v3] ensured sync columns on $t');
    }
  }

  Future<void> _backfillSyncColumns(Database db, {bool verbose = false}) async {
    for (final t in _tables) {
      await _exec(db,
          'UPDATE $t SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity))');
      await _exec(db,
          'UPDATE $t SET device_id  = COALESCE(device_id, (SELECT device_id  FROM sync_identity))');
      await _exec(db, 'UPDATE $t SET local_id   = COALESCE(local_id, rowid)');
      await _exec(db,
          'UPDATE $t SET updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)');
      if (verbose) print('[parity_v3] backfilled $t');
    }
  }

  Future<void> _dedupeAccDevLocal(Database db, {bool verbose = false}) async {
    for (final t in _tables) {
      final sql = '''
      DELETE FROM $t WHERE EXISTS (
        SELECT 1 FROM $t AS b
        WHERE $t.account_id = b.account_id
          AND $t.device_id  = b.device_id
          AND $t.local_id   = b.local_id
          AND (COALESCE(b.updated_at,'') > COALESCE($t.updated_at,'')
               OR (b.updated_at = $t.updated_at AND b.rowid > $t.rowid))
      )
      ''';
      await _exec(db, sql);
      if (verbose) print('[parity_v3] dedup acc/dev/local on $t');
    }
  }

  /// دمج آمن لتكرارات الأسماء الطبيعية:
  /// - drugs: (account_id, lower(trim(name)))
  /// - items: (account_id, type_id, trim(name))
  /// يتم داخل معاملة: بناء فائز/خاسر → إعادة ربط المراجع → حذف الخاسرين → تنظيف الأسماء
  Future<void> _mergeNaturalDuplicates(Database db,
      {bool verbose = false}) async {
    await db.transaction((txn) async {
      // ===== DRUGS =====
      // 1) جدول بالفائزين (الأحدث بـ updated_at ثم الأعلى rowid)
      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_drug_winners');
      await _execOn(
          txn, 'CREATE TEMP TABLE tmp_drug_winners(id INTEGER PRIMARY KEY)');
      await _execOn(txn, '''
        INSERT OR IGNORE INTO tmp_drug_winners(id)
        SELECT d.id
        FROM drugs d
        WHERE NOT EXISTS (
          SELECT 1 FROM drugs b
          WHERE b.account_id = d.account_id
            AND lower(trim(b.name)) = lower(trim(d.name))
            AND (COALESCE(b.updated_at,'') > COALESCE(d.updated_at,'')
                 OR (b.updated_at = d.updated_at AND b.rowid > d.rowid))
        )
      ''');

      // 2) خريطة الخاسر ← الفائز
      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_drug_map');
      await _execOn(txn,
          'CREATE TEMP TABLE tmp_drug_map(loser_id INTEGER PRIMARY KEY, winner_id INTEGER NOT NULL)');
      await _execOn(txn, '''
        INSERT OR IGNORE INTO tmp_drug_map(loser_id, winner_id)
        SELECT d.id, w.id
        FROM drugs d
        JOIN drugs w
          ON w.id IN (SELECT id FROM tmp_drug_winners)
         AND w.account_id = d.account_id
         AND lower(trim(w.name)) = lower(trim(d.name))
        WHERE d.id != w.id
      ''');

      // 3) إعادة ربط المراجع
      await _execOn(txn, '''
        UPDATE prescription_items
           SET drugId = (SELECT winner_id FROM tmp_drug_map WHERE loser_id = prescription_items.drugId)
         WHERE drugId IN (SELECT loser_id FROM tmp_drug_map)
      ''');

      // 4) حذف الخاسرين
      await _execOn(txn,
          'DELETE FROM drugs WHERE id IN (SELECT loser_id FROM tmp_drug_map)');

      // 5) تنظيف الأسماء (TRIM) بعد الدمج
      await _execOn(
          txn, "UPDATE drugs SET name = TRIM(name) WHERE name IS NOT NULL");

      // ===== ITEMS =====
      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_item_winners');
      await _execOn(
          txn, 'CREATE TEMP TABLE tmp_item_winners(id INTEGER PRIMARY KEY)');
      await _execOn(txn, '''
        INSERT OR IGNORE INTO tmp_item_winners(id)
        SELECT i.id
        FROM items i
        WHERE NOT EXISTS (
          SELECT 1 FROM items b
          WHERE b.account_id = i.account_id
            AND b.type_id     = i.type_id
            AND TRIM(b.name)  = TRIM(i.name)
            AND (COALESCE(b.updated_at,'') > COALESCE(i.updated_at,'')
                 OR (b.updated_at = i.updated_at AND b.rowid > i.rowid))
        )
      ''');

      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_item_map');
      await _execOn(txn,
          'CREATE TEMP TABLE tmp_item_map(loser_id INTEGER PRIMARY KEY, winner_id INTEGER NOT NULL)');
      await _execOn(txn, '''
        INSERT OR IGNORE INTO tmp_item_map(loser_id, winner_id)
        SELECT i.id, w.id
        FROM items i
        JOIN items w
          ON w.id IN (SELECT id FROM tmp_item_winners)
         AND w.account_id = i.account_id
         AND w.type_id    = i.type_id
         AND TRIM(w.name) = TRIM(i.name)
        WHERE i.id != w.id
      ''');

      // إعادة ربط المراجع المحتملة
      // 1) استهلاكات: itemId نصّي
      await _execOn(txn, '''
        UPDATE consumptions
           SET itemId = CAST((SELECT winner_id FROM tmp_item_map WHERE loser_id = CAST(itemId AS INTEGER)) AS TEXT)
         WHERE itemId IN (SELECT CAST(loser_id AS TEXT) FROM tmp_item_map)
      ''');

      // 2) المشتريات (إن كان بها item_id)
      await _execOn(txn, '''
        UPDATE purchases
           SET item_id = (SELECT winner_id FROM tmp_item_map WHERE loser_id = purchases.item_id)
         WHERE EXISTS (SELECT 1 FROM pragma_table_info('purchases') WHERE name = 'item_id')
           AND item_id IN (SELECT loser_id FROM tmp_item_map)
      ''');

      // 3) إعدادات التنبيه (alert_settings.item_id)
      await _execOn(txn, '''
        UPDATE alert_settings
           SET item_id = (SELECT winner_id FROM tmp_item_map WHERE loser_id = alert_settings.item_id)
         WHERE item_id IN (SELECT loser_id FROM tmp_item_map)
      ''');

      // حذف الخاسرين
      await _execOn(txn,
          'DELETE FROM items WHERE id IN (SELECT loser_id FROM tmp_item_map)');

      // تنظيف أسماء العناصر
      await _execOn(
          txn, "UPDATE items SET name = TRIM(name) WHERE name IS NOT NULL");

      // إسقاط الجداول المؤقتة (اختياري)
      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_drug_winners');
      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_drug_map');
      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_item_winners');
      await _execOn(txn, 'DROP TABLE IF EXISTS tmp_item_map');
    });

    if (verbose) {
      print(
          '[parity_v3] natural duplicates merged for drugs/items (with repoint)');
    }
  }

  Future<void> _createIndexes(Database db, {bool verbose = false}) async {
    // فهرس فريد لكل جدول على (account_id,device_id,local_id)
    for (final t in _tables) {
      final idx = '${t}_uix_acc_dev_local';
      await _exec(
        db,
        'CREATE UNIQUE INDEX IF NOT EXISTS $idx ON $t(account_id, device_id, local_id)',
      );
    }

    // فهارس الطبيعة
    await _exec(db,
        'CREATE UNIQUE INDEX IF NOT EXISTS uidx_drugs_name_per_account ON drugs(account_id, lower(name))');
    await _exec(db,
        'CREATE UNIQUE INDEX IF NOT EXISTS items_type_name ON items(account_id, type_id, name)');

    if (verbose) print('[parity_v3] indexes ensured');
  }

  Future<void> _createTriggers(Database db, {bool verbose = false}) async {
    // AFTER UPDATE: touch updated_at (مرة واحدة فقط لتفادي الحلقة)
    for (final t in _tables) {
      final trg = 'trg_${t}_touch_updated_at';
      await _exec(db, '''
        CREATE TRIGGER IF NOT EXISTS $trg
        AFTER UPDATE ON $t FOR EACH ROW
        WHEN NEW.updated_at IS OLD.updated_at
        BEGIN
          UPDATE $t SET updated_at = CURRENT_TIMESTAMP WHERE rowid = NEW.rowid;
        END;
      ''');
    }

    // AFTER INSERT: تعبئة account_id/device_id/local_id/updated_at
    for (final t in _tables) {
      final trg = 'trg_${t}_fill_sync_cols';
      await _exec(db, '''
        CREATE TRIGGER IF NOT EXISTS $trg
        AFTER INSERT ON $t FOR EACH ROW
        BEGIN
          UPDATE $t
             SET account_id = COALESCE(account_id,(SELECT account_id FROM sync_identity)),
                 device_id  = COALESCE(device_id, (SELECT device_id  FROM sync_identity)),
                 local_id   = COALESCE(local_id, rowid),
                 updated_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
           WHERE rowid = NEW.rowid;
        END;
      ''');
    }

    if (verbose) print('[parity_v3] triggers ensured');
  }

  Future<Map<String, int>> _finalChecks(Database db) async {
    final Map<String, int> out = {};
    Future<void> check(String key, String sql) async {
      try {
        final res = await db.rawQuery(sql);
        final v = (res.isNotEmpty ? res.first.values.first : 0) as int? ?? 0;
        out[key] = v;
      } catch (_) {
        out[key] = -1; // إشارة لفشل الفحص
      }
    }

    // تكرارات acc/dev/local (يُفترض 0)
    for (final t in _tables) {
      final k = 'dup_acc_dev_local_$t';
      final sql =
          "SELECT COUNT(*) AS c FROM (SELECT account_id,device_id,local_id,COUNT(*) c FROM $t GROUP BY 1,2,3 HAVING c>1)";
      await check(k, sql);
    }

    // Checks الطبيعية
    await check(
      'dup_drugs_name_per_account',
      "SELECT COUNT(*) c FROM (SELECT account_id, lower(TRIM(name)) k, COUNT(*) c FROM drugs GROUP BY 1,2 HAVING c>1)",
    );
    await check(
      'dup_items_type_name',
      "SELECT COUNT(*) c FROM (SELECT account_id, type_id, TRIM(name) k, COUNT(*) c FROM items GROUP BY 1,2,3 HAVING c>1)",
    );

    return out;
  }
}
