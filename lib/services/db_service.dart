library db_service;

// lib/services/db_service.dart
// - Works on Android + Desktop (Windows/Linux/macOS) using sqflite + sqflite_common_ffi
// - Fix generics: Future<int> (not Future[int])
// - Add `dart:async` import so `Future` is recognized
// - Enable WAL & add a lightweight change stream for live sync integrations.
// - Windows path unified to C:\aelmam_clinic with auto-migration from legacy D:\aelmam_clinic
//
// 🔗 للربط مع SyncService (الدفع المؤجّل لكل جدول):
// final sync = SyncService(db, accountId, deviceId: deviceId);
// DBService.instance.bindSyncPush(sync.pushFor);

import 'dart:async';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'package:path/path.dart' as p;
import 'package:meta/meta.dart';

/*─────────────────── موديلات ───────────────────*/
import 'package:aelmamclinic/models/patient_service.dart';
import 'package:aelmamclinic/models/drug.dart';
import 'package:aelmamclinic/models/prescription.dart';
import 'package:aelmamclinic/models/prescription_item.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/models/appointment.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/models/employee.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/purchase.dart';
import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/models/attachment.dart';

/*─────────────── خدمة الإشعارات ───────────────*/
import 'notification_service.dart';

part 'db_service_parts/patient_local_repository.dart';

/// دالة اختيارية يتم استدعاؤها بعد أي تعديل محلي.
/// مررها من أعلى (مثلاً من AuthProvider) لعمل push تلقائي للجدول المتأثر.
typedef LocalChangeCallback = Future<void> Function(String tableName);

/// 🗂️ الجداول التي تُزامَن (تُستخدم لضبط أعمدة المزامنة + تحديد من يُدفع للSyncService)
const Set<String> _kSyncTables = {
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
  // ⚠️ 'attachments' مستبعدة عمدًا لأنها محلية فقط
};

// جداول تؤثر على إحصاءات الواجهة (لتمييز تحديث الإحصاءات بسرعة)
const Set<String> _kStatsTables = {
  'patients',
  'returns',
  'consumptions',
  'prescriptions',
  'prescription_items',
  'appointments',
  'doctors',
  'medical_services',
  'service_doctor_share',
  'employees_loans',
  'employees_discounts',
  'employees_salaries',
  'financial_logs',
  'patient_services',
  'items',
  'item_types',
  'alert_settings',
};

class DBService {
  DBService._();
  static final DBService instance = DBService._();

  static Database? _db;
  // 🧯 يمنع سباقات الفتح عند استدعاء .database من عدّة أماكن بالتوازي
  static Future<Database>? _opening;
  late final PatientLocalRepository patients = PatientLocalRepository(this);

  static String? _testDbPathOverride;

  /// Stream يبث اسم الجدول عند أي تعديل محلي (مكمل لـ onLocalChange)
  final _changeController = StreamController<String>.broadcast();
  Stream<String> get changes => _changeController.stream;

  /// يمكنك تعيينها من الخارج:
  /// DBService.instance.onLocalChange = (tbl) => sync.pushFor(tbl);
  LocalChangeCallback? onLocalChange;

  /// تجميع + تأخير خفيف لنداءات الـ push لتفادي ضغط الطلبات و"database is locked"
  final Map<String, Timer> _pushDebouncers = <String, Timer>{};
  final Set<String> _pendingTables = <String>{};

  /// ربط سريع مع SyncService.pushFor (تفادي الاستيراد الدائري) + تفريغ المعلّق
  void bindSyncPush(LocalChangeCallback callback) {
    onLocalChange = callback;
    // تفريغ كل الجداول التي تكدّست قبل الربط
    for (final t in _pendingTables) {
      _schedulePush(t);
    }
    _pendingTables.clear();
  }

  /// تنبيه يدوي بأن جدولًا تغيّر (لو احتجت خارج دوال الخدمة).
  Future<void> notifyTableChanged(String table) => _markChanged(table);

  Future<void> _markChanged(String table) async {
    try {
      // بثّ فوري للتغييرات (للاستخدامات الاختيارية داخل التطبيق)
      if (!_changeController.isClosed) {
        _changeController.add(table);
      }

      if (_kStatsTables.contains(table)) {
        unawaited(markStatisticsDirty());
      }

      // 🛑 الدفع للمزامنة فقط للجداول المتزامنة (attachments تبقى خارج الدفع)
      if (!_kSyncTables.contains(table)) {
        return;
      }

      // إذا لم تكن آلية الدفع مربوطة بعد → خزّن الاسم مؤقتًا
      if (onLocalChange == null) {
        _pendingTables.add(table);
      } else {
        _schedulePush(table);
      }
    } catch (_) {
      // نتجاهل أي خطأ حتى لا يكسر عمليات الكتابة المحلية
    }
  }

  /// بث تغيير دون جدولة دفع (للعمليات القادمة من المزامنة).
  void emitPassiveChange(String table) {
    try {
      if (!_changeController.isClosed) {
        _changeController.add(table);
      }
      if (_kStatsTables.contains(table)) {
        unawaited(markStatisticsDirty());
      }
    } catch (_) {}
  }

  /// جدولة دفع متأخر (Debounce) لجدول واحد
  void _schedulePush(String table) {
    _pushDebouncers[table]?.cancel();
    _pushDebouncers[table] = Timer(const Duration(milliseconds: 220), () async {
      try {
        final cb = onLocalChange;
        if (cb != null) {
          await cb(table);
        } else {
          // عاد انفصل الربط فجأة؟ أعدها معلّقة
          _pendingTables.add(table);
        }
      } catch (_) {
        // لا نرمي الخطأ هنا
      }
    });
  }

  void dispose() {
    onLocalChange = null;
    for (final t in _pushDebouncers.values) {
      t.cancel();
    }
    _pushDebouncers.clear();
    if (!_changeController.isClosed) {
      _changeController.close();
    }
  }

  /*────────────────── init / open ──────────────────*/
  Future<Database> get database async {
    if (_db != null) return _db!;
    if (_opening != null) return _opening!;
    final future = _initDB('clinic.db');
    _opening = future;
    _db = await future;
    _opening = null;
    return _db!;
  }

  Future<Database> _initDB(String fileName) async {
    // تهيئة FFI لسطح المكتب
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqflite_ffi.sqfliteFfiInit();
      databaseFactory = sqflite_ffi.databaseFactoryFfi;
    }

    final overridePath = _testDbPathOverride;
    String dbPath;
    if (overridePath != null && overridePath.isNotEmpty) {
      dbPath = overridePath;
      try {
        await File(dbPath).parent.create(recursive: true);
      } catch (_) {}
    } else if (Platform.isWindows) {
      // ✅ توحيد المسار على C:\aelmam_clinic + هجرة تلقائية من D:\aelmam_clinic إن وُجد
      const targetFolder = r'C:\aelmam_clinic';
      final dir = Directory(targetFolder);
      if (!(await dir.exists())) {
        await dir.create(recursive: true);
      }
      final legacyFile = File(p.join(r'D:\aelmam_clinic', fileName));
      final targetFile = File(p.join(targetFolder, fileName));
      if (await legacyFile.exists() && !(await targetFile.exists())) {
        try {
          await targetFile.writeAsBytes(await legacyFile.readAsBytes());
        } catch (_) {}
      }
      dbPath = targetFile.path;
    } else {
      dbPath = p.join(await getDatabasesPath(), fileName);
    }

    print('📁 تم إنشاء/قراءة قاعدة البيانات من المسار: $dbPath');

    return openDatabase(
      dbPath,
      version: 34, // ↑ دعم شعار المرفق الصحي المحلي
      onConfigure: (db) async {
        // ✅ على أندرويد: بعض أوامر PRAGMA يجب تنفيذها بـ rawQuery
        await db.rawQuery('PRAGMA foreign_keys = ON');

        // تفعيل WAL
        final jm = await db.rawQuery('PRAGMA journal_mode = WAL');
        if (jm.isNotEmpty) {
          print('SQLite journal_mode -> ${jm.first.values.first}');
        }

        await db.rawQuery('PRAGMA synchronous = NORMAL');
        await db.rawQuery('PRAGMA busy_timeout = 5000');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: (db) async => _postOpenChecks(db),
    );
  }

  Future<String> getDatabasePath() async {
    final override = _testDbPathOverride;
    if (override != null && override.isNotEmpty) {
      final file = File(override);
      try {
        await file.parent.create(recursive: true);
      } catch (_) {}
      return file.path;
    }
    if (Platform.isWindows) {
      const targetFolder = r'C:\aelmam_clinic';
      final dir = Directory(targetFolder);
      if (!(await dir.exists())) {
        await dir.create(recursive: true);
      }
      // هجرة لمرة واحدة إن وُجد ملف قديم في D:
      final legacyFile = File(p.join(r'D:\aelmam_clinic', 'clinic.db'));
      final targetFile = File(p.join(targetFolder, 'clinic.db'));
      if (await legacyFile.exists() && !(await targetFile.exists())) {
        try {
          await targetFile.writeAsBytes(await legacyFile.readAsBytes());
        } catch (_) {}
      }
      return targetFile.path;
    } else {
      return p.join(await getDatabasesPath(), 'clinic.db');
    }
  }

  /*──────────────── إنشاء بنية stats_dirty ───────────────*/
  Future<void> _createStatsDirtyStructure(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stats_dirty (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        dirty INTEGER NOT NULL DEFAULT 1
      );
    ''');
    await db.insert(
      'stats_dirty',
      {'id': 1, 'dirty': 1},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    const affectedTables = [
      'patients',
      'returns',
      'consumptions',
      'appointments',
      'items',
      'employees_loans',
      'prescriptions',
      'prescription_items',
      'drugs',
      'complaints'
    ];

    for (final table in affectedTables) {
      for (final op in ['INSERT', 'UPDATE', 'DELETE']) {
        final trigName = 'tg_${table}_${op.toLowerCase()}_stats_dirty';
        await db.execute('''
          CREATE TRIGGER IF NOT EXISTS $trigName
          AFTER $op ON $table
          BEGIN
            UPDATE stats_dirty SET dirty = 1 WHERE id = 1;
          END;
        ''');
      }
    }
  }

  /*────────────── فحوصات ما بعد الفتح/الترقية ──────────────*/
  /// ⚠️ مهم: لا نستخدم DEFAULT دوال في ALTER TABLE. نضيف الأعمدة ثم نملأها وننشىء تريجر.
  Future<void> _ensureAlertSettingsColumns(Database db) async {
    try {
      var cols = await db.rawQuery("PRAGMA table_info(alert_settings)");
      bool has(String name) => cols.any((c) =>
          ((c['name'] ?? '') as String).toLowerCase() == name.toLowerCase());
      String? columnType(String name) {
        for (final row in cols) {
          final colName = (row['name'] ?? '').toString();
          if (colName.toLowerCase() == name.toLowerCase()) {
            return (row['type'] ?? '').toString();
          }
        }
        return null;
      }

      // الأعمدة (camel + snake)
      Future<void> _ensureColumn(String name, String ddl) async {
        if (!has(name)) {
          await db.execute('ALTER TABLE alert_settings ADD COLUMN $name $ddl');
        }
      }

      await _ensureColumn('itemId', 'INTEGER');
      await _ensureColumn('item_id', 'INTEGER');
      await _ensureColumn('threshold', 'REAL NOT NULL DEFAULT 0');

      await _ensureColumn('isEnabled', 'INTEGER NOT NULL DEFAULT 1');
      await _ensureColumn('is_enabled', 'INTEGER NOT NULL DEFAULT 1');

      await _ensureColumn('lastTriggered', 'TEXT');
      await _ensureColumn('last_triggered', 'TEXT');

      // 🔔 وقت الإشعار الجديد (camel + snake)
      await _ensureColumn('notifyTime', 'TEXT');
      await _ensureColumn('notify_time', 'TEXT');

      // 🆔 uuid العنصر المرتبط (camel + snake)
      await _ensureColumn('itemUuid', 'TEXT');
      await _ensureColumn('item_uuid', 'TEXT');

      // createdAt/created_at
      if (!has('createdAt')) {
        await db
            .execute('ALTER TABLE alert_settings ADD COLUMN createdAt TEXT');
      }
      if (!has('created_at')) {
        await db
            .execute('ALTER TABLE alert_settings ADD COLUMN created_at TEXT');
      }
      cols = await db.rawQuery("PRAGMA table_info(alert_settings)");
      final thresholdType = columnType('threshold');
      final needsRebuild = thresholdType != null &&
          !thresholdType.toUpperCase().contains('REAL');
      if (needsRebuild) {
        await db.rawQuery('PRAGMA foreign_keys = OFF');
        try {
          await db.execute(
              'ALTER TABLE alert_settings RENAME TO alert_settings_old');
          await db.execute(AlertSetting.createTable);
          await db.execute('''
            INSERT INTO alert_settings (
              id,
              item_id,
              threshold,
              is_enabled,
              last_triggered,
              notify_time,
              item_uuid,
              created_at
            )
            SELECT
              id,
              COALESCE(item_id, itemId),
              CAST(threshold AS REAL),
              COALESCE(is_enabled, isEnabled, 1),
              COALESCE(last_triggered, lastTriggered),
              COALESCE(notify_time, notifyTime),
              COALESCE(item_uuid, itemUuid),
              COALESCE(created_at, createdAt, CURRENT_TIMESTAMP)
            FROM alert_settings_old;
          ''');
          await db.execute('DROP TABLE alert_settings_old');
        } finally {
          await db.rawQuery('PRAGMA foreign_keys = ON');
        }

        cols = await db.rawQuery("PRAGMA table_info(alert_settings)");
        await _ensureColumn('itemId', 'INTEGER');
        await _ensureColumn('isEnabled', 'INTEGER NOT NULL DEFAULT 1');
        await _ensureColumn('lastTriggered', 'TEXT');
        await _ensureColumn('notifyTime', 'TEXT');
        await _ensureColumn('itemUuid', 'TEXT');
        if (!has('createdAt')) {
          await db
              .execute('ALTER TABLE alert_settings ADD COLUMN createdAt TEXT');
        }
      }

      // ترحيل ثنائي الاتجاه + تعبئة تواريخ خالية
      final hasItemsTable = await _tableExists(db, 'items');
      if (!hasItemsTable) {
        await db.rawQuery('PRAGMA foreign_keys = OFF');
      }
      try {
        await db.execute(
            'UPDATE alert_settings SET itemId = COALESCE(itemId, item_id)');
        await db.execute(
            'UPDATE alert_settings SET item_id = COALESCE(item_id, itemId)');
        await db.execute(
            'UPDATE alert_settings SET isEnabled = COALESCE(isEnabled, is_enabled, 1)');
        await db.execute(
            'UPDATE alert_settings SET is_enabled = COALESCE(is_enabled, isEnabled, 1)');
        await db.execute(
            'UPDATE alert_settings SET lastTriggered = COALESCE(lastTriggered, last_triggered)');
        await db.execute(
            'UPDATE alert_settings SET last_triggered = COALESCE(last_triggered, lastTriggered)');
        await db.execute(
            'UPDATE alert_settings SET notifyTime = COALESCE(notifyTime, notify_time)');
        await db.execute(
            'UPDATE alert_settings SET notify_time = COALESCE(notify_time, notifyTime)');
        await db.execute(
            'UPDATE alert_settings SET itemUuid = COALESCE(itemUuid, item_uuid)');
        await db.execute(
            'UPDATE alert_settings SET item_uuid = COALESCE(item_uuid, itemUuid)');
        await db.execute(
            'UPDATE alert_settings SET createdAt = COALESCE(createdAt, created_at, CURRENT_TIMESTAMP)');
        await db.execute(
            'UPDATE alert_settings SET created_at = COALESCE(created_at, createdAt, CURRENT_TIMESTAMP)');
      } finally {
        if (!hasItemsTable) {
          await db.rawQuery('PRAGMA foreign_keys = ON');
        }
      }

      // فهرس للأداء
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_alert_settings_item_id ON alert_settings(item_id)');

      // تريجر تعبئة القيم الافتراضية
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_alert_settings_set_defaults
        AFTER INSERT ON alert_settings
        BEGIN
          UPDATE alert_settings
             SET createdAt      = COALESCE(NEW.createdAt,  CURRENT_TIMESTAMP),
                 created_at     = COALESCE(NEW.created_at, COALESCE(NEW.createdAt, CURRENT_TIMESTAMP)),
                 isEnabled      = COALESCE(NEW.isEnabled,  1),
                 is_enabled     = COALESCE(NEW.is_enabled, 1),
                 itemId         = COALESCE(NEW.itemId,     NEW.item_id),
                 item_id        = COALESCE(NEW.item_id,    NEW.itemId),
                 lastTriggered  = COALESCE(NEW.lastTriggered,  NEW.last_triggered),
                 last_triggered = COALESCE(NEW.last_triggered, NEW.lastTriggered),
                 notifyTime     = COALESCE(NEW.notifyTime, NEW.notify_time),
                 notify_time    = COALESCE(NEW.notify_time, NEW.notifyTime),
                 itemUuid       = COALESCE(NEW.itemUuid, NEW.item_uuid),
                 item_uuid      = COALESCE(NEW.item_uuid, NEW.itemUuid)
           WHERE id = NEW.id;
        END;
      ''');
    } catch (e) {
      print('ensureAlertSettingsColumns: $e');
    }
  }

  Future<void> _relaxFinancialLogsEmployeeId(Database db) async {
    try {
      final info = await db.rawQuery('PRAGMA table_info(financial_logs)');
      Map<String, Object?>? employeeCol;
      for (final row in info) {
        final name = (row['name'] ?? '').toString();
        if (name.toLowerCase() == 'employee_id') {
          employeeCol = row;
          break;
        }
      }

      if (employeeCol == null) return;
      final notNullFlag = int.tryParse('${employeeCol['notnull'] ?? 0}') ?? 0;
      if (notNullFlag == 0) return;

      await db.execute('''
        CREATE TABLE IF NOT EXISTS financial_logs_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          transaction_type     TEXT NOT NULL,
          operation            TEXT NOT NULL DEFAULT 'create',
          amount               REAL NOT NULL,
          employee_id          TEXT,
          description          TEXT,
          modification_details TEXT,
          timestamp            TEXT NOT NULL,
          isDeleted            INTEGER NOT NULL DEFAULT 0,
          deletedAt            TEXT,
          account_id           TEXT,
          device_id            TEXT,
          local_id             INTEGER,
          updated_at           TEXT
        );
      ''');

      final availableCols = info
          .map((row) => (row['name'] ?? '').toString())
          .where((name) => name.isNotEmpty)
          .toSet();

      const desiredCols = <String>[
        'id',
        'transaction_type',
        'operation',
        'amount',
        'employee_id',
        'description',
        'modification_details',
        'timestamp',
        'isDeleted',
        'deletedAt',
        'account_id',
        'device_id',
        'local_id',
        'updated_at',
      ];

      final copyCols =
          desiredCols.where((col) => availableCols.contains(col)).toList();

      if (copyCols.isNotEmpty) {
        final cols = copyCols.join(', ');
        await db.execute('''
          INSERT INTO financial_logs_new ($cols)
          SELECT $cols FROM financial_logs;
        ''');
      }

      await db.execute('DROP TABLE financial_logs;');
      await db
          .execute('ALTER TABLE financial_logs_new RENAME TO financial_logs;');

      await _ensureSoftDeleteColumns(db);
      await _ensureSyncMetaColumns(db);
    } catch (e) {
      print('relaxFinancialLogsEmployeeId: $e');
    }
  }

  /// يضمن أعمدة الحذف المنطقي لكل الجداول المحلية + فهرس isDeleted (idempotent)
  Future<void> _ensureSoftDeleteColumns(Database db) async {
    final tables = <String>[
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
      'patient_services'
    ];

    for (final t in tables) {
      await _addColumnIfMissing(
          db, t, 'isDeleted', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, t, 'deletedAt', 'TEXT');
      await _createIndexIfMissing(db, 'idx_${t}_isDeleted', t, ['isDeleted']);
    }
  }

  /// يضمن أعمدة المزامنة المحلية (snake_case) + فهرس مركّب (idempotent)
  ///
  /// 🔄 تمت مواءمته مع سكربت parity v3 (account_id/device_id/local_id/updated_at).
  Future<void> _ensureSyncMetaColumns(Database db) async {
    // استعمل لائحة الجداول المتزامنة الموحّدة (بدون attachments)
    for (final t in _kSyncTables) {
      await _addColumnIfMissing(db, t, 'account_id', 'TEXT');
      await _addColumnIfMissing(db, t, 'device_id', 'TEXT');
      await _addColumnIfMissing(db, t, 'local_id', 'INTEGER');
      await _addColumnIfMissing(db, t, 'updated_at', 'TEXT');
      await _createIndexIfMissing(db, 'idx_${t}_acc_dev_local', t,
          ['account_id', 'device_id', 'local_id']);
    }
  }

  Future<void> _ensureReturnsAttendanceColumns(Database db) async {
    await _addColumnIfMissing(
        db, 'returns', 'isAttended', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'returns', 'attendedAt', 'TEXT');
  }

  Future<void> _ensureSyncFkMappingTable(Database db) async {
    await db.execute('''
  CREATE TABLE IF NOT EXISTS sync_fk_mapping (
    table_name TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        remote_id TEXT NOT NULL,
        remote_device_id TEXT,
        remote_local_id INTEGER,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (table_name, local_id)
      );
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_fk_mapping_table_remote
      ON sync_fk_mapping(table_name, remote_id)
  ''');
  }

  Future<void> _ensureClinicProfileTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS clinic_profile (
        account_id TEXT PRIMARY KEY,
        name_ar TEXT,
        city_ar TEXT,
        street_ar TEXT,
        near_ar TEXT,
        name_en TEXT,
        city_en TEXT,
        street_en TEXT,
        near_en TEXT,
        phone TEXT,
        phone2 TEXT,
        logo_path TEXT,
        updated_at TEXT
      )
    ''');
    await _addColumnIfMissing(db, 'clinic_profile', 'logo_path', 'TEXT');
    await _addColumnIfMissing(db, 'clinic_profile', 'phone2', 'TEXT');
  }

  Future<void> saveClinicProfile(ClinicProfile profile) async {
    final db = await database;
    final data = profile.toMap();
    if (profile.logoPath == null || profile.logoPath!.trim().isEmpty) {
      final existing = await db.query(
        'clinic_profile',
        columns: const ['logo_path'],
        where: 'account_id = ?',
        whereArgs: [profile.accountId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final logo = existing.first['logo_path']?.toString();
        if (logo != null && logo.trim().isNotEmpty) {
          data['logo_path'] = logo;
        }
      }
    }
    data['updated_at'] = DateTime.now().toIso8601String();
    await db.insert(
      'clinic_profile',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateClinicLogoPath(String accountId, String? path) async {
    final trimmedId = accountId.trim();
    if (trimmedId.isEmpty) return;
    final db = await database;
    final trimmedPath = path?.trim();
    final updateData = <String, dynamic>{
      'logo_path':
          (trimmedPath == null || trimmedPath.isEmpty) ? null : trimmedPath,
      'updated_at': DateTime.now().toIso8601String(),
    };
    final rows = await db.update(
      'clinic_profile',
      updateData,
      where: 'account_id = ?',
      whereArgs: [trimmedId],
    );
    if (rows == 0) {
      await db.insert(
        'clinic_profile',
        {'account_id': trimmedId, ...updateData},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<ClinicProfile?> getClinicProfile(String accountId) async {
    if (accountId.trim().isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'clinic_profile',
      where: 'account_id = ?',
      whereArgs: [accountId.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ClinicProfile.fromMap(rows.first);
  }

  /// فهارس مشتركة للأداء (JOIN/WHERE شائعة)
  Future<void> _ensureCommonIndexes(Database db) async {
    Future<void> safeIndex(String name, String table, List<String> cols) async {
      if (await _tableExists(db, table)) {
        await _createIndexIfMissing(db, name, table, cols);
      }
    }

    await safeIndex('idx_patients_doctorId', 'patients', ['doctorId']);
    await safeIndex('idx_patients_registerDate', 'patients', ['registerDate']);
    await safeIndex('idx_purchases_created_at', 'purchases', ['created_at']);
    await safeIndex('idx_attachments_patient_created', 'attachments',
        ['patientId', 'createdAt']);

    await safeIndex(
        'idx_patient_services_patientId', PatientService.table, ['patientId']);
    await safeIndex(
        'idx_patient_services_serviceId', PatientService.table, ['serviceId']);

    await safeIndex(
        'idx_prescriptions_patientId', 'prescriptions', ['patientId']);
    await safeIndex('idx_prescription_items_prescriptionId',
        'prescription_items', ['prescriptionId']);

    await safeIndex('idx_service_doctor_share_serviceId',
        'service_doctor_share', ['serviceId']);
    await safeIndex('idx_service_doctor_share_doctorId', 'service_doctor_share',
        ['doctorId']);
    await safeIndex('idx_doctors_userUid', 'doctors', ['userUid']);

    await safeIndex(
        'idx_consumptions_patientId', 'consumptions', ['patientId']);
    await safeIndex('idx_consumptions_itemId', 'consumptions', ['itemId']);

    await safeIndex('idx_items_name', 'items', ['name']);
    await safeIndex(
        'idx_appointments_patientId', 'appointments', ['patientId']);
    await safeIndex('idx_returns_date', 'returns', ['date']);

    await safeIndex(
        'idx_employees_loans_employeeId', 'employees_loans', ['employeeId']);
    await safeIndex('idx_employees_salaries_employeeId', 'employees_salaries',
        ['employeeId']);
    await safeIndex('idx_employees_discounts_employeeId', 'employees_discounts',
        ['employeeId']);
    await safeIndex('idx_employees_userUid', 'employees', ['userUid']);

    Future<void> safeUniqueIndex(String name, String table, String sql) async {
      if (!await _tableExists(db, table)) return;
      try {
        await db.execute(sql);
      } catch (e) {
        print('$name creation skipped: $e');
      }
    }

    // 🧪 فهرس فريد يمنع تكرار أسماء الأدوية باختلاف حالة الأحرف
    await safeUniqueIndex(
      'uix_drugs_lower_name',
      'drugs',
      'CREATE UNIQUE INDEX IF NOT EXISTS uix_drugs_lower_name ON drugs(lower(name))',
    );

    // 🧪 فهرس فريد لعناصر المخزون على (type_id, name) كـ backfill لقواعد قديمة
    await safeUniqueIndex(
      'uix_items_type_name',
      'items',
      'CREATE UNIQUE INDEX IF NOT EXISTS uix_items_type_name ON items(type_id, name)',
    );

    // ✅ فهرس فريد لمنع ازدواج (خدمة، طبيب) الفعال فقط — بدون دوال داخل WHERE (متوافق مع SQLite)
    await safeUniqueIndex(
      'uix_sds_service_doctor_active',
      'service_doctor_share',
      '''
        CREATE UNIQUE INDEX IF NOT EXISTS uix_sds_service_doctor_active
        ON service_doctor_share(serviceId, doctorId)
        WHERE isDeleted IS NULL OR isDeleted = 0
      '''
          .trim(),
    );

    await safeUniqueIndex(
      'uix_doctors_userUid_active',
      'doctors',
      '''
        CREATE UNIQUE INDEX IF NOT EXISTS uix_doctors_userUid_active
        ON doctors(userUid)
        WHERE userUid IS NOT NULL AND (isDeleted IS NULL OR isDeleted = 0)
      '''
          .trim(),
    );

    await safeUniqueIndex(
      'uix_employees_userUid_active',
      'employees',
      '''
        CREATE UNIQUE INDEX IF NOT EXISTS uix_employees_userUid_active
        ON employees(userUid)
        WHERE userUid IS NOT NULL AND (isDeleted IS NULL OR isDeleted = 0)
      '''
          .trim(),
    );
  }

  Future<void> _postOpenChecks(Database db) async {
    await db.rawQuery('PRAGMA foreign_keys = ON');
    await _ensureClinicProfileTable(db);
    await _ensureAlertSettingsColumns(db);
    await _ensureSoftDeleteColumns(db);
    await _ensureSyncMetaColumns(db); // ← snake_case (متوافق مع parity v3)
    await _ensureReturnsAttendanceColumns(db);
    await _ensureSyncFkMappingTable(db);
    await _ensureCommonIndexes(db);
  }

  /*──────────────── إنشاء الجداول ───────────────*/
  Future<void> _onCreate(Database db, int version) async {
    await _ensureSyncFkMappingTable(db);
    await _ensureClinicProfileTable(db);
    await db.execute('''
  CREATE TABLE patients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    age INTEGER,
    diagnosis TEXT,
    paidAmount REAL,
    remaining REAL,
    registerDate TEXT,
    phoneNumber TEXT,
    healthStatus TEXT,
    preferences TEXT,
    doctorId INTEGER,
    doctorName TEXT,
    doctorSpecialization TEXT,
    notes TEXT,
    serviceType TEXT,
    serviceId INTEGER,
    serviceName TEXT,
    serviceCost REAL,
    doctorShare REAL DEFAULT 0,
    doctorInput REAL DEFAULT 0,
    towerShare REAL DEFAULT 0,
    departmentShare REAL DEFAULT 0,
    doctorReviewPending INTEGER NOT NULL DEFAULT 0,
    doctorReviewedAt TEXT
  );
''');

    await db.execute('''
  CREATE TABLE returns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT,
    patientName TEXT,
    phoneNumber TEXT,
    diagnosis TEXT,
    remaining REAL,
    age INTEGER DEFAULT 0,
    doctor TEXT DEFAULT '',
    notes TEXT DEFAULT '',
    isAttended INTEGER NOT NULL DEFAULT 0,
    attendedAt TEXT
  );
''');

    await db.execute('''
  CREATE TABLE consumptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patientId TEXT,
    itemId TEXT,
    quantity INTEGER,
    date TEXT,
    amount REAL,
    note TEXT
  );
''');

    await db.execute('''
      CREATE TABLE drugs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        notes TEXT,
        createdAt TEXT NOT NULL
      );
    ''');
    // 🧪 فهرس فريد case-insensitive للأدوية أثناء الإنشاء الأولي
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS uix_drugs_lower_name ON drugs(lower(name))');

    await db.execute('''
      CREATE TABLE prescriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        patientId INTEGER NOT NULL,
        doctorId  INTEGER,
        recordDate TEXT NOT NULL,
        createdAt  TEXT NOT NULL,
        FOREIGN KEY (patientId) REFERENCES patients(id),
        FOREIGN KEY (doctorId)  REFERENCES doctors(id)
      );
    ''');

    await db.execute('''
      CREATE TABLE prescription_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        prescriptionId INTEGER NOT NULL,
        drugId INTEGER NOT NULL,
        days INTEGER NOT NULL,
        timesPerDay INTEGER NOT NULL,
        FOREIGN KEY (prescriptionId) REFERENCES prescriptions(id) ON DELETE CASCADE,
        FOREIGN KEY (drugId)        REFERENCES drugs(id)
      );
    ''');

    await db.execute('''
      CREATE TABLE complaints (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        description TEXT,
        subject TEXT,
        message TEXT,
        status TEXT NOT NULL DEFAULT 'open',
        createdAt TEXT NOT NULL,
        updatedAt TEXT,
        replyMessage TEXT,
        repliedAt TEXT,
        repliedBy TEXT,
        replySeen INTEGER NOT NULL DEFAULT 0
      );
    ''');

    await db.execute('''
  CREATE TABLE appointments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patientId INTEGER,
    appointmentTime TEXT,
    status TEXT,
    notes TEXT,
    FOREIGN KEY (patientId) REFERENCES patients(id)
  );
''');

    await db.execute('''
  CREATE TABLE doctors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    employeeId INTEGER,
    userUid TEXT,
    name TEXT,
    specialization TEXT,
    phoneNumber TEXT,
    startTime TEXT,
    endTime TEXT,
    printCounter INTEGER DEFAULT 0
  );
''');

    await db.execute('''
  CREATE TABLE consumption_types (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT UNIQUE
  );
''');

    await db.execute('''
  CREATE TABLE medical_services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    cost REAL NOT NULL,
    serviceType TEXT NOT NULL
  );
''');

    await db.execute('''
  CREATE TABLE service_doctor_share (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    serviceId INTEGER NOT NULL,
    doctorId INTEGER NOT NULL,
    sharePercentage REAL NOT NULL,
    towerSharePercentage REAL NOT NULL DEFAULT 0,
    isHidden INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (serviceId) REFERENCES medical_services(id),
    FOREIGN KEY (doctorId)   REFERENCES doctors(id)
  );
''');

    await db.execute('''
  CREATE TABLE employees (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    identityNumber TEXT,
    phoneNumber TEXT,
    jobTitle TEXT,
    address TEXT,
    maritalStatus TEXT,
    basicSalary REAL,
    finalSalary REAL,
    isDoctor INTEGER DEFAULT 0,
    userUid TEXT
  );
''');

    await db.execute('''
  CREATE TABLE employees_loans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    employeeId INTEGER,
    loanDateTime TEXT,
    finalSalary REAL,
    ratioSum REAL,
    loanAmount REAL,
    leftover REAL,
    FOREIGN KEY(employeeId) REFERENCES employees(id)
  );
''');

    await db.execute('''
  CREATE TABLE employees_salaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    employeeId INTEGER,
    year INTEGER,
    month INTEGER,
    finalSalary REAL,
    ratioSum REAL,
    totalLoans REAL,
    netPay REAL,
    isPaid INTEGER DEFAULT 0,
    paymentDate TEXT,
    FOREIGN KEY(employeeId) REFERENCES employees(id)
  );
''');

    await db.execute('''
  CREATE TABLE employees_discounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    employeeId INTEGER,
    discountDateTime TEXT,
    amount REAL,
    notes TEXT,
    FOREIGN KEY(employeeId) REFERENCES employees(id)
  );
''');

    await db.execute(ItemType.createTable);
    await db.execute(Item.createTable);
    await db.execute(Purchase.createTable);
    await db.execute(AlertSetting.createTable);

    await db.execute('''
  CREATE TABLE financial_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    transaction_type     TEXT NOT NULL,
    operation            TEXT NOT NULL DEFAULT 'create',
    amount               REAL NOT NULL,
    employee_id          TEXT,
    description          TEXT,
    modification_details TEXT,
    timestamp            TEXT NOT NULL,
    isDeleted            INTEGER NOT NULL DEFAULT 0,
    deletedAt            TEXT,
    account_id           TEXT,
    device_id            TEXT,
    local_id             INTEGER,
    updated_at           TEXT
  );
''');

    await db.execute(Attachment.createTable);
    await db.execute(PatientService.createTable);

    await _createStatsDirtyStructure(db);

    // أعمدة الحذف المنطقي + الفهارس بعد الإنشاء
    await _ensureSoftDeleteColumns(db);
    await _ensureRemoteIdMap(db);

    // تأكيد alert_settings بعد الإنشاء (للتوافق + notifyTime)
    await _ensureAlertSettingsColumns(db);

    // ← أعمدة المزامنة المحلية (snake_case) + فهرس مركّب
    await _ensureSyncMetaColumns(db);

    // فهارس عامة
    await _ensureCommonIndexes(db);

    await _ensureUuidMappingTable(db);
  }

  Future<void> _ensureRemoteIdMap(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS remote_id_map (
        table_name TEXT NOT NULL,
        remote_uuid TEXT NOT NULL,
        account_id TEXT,
        device_id TEXT,
        local_id INTEGER,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (table_name, remote_uuid)
      );
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_remote_id_map_table_local
      ON remote_id_map(table_name, local_id)
    ''');
  }

  /*────────────────── الترقيات ──────────────────*/
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 6) {
      await db
          .execute('ALTER TABLE patients ADD COLUMN doctorSpecialization TEXT');
    }

    if (oldVersion < 7) {
      await db.execute("ALTER TABLE returns ADD COLUMN age INTEGER DEFAULT 0");
      await db.execute("ALTER TABLE returns ADD COLUMN doctor TEXT DEFAULT ''");
      await db.execute("ALTER TABLE returns ADD COLUMN notes  TEXT DEFAULT ''");
    }

    if (oldVersion < 8) {
      await db.execute(
          "ALTER TABLE doctors ADD COLUMN printCounter INTEGER DEFAULT 0");
    }

    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE medical_services (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          name        TEXT   NOT NULL,
          cost        REAL   NOT NULL,
          serviceType TEXT   NOT NULL
        );
      ''');
      await db.execute('''
        CREATE TABLE service_doctor_share (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          serviceId INTEGER NOT NULL,
          doctorId  INTEGER NOT NULL,
          sharePercentage REAL NOT NULL,
          FOREIGN KEY (serviceId) REFERENCES medical_services(id),
          FOREIGN KEY (doctorId)  REFERENCES doctors(id)
        );
      ''');
    }

    if (oldVersion < 10) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS employees (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT,
          identityNumber TEXT,
          phoneNumber TEXT,
          jobTitle TEXT,
          address TEXT,
          maritalStatus TEXT,
          basicSalary REAL,
          finalSalary REAL,
          doctorId INTEGER DEFAULT 0,
          userUid TEXT
        );
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS employees_loans (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          employeeId  INTEGER,
          loanDateTime TEXT,
          finalSalary REAL,
          ratioSum REAL,
          loanAmount REAL,
          leftover REAL,
          FOREIGN KEY(employeeId) REFERENCES employees(id)
        );
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS employees_salaries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          employeeId  INTEGER,
          year        INTEGER,
          month       INTEGER,
          finalSalary REAL,
          ratioSum    REAL,
          totalLoans  REAL,
          netPay      REAL,
          isPaid      INTEGER DEFAULT 0,
          paymentDate TEXT,
          FOREIGN KEY(employeeId) REFERENCES employees(id)
        );
      ''');
    }

    if (oldVersion < 11) {
      await _addColumnIfMissing(db, 'doctors', 'employeeId', 'INTEGER');
    }

    if (oldVersion < 12) {
      await _addColumnIfMissing(
          db, 'patients', 'doctorShare', 'REAL DEFAULT 0');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS employees_discounts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          employeeId INTEGER,
          discountDateTime TEXT,
          amount REAL,
          notes TEXT,
          FOREIGN KEY(employeeId) REFERENCES employees(id)
        );
      ''');
    }

    if (oldVersion < 13) {
      await _addColumnIfMissing(
          db, 'patients', 'doctorInput', 'REAL DEFAULT 0');
    }

    if (oldVersion < 14) {
      await _addColumnIfMissing(
          db, 'service_doctor_share', 'towerSharePercentage', 'REAL DEFAULT 0');
      await _addColumnIfMissing(db, 'patients', 'towerShare', 'REAL DEFAULT 0');
    }

    if (oldVersion < 15) {
      await _addColumnIfMissing(
          db, 'patients', 'departmentShare', 'REAL DEFAULT 0');
    }

    if (oldVersion < 16) {
      await _addColumnIfMissing(
          db, 'employees', 'isDoctor', 'INTEGER DEFAULT 0');
    }

    if (oldVersion < 17) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS financial_logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          transaction_type     TEXT NOT NULL,
          operation            TEXT NOT NULL DEFAULT 'create',
          amount               REAL NOT NULL,
          employee_id          TEXT,
          description          TEXT,
          modification_details TEXT,
          timestamp            TEXT NOT NULL,
          isDeleted            INTEGER NOT NULL DEFAULT 0,
          deletedAt            TEXT,
          account_id           TEXT,
          device_id            TEXT,
          local_id             INTEGER,
          updated_at           TEXT
        );
      ''');
    }

    if (oldVersion < 19) {
      await _addColumnIfMissing(
          db, 'financial_logs', 'operation', "TEXT NOT NULL DEFAULT 'create'");
      await _addColumnIfMissing(
          db, 'financial_logs', 'modification_details', 'TEXT');
    }

    if (oldVersion < 20) {
      try {
        await db.execute("ALTER TABLE items RENAME COLUMN typeId TO type_id");
      } catch (_) {}
      try {
        await db.execute(
            "ALTER TABLE items RENAME COLUMN quantityAvailable TO stock");
      } catch (_) {}
      await _addColumnIfMissing(db, 'consumptions', 'patientId', 'TEXT');
      await _addColumnIfMissing(db, 'consumptions', 'itemId', 'TEXT');
      await _addColumnIfMissing(
          db, 'consumptions', 'quantity', 'INTEGER DEFAULT 0');
      await db.execute(Attachment.createTable);
    }

    if (oldVersion < 30) {
      await _relaxFinancialLogsEmployeeId(db);
    }

    if (oldVersion < 31) {
      if (await _tableExists(db, 'patients')) {
        await _addColumnIfMissing(
          db,
          'patients',
          'doctorReviewPending',
          'INTEGER NOT NULL DEFAULT 0',
        );
        await _addColumnIfMissing(
          db,
          'patients',
          'doctorReviewedAt',
          'TEXT',
        );
        try {
          await db.rawUpdate(
            'UPDATE patients SET doctorReviewPending = 0 WHERE doctorReviewPending IS NULL',
          );
          await db.rawUpdate(
            'UPDATE patients SET doctorReviewedAt = NULL WHERE doctorReviewPending = 0',
          );
        } catch (_) {
          // Ignore if table missing mid-migration.
        }
      }
    }

    if (oldVersion < 21) {
      final chk = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='stats_dirty'");
      if (chk.isEmpty) {
        await _createStatsDirtyStructure(db);
      }
    }

    if (oldVersion < 22) {
      await db.execute(PatientService.createTable);
    }

    if (oldVersion < 23) {
      await _addColumnIfMissing(
          db, 'service_doctor_share', 'isHidden', 'INTEGER NOT NULL DEFAULT 0');
    }

    if (oldVersion < 24) {
      await db.execute('''
      CREATE TABLE IF NOT EXISTS drugs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT UNIQUE NOT NULL,
          notes TEXT,
          createdAt TEXT NOT NULL
        );
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS prescriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          patientId INTEGER NOT NULL,
          doctorId  INTEGER,
          recordDate TEXT NOT NULL,
          createdAt  TEXT NOT NULL
        );
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS prescription_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          prescriptionId INTEGER NOT NULL,
          drugId INTEGER NOT NULL,
          days INTEGER NOT NULL,
          timesPerDay INTEGER NOT NULL
        );
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS complaints (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT,
          description TEXT,
          subject TEXT,
          message TEXT,
          status TEXT NOT NULL DEFAULT 'open',
          createdAt TEXT NOT NULL,
          updatedAt TEXT,
          replyMessage TEXT,
          repliedAt TEXT,
          repliedBy TEXT,
          replySeen INTEGER NOT NULL DEFAULT 0
        );
      ''');

      for (final tbl in [
        'drugs',
        'prescriptions',
        'prescription_items',
        'complaints'
      ]) {
        for (final op in ['INSERT', 'UPDATE', 'DELETE']) {
          final trig = 'tg_${tbl}_${op.toLowerCase()}_stats_dirty';
          await db.execute('''
            CREATE TRIGGER IF NOT EXISTS $trig
            AFTER $op ON $tbl
            BEGIN
              UPDATE stats_dirty SET dirty = 1 WHERE id = 1;
            END;
          ''');
        }
      }
    }

    if (oldVersion < 25) {
      await _ensureAlertSettingsColumns(
          db); // camel + snake + ترحيل + تريجر + notifyTime
    }

    if (oldVersion < 26) {
      await _ensureSoftDeleteColumns(db);
    }

    if (oldVersion < 27) {
      await _ensureAlertSettingsColumns(db);
      await _ensureSoftDeleteColumns(db);
      await _ensureCommonIndexes(db);
    }

    if (oldVersion < 28) {
      // ← أعمدة المزامنة المحلية (snake_case) + الفهرس المركّب
      await _ensureSyncMetaColumns(db);
      await _ensureCommonIndexes(db);
    }

    if (oldVersion < 29) {
      await _addColumnIfMissing(db, 'doctors', 'userUid', 'TEXT');
      await _addColumnIfMissing(db, 'employees', 'userUid', 'TEXT');
      await _ensureCommonIndexes(db);
    }

    if (oldVersion < 32) {
      await _addColumnIfMissing(
        db,
        'complaints',
        'replySeen',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }

    if (oldVersion < 33) {
      await _addColumnIfMissing(db, 'complaints', 'subject', 'TEXT');
      await _addColumnIfMissing(db, 'complaints', 'message', 'TEXT');
      await _addColumnIfMissing(db, 'complaints', 'replyMessage', 'TEXT');
      await _addColumnIfMissing(db, 'complaints', 'repliedAt', 'TEXT');
      await _addColumnIfMissing(db, 'complaints', 'repliedBy', 'TEXT');
      await _addColumnIfMissing(db, 'complaints', 'updatedAt', 'TEXT');
      await _addColumnIfMissing(db, 'complaints', 'title', 'TEXT');
      await _addColumnIfMissing(db, 'complaints', 'description', 'TEXT');
      try {
        await db.rawUpdate(
          "UPDATE complaints SET subject = COALESCE(subject, title)",
        );
        await db.rawUpdate(
          "UPDATE complaints SET message = COALESCE(message, description)",
        );
      } catch (_) {}
    }

    if (oldVersion < 34) {
      await _addColumnIfMissing(db, 'clinic_profile', 'logo_path', 'TEXT');
    }
  }

  /*─────────────────── المرفقات ───────────────────*/
  Future<int> insertAttachment(Attachment a) async {
    final db = await database;
    final id = await db.insert(Attachment.tableName, a.toMap());
    // ⚠️ attachments محلية فقط → سنبثّ التغيير لكن لن نحفّز دفعًا للمزامنة (انظر _markChanged)
    await _markChanged(Attachment.tableName);
    return id;
  }

  Future<List<Attachment>> getAttachmentsForPatient(int patientId) async {
    final db = await database;
    final res = await db.query(
      Attachment.tableName,
      where: 'patientId = ?',
      whereArgs: [patientId],
      orderBy: 'createdAt DESC',
    );
    return res.map((r) => Attachment.fromMap(r)).toList();
  }

  Future<List<Attachment>> getAttachmentsByPatient(int patientId) =>
      getAttachmentsForPatient(patientId);

  Future<void> deleteAttachment(int id) async {
    // المرفقات محلية فقط: حذف فعلي للملف/السجل
    final db = await database;
    await db.delete(Attachment.tableName, where: 'id = ?', whereArgs: [id]);
    await _markChanged(Attachment.tableName);
  }

  /*────────────── مساعد للحذف المنطقي العام ─────────────*/
  Future<int> _softDeleteById(String table, int id) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return db.update(
      table,
      {'isDeleted': 1, 'deletedAt': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> _softDeleteWhere(
      String table, String where, List<Object?> whereArgs) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      table,
      {'isDeleted': 1, 'deletedAt': now},
      where: where,
      whereArgs: whereArgs,
    );
  }

  /*=============================== item_types ===============================*/
  Future<int> insertItemType(ItemType t) async {
    final db = await database;
    final id = await db.insert(ItemType.table, t.toMap());
    await _markChanged(ItemType.table);
    return id;
  }

  Future<List<ItemType>> getAllItemTypes() async {
    final db = await database;
    final res = await db.query(
      ItemType.table,
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'name ASC',
    );
    return res.map((r) => ItemType.fromMap(r)).toList();
  }

  Future<int> updateItemType(int id, String name) async {
    final db = await database;
    final rows = await db.update(ItemType.table, {'name': name},
        where: 'id = ?', whereArgs: [id]);
    await _markChanged(ItemType.table);
    return rows;
  }

  Future<int> deleteItemType(int id) async {
    final rows = await _softDeleteById(ItemType.table, id);
    await _markChanged(ItemType.table);
    return rows;
  }

  /*=============================== items ===============================*/
  Future<int> insertItem(Item i) async {
    final db = await database;
    final id = await db.insert(Item.table, i.toMap());
    await _markChanged(Item.table);
    return id;
  }

  Future<List<Item>> getAllItems() async {
    final db = await database;
    final res = await db.query(
      Item.table,
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'name ASC',
    );
    return res.map((r) => Item.fromMap(r)).toList();
  }

  Future<int> updateItem(Item i) async {
    final db = await database;
    final rows = await db
        .update(Item.table, i.toMap(), where: 'id = ?', whereArgs: [i.id]);
    await _markChanged(Item.table);
    return rows;
  }

  Future<int> deleteItem(int id) async {
    final rows = await _softDeleteById(Item.table, id);
    await _markChanged(Item.table);
    return rows;
  }

  //=============================== patient_services ===============================
  Future<int> insertPatientService(PatientService ps) async {
    final db = await database;
    final data = ps.toMap();
    data.remove('id'); // always autoincrement to avoid UNIQUE conflicts
    final id = await db.insert(PatientService.table, data);
    await _markChanged(PatientService.table);
    return id;
  }

  Future<List<PatientService>> getPatientServices(int patientId) async {
    final db = await database;
    final rows = await db.rawQuery('''
    SELECT
      ps.*,
      COALESCE(ps.serviceName, ms.name)  AS serviceName,
      COALESCE(ps.serviceCost, ms.cost)  AS serviceCost
    FROM ${PatientService.table} ps
    LEFT JOIN medical_services ms
      ON ms.id = ps.serviceId
    WHERE ps.patientId = ?
      AND ifnull(ps.isDeleted,0)=0
      AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
    ORDER BY ps.id ASC
  ''', [patientId]);

    return rows.map((m) => PatientService.fromMap(m)).toList();
  }

  Future<int> deletePatientServices(int patientId) async {
    await _softDeleteWhere(PatientService.table, 'patientId=?', [patientId]);
    await _markChanged(PatientService.table);
    return 1;
  }

  /*=============================== drugs ===============================*/
  Future<int> insertDrug(Drug d) async {
    final db = await database;

    // UNIQUE(name): إن وُجد سجل بنفس الاسم → إما استعادة المحذوف أو إعادة استخدام الموجود.
    final exists = await db.query(
      Drug.table,
      where: 'lower(name)=lower(?)',
      whereArgs: [d.name],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      final row = exists.first;
      final id = row['id'] as int;
      final isDel = (row['isDeleted'] as int? ?? 0) == 1;
      if (isDel) {
        await db.update(
          Drug.table,
          {
            'notes': d.notes,
            'createdAt': d.createdAt.toIso8601String(),
            'isDeleted': 0,
            'deletedAt': null
          },
          where: 'id=?',
          whereArgs: [id],
        );
        await _markChanged(Drug.table);
        return id;
      } else {
        // موجود وغير محذوف: نعيد المعرّف بدل رمي استثناء UNIQUE
        await _markChanged(Drug.table);
        return id;
      }
    }

    final id = await db.insert(Drug.table, d.toMap());
    await _markChanged(Drug.table);
    return id;
  }

  Future<List<Drug>> getAllDrugs() async {
    final res = await (await database).query(
      Drug.table,
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'name COLLATE NOCASE',
    );
    return res.map((m) => Drug.fromMap(m)).toList();
  }

  Future<int> updateDrug(Drug d) async {
    final rows = await (await database)
        .update(Drug.table, d.toMap(), where: 'id = ?', whereArgs: [d.id]);
    await _markChanged(Drug.table);
    return rows;
  }

  Future<int> deleteDrug(int id) async {
    final rows = await _softDeleteById(Drug.table, id);
    await _markChanged(Drug.table);
    return rows;
  }

  /*=============================== prescriptions ===============================*/
  Future<int> insertPrescription(Prescription p) async {
    final id = await (await database).insert(Prescription.table, p.toMap());
    await _markChanged(Prescription.table);
    return id;
  }

  Future<List<Prescription>> getPrescriptionsOfPatient(int patientId) async {
    final res = await (await database).query(
      Prescription.table,
      where: 'patientId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [patientId],
      orderBy: 'recordDate DESC',
    );
    return res.map((m) => Prescription.fromMap(m)).toList();
  }

  Future<int> updatePrescription(Prescription p) async {
    final rows = await (await database).update(
      Prescription.table,
      p.toMap(),
      where: 'id = ?',
      whereArgs: [p.id],
    );
    await _markChanged(Prescription.table);
    return rows;
  }

  Future<int> deletePrescription(int id) async {
    final rows = await _softDeleteById(Prescription.table, id);
    await _markChanged(Prescription.table);
    return rows;
  }

  /*=============================== prescription_items ===============================*/
  Future<int> insertPrescriptionItem(PrescriptionItem pi) async {
    final id =
        await (await database).insert(PrescriptionItem.table, pi.toMap());
    await _markChanged(PrescriptionItem.table);
    return id;
  }

  Future<List<PrescriptionItem>> getItemsOfPrescription(
      int prescriptionId) async {
    final res = await (await database).query(
      PrescriptionItem.table,
      where: 'prescriptionId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [prescriptionId],
    );
    return res.map((m) => PrescriptionItem.fromMap(m)).toList();
  }

  Future<int> deleteItemsOfPrescription(int prescriptionId) async {
    await _softDeleteWhere(
        PrescriptionItem.table, 'prescriptionId=?', [prescriptionId]);
    await _markChanged(PrescriptionItem.table);
    return 1;
  }

  //=============================== purchases ===============================
  Future<int> insertPurchase(Purchase p) async {
    final db = await database;
    final id = await db.insert(Purchase.table, p.toMap());
    await _markChanged(Purchase.table);
    return id;
  }

  Future<List<Purchase>> getAllPurchases() async {
    final db = await database;
    final res = await db.query(
      Purchase.table,
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'created_at DESC', // ✅ العمود محليًا هو snake_case
    );
    return res.map((r) => Purchase.fromMap(r)).toList();
  }

  Future<int> updatePurchase(Purchase p) async {
    final db = await database;
    final rows = await db
        .update(Purchase.table, p.toMap(), where: 'id = ?', whereArgs: [p.id]);
    await _markChanged(Purchase.table);
    return rows;
  }

  Future<int> deletePurchase(int id) async {
    final rows = await _softDeleteById(Purchase.table, id);
    await _markChanged(Purchase.table);
    return rows;
  }

  //=============================== alert_settings ===============================
  Future<int> insertAlert(AlertSetting a) async {
    final db = await database;
    final id = await db.insert(AlertSetting.table, a.toMap());
    // مزامنة أعمدة camel/snake بعد الإدراج
    await _ensureAlertSettingsColumns(db);
    await _markChanged(AlertSetting.table);
    return id;
  }

  Future<List<AlertSetting>> getAllAlerts() async {
    final db = await database;
    final res = await db.query(
      AlertSetting.table,
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'id DESC',
    );
    return res.map((r) => AlertSetting.fromMap(r)).toList();
  }

  Future<int> updateAlert(AlertSetting a) async {
    final db = await database;
    final rows = await db.update(AlertSetting.table, a.toMap(),
        where: 'id = ?', whereArgs: [a.id]);
    await _ensureAlertSettingsColumns(db);
    await _markChanged(AlertSetting.table);
    return rows;
  }

  Future<int> deleteAlert(int id) async {
    final rows = await _softDeleteById(AlertSetting.table, id);
    await _markChanged(AlertSetting.table);
    return rows;
  }

  //=============================== المرضى ===============================
  Future<int> insertPatient(Patient patient) => patients.insertPatient(patient);

  Future<List<Patient>> getAllPatients({int? doctorId}) =>
      patients.getAllPatients(doctorId: doctorId);

  Future<Patient?> getPatientById(int id) => patients.getPatientById(id);

  Future<int> markPatientReviewed(int id) => patients.markPatientReviewed(id);

  Future<int> updatePatient(Patient p, List<PatientService> newServices) =>
      patients.updatePatient(p, newServices);

  /// حذف منطقي للمريض وكل العناصر التابعة + عكس المخزون + قيد مالي سالب
  /// الآن داخل معاملة واحدة لضمان الذرّية.
  Future<int> deletePatient(int id) => patients.deletePatient(id);

  //=============================== العودات ===============================
  Future<int> insertReturnEntry(ReturnEntry entry) async {
    final db = await database;
    final id = await db.insert('returns', entry.toMap());
    final notificationId = id % 1000000;
    try {
      await NotificationService().scheduleNotification(
        id: notificationId,
        title: 'تذكير موعد المريض',
        body: 'لديك موعد مع المريض ${entry.patientName} اليوم.',
        scheduledTime: entry.date,
      );
    } catch (e) {
      print('فشل جدولة الإشعار: $e');
    }
    await _markChanged('returns');
    return id;
  }

  Future<List<ReturnEntry>> getAllReturns() async {
    final db = await database;
    final res = await db.query(
      'returns',
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'date DESC',
    );
    return res.map((row) => ReturnEntry.fromMap(row)).toList();
  }

  Future<int> updateReturnEntry(ReturnEntry entry) async {
    final db = await database;
    final rows = await db.update('returns', entry.toMap(),
        where: 'id = ?', whereArgs: [entry.id]);
    await _markChanged('returns');
    return rows;
  }

  Future<int> setReturnAttended(int id, bool attended) async {
    final db = await database;
    final rows = await db.update(
      'returns',
      {
        'isAttended': attended ? 1 : 0,
        'attendedAt': attended ? DateTime.now().toIso8601String() : null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _markChanged('returns');
    return rows;
  }

  Future<void> setReturnsAttendedBulk(
      List<int> ids, bool attended) async {
    if (ids.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    final payload = {
      'isAttended': attended ? 1 : 0,
      'attendedAt': attended ? DateTime.now().toIso8601String() : null,
    };
    for (final id in ids) {
      batch.update('returns', payload, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
    await _markChanged('returns');
  }

  Future<int> deleteReturn(int id) async {
    try {
      final notificationId = id % 1000000;
      await NotificationService().cancelNotification(notificationId);
    } catch (e) {
      print('فشل إلغاء الإشعار: $e');
    }
    final rows = await _softDeleteById('returns', id);
    await _markChanged('returns');
    return rows;
  }

  //=============================== الاستهلاك ===============================
  Future<int> insertConsumption(Consumption c) async {
    final db = await database;
    var amount = c.amount;
    if ((amount == 0 || amount.isNaN) && (c.itemId ?? '').isNotEmpty) {
      final itemRows = await db.query(
        'items',
        columns: ['price'],
        where: 'id = ?',
        whereArgs: [c.itemId],
        limit: 1,
      );
      if (itemRows.isNotEmpty) {
        final price = (itemRows.first['price'] as num?)?.toDouble() ?? 0.0;
        amount = price * c.quantity;
      }
    }
    final id = await db.insert('consumptions', {
      ...c.toMap(),
      'amount': amount,
    });
    await _markChanged('consumptions');
    return id;
  }

  Future<List<Consumption>> getAllConsumption() async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT 
        c.*,
        CASE 
          WHEN (c.amount IS NULL OR c.amount = 0) 
            THEN COALESCE(i.price, 0) * COALESCE(c.quantity, 0)
          ELSE c.amount
        END AS amount
      FROM consumptions c
      LEFT JOIN items i ON i.id = c.itemId
      WHERE ifnull(c.isDeleted,0)=0
      ORDER BY c.date DESC
    ''');
    return res.map((row) => Consumption.fromMap(row)).toList();
  }

  Future<int> deleteConsumption(int id) async {
    final rows = await _softDeleteById('consumptions', id);
    await _markChanged('consumptions');
    return rows;
  }

  //=============================== المواعيد ===============================
  Future<int> saveAppointment(Appointment appointment) async {
    final db = await database;
    if (appointment.id == null) {
      final id = await db.insert('appointments', appointment.toMap());
      await _markChanged('appointments');
      return id;
    } else {
      final rows = await db.update(
        'appointments',
        appointment.toMap(),
        where: 'id = ?',
        whereArgs: [appointment.id],
      );
      await _markChanged('appointments');
      return rows;
    }
  }

  Future<List<Appointment>> getAllAppointments() async {
    final db = await database;
    final res = await db.query(
      'appointments',
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'appointmentTime DESC',
    );
    return res.map((row) => Appointment.fromMap(row)).toList();
  }

  /// مواعيد اليوم الحالي فقط (يعتمد أن appointmentTime محفوظ كنص ISO8601)
  Future<List<Appointment>> getAppointmentsForToday() async {
    final db = await database;
    final now = DateTime.now();
    final fromIso = DateTime(now.year, now.month, now.day).toIso8601String();
    final toIso = DateTime(now.year, now.month, now.day, 23, 59, 59, 999)
        .toIso8601String();

    final res = await db.query(
      'appointments',
      where: 'appointmentTime BETWEEN ? AND ? AND ifnull(isDeleted,0)=0',
      whereArgs: [fromIso, toIso],
      orderBy: 'appointmentTime DESC',
    );
    return res.map((row) => Appointment.fromMap(row)).toList();
  }

  Future<int> deleteAppointment(int id) async {
    final rows = await _softDeleteById('appointments', id);
    await _markChanged('appointments');
    return rows;
  }

  //=============================== الأطباء ===============================
  Future<int> insertDoctor(Doctor doctor) async {
    final db = await database;
    final id = await db.insert('doctors', doctor.toMap());
    await _markChanged('doctors');
    return id;
  }

  Future<List<Doctor>> getAllDoctors() async {
    final db = await database;
    final res = await db.query('doctors',
        where: 'ifnull(isDeleted,0)=0', orderBy: 'id DESC');
    return res.map((row) => Doctor.fromMap(row)).toList();
  }

  Future<Doctor?> getDoctorByUserUid(String userUid) async {
    final trimmed = userUid.trim();
    if (trimmed.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'doctors',
      where: 'userUid = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [trimmed],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Doctor.fromMap(rows.first);
  }

  Future<Set<String>> getDoctorUserUids() async {
    final db = await database;
    final rows = await db.query(
      'doctors',
      columns: const ['userUid'],
      where:
          "userUid IS NOT NULL AND TRIM(userUid) <> '' AND ifnull(isDeleted,0)=0",
    );
    final set = <String>{};
    for (final row in rows) {
      final raw = row['userUid']?.toString().trim() ?? '';
      if (raw.isNotEmpty) set.add(raw);
    }
    return set;
  }

  Future<int> updateDoctor(Doctor doctor) async {
    final db = await database;
    final rows = await db.update('doctors', doctor.toMap(),
        where: 'id = ?', whereArgs: [doctor.id]);
    await _markChanged('doctors');
    return rows;
  }

  Future<int> deleteDoctor(int id) async {
    final rows = await _softDeleteById('doctors', id);
    await _markChanged('doctors');
    return rows;
  }

  Future<int> getNextPrintCounterForDoctor(String doctorName) async {
    final db = await database;
    final results = await db.query(
      'doctors',
      columns: ['id', 'printCounter'],
      where: 'name = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [doctorName],
      limit: 1,
    );
    if (results.isEmpty) return 1;

    final row = results.first;
    final doctorId = row['id'] as int;
    final currentCounter = (row['printCounter'] ?? 0) as int;
    final nextCounter = currentCounter + 1;

    await db.update('doctors', {'printCounter': nextCounter},
        where: 'id = ?', whereArgs: [doctorId]);
    await _markChanged('doctors');
    return nextCounter;
  }

  Future<void> resetDoctorPrintCounter(int doctorId) async {
    final db = await database;
    await db.update('doctors', {'printCounter': 0},
        where: 'id = ?', whereArgs: [doctorId]);
    await _markChanged('doctors');
  }

  Future<int> updateDoctorByEmployeeId(
      int employeeId, Map<String, dynamic> updatedData) async {
    final db = await database;
    final rows = await db.update('doctors', updatedData,
        where: 'employeeId = ?', whereArgs: [employeeId]);
    await _markChanged('doctors');
    return rows;
  }

  //====================== الخدمات الطبية ونسب الأطباء ======================
  Future<int> insertMedicalService({
    required String name,
    required double cost,
    required String serviceType,
  }) async {
    final db = await database;
    final id = await db.insert('medical_services', {
      'name': name,
      'cost': cost,
      'serviceType': serviceType,
    });
    await _markChanged('medical_services');
    return id;
  }

  Future<int> updateMedicalService({
    required int id,
    required String name,
    required double cost,
    required String serviceType,
  }) async {
    final db = await database;
    final rows = await db.update(
      'medical_services',
      {'name': name, 'cost': cost, 'serviceType': serviceType},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _markChanged('medical_services');
    return rows;
  }

  Future<int> deleteMedicalService(int id) async {
    final rows = await _softDeleteById('medical_services', id);
    await _markChanged('medical_services');
    return rows;
  }

  Future<List<Map<String, dynamic>>> getServicesByType(
      String serviceType) async {
    final db = await database;
    final res = await db.query(
      'medical_services',
      where: 'serviceType = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [serviceType],
      orderBy: 'name',
    );
    return res;
  }

  Future<List<Map<String, dynamic>>> getAllMedicalServices() async {
    final db = await database;
    final res = await db.query(
      'medical_services',
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'id DESC',
    );
    return res;
  }

  //=============================== نسب الأطباء ===============================
  Future<int> insertServiceDoctorShare({
    required int serviceId,
    required int doctorId,
    required double sharePercentage,
    double towerSharePercentage = 0.0,
  }) async {
    final db = await database;
    final id = await db.insert('service_doctor_share', {
      'serviceId': serviceId,
      'doctorId': doctorId,
      'sharePercentage': sharePercentage,
      'towerSharePercentage': towerSharePercentage,
    });
    await _markChanged('service_doctor_share');
    return id;
  }

  Future<List<Map<String, dynamic>>> getDoctorSharesForService(
      int serviceId) async {
    final db = await database;
    return db.query(
      'service_doctor_share',
      where: 'serviceId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [serviceId],
    );
  }

  Future<double?> getDoctorShareForService({
    required int doctorId,
    required int serviceId,
  }) async {
    final db = await database;
    final res = await db.query(
      'service_doctor_share',
      columns: ['sharePercentage'],
      where: 'doctorId = ? AND serviceId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [doctorId, serviceId],
      limit: 1,
    );
    if (res.isEmpty) return null;
    final v = res.first['sharePercentage'];
    return (v is num) ? v.toDouble() : double.tryParse(v.toString());
  }

  Future<int> updateServiceDoctorShare({
    required int id,
    double? sharePercentage,
    double? towerSharePercentage,
  }) async {
    final db = await database;
    final updateData = <String, dynamic>{};
    if (sharePercentage != null)
      updateData['sharePercentage'] = sharePercentage;
    if (towerSharePercentage != null)
      updateData['towerSharePercentage'] = towerSharePercentage;
    final rows = await db.update('service_doctor_share', updateData,
        where: 'id = ?', whereArgs: [id]);
    await _markChanged('service_doctor_share');
    return rows;
  }

  Future<int> deleteServiceDoctorShare(int id) async {
    final rows = await _softDeleteById('service_doctor_share', id);
    await _markChanged('service_doctor_share');
    return rows;
  }

  Future<int> updateServiceDoctorShareHidden({
    required int id,
    required int isHidden,
  }) async {
    final db = await database;
    final rows = await db.update('service_doctor_share', {'isHidden': isHidden},
        where: 'id = ?', whereArgs: [id]);
    await _markChanged('service_doctor_share');
    return rows;
  }

  Future<List<Map<String, dynamic>>> getDoctorGeneralServices(
      int doctorId) async {
    final db = await database;
    return db.rawQuery('''
    SELECT ms.id, ms.name, ms.cost
    FROM medical_services ms
    JOIN service_doctor_share sds 
      ON sds.serviceId = ms.id AND sds.doctorId = ? AND ifnull(sds.isDeleted,0)=0
    WHERE ms.serviceType = 'doctorGeneral'
      AND sds.isHidden = 0
      AND ifnull(ms.isDeleted,0)=0
    ORDER BY ms.id DESC
  ''', [doctorId]);
  }

  /*───────────────────────────────────────────────────────────────
   📌 جديد: إظهار نسب الطبيب والمركز لكل خدمة يقدّمها الطبيب
   - الدالة الأولى: كتالوج الخدمات للطبيب مع نسب "محسوبة" و"خام".
   - الدالة الثانية: تفصيل فترة (عدد المرات + إجمالي المبالغ للطبيب والمركز).
   ملاحظة الحساب:
     * خدمات الطبيب (doctor / doctorGeneral / طبيب):
         doctorPercentComputed = 100 - towerSharePercentage
         clinicPercentComputed = towerSharePercentage
     * المختبر/الأشعة:
         doctorPercentComputed = sharePercentage
         clinicPercentComputed = 100 - sharePercentage
  ───────────────────────────────────────────────────────────────*/

  /// كتالوج خدمات الطبيب مع النِّسب
  Future<List<Map<String, dynamic>>> getDoctorServiceCatalogWithPercents(
      int doctorId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT 
        ms.id   AS serviceId,
        ms.name AS serviceName,
        ms.serviceType,
        ms.cost,
        sds.sharePercentage       AS doctorPercentRaw,
        sds.towerSharePercentage  AS clinicPercentRaw,
        COALESCE(sds.sharePercentage, 0)      AS doctorPercentComputed,
        COALESCE(sds.towerSharePercentage, 0) AS clinicPercentComputed
      FROM service_doctor_share sds
      JOIN medical_services ms ON ms.id = sds.serviceId
      WHERE sds.doctorId = ?
        AND (sds.isDeleted IS NULL OR sds.isDeleted = 0)
        AND (ms.isDeleted  IS NULL OR ms.isDeleted  = 0)
        AND sds.isHidden = 0
      ORDER BY ms.name COLLATE NOCASE;
    ''', [doctorId]);
  }

  /// تفصيل فترة: عدد المرات + إجمالي مبالغ الطبيب والمركز لكل خدمة للطبيب
  Future<List<Map<String, dynamic>>> getDoctorServiceBreakdownBetween(
    int doctorId,
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    return db.rawQuery('''
      SELECT 
        ms.id   AS serviceId,
        ms.name AS serviceName,
        ms.serviceType,
        ms.cost,
        sds.sharePercentage      AS doctorPercentRaw,
        sds.towerSharePercentage AS clinicPercentRaw,
        COALESCE(sds.sharePercentage, 0)      AS doctorPercentComputed,
        COALESCE(sds.towerSharePercentage, 0) AS clinicPercentComputed,
        COUNT(ps.id)                      AS times,
        COALESCE(SUM(ps.serviceCost), 0)  AS totalRevenue,
        COALESCE(SUM(
          ps.serviceCost * (COALESCE(sds.sharePercentage, 0)/100.0)
        ), 0) AS doctorTotalAmount,
        COALESCE(SUM(
          ps.serviceCost * (COALESCE(sds.towerSharePercentage, 0)/100.0)
        ), 0) AS clinicTotalAmount
      FROM service_doctor_share sds
      JOIN medical_services ms ON ms.id = sds.serviceId
      LEFT JOIN ${PatientService.table} ps
        ON ps.serviceId = ms.id
       AND (ps.isDeleted IS NULL OR ps.isDeleted = 0)
      LEFT JOIN patients p ON p.id = ps.patientId
      WHERE sds.doctorId = ?
        AND (sds.isDeleted IS NULL OR sds.isDeleted = 0)
        AND (ms.isDeleted  IS NULL OR ms.isDeleted  = 0)
        AND sds.isHidden   = 0
        AND (p.registerDate BETWEEN ? AND ? OR p.registerDate IS NULL)
      GROUP BY ms.id, ms.name, ms.serviceType, ms.cost, sds.sharePercentage, sds.towerSharePercentage
      ORDER BY ms.name COLLATE NOCASE;
    ''', [doctorId, from.toIso8601String(), to.toIso8601String()]);
  }

  /// نسبة محسوبة لخدمة محددة لطبيب معيّن (مفيد للواجهات عند عرض خدمة واحدة).
  Future<Map<String, double>> getComputedPercentsForDoctorService({
    required int doctorId,
    required int serviceId,
  }) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT 
        ms.serviceType,
        COALESCE(sds.sharePercentage, 0)      AS shareP,
        COALESCE(sds.towerSharePercentage, 0) AS towerP
      FROM service_doctor_share sds
      JOIN medical_services ms ON ms.id = sds.serviceId
      WHERE sds.doctorId = ? AND sds.serviceId = ?
        AND (sds.isDeleted IS NULL OR sds.isDeleted = 0)
        AND (ms.isDeleted  IS NULL OR ms.isDeleted  = 0)
        AND sds.isHidden = 0
      LIMIT 1;
    ''', [doctorId, serviceId]);

    if (rows.isEmpty) {
      return {'doctor': 0.0, 'clinic': 0.0};
    }
    final r = rows.first;
    final double shareP = (r['shareP'] as num).toDouble();
    final double towerP = (r['towerP'] as num).toDouble();

    return {'doctor': shareP, 'clinic': towerP};
  }

  //=============================== إدارة الموظفين ===============================
  Future<int> insertEmployee(Map<String, dynamic> employeeData) async {
    final db = await database;
    final id = await db.insert('employees', employeeData);
    await _markChanged('employees');
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllEmployees() async {
    final db = await database;
    return db.query('employees',
        where: 'ifnull(isDeleted,0)=0', orderBy: 'id DESC');
  }

  Future<Employee?> getEmployeeByUserUid(String userUid) async {
    final trimmed = userUid.trim();
    if (trimmed.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'employees',
      where: 'userUid = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [trimmed],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Employee.fromMap(rows.first);
  }

  Future<Set<String>> getEmployeeUserUids() async {
    final db = await database;
    final rows = await db.query(
      'employees',
      columns: const ['userUid'],
      where:
          "userUid IS NOT NULL AND TRIM(userUid) <> '' AND ifnull(isDeleted,0)=0",
    );
    final set = <String>{};
    for (final row in rows) {
      final raw = row['userUid']?.toString().trim() ?? '';
      if (raw.isNotEmpty) set.add(raw);
    }
    return set;
  }

  Future<int> updateEmployee(
      int employeeId, Map<String, dynamic> newData) async {
    final db = await database;
    final rows = await db
        .update('employees', newData, where: 'id = ?', whereArgs: [employeeId]);
    await _markChanged('employees');
    return rows;
  }

  Future<int> deleteEmployee(int employeeId) async {
    final rows = await _softDeleteById('employees', employeeId);
    await _markChanged('employees');
    return rows;
  }

  Future<Map<String, dynamic>?> getEmployeeById(int employeeId) async {
    final db = await database;
    final res = await db.query('employees',
        where: 'id = ? AND ifnull(isDeleted,0)=0',
        whereArgs: [employeeId],
        limit: 1);
    return res.isEmpty ? null : res.first;
  }

  Future<Set<String>> getLinkedUserUids() async {
    final db = await database;
    final linked = <String>{};

    final doctors = await db.query(
      'doctors',
      columns: const ['userUid'],
      where: 'ifnull(isDeleted,0)=0',
    );
    for (final row in doctors) {
      final raw = row['userUid'] ?? row['user_uid'];
      final uid = (raw ?? '').toString().trim();
      if (uid.isNotEmpty) linked.add(uid);
    }

    final employees = await db.query(
      'employees',
      columns: const ['userUid'],
      where: 'ifnull(isDeleted,0)=0',
    );
    for (final row in employees) {
      final raw = row['userUid'] ?? row['user_uid'];
      final uid = (raw ?? '').toString().trim();
      if (uid.isNotEmpty) linked.add(uid);
    }

    return linked;
  }

  //=============================== سلف الموظفين ===============================
  Future<int> insertEmployeeLoan(Map<String, dynamic> loanData) async {
    final db = await database;
    final id = await db.insert('employees_loans', loanData);
    await _markChanged('employees_loans');
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllEmployeeLoans() async {
    final db = await database;
    return db.query('employees_loans',
        where: 'ifnull(isDeleted,0)=0', orderBy: 'loanDateTime DESC');
  }

  Future<int> updateEmployeeLoan(
      int loanId, Map<String, dynamic> newData) async {
    final db = await database;
    final rows = await db.update('employees_loans', newData,
        where: 'id = ?', whereArgs: [loanId]);
    await _markChanged('employees_loans');
    return rows;
  }

  Future<int> deleteEmployeeLoan(int loanId) async {
    final rows = await _softDeleteById('employees_loans', loanId);
    await _markChanged('employees_loans');
    return rows;
  }

  Future<int> markEmployeeLoansSettled({
    required int employeeId,
    required int year,
    required int month,
  }) async {
    final db = await database;
    final rows = await db.rawUpdate('''
        UPDATE employees_loans
        SET loanAmount = 0
        WHERE employeeId = ?
          AND strftime('%Y', loanDateTime) = ?
          AND strftime('%m', loanDateTime) = ?
          AND ifnull(isDeleted,0)=0
      ''', [employeeId, year.toString(), month.toString().padLeft(2, '0')]);
    await _markChanged('employees_loans');
    return rows;
  }

  //=============================== رواتب الموظفين ===============================
  Future<int> insertEmployeeSalary(Map<String, dynamic> salaryData) async {
    final db = await database;
    final id = await db.insert('employees_salaries', salaryData);
    await _markChanged('employees_salaries');
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllEmployeeSalaries() async {
    final db = await database;
    return db.query('employees_salaries',
        where: 'ifnull(isDeleted,0)=0', orderBy: 'id DESC');
  }

  Future<int> updateEmployeeSalary(
      int salaryId, Map<String, dynamic> newData) async {
    final db = await database;
    final rows = await db.update('employees_salaries', newData,
        where: 'id = ?', whereArgs: [salaryId]);
    await _markChanged('employees_salaries');
    return rows;
  }

  Future<int> deleteEmployeeSalary(int salaryId) async {
    final rows = await _softDeleteById('employees_salaries', salaryId);
    await _markChanged('employees_salaries');
    return rows;
  }

  //=============================== خصومات الموظفين ===============================
  Future<int> insertEmployeeDiscount(Map<String, dynamic> discountData) async {
    final db = await database;
    final id = await db.insert('employees_discounts', discountData);
    await _markChanged('employees_discounts');
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllEmployeeDiscounts() async {
    final db = await database;
    return db.query(
      'employees_discounts',
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'discountDateTime DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getDiscountsByEmployee(int empId) async {
    final db = await database;
    return db.query(
      'employees_discounts',
      where: 'employeeId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [empId],
      orderBy: 'discountDateTime DESC',
    );
  }

  Future<int> updateEmployeeDiscount(
      int discountId, Map<String, dynamic> newData) async {
    final db = await database;
    final rows = await db.update('employees_discounts', newData,
        where: 'id = ?', whereArgs: [discountId]);
    await _markChanged('employees_discounts');
    return rows;
  }

  Future<int> deleteEmployeeDiscount(int discountId) async {
    final rows = await _softDeleteById('employees_discounts', discountId);
    await _markChanged('employees_discounts');
    return rows;
  }

  //=============================== الإحصائيات ===============================
  Future<int> getTotalPatients() async {
    final db = await database;
    final res = await db.rawQuery(
        'SELECT COUNT(*) as count FROM patients WHERE ifnull(isDeleted,0)=0');
    return Sqflite.firstIntValue(res) ?? 0;
  }

  Future<int> getSuccessfulAppointments() async {
    final db = await database;
    final res = await db.rawQuery(
        "SELECT COUNT(*) as count FROM appointments WHERE status = 'مؤكد' AND ifnull(isDeleted,0)=0");
    return Sqflite.firstIntValue(res) ?? 0;
  }

  Future<int> getFollowUpCount() async {
    final db = await database;
    final res = await db.rawQuery(
        "SELECT COUNT(*) as count FROM appointments WHERE status = 'متابعة' AND ifnull(isDeleted,0)=0");
    return Sqflite.firstIntValue(res) ?? 0;
  }

  Future<double> getFinancialTotal() async {
    final db = await database;
    final res = await db.rawQuery(
        'SELECT SUM(paidAmount) as total FROM patients WHERE ifnull(isDeleted,0)=0');
    return res.first['total'] == null
        ? 0.0
        : (res.first['total'] as num).toDouble();
  }

  //=============================== إدارة قاعدة البيانات ===============================
  Future<void> flushAndClose() async {
    if (_db == null) return;
    await _db!.rawQuery('PRAGMA wal_checkpoint(FULL)');
    await _db!.close();
    _db = null;
  }

  @visibleForTesting
  static void setTestDatabasePath(String? path) {
    _testDbPathOverride = (path == null || path.isEmpty) ? null : path;
  }

  @visibleForTesting
  Future<void> resetForTesting({String? databasePath}) async {
    await flushAndClose();
    setTestDatabasePath(databasePath);
    _opening = null;
  }

  /// مسح كل الجداول المحلية (لما تغيّر الحساب) ثم تعليم الإحصاءات كـ Dirty.
  Future<void> clearAllLocalTables() async {
    final db = await database;
    final batch = db.batch();
    const tables = <String>[
      'patients',
      'returns',
      'consumptions',
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
      'attachments',
      'financial_logs',
      PatientService.table,
      Drug.table,
      Prescription.table,
      PrescriptionItem.table,
      'complaints',
      'sync_fk_mapping',
    ];
    for (final t in tables) {
      batch.delete(t);
    }
    batch.delete('remote_id_map');
    await batch.commit(noResult: true);

    // 🧽 إعادة ضبط عدّادات AUTOINCREMENT (إن وُجدت)
    try {
      await db.rawDelete('DELETE FROM sqlite_sequence');
    } catch (_) {
      // بعض الإصدارات/البيئات قد لا تحتوي sqlite_sequence
    }

    await db.update('stats_dirty', {'dirty': 1}, where: 'id = 1');
  }

  //=============================== دوال إضافية للإحصاء ===============================
  Future<double> getSumPatientsBetween(DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
        SELECT SUM(paidAmount) as total
        FROM patients
        WHERE registerDate BETWEEN ? AND ?
          AND ifnull(isDeleted,0)=0
      ''', [from.toIso8601String(), to.toIso8601String()]);
    return res.first['total'] == null
        ? 0.0
        : (res.first['total'] as num).toDouble();
  }

  Future<double> getSumConsumptionBetween(DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
        SELECT COALESCE(SUM(
          CASE 
            WHEN (c.amount IS NULL OR c.amount = 0)
              THEN COALESCE(i.price, 0) * COALESCE(c.quantity, 0)
            ELSE c.amount
          END
        ), 0) as total
        FROM consumptions c
        LEFT JOIN items i ON i.id = c.itemId
        WHERE c.date BETWEEN ? AND ?
          AND ifnull(c.isDeleted,0)=0
      ''', [from.toIso8601String(), to.toIso8601String()]);
    return res.first['total'] == null
        ? 0.0
        : (res.first['total'] as num).toDouble();
  }

  Future<double> getSumReturnsRemainingBetween(
      DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
        SELECT SUM(remaining) as total
        FROM returns
        WHERE date BETWEEN ? AND ?
          AND ifnull(isDeleted,0)=0
      ''', [from.toIso8601String(), to.toIso8601String()]);
    return res.first['total'] == null
        ? 0.0
        : (res.first['total'] as num).toDouble();
  }

  /*───────────────────────────────────────────────────────────────
    🔧 دوال الراتب/النِّسب (مصَحّحة لتُحسب من patient_services + medical_services)
    - نعتمد ms.serviceType بدل p.serviceType
    - ننسب خدمات الـ serviceId عبر sds.doctorId
    - السطور الحرّة (serviceId NULL) تُنسب لطبيب المريض فقط في مدخلات الطبيب
   ───────────────────────────────────────────────────────────────*/
  Future<double> getDoctorRatioSum(
      int doctorId, DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        ps.serviceCost * (COALESCE(sds.sharePercentage, 0) / 100.0)
      ), 0) AS ratioSum
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = ?
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND ms.serviceType IN ('radiology','lab','الأشعة','المختبر')
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND ifnull(ms.isDeleted,0)=0
    ''', [doctorId, from.toIso8601String(), to.toIso8601String()]);
    return (res.first['ratioSum'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getEffectiveDoctorDirectInputSum(
      int doctorId, DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        CASE
          -- سطر حر بلا serviceId: يُنسب لطبيب المريض فقط
          WHEN ps.serviceId IS NULL THEN CASE WHEN p.doctorId = ? THEN ps.serviceCost ELSE 0 END
          -- خدمة مُعرّفة: تُنسب لطبيب الخدمة عبر sds.doctorId وتكون من نوع طبيب
          WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب') THEN
            CASE WHEN sds.doctorId = ? THEN ps.serviceCost * (1.0 - COALESCE(sds.towerSharePercentage, 0) / 100.0)
                 ELSE 0 END
          ELSE 0
        END
      ), 0) AS docInput
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = ?
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
    ''', [
      doctorId, // حالة السطر الحر
      doctorId, // خدمات الطبيب المُعرّفة
      doctorId, // ربط sds
      from.toIso8601String(),
      to.toIso8601String(),
    ]);
    return (res.first['docInput'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getDoctorTowerShareSum(
      int doctorId, DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        CASE
          -- بلا serviceId لا نعرف نسبة المركز من sds
          WHEN ps.serviceId IS NULL THEN 0
          -- خدمة مُعرّفة لطبيب هذه الخدمة، وتحت طبيب/أشعة/مختبر
          WHEN sds.doctorId = ? AND
               (ms.serviceType IN ('radiology','lab','doctor','doctorGeneral','الأشعة','المختبر','طبيب'))
            THEN ps.serviceCost * (COALESCE(sds.towerSharePercentage, 0) / 100.0)
          ELSE 0
        END
      ), 0) AS towerShare
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = ?
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
    ''', [doctorId, doctorId, from.toIso8601String(), to.toIso8601String()]);
    return (res.first['towerShare'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getEffectiveSumAllDoctorInputBetween(
      DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        CASE
          -- سطور حرّة تُحسب لطبيب المريض
          WHEN ps.serviceId IS NULL THEN ps.serviceCost
          -- خدمات طبيب مُعرّفة تُنسب لطبيب الخدمة = طبيب المريض هنا
          WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
               AND sds.doctorId = p.doctorId
            THEN ps.serviceCost * (1.0 - COALESCE(sds.towerSharePercentage, 0) / 100.0)
          ELSE 0
        END
      ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = p.doctorId
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND (ps.serviceId IS NULL OR ms.serviceType IN ('doctor','doctorGeneral','طبيب'))
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
    ''', [from.toIso8601String(), to.toIso8601String()]);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getSumAllDoctorShareBetween(DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        ps.serviceCost * (COALESCE(sds.sharePercentage, 0) / 100.0)
      ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = p.doctorId
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND ms.serviceType IN ('radiology','lab','الأشعة','المختبر')
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND ifnull(ms.isDeleted,0)=0
    ''', [from.toIso8601String(), to.toIso8601String()]);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getSumAllDoctorInputBetween(DateTime from, DateTime to) async {
    return getEffectiveSumAllDoctorInputBetween(from, to);
  }

  Future<double> getSumAllTowerShareBetween(DateTime from, DateTime to) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        CASE
          WHEN ps.serviceId IS NULL THEN 0
          WHEN ms.serviceType IN ('radiology','lab','doctor','doctorGeneral','الأشعة','المختبر','طبيب')
               AND sds.doctorId = p.doctorId
            THEN ps.serviceCost * (COALESCE(sds.towerSharePercentage, 0) / 100.0)
          ELSE 0
        END
      ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = p.doctorId
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND (ps.serviceId IS NULL OR ms.serviceType IN ('radiology','lab','doctor','doctorGeneral','الأشعة','المختبر','طبيب'))
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
    ''', [from.toIso8601String(), to.toIso8601String()]);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<Map<String, double>> getDoctorShareByDateBetween(
      DateTime from, DateTime to) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT 
        date(p.registerDate) AS dayKey,
        COALESCE(SUM(
          ps.serviceCost * (COALESCE(sds.sharePercentage, 0) / 100.0)
        ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = p.doctorId
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND ms.serviceType IN ('radiology','lab','الأشعة','المختبر')
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND ifnull(ms.isDeleted,0)=0
      GROUP BY date(p.registerDate)
      ORDER BY dayKey ASC
    ''', [from.toIso8601String(), to.toIso8601String()]);
    final out = <String, double>{};
    for (final row in rows) {
      final key = row['dayKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  Future<Map<String, double>> getDoctorInputByDateBetween(
      DateTime from, DateTime to) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT 
        date(p.registerDate) AS dayKey,
        COALESCE(SUM(
          CASE
            WHEN ps.serviceId IS NULL THEN ps.serviceCost
            WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
                 AND sds.doctorId = p.doctorId
              THEN ps.serviceCost * (COALESCE(sds.sharePercentage, 0) / 100.0)
            ELSE 0
          END
        ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND sds.doctorId = p.doctorId
       AND ifnull(sds.isDeleted,0)=0
      WHERE p.registerDate BETWEEN ? AND ?
        AND (ps.serviceId IS NULL OR ms.serviceType IN ('doctor','doctorGeneral','طبيب'))
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
      GROUP BY date(p.registerDate)
      ORDER BY dayKey ASC
    ''', [from.toIso8601String(), to.toIso8601String()]);
    final out = <String, double>{};
    for (final row in rows) {
      final key = row['dayKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  Future<int> insertConsumptionType(String type) async {
    final db = await database;
    final id = await db.insert('consumption_types', {'type': type},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await _markChanged('consumption_types'); // ← ضمان الدفع
    return id;
  }

  Future<List<String>> getAllConsumptionTypes() async {
    final db = await database;
    final res = await db.query('consumption_types',
        where: 'ifnull(isDeleted,0)=0', orderBy: 'id ASC');
    return res.map((row) => row['type'] as String).toList();
  }

  Future<String> getAttachmentsDir() async {
    final dbPath = await getDatabasePath();
    final dirPath = p.join(p.dirname(dbPath), 'attachments');
    try {
      await Directory(dirPath).create(recursive: true);
    } catch (_) {}
    return dirPath;
  }

  /*────────────────── دوال stats_dirty للمزامنة ──────────────────*/
  Future<bool> isStatisticsDirty() async {
    final db = await database;
    final res = await db.query('stats_dirty', where: 'id = 1', limit: 1);
    if (res.isEmpty) return true;
    return (res.first['dirty'] as int? ?? 1) == 1;
  }

  Future<void> clearStatisticsDirty() async {
    final db = await database;
    await db.update('stats_dirty', {'dirty': 0}, where: 'id = 1');
  }

  Future<void> markStatisticsDirty() async {
    final db = await database;
    await db.update('stats_dirty', {'dirty': 1}, where: 'id = 1');
  }

  /*────────────────── Helpers (idempotent DDL) ──────────────────*/
  Future<bool> _tableExists(DatabaseExecutor db, String table) async {
    try {
      final res = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [table]);
      return res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _columnExists(
      DatabaseExecutor db, String table, String column) async {
    if (!await _tableExists(db, table)) return false;
    List<Map<String, Object?>> info = const [];
    try {
      info = await db.rawQuery("PRAGMA table_info('$table')");
    } catch (_) {
      return false;
    }
    for (final row in info) {
      final name = (row['name'] ?? '').toString();
      if (name.toLowerCase() == column.toLowerCase()) return true;
    }
    return false;
  }

  Future<void> _addColumnIfMissing(
      DatabaseExecutor db, String table, String column, String sqlType) async {
    if (!await _tableExists(db, table)) {
      return;
    }
    if (!await _columnExists(db, table, column)) {
      try {
        await db.execute('ALTER TABLE $table ADD COLUMN $column $sqlType');
      } catch (_) {
        // Ignore missing table/column errors during defensive upgrades.
      }
    }
  }

  Future<void> _ensureUuidMappingTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_uuid_mapping (
        table_name TEXT NOT NULL,
        record_id INTEGER NOT NULL,
        account_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        local_sync_id INTEGER NOT NULL,
        uuid TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (table_name, uuid)
      );
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tg_sync_uuid_mapping_updated_at
      AFTER UPDATE ON sync_uuid_mapping
      FOR EACH ROW
      BEGIN
        UPDATE sync_uuid_mapping
        SET updated_at = CURRENT_TIMESTAMP
        WHERE table_name = OLD.table_name AND uuid = OLD.uuid;
      END;
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uix_sync_uuid_mapping_record
      ON sync_uuid_mapping(table_name, record_id);
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uix_sync_uuid_mapping_sync_key
      ON sync_uuid_mapping(table_name, account_id, device_id, local_sync_id);
    ''');
  }

  Future<void> _createIndexIfMissing(DatabaseExecutor db, String indexName,
      String table, List<String> columns) async {
    if (!await _tableExists(db, table)) {
      return;
    }
    final cols = columns.join(',');
    try {
      await db
          .execute('CREATE INDEX IF NOT EXISTS $indexName ON $table($cols)');
    } catch (_) {
      // قد يُستدعى أثناء ترقية دفاعية قبل إنشاء الجدول، لذا نتجاهل الخطأ.
    }
  }
}
