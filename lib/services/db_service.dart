library db_service;

// lib/services/db_service.dart
// - Works on Android + Desktop (Windows/Linux/macOS) using sqflite + sqflite_common_ffi
// - Fix generics: Future<int> (not Future[int])
// - Add `dart:async` import so `Future` is recognized
// - Enable WAL & add a lightweight change stream for live sync integrations.
// - Windows path unified via AppPaths (LOCALAPPDATA only) with auto-migration from legacy locations
//
// 🔗 للربط مع SyncService (الدفع المؤجّل لكل جدول):
// final sync = SyncService(db, accountId, deviceId: deviceId);
// DBService.instance.bindSyncPush(sync.pushFor);

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'package:path/path.dart' as p;
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/sync/clinic_sync_domains.dart';
import 'package:aelmamclinic/l10n/raw_string_localizer.dart';
import 'package:uuid/uuid.dart';

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
import 'package:aelmamclinic/models/inventory_health_report.dart';
import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/models/attachment.dart';
import 'package:aelmamclinic/utils/app_paths.dart';
import 'package:aelmamclinic/utils/app_observability.dart';

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

const String _kClinicSyncOutboxTable = 'clinic_sync_outbox';
const String _kClinicSyncStateTable = 'clinic_sync_state';
const String _kClinicSyncConflictsTable = 'clinic_sync_conflicts';
const String _kClinicSyncHealthEventsTable = 'clinic_sync_health_events';
const Set<String> _kClinicOutboxFoundationTables = {
  'item_types',
  'items',
  'drugs',
  'medical_services',
  'consumption_types',
  'service_doctor_share',
  'employees',
  'doctors',
  'patients',
  'patient_services',
  'returns',
  'appointments',
  'prescriptions',
  'prescription_items',
  'consumptions',
  'purchases',
  'alert_settings',
  'employees_loans',
  'employees_salaries',
  'employees_discounts',
  'complaints',
  'financial_logs',
};
const Uuid _clinicSyncUuid = Uuid();

class DBService {
  DBService._();
  static final DBService instance = DBService._();
  static String _tr(String raw) =>
      RawStringLocalizer.translateWithCurrentLocale(raw);

  static Database? _db;
  // 🧯 يمنع سباقات الفتح عند استدعاء .database من عدّة أماكن بالتوازي
  static Future<Database>? _opening;
  late final PatientLocalRepository patients = PatientLocalRepository(this);

  static String? _testDbPathOverride;

  /// Stream يبث اسم الجدول عند أي تعديل محلي (مكمل لـ onLocalChange)
  final _changeController = StreamController<String>.broadcast();
  Stream<String> get changes => _changeController.stream;

  // Serialize write operations to avoid SQLite "database is locked" under sync load.
  Future<void> _writeQueue = Future<void>.value();
  static final Object _writeZoneKey = Object();
  Future<void>? _ensureAlertSettingsColumnsInFlight;
  Future<void>? _ensureItemTypesNoUniqueNameInFlight;
  bool _patientPaymentBackfillBusy = false;

  String _newDbFlow(String label) => AppObservability.newFlowId('db_$label');

  Map<String, Object?> _dbContext([Map<String, Object?>? extra]) {
    return <String, Object?>{
      'cachedAccountId': _cachedAccountId,
      'cachedDeviceId': _cachedDeviceId,
      ...?extra,
    };
  }

  void _dbWarn(
    String code,
    String message, {
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    AppObservability.warn(
      scope: 'DB',
      code: code,
      message: message,
      flowId: flowId,
      context: _dbContext(context),
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<T> runQueuedWrite<T>(Future<T> Function() op) {
    if (Zone.current[_writeZoneKey] == true) {
      return op();
    }
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        final res = await runZoned(
          () => op(),
          zoneValues: {_writeZoneKey: true},
        );
        completer.complete(res);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// يمكنك تعيينها من الخارج:
  /// DBService.instance.onLocalChange = (tbl) => sync.pushFor(tbl);
  LocalChangeCallback? onLocalChange;

  /// تجميع + تأخير خفيف لنداءات الـ push لتفادي ضغط الطلبات و"database is locked"
  final Map<String, Timer> _pushDebouncers = <String, Timer>{};
  final Set<String> _pendingTables = <String>{};
  final Map<String, Set<String>> _tableColumnsCache = <String, Set<String>>{};
  String? _cachedAccountId;
  String? _cachedDeviceId;
  DateTime? _lastRepairBackupAt;

  void setCachedSyncIdentity({String? accountId, String? deviceId}) {
    _cachedAccountId = accountId?.trim().isEmpty == true ? null : accountId;
    _cachedDeviceId = deviceId?.trim().isEmpty == true ? null : deviceId;
    unawaited(_runPatientPaymentBackfillIfNeeded());
  }

  void clearCachedSyncIdentity() {
    _cachedAccountId = null;
    _cachedDeviceId = null;
  }

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

      await _setDirty(table);

      // إذا لم تكن آلية الدفع مربوطة بعد → خزّن الاسم مؤقتًا
      if (onLocalChange == null) {
        _pendingTables.add(table);
      } else {
        _schedulePush(table);
      }
    } catch (_) {
      _dbWarn(
        ObsCode.dbMarkChangedFailed,
        'markChanged failed while signaling local table mutation',
        flowId: _newDbFlow('mark_changed'),
        context: {'table': table},
      );
    }
  }

  Future<Set<String>> _getTableColumns(
    DatabaseExecutor db,
    String table,
  ) async {
    if (_tableColumnsCache.containsKey(table)) {
      return _tableColumnsCache[table]!;
    }
    try {
      final rows = await db.rawQuery("PRAGMA table_info($table)");
      final cols = rows
          .map((r) => r['name']?.toString() ?? '')
          .where((v) => v.isNotEmpty)
          .toSet();
      _tableColumnsCache[table] = cols;
      return cols;
    } catch (e, st) {
      _dbWarn(
        ObsCode.dbGetTableColumnsFailed,
        'loading table columns failed',
        flowId: _newDbFlow('table_columns'),
        context: {'table': table},
        error: e,
        stackTrace: st,
      );
      return const <String>{};
    }
  }

  Future<bool> _hasColumn(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
    final cols = await _getTableColumns(db, table);
    return cols.contains(column);
  }

  Future<bool> hasColumn(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
    return _hasColumn(db, table, column);
  }

  Future<bool> _isAccountIsolationPending() async {
    final snapshot = await ActiveAccountStore.readSnapshot();
    return snapshot.pendingWipe;
  }

  Future<String?> _currentAccountIdFrom(DatabaseExecutor db) async {
    if (await _isAccountIsolationPending()) {
      _cachedAccountId = null;
      return null;
    }
    try {
      final fromStore = await ActiveAccountStore.readAccountId();
      if (fromStore != null && fromStore.trim().isNotEmpty) {
        final candidate = fromStore.trim();
        if (_cachedAccountId == candidate) {
          return candidate;
        }
        _cachedAccountId = candidate;
        await _ensureSyncIdentityAccountId(db, candidate);
        return candidate;
      }
    } catch (e, st) {
      _dbWarn(
        ObsCode.dbCurrentAccountIdFailed,
        'reading active account id from ActiveAccountStore failed',
        flowId: _newDbFlow('current_account_store'),
        error: e,
        stackTrace: st,
      );
    }
    if (_cachedAccountId != null && _cachedAccountId!.trim().isNotEmpty) {
      return _cachedAccountId;
    }
    try {
      if (!await _tableExists(db, 'sync_identity')) return null;
      final rows = await db.rawQuery(
        'SELECT account_id FROM sync_identity LIMIT 1',
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['account_id']?.toString().trim() ?? '';
      final acc = raw.isEmpty ? null : raw;
      if (acc != null) _cachedAccountId = acc;
      return acc;
    } catch (e, st) {
      _dbWarn(
        ObsCode.dbCurrentAccountIdFailed,
        'reading current account id from sync_identity failed',
        flowId: _newDbFlow('current_account_from'),
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  Future<String?> _fallbackAccountIdFromLocal(DatabaseExecutor db) async {
    try {
      final tables = <String>[
        'employees',
        'accounts',
        'clinic_profile',
        'items',
        'patients',
        'appointments',
        'purchases',
        'consumptions',
      ];
      final found = <String>{};
      for (final table in tables) {
        if (!await _tableExists(db, table)) continue;
        if (!await _hasColumn(db, table, 'account_id')) continue;
        final rows = await db.rawQuery(
          "SELECT DISTINCT account_id FROM $table "
          "WHERE account_id IS NOT NULL AND length(trim(account_id)) > 0 "
          "LIMIT 2",
        );
        for (final row in rows) {
          final acc = row['account_id']?.toString().trim();
          if (acc != null && acc.isNotEmpty) {
            found.add(acc);
            if (found.length > 1) return null;
          }
        }
      }
      if (found.length == 1) return found.first;
    } catch (e, st) {
      _dbWarn(
        ObsCode.dbFallbackAccountIdFailed,
        'fallback local account id discovery failed',
        flowId: _newDbFlow('fallback_account_from_local'),
        error: e,
        stackTrace: st,
      );
    }
    return null;
  }

  Future<void> _ensureSyncIdentityAccountId(
    DatabaseExecutor db,
    String accountId,
  ) async {
    try {
      if (!await _tableExists(db, 'sync_identity')) return;
      final rows = await db.rawQuery(
        'SELECT account_id FROM sync_identity LIMIT 1',
      );
      if (rows.isEmpty) {
        await db.rawInsert(
          'INSERT INTO sync_identity(account_id, device_id) VALUES (?, COALESCE((SELECT device_id FROM sync_identity LIMIT 1), ""))',
          [accountId],
        );
        return;
      }
      final existing = rows.first['account_id']?.toString().trim() ?? '';
      if (existing.isEmpty) {
        await db.rawUpdate('UPDATE sync_identity SET account_id = ?', [
          accountId,
        ]);
      }
    } catch (e, st) {
      _dbWarn(
        ObsCode.dbEnsureSyncIdentityFailed,
        'ensuring sync_identity account id failed',
        flowId: _newDbFlow('ensure_sync_identity_account'),
        context: {'accountId': accountId},
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<String?> _currentAccountId() async {
    final db = await database;
    if (await _isAccountIsolationPending()) {
      _cachedAccountId = null;
      return null;
    }
    final acc = await _currentAccountIdFrom(db);
    if (acc != null && acc.trim().isNotEmpty) {
      return acc.trim();
    }
    final fallback = await _fallbackAccountIdFromLocal(db);
    if (fallback != null && fallback.trim().isNotEmpty) {
      _cachedAccountId = fallback;
      await _ensureSyncIdentityAccountId(db, fallback);
      try {
        await ActiveAccountStore.writeAccountId(fallback);
      } catch (e, st) {
        _dbWarn(
          ObsCode.dbCurrentAccountIdFailed,
          'persisting fallback account id to ActiveAccountStore failed',
          flowId: _newDbFlow('persist_fallback_account'),
          context: {'accountId': fallback},
          error: e,
          stackTrace: st,
        );
      }
      return fallback;
    }
    return null;
  }

  Future<String?> currentAccountId() async {
    return _currentAccountId();
  }

  Future<String?> _currentDeviceIdFrom(DatabaseExecutor db) async {
    if (_cachedDeviceId != null && _cachedDeviceId!.trim().isNotEmpty) {
      return _cachedDeviceId;
    }
    try {
      if (!await _tableExists(db, 'sync_identity')) return null;
      if (!await _hasColumn(db, 'sync_identity', 'device_id')) return null;
      final rows = await db.rawQuery(
        'SELECT device_id FROM sync_identity LIMIT 1',
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['device_id']?.toString().trim() ?? '';
      final dev = raw.isEmpty ? null : raw;
      if (dev != null) _cachedDeviceId = dev;
      return dev;
    } catch (e, st) {
      _dbWarn(
        ObsCode.dbCurrentDeviceIdFailed,
        'reading current device id from sync_identity failed',
        flowId: _newDbFlow('current_device_from'),
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  Future<Map<String, dynamic>> prepareInsert(
    String table,
    Map<String, dynamic> data, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final prepared = Map<String, dynamic>.from(data);

    if (await _hasColumn(db, table, 'account_id')) {
      final accountId = await _currentAccountIdFrom(db);
      if (accountId == null || accountId.trim().isEmpty) {
        throw StateError(_tr('لا يوجد حساب نشط للحفظ في $table'));
      }
      prepared.putIfAbsent('account_id', () => accountId);
    }

    if (await _hasColumn(db, table, 'device_id')) {
      final deviceId = await _currentDeviceIdFrom(db);
      if (deviceId != null && deviceId.trim().isNotEmpty) {
        prepared.putIfAbsent('device_id', () => deviceId);
      }
    }

    if (await _hasColumn(db, table, 'updated_at')) {
      prepared.putIfAbsent(
        'updated_at',
        () => DateTime.now().toIso8601String(),
      );
    }

    if (await _hasColumn(db, table, 'isDeleted')) {
      prepared.putIfAbsent('isDeleted', () => 0);
    }

    return prepared;
  }

  Future<void> _ensureClinicSyncInfrastructure(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_kClinicSyncOutboxTable (
        id TEXT PRIMARY KEY,
        operation_type TEXT NOT NULL,
        entity_table TEXT NOT NULL,
        entity_id INTEGER,
        remote_id TEXT,
        client_mutation_id TEXT NOT NULL UNIQUE,
        account_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        local_id INTEGER,
        payload_json TEXT NOT NULL,
        local_reference_json TEXT,
        status TEXT NOT NULL DEFAULT 'queued',
        retry_count INTEGER NOT NULL DEFAULT 0,
        next_retry_at TEXT,
        last_attempt_at TEXT,
        locked_at TEXT,
        last_error_code TEXT,
        last_error_message TEXT,
        last_response_json TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT
      );
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uix_clinic_sync_outbox_client_mutation
      ON $_kClinicSyncOutboxTable(client_mutation_id);
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clinic_sync_outbox_status_retry
      ON $_kClinicSyncOutboxTable(status, next_retry_at);
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clinic_sync_outbox_account_status
      ON $_kClinicSyncOutboxTable(account_id, status);
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clinic_sync_outbox_entity
      ON $_kClinicSyncOutboxTable(entity_table, entity_id);
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clinic_sync_outbox_sync_key
      ON $_kClinicSyncOutboxTable(account_id, device_id, local_id);
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_kClinicSyncStateTable (
        scope_key TEXT PRIMARY KEY,
        cursor_json TEXT,
        last_server_timestamp TEXT,
        last_pull_started_at TEXT,
        last_pull_completed_at TEXT,
        last_push_completed_at TEXT,
        is_full_resync_required INTEGER NOT NULL DEFAULT 0,
        last_error_code TEXT,
        updated_at TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_kClinicSyncConflictsTable (
        id TEXT PRIMARY KEY,
        account_id TEXT,
        device_id TEXT,
        entity_table TEXT NOT NULL,
        entity_id INTEGER,
        remote_id TEXT,
        operation_type TEXT,
        client_mutation_id TEXT,
        conflict_code TEXT NOT NULL,
        local_payload_json TEXT,
        remote_payload_json TEXT,
        resolution_status TEXT NOT NULL DEFAULT 'open',
        last_error_message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clinic_sync_conflicts_account_status
      ON $_kClinicSyncConflictsTable(account_id, resolution_status);
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clinic_sync_conflicts_entity
      ON $_kClinicSyncConflictsTable(entity_table, entity_id);
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_kClinicSyncHealthEventsTable (
        id TEXT PRIMARY KEY,
        scope TEXT NOT NULL,
        severity TEXT NOT NULL,
        code TEXT NOT NULL,
        message TEXT NOT NULL,
        account_id TEXT,
        device_id TEXT,
        entity_table TEXT,
        entity_id INTEGER,
        payload_json TEXT,
        created_at TEXT NOT NULL
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clinic_sync_health_account_created
      ON $_kClinicSyncHealthEventsTable(account_id, created_at);
    ''');
  }

  Future<void> _enqueueClinicOutboxForRow(
    DatabaseExecutor db, {
    required String table,
    required int? entityId,
    required String operationType,
  }) async {
    if (!_kClinicOutboxFoundationTables.contains(table)) return;
    if (entityId == null || entityId <= 0) return;
    try {
      await _ensureClinicSyncInfrastructure(db);
      if (!await _tableExists(db, table)) return;
      final rows = await db.query(
        table,
        where: 'id = ?',
        whereArgs: <Object?>[entityId],
        limit: 1,
      );
      if (rows.isEmpty) {
        await _recordClinicSyncHealthEvent(
          db,
          severity: 'warning',
          code: 'outbox_source_row_missing',
          message: 'تعذر تسجيل عملية المزامنة لأن السجل المحلي غير موجود.',
          entityTable: table,
          entityId: entityId,
        );
        return;
      }

      final row = Map<String, Object?>.from(rows.first);
      final accountId =
          _nonEmpty(row['account_id']) ?? await _currentAccountIdFrom(db);
      final deviceId =
          _nonEmpty(row['device_id']) ?? await _currentDeviceIdFrom(db);
      if (accountId == null || deviceId == null) {
        await _recordClinicSyncHealthEvent(
          db,
          severity: 'warning',
          code: 'outbox_identity_missing',
          message:
              'تم حفظ السجل محليًا لكن لم يتم إنشاء outbox لغياب account_id أو device_id.',
          entityTable: table,
          entityId: entityId,
          payload: <String, Object?>{
            'has_account_id': accountId != null,
            'has_device_id': deviceId != null,
          },
        );
        return;
      }

      final localId = _intValue(row['local_id']) ?? entityId;
      final remoteId = await _remoteUuidForOutboxRow(
        db,
        table: table,
        entityId: entityId,
      );
      final now = DateTime.now().toIso8601String();
      final clientMutationId =
          '$accountId:$deviceId:$table:$localId:$operationType:'
          '${DateTime.now().toUtc().microsecondsSinceEpoch}:'
          '${_clinicSyncUuid.v4()}';
      final domain = ClinicSyncDomains.domainForTable(table).name;
      final payload = <String, Object?>{
        ...row,
        'client_mutation_id': clientMutationId,
        'operation_type': operationType,
        'sync_domain': domain,
      };
      final localReference = <String, Object?>{
        'entity_table': table,
        'entity_id': entityId,
        'local_id': localId,
        'account_id': accountId,
        'device_id': deviceId,
        'domain': domain,
      };

      await db.insert(_kClinicSyncOutboxTable, <String, Object?>{
        'id': _clinicSyncUuid.v4(),
        'operation_type': operationType,
        'entity_table': table,
        'entity_id': entityId,
        'remote_id': remoteId,
        'client_mutation_id': clientMutationId,
        'account_id': accountId,
        'device_id': deviceId,
        'local_id': localId,
        'payload_json': jsonEncode(_jsonSafe(payload)),
        'local_reference_json': jsonEncode(localReference),
        'status': 'queued',
        'retry_count': 0,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } catch (e, st) {
      _dbWarn(
        ObsCode.dbMarkChangedFailed,
        'clinic outbox enqueue failed',
        flowId: _newDbFlow('clinic_outbox_enqueue'),
        context: <String, Object?>{
          'table': table,
          'entityId': entityId,
          'operationType': operationType,
        },
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _enqueueClinicOutboxForRows(
    DatabaseExecutor db, {
    required String table,
    required Iterable<int> entityIds,
    required String operationType,
  }) async {
    for (final entityId in entityIds) {
      await _enqueueClinicOutboxForRow(
        db,
        table: table,
        entityId: entityId,
        operationType: operationType,
      );
    }
  }

  Future<String?> _remoteUuidForOutboxRow(
    DatabaseExecutor db, {
    required String table,
    required int entityId,
  }) async {
    try {
      if (!await _tableExists(db, 'sync_uuid_mapping')) return null;
      final rows = await db.query(
        'sync_uuid_mapping',
        columns: const <String>['uuid'],
        where: 'table_name = ? AND record_id = ?',
        whereArgs: <Object?>[table, entityId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return _nonEmpty(rows.first['uuid']);
    } catch (_) {
      return null;
    }
  }

  Future<void> _recordClinicSyncHealthEvent(
    DatabaseExecutor db, {
    required String severity,
    required String code,
    required String message,
    String scope = 'outbox',
    String? entityTable,
    int? entityId,
    Map<String, Object?>? payload,
  }) async {
    try {
      await _ensureClinicSyncInfrastructure(db);
      final accountId = await _currentAccountIdFrom(db);
      final deviceId = await _currentDeviceIdFrom(db);
      await db.insert(_kClinicSyncHealthEventsTable, <String, Object?>{
        'id': _clinicSyncUuid.v4(),
        'scope': scope,
        'severity': severity,
        'code': code,
        'message': message,
        'account_id': accountId,
        'device_id': deviceId,
        'entity_table': entityTable,
        'entity_id': entityId,
        'payload_json': payload == null ? null : jsonEncode(_jsonSafe(payload)),
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } catch (_) {}
  }

  Map<String, Object?> _jsonSafe(Map<String, Object?> input) {
    return input.map((key, value) {
      if (value == null ||
          value is num ||
          value is bool ||
          value is String ||
          value is List ||
          value is Map) {
        return MapEntry(key, value);
      }
      return MapEntry(key, value.toString());
    });
  }

  String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  int? _intValue(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Future<String> _accountFilterClause(
    DatabaseExecutor db,
    String table, {
    String? alias,
    List<Object?>? args,
  }) async {
    if (!await _hasColumn(db, table, 'account_id')) return '';
    if (await _isAccountIsolationPending()) {
      return ' AND 1=0';
    }
    // IMPORTANT: stay on the provided executor (txn) to avoid nested connections.
    var accountId = await _currentAccountIdFrom(db);
    if (accountId == null || accountId.trim().isEmpty) {
      accountId = await _fallbackAccountIdFromLocal(db);
      if (accountId != null && accountId.trim().isNotEmpty) {
        _cachedAccountId = accountId.trim();
        await _ensureSyncIdentityAccountId(db, _cachedAccountId!);
        try {
          await ActiveAccountStore.writeAccountId(_cachedAccountId);
        } catch (_) {}
      }
    }
    if (accountId == null || accountId.trim().isEmpty) {
      try {
        final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM $table '
          "WHERE account_id IS NOT NULL AND length(trim(account_id)) > 0",
        );
        final c = (rows.first['c'] as num?)?.toInt() ?? 0;
        if (c == 0) return '';
      } catch (_) {
        return '';
      }
      return ' AND 1=0';
    }
    if (args != null) args.add(accountId);
    final col = alias != null ? '$alias.account_id' : 'account_id';
    return ' AND $col = ?';
  }

  Future<int> _countMissingAccount(DatabaseExecutor db, String table) async {
    if (!await _hasColumn(db, table, 'account_id')) return 0;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table '
      "WHERE account_id IS NULL OR length(trim(account_id)) = 0",
    );
    return (rows.first['c'] as num).toInt();
  }

  /// يملأ account_id المفقود في جداول محددة (مهم لبيانات المستودع).
  Future<void> backfillAccountForTables(
    Iterable<String> tables,
    String accountId,
  ) async {
    final acc = accountId.trim();
    if (acc.isEmpty) return;
    await runQueuedWrite(() async {
      await runWithDbRetry(() async {
        final db = await database;
        for (final table in tables) {
          if (!await _tableExists(db, table)) continue;
          if (!await _hasColumn(db, table, 'account_id')) continue;
          await db.update(table, {
            'account_id': acc,
          }, where: "account_id IS NULL OR length(trim(account_id)) = 0");
        }
      });
    });
  }

  Future<InventoryHealthReport> getInventoryHealthReport() async {
    final db = await database;
    final accountId = await currentAccountId();
    if (accountId == null || accountId.trim().isEmpty) {
      return InventoryHealthReport.empty(reason: 'missing_account');
    }

    Future<int> countTable(String table, {String? alias}) async {
      final args = <Object?>[];
      final clause = await _accountFilterClause(
        db,
        table,
        alias: alias,
        args: args,
      );
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table ${alias != null ? '$alias' : ''} WHERE 1=1 $clause',
        args,
      );
      return (rows.first['c'] as num).toInt();
    }

    final itemTypes = await countTable(ItemType.table);
    final items = await countTable(Item.table);

    final orphanItemArgs = <Object?>[];
    final itemAcc = await _accountFilterClause(
      db,
      Item.table,
      alias: 'i',
      args: orphanItemArgs,
    );
    final typeAcc = await _accountFilterClause(
      db,
      ItemType.table,
      alias: 't',
      args: orphanItemArgs,
    );
    final orphanItemsRows = await db.rawQuery('''
      SELECT COUNT(*) AS c
        FROM ${Item.table} i
        LEFT JOIN ${ItemType.table} t
          ON t.id = i.type_id
          $typeAcc
       WHERE t.id IS NULL
         $itemAcc
      ''', orphanItemArgs);
    final orphanItems = (orphanItemsRows.first['c'] as num).toInt();

    final orphanPurchaseArgs = <Object?>[];
    final purchaseAcc = await _accountFilterClause(
      db,
      Purchase.table,
      alias: 'p',
      args: orphanPurchaseArgs,
    );
    final itemAccOnPurchase = await _accountFilterClause(
      db,
      Item.table,
      alias: 'i',
      args: orphanPurchaseArgs,
    );
    final orphanPurchasesRows = await db.rawQuery('''
      SELECT COUNT(*) AS c
        FROM ${Purchase.table} p
        LEFT JOIN ${Item.table} i
          ON i.id = p.item_id
          $itemAccOnPurchase
       WHERE i.id IS NULL
         $purchaseAcc
      ''', orphanPurchaseArgs);
    final orphanPurchases = (orphanPurchasesRows.first['c'] as num).toInt();

    final orphanConsumptionArgs = <Object?>[];
    final consumptionAcc = await _accountFilterClause(
      db,
      Consumption.table,
      alias: 'c',
      args: orphanConsumptionArgs,
    );
    final itemAccOnConsumption = await _accountFilterClause(
      db,
      Item.table,
      alias: 'i',
      args: orphanConsumptionArgs,
    );
    final orphanConsumptionsRows = await db.rawQuery('''
      SELECT COUNT(*) AS c
        FROM ${Consumption.table} c
        LEFT JOIN ${Item.table} i
          ON i.id = CAST(c.itemId AS INTEGER)
          $itemAccOnConsumption
       WHERE (c.itemId IS NULL OR trim(c.itemId) = '' OR i.id IS NULL)
         $consumptionAcc
      ''', orphanConsumptionArgs);
    final orphanConsumptions = (orphanConsumptionsRows.first['c'] as num)
        .toInt();

    final missingAccountRows =
        await _countMissingAccount(db, ItemType.table) +
        await _countMissingAccount(db, Item.table) +
        await _countMissingAccount(db, Purchase.table) +
        await _countMissingAccount(db, Consumption.table);

    return InventoryHealthReport(
      itemTypes: itemTypes,
      items: items,
      orphanItems: orphanItems,
      orphanPurchases: orphanPurchases,
      orphanConsumptions: orphanConsumptions,
      missingAccountRows: missingAccountRows,
    );
  }

  Future<Map<String, int>> auditSyncMappings({int minGap = 1}) async {
    final db = await database;
    final accountId = await _currentAccountId();
    if (accountId == null || accountId.trim().isEmpty) {
      return {};
    }

    final gaps = <String, int>{};

    Future<int> countTable(String table) async {
      final args = <Object?>[];
      final clause = await _accountFilterClause(db, table, args: args);
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table WHERE 1=1 $clause',
        args,
      );
      return (rows.first['c'] as num).toInt();
    }

    final uuidRows = await db.rawQuery(
      '''
      SELECT table_name, COUNT(*) AS c
        FROM sync_uuid_mapping
       WHERE account_id = ?
    GROUP BY table_name
    ''',
      [accountId],
    );

    for (final row in uuidRows) {
      final table = (row['table_name'] ?? '').toString();
      if (table.isEmpty) continue;
      if (!await _tableExists(db, table)) continue;
      final mappingCount = (row['c'] as num).toInt();
      final tableCount = await countTable(table);
      final gap = mappingCount - tableCount;
      if (gap >= minGap) {
        gaps['uuid:$table'] = gap;
      }
    }

    final fkRows = await db.rawQuery('''
      SELECT table_name, COUNT(*) AS c
        FROM sync_fk_mapping
    GROUP BY table_name
    ''');
    for (final row in fkRows) {
      final table = (row['table_name'] ?? '').toString();
      if (table.isEmpty) continue;
      if (!await _tableExists(db, table)) continue;
      final mappingCount = (row['c'] as num).toInt();
      final tableCount = await countTable(table);
      final gap = mappingCount - tableCount;
      if (gap >= minGap) {
        gaps['fk:$table'] = gap;
      }
    }

    if (gaps.isNotEmpty) {
      // لا نرمي استثناء هنا، فقط نطبع للتشخيص.
      // المرحلة الثالثة ستستخدم هذا التقرير كتحذير بعد pull.
      // ignore: avoid_print
      print('[SYNC_AUDIT] mapping gaps detected: $gaps');
    }

    return gaps;
  }

  Future<String> accountFilterClause(
    DatabaseExecutor db,
    String table, {
    String? alias,
    List<Object?>? args,
  }) async {
    return _accountFilterClause(db, table, alias: alias, args: args);
  }

  Future<T> runWithDbRetry<T>(
    Future<T> Function() op, {
    int retries = 3,
    Duration delay = const Duration(milliseconds: 200),
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await op();
      } on DatabaseException catch (e) {
        final isLocked = _isDatabaseLockedError(e);
        if (!isLocked || attempt >= retries) rethrow;
        attempt += 1;
        await Future<void>.delayed(delay * attempt);
      }
    }
  }

  bool _isDatabaseLockedError(DatabaseException e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('database is locked') || msg.contains('locked');
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

  /*────────────────── dirty tracking (sync) ──────────────────*/
  Future<void> _ensureSyncDirtyTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_dirty (
        table_name TEXT PRIMARY KEY,
        dirty INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT
      );
    ''');

    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM sync_dirty LIMIT 1',
    );
    final count = (rows.first['c'] as num?)?.toInt() ?? 0;
    if (count == 0) {
      final now = DateTime.now().toIso8601String();
      final batch = db.batch();
      for (final t in _kSyncTables) {
        batch.insert('sync_dirty', {
          'table_name': t,
          'dirty': 1,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> _setDirty(String table) async {
    try {
      final db = await database;
      await db.insert('sync_dirty', {
        'table_name': table,
        'dirty': 1,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  Future<void> clearDirty(String table) async {
    try {
      final db = await database;
      await db.update(
        'sync_dirty',
        {'dirty': 0, 'updated_at': DateTime.now().toIso8601String()},
        where: 'table_name = ?',
        whereArgs: [table],
      );
    } catch (_) {}
  }

  Future<bool> isTableDirty(String table) async {
    try {
      final db = await database;
      final rows = await db.query(
        'sync_dirty',
        columns: const ['dirty'],
        where: 'table_name = ?',
        whereArgs: [table],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final v = rows.first['dirty'];
      if (v is num) return v.toInt() != 0;
      return v?.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<Set<String>> getDirtySyncTables() async {
    try {
      final db = await database;
      final rows = await db.query(
        'sync_dirty',
        columns: const ['table_name'],
        where: 'dirty = 1',
      );
      return rows
          .map((r) => (r['table_name'] ?? '').toString())
          .where((t) => t.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
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
      // ✅ توحيد المسار على LOCALAPPDATA فقط (بدون Temp)
      final root = await AppPaths.dataRoot();
      final targetFolder = root.path;
      final dir = Directory(targetFolder);
      if (!(await dir.exists())) {
        await dir.create(recursive: true);
      }
      if (!await _ensureWritable(dir)) {
        throw StateError('Windows data dir not writable: $targetFolder');
      }
      final targetFile = File(p.join(targetFolder, fileName));
      if (!(await targetFile.exists())) {
        for (final legacy in _legacyWindowsDataDirs()) {
          final legacyFile = File(p.join(legacy, fileName));
          if (await legacyFile.exists()) {
            try {
              await targetFile.writeAsBytes(await legacyFile.readAsBytes());
            } catch (_) {}
            break;
          }
        }
      }
      dbPath = targetFile.path;
      _logDbOpen('Windows data dir: $dbPath');
    } else {
      dbPath = p.join(await getDatabasesPath(), fileName);
    }

    print('📁 تم إنشاء/قراءة قاعدة البيانات من المسار: $dbPath');

    return await _openDatabaseAt(dbPath);
  }

  Future<Database> _openDatabaseAt(String dbPath) {
    return openDatabase(
      dbPath,
      version: 36, // ↑ ضمان جداول ربط UUID/Outbox بعد الترقيات
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
      final root = await AppPaths.dataRoot();
      final targetFolder = root.path;
      final dir = Directory(targetFolder);
      if (!(await dir.exists())) {
        await dir.create(recursive: true);
      }
      if (!await _ensureWritable(dir)) {
        throw StateError('Windows data dir not writable: $targetFolder');
      }
      final targetFile = File(p.join(targetFolder, 'clinic.db'));
      if (!(await targetFile.exists())) {
        for (final legacy in _legacyWindowsDataDirs()) {
          final legacyFile = File(p.join(legacy, 'clinic.db'));
          if (await legacyFile.exists()) {
            try {
              await targetFile.writeAsBytes(await legacyFile.readAsBytes());
            } catch (_) {}
            break;
          }
        }
      }
      _logDbOpen('getDatabasePath selected: ${targetFile.path}');
      return targetFile.path;
    } else {
      return p.join(await getDatabasesPath(), 'clinic.db');
    }
  }

  Future<bool> _ensureWritable(Directory dir) async {
    try {
      final probe = File(p.join(dir.path, '.write_test'));
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _logDbOpen(String msg) async {
    try {
      if (!Platform.isWindows) return;
      final dir = await AppPaths.logsDir();
      final file = File(p.join(dir.path, 'db_open.log'));
      final ts = DateTime.now().toIso8601String();
      await file.writeAsString('[$ts] $msg\n', mode: FileMode.append);
    } catch (_) {}
  }

  List<String> _legacyWindowsDataDirs() {
    final env = Platform.environment;
    final legacy = <String>[
      r'C:\ElmamClinic',
      r'D:\ElmamClinic',
      r'C:\aelmam_clinic',
      r'D:\aelmam_clinic',
    ];
    final appData = env['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      legacy.add(p.join(appData, 'aelmam_clinic'));
    }
    final localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      legacy.add(p.join(localAppData, 'aelmam_clinic'));
    }
    return legacy;
  }

  Future<String?> backupDatabase({
    String reason = 'repair',
    Duration minInterval = const Duration(minutes: 30),
    bool force = false,
  }) async {
    try {
      final now = DateTime.now();
      if (!force &&
          _lastRepairBackupAt != null &&
          now.difference(_lastRepairBackupAt!) < minInterval) {
        return null;
      }
      _lastRepairBackupAt = now;

      final dbPath = await getDatabasePath();
      final dbFile = File(dbPath);
      if (!await dbFile.exists()) return null;

      final dir = Directory(p.join(p.dirname(dbPath), 'backups'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final stamp = now
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .replaceAll('.', '');
      final safeReason = reason.trim().isEmpty ? 'backup' : reason.trim();
      final baseName = 'clinic_${safeReason}_$stamp.db';
      final backupPath = p.join(dir.path, baseName);

      await dbFile.copy(backupPath);

      final walFile = File('$dbPath-wal');
      if (await walFile.exists()) {
        await walFile.copy('$backupPath-wal');
      }
      final shmFile = File('$dbPath-shm');
      if (await shmFile.exists()) {
        await shmFile.copy('$backupPath-shm');
      }

      return backupPath;
    } catch (_) {
      return null;
    }
  }

  Future<InventoryRepairReport> repairInventoryIntegrity({
    bool backup = true,
  }) async {
    final db = await database;
    final accountId = await _currentAccountIdFrom(db);
    if (accountId == null || accountId.trim().isEmpty) {
      return InventoryRepairReport.skipped('missing_account');
    }

    if (backup) {
      await backupDatabase(reason: 'inventory_repair');
    }

    final report = InventoryRepairReport();

    await runQueuedWrite(() async {
      await runWithDbRetry(() async {
        await db.transaction((txn) async {
          // إصلاح سريع لسجلات بدون account_id في الجداول الحساسة
          Future<void> backfillAccount(String table) async {
            final cols = await _getTableColumns(txn, table);
            if (!cols.contains('account_id')) return;
            await txn.update(table, {
              'account_id': accountId,
            }, where: "account_id IS NULL OR length(trim(account_id)) = 0");
          }

          await backfillAccount(ItemType.table);
          await backfillAccount(Item.table);
          await backfillAccount('medical_services');
          await backfillAccount('service_doctor_share');

          final cols = await _getTableColumns(txn, 'item_types');
          final nameCol = cols.contains('name') ? 'name' : null;
          if (nameCol == null) return;

          final accCol = cols.contains('account_id') ? 'account_id' : null;
          final args = <Object?>['غير مصنف'];
          var where = '$nameCol = ?';
          if (accCol != null) {
            where += ' AND $accCol = ?';
            args.add(accountId);
          }

          final existing = await txn.query(
            'item_types',
            columns: const ['id'],
            where: where,
            whereArgs: args,
            limit: 1,
          );
          final int fallbackId;
          if (existing.isNotEmpty) {
            fallbackId = (existing.first['id'] as num).toInt();
          } else {
            final row = <String, dynamic>{nameCol: 'غير مصنف'};
            if (accCol != null) row[accCol] = accountId;
            fallbackId = await txn.insert(
              'item_types',
              row,
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
            report.createdFallbackType = fallbackId > 0;
          }

          if (fallbackId <= 0) return;

          final itemCols = await _getTableColumns(txn, Item.table);
          final itemAccCol = itemCols.contains('account_id')
              ? 'account_id'
              : null;

          final orphans = await txn.rawQuery('''
            SELECT i.id
              FROM ${Item.table} i
         LEFT JOIN item_types t
                ON t.id = i.type_id
               ${itemAccCol != null ? 'AND t.account_id = i.account_id' : ''}
             WHERE ifnull(i.isDeleted,0)=0
               AND t.id IS NULL
               ${itemAccCol != null ? 'AND i.account_id = ?' : ''}
          ''', itemAccCol != null ? [accountId] : null);

          if (orphans.isNotEmpty) {
            final ids = orphans
                .map((r) => (r['id'] as num).toInt())
                .toList(growable: false);
            final inClause = ids.map((_) => '?').join(',');
            await txn.rawUpdate(
              'UPDATE ${Item.table} SET type_id = ? WHERE id IN ($inClause)',
              [fallbackId, ...ids],
            );
            report.orphanItemsFixed = ids.length;
          }

          if (itemCols.contains('name')) {
            await txn.rawUpdate(
              "UPDATE ${Item.table} SET name = 'بدون اسم' WHERE (name IS NULL OR trim(name) = '')"
              '${itemAccCol != null ? ' AND account_id = ?' : ''}',
              itemAccCol != null ? [accountId] : null,
            );
          }
          if (itemCols.contains('price')) {
            await txn.rawUpdate(
              'UPDATE ${Item.table} SET price = 0 WHERE price IS NULL'
              '${itemAccCol != null ? ' AND account_id = ?' : ''}',
              itemAccCol != null ? [accountId] : null,
            );
          }
          if (itemCols.contains('stock')) {
            await txn.rawUpdate(
              'UPDATE ${Item.table} SET stock = 0 WHERE stock IS NULL'
              '${itemAccCol != null ? ' AND account_id = ?' : ''}',
              itemAccCol != null ? [accountId] : null,
            );
          }
        });
      });
    });

    await notifyTableChanged(Item.table);
    await notifyTableChanged(ItemType.table);
    return report;
  }

  /*──────────────── إنشاء بنية stats_dirty ───────────────*/
  Future<void> _createStatsDirtyStructure(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stats_dirty (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        dirty INTEGER NOT NULL DEFAULT 1
      );
    ''');
    await db.insert('stats_dirty', {
      'id': 1,
      'dirty': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

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
      'complaints',
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
  Future<void> _ensureAlertSettingsColumns(Database db) {
    final inFlight = _ensureAlertSettingsColumnsInFlight;
    if (inFlight != null) return inFlight;
    final future = _ensureAlertSettingsColumnsImpl(db);
    _ensureAlertSettingsColumnsInFlight = future;
    return future.whenComplete(() {
      _ensureAlertSettingsColumnsInFlight = null;
    });
  }

  Future<void> _ensureAlertSettingsColumnsImpl(Database db) async {
    try {
      var cols = await db.rawQuery("PRAGMA table_info(alert_settings)");
      bool has(String name) => cols.any(
        (c) =>
            ((c['name'] ?? '') as String).toLowerCase() == name.toLowerCase(),
      );
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
        await db.execute(
          'ALTER TABLE alert_settings ADD COLUMN createdAt TEXT',
        );
      }
      if (!has('created_at')) {
        await db.execute(
          'ALTER TABLE alert_settings ADD COLUMN created_at TEXT',
        );
      }
      cols = await db.rawQuery("PRAGMA table_info(alert_settings)");
      final thresholdType = columnType('threshold');
      final needsRebuild =
          thresholdType != null &&
          !thresholdType.toUpperCase().contains('REAL');
      if (needsRebuild) {
        await db.rawQuery('PRAGMA foreign_keys = OFF');
        try {
          await db.execute(
            'ALTER TABLE alert_settings RENAME TO alert_settings_old',
          );
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
          await db.execute(
            'ALTER TABLE alert_settings ADD COLUMN createdAt TEXT',
          );
        }
      }

      // ترحيل ثنائي الاتجاه + تعبئة تواريخ خالية
      final hasItemsTable = await _tableExists(db, 'items');
      if (!hasItemsTable) {
        await db.rawQuery('PRAGMA foreign_keys = OFF');
      }
      try {
        await db.execute(
          'UPDATE alert_settings SET itemId = COALESCE(itemId, item_id)',
        );
        await db.execute(
          'UPDATE alert_settings SET item_id = COALESCE(item_id, itemId)',
        );
        await db.execute(
          'UPDATE alert_settings SET isEnabled = COALESCE(isEnabled, is_enabled, 1)',
        );
        await db.execute(
          'UPDATE alert_settings SET is_enabled = COALESCE(is_enabled, isEnabled, 1)',
        );
        await db.execute(
          'UPDATE alert_settings SET lastTriggered = COALESCE(lastTriggered, last_triggered)',
        );
        await db.execute(
          'UPDATE alert_settings SET last_triggered = COALESCE(last_triggered, lastTriggered)',
        );
        await db.execute(
          'UPDATE alert_settings SET notifyTime = COALESCE(notifyTime, notify_time)',
        );
        await db.execute(
          'UPDATE alert_settings SET notify_time = COALESCE(notify_time, notifyTime)',
        );
        await db.execute(
          'UPDATE alert_settings SET itemUuid = COALESCE(itemUuid, item_uuid)',
        );
        await db.execute(
          'UPDATE alert_settings SET item_uuid = COALESCE(item_uuid, itemUuid)',
        );
        await db.execute(
          'UPDATE alert_settings SET createdAt = COALESCE(createdAt, created_at, CURRENT_TIMESTAMP)',
        );
        await db.execute(
          'UPDATE alert_settings SET created_at = COALESCE(created_at, createdAt, CURRENT_TIMESTAMP)',
        );
      } finally {
        if (!hasItemsTable) {
          await db.rawQuery('PRAGMA foreign_keys = ON');
        }
      }

      // فهرس للأداء
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_alert_settings_item_id ON alert_settings(item_id)',
      );

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

  Future<void> _ensurePatientCollateralColumn(Database db) async {
    try {
      await _addColumnIfMissing(db, 'patients', 'collateral', 'TEXT');
    } catch (_) {}
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
          patient_id           INTEGER,
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
        'patient_id',
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

      final copyCols = desiredCols
          .where((col) => availableCols.contains(col))
          .toList();

      if (copyCols.isNotEmpty) {
        final cols = copyCols.join(', ');
        await db.execute('''
          INSERT INTO financial_logs_new ($cols)
          SELECT $cols FROM financial_logs;
        ''');
      }

      await db.execute('DROP TABLE financial_logs;');
      await db.execute(
        'ALTER TABLE financial_logs_new RENAME TO financial_logs;',
      );

      await _ensureSoftDeleteColumns(db);
      await _ensureSyncMetaColumns(db);
      await _ensureFinancialLogsColumns(db);
    } catch (e) {
      print('relaxFinancialLogsEmployeeId: $e');
    }
  }

  Future<void> _ensureFinancialLogsColumns(Database db) async {
    try {
      await _addColumnIfMissing(db, 'financial_logs', 'patient_id', 'INTEGER');
    } catch (_) {}
  }

  String _patientPaymentBackfillKey(String accountId) {
    return 'backfill.patient_payment.v1.${accountId.trim()}';
  }

  Future<void> _runPatientPaymentBackfillIfNeeded({Database? db}) async {
    if (_patientPaymentBackfillBusy) return;
    _patientPaymentBackfillBusy = true;
    try {
      final database = db ?? await this.database;
      final accountId = await _currentAccountIdFrom(database);
      if (accountId == null || accountId.trim().isEmpty) {
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final key = _patientPaymentBackfillKey(accountId);
      if (prefs.getBool(key) == true) {
        return;
      }

      final hasPatientId = await _hasColumn(
        database,
        'financial_logs',
        'patient_id',
      );
      if (!hasPatientId) {
        return;
      }
      final logsHasAccCol = await _hasColumn(
        database,
        'financial_logs',
        'account_id',
      );
      final patientsHasAccCol = await _hasColumn(
        database,
        'patients',
        'account_id',
      );
      if ((logsHasAccCol || patientsHasAccCol) && (accountId.trim().isEmpty)) {
        return;
      }

      final nowIso = DateTime.now().toIso8601String();
      final reg = RegExp(r'ID:\\s*(\\d+)');
      var touched = false;

      await database.transaction((txn) async {
        // 1) تعبئة patient_id من الوصف إن كان مفقودًا
        final whereArgs = <Object?>['PatientPayment'];
        var where =
            'transaction_type = ? AND ifnull(isDeleted,0)=0 AND patient_id IS NULL';
        if (logsHasAccCol) {
          where += ' AND account_id = ?';
          whereArgs.add(accountId);
        }
        final logs = await txn.query(
          'financial_logs',
          columns: const ['id', 'description'],
          where: where,
          whereArgs: whereArgs,
        );

        if (logs.isNotEmpty) {
          final hasUpdatedAt = await _hasColumn(
            txn,
            'financial_logs',
            'updated_at',
          );
          for (final row in logs) {
            final desc = (row['description'] ?? '').toString();
            final m = reg.firstMatch(desc);
            if (m == null) continue;
            final pid = int.tryParse(m.group(1) ?? '');
            if (pid == null) continue;
            final update = <String, Object?>{'patient_id': pid};
            if (hasUpdatedAt) {
              update['updated_at'] = nowIso;
            }
            await txn.update(
              'financial_logs',
              update,
              where: 'id = ?',
              whereArgs: [row['id']],
            );
            touched = true;
          }
        }

        // 2) بناء سجلات مفقودة لمطابقة paidAmount
        final pWhereArgs = <Object?>[];
        var pWhere = 'ifnull(isDeleted,0)=0';
        if (patientsHasAccCol) {
          pWhere += ' AND account_id = ?';
          pWhereArgs.add(accountId);
        }
        final patients = await txn.query(
          'patients',
          columns: const ['id', 'name', 'paidAmount', 'registerDate'],
          where: pWhere,
          whereArgs: pWhereArgs,
        );

        for (final p in patients) {
          final pid = (p['id'] as num?)?.toInt();
          if (pid == null) continue;
          final paid = (p['paidAmount'] as num?)?.toDouble() ?? 0.0;
          if (paid <= 0) continue;

          var sumWhere =
              'transaction_type = ? AND ifnull(isDeleted,0)=0 AND patient_id = ?';
          final sumParams = <Object?>['PatientPayment', pid];
          if (logsHasAccCol) {
            sumWhere += ' AND account_id = ?';
            sumParams.add(accountId);
          }
          final sumRes = await txn.query(
            'financial_logs',
            columns: const ['amount'],
            where: sumWhere,
            whereArgs: sumParams,
          );
          var logged = 0.0;
          for (final r in sumRes) {
            logged += (r['amount'] as num?)?.toDouble() ?? 0.0;
          }

          final diff = paid - logged;
          if (diff <= 0.01) continue;

          DateTime ts;
          try {
            ts = DateTime.parse((p['registerDate'] ?? '').toString());
          } catch (_) {
            ts = DateTime.now();
          }

          final fData = await prepareInsert('financial_logs', {
            'transaction_type': 'PatientPayment',
            'operation': 'backfill',
            'amount': diff,
            'employee_id': null,
            'patient_id': pid,
            'description':
                'Backfill دفعات مريض: ${(p['name'] ?? '').toString()} (ID: $pid)',
            'modification_details': 'auto backfill to match paidAmount',
            'timestamp': ts.toIso8601String(),
          }, executor: txn);
          await txn.insert('financial_logs', fData);
          touched = true;
        }
      });

      if (touched) {
        await _markChanged('financial_logs');
        await notifyTableChanged('financial_logs');
        await markStatisticsDirty();
      }

      await prefs.setBool(key, true);
    } catch (e) {
      // نتجاهل أخطاء الخلفية حتى لا نكسر الإقلاع.
      // اختبارات الإغلاق قد تسابق هذه المهمة غير الحرجة فتنتج database_closed.
      final msg = e.toString().toLowerCase();
      if (!msg.contains('database_closed')) {
        print('patientPaymentBackfill: $e');
      }
    } finally {
      _patientPaymentBackfillBusy = false;
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
      'patient_services',
    ];

    for (final t in tables) {
      await _addColumnIfMissing(
        db,
        t,
        'isDeleted',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(db, t, 'deletedAt', 'TEXT');
      await _createIndexIfMissing(db, 'idx_${t}_isDeleted', t, ['isDeleted']);
    }
  }

  Future<void> _ensureEmployeeSalariesColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'employees_salaries',
      'totalDiscounts',
      'REAL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'employees_salaries',
      'totalLoans',
      'REAL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'employees_salaries',
      'ratioSum',
      'REAL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'employees_salaries',
      'finalSalary',
      'REAL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'employees_salaries',
      'netPay',
      'REAL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'employees_salaries',
      'isPaid',
      'INTEGER DEFAULT 0',
    );
    await _addColumnIfMissing(db, 'employees_salaries', 'paymentDate', 'TEXT');
    await _addColumnIfMissing(db, 'employees_salaries', 'periodStart', 'TEXT');
    await _addColumnIfMissing(db, 'employees_salaries', 'periodEnd', 'TEXT');
    await _addColumnIfMissing(
      db,
      'employees_salaries',
      'employeeId',
      'INTEGER',
    );
  }

  Map<String, dynamic> _normalizeEmployeeSalaryData(Map<String, dynamic> data) {
    final normalized = <String, dynamic>{};

    final mapped = Map<String, dynamic>.from(data);
    if (mapped.containsKey('employeeld') && !mapped.containsKey('employeeId')) {
      mapped['employeeId'] = mapped.remove('employeeld');
    }
    if (mapped.containsKey('employee_id') &&
        !mapped.containsKey('employeeId')) {
      mapped['employeeId'] = mapped.remove('employee_id');
    }
    if (mapped.containsKey('final_salary') &&
        !mapped.containsKey('finalSalary')) {
      mapped['finalSalary'] = mapped.remove('final_salary');
    }
    if (mapped.containsKey('ratio_sum') && !mapped.containsKey('ratioSum')) {
      mapped['ratioSum'] = mapped.remove('ratio_sum');
    }
    if (mapped.containsKey('total_loans') &&
        !mapped.containsKey('totalLoans')) {
      mapped['totalLoans'] = mapped.remove('total_loans');
    }
    if (mapped.containsKey('total_discounts') &&
        !mapped.containsKey('totalDiscounts')) {
      mapped['totalDiscounts'] = mapped.remove('total_discounts');
    }
    if (mapped.containsKey('net_pay') && !mapped.containsKey('netPay')) {
      mapped['netPay'] = mapped.remove('net_pay');
    }
    if (mapped.containsKey('is_paid') && !mapped.containsKey('isPaid')) {
      mapped['isPaid'] = mapped.remove('is_paid');
    }
    if (mapped.containsKey('payment_date') &&
        !mapped.containsKey('paymentDate')) {
      mapped['paymentDate'] = mapped.remove('payment_date');
    }
    if (mapped.containsKey('period_start') &&
        !mapped.containsKey('periodStart')) {
      mapped['periodStart'] = mapped.remove('period_start');
    }
    if (mapped.containsKey('period_end') && !mapped.containsKey('periodEnd')) {
      mapped['periodEnd'] = mapped.remove('period_end');
    }

    const allowed = <String>{
      'employeeId',
      'year',
      'month',
      'finalSalary',
      'ratioSum',
      'totalLoans',
      'totalDiscounts',
      'netPay',
      'isPaid',
      'paymentDate',
      'periodStart',
      'periodEnd',
      'isDeleted',
      'deletedAt',
      'account_id',
      'device_id',
      'local_id',
      'updated_at',
    };

    for (final entry in mapped.entries) {
      if (allowed.contains(entry.key)) {
        normalized[entry.key] = entry.value;
      }
    }
    return normalized;
  }

  /// آخر تاريخ صرف راتب لموظف (إن وجد).
  Future<DateTime?> getLastSalaryPaymentDate(int employeeId) async {
    try {
      final db = await database;
      final res = await db.query(
        'employees_salaries',
        columns: const ['paymentDate'],
        where:
            'employeeId = ? AND ifnull(isPaid,0)=1 AND ifnull(isDeleted,0)=0 AND paymentDate IS NOT NULL',
        whereArgs: [employeeId],
        orderBy: 'paymentDate DESC',
        limit: 1,
      );
      if (res.isEmpty) return null;
      final raw = (res.first['paymentDate'] ?? '').toString().trim();
      if (raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// يضمن أعمدة المزامنة المحلية (snake_case) + فهرس مركّب (idempotent)
  ///
  /// 🔄 تمت مواءمته مع سكربت parity v3 (account_id/device_id/local_id/updated_at).
  Future<void> _ensureSyncMetaColumns(Database db) async {
    await _ensureSyncIdentityTable(db);
    // استعمل لائحة الجداول المتزامنة الموحّدة (بدون attachments)
    for (final t in _kSyncTables) {
      await _addColumnIfMissing(db, t, 'account_id', 'TEXT');
      await _addColumnIfMissing(db, t, 'device_id', 'TEXT');
      await _addColumnIfMissing(db, t, 'local_id', 'INTEGER');
      await _addColumnIfMissing(db, t, 'updated_at', 'TEXT');
      await _createIndexIfMissing(db, 'idx_${t}_acc_dev_local', t, [
        'account_id',
        'device_id',
        'local_id',
      ]);
    }
    await _ensureUpdatedAtTriggers(db);
  }

  Future<void> _ensureSyncIdentityTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_identity (
        account_id TEXT,
        device_id TEXT
      )
    ''');
  }

  Future<void> _ensureUpdatedAtTriggers(Database db) async {
    for (final t in _kSyncTables) {
      if (!await _tableExists(db, t)) {
        continue;
      }
      // بعد الإدراج: لو لم يُمرر updated_at، املأه تلقائيًا
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_${t}_updated_at_ins
        AFTER INSERT ON $t
        FOR EACH ROW
        WHEN NEW.updated_at IS NULL OR NEW.updated_at = ''
        BEGIN
          UPDATE $t SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
        END;
      ''');
      // بعد التحديث: لو لم يتغير updated_at، حدّثه تلقائيًا
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_${t}_updated_at_upd
        AFTER UPDATE ON $t
        FOR EACH ROW
        WHEN NEW.updated_at IS NULL OR NEW.updated_at = OLD.updated_at
        BEGIN
          UPDATE $t SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
        END;
      ''');
    }
  }

  Future<void> _ensureReturnsAttendanceColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'returns',
      'isAttended',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(db, 'returns', 'attendedAt', 'TEXT');
  }

  Future<void> _ensureLoansSettlementColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'employees_loans',
      'isSettled',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(db, 'employees_loans', 'settledAt', 'TEXT');
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
      'logo_path': (trimmedPath == null || trimmedPath.isEmpty)
          ? null
          : trimmedPath,
      'updated_at': DateTime.now().toIso8601String(),
    };
    final rows = await db.update(
      'clinic_profile',
      updateData,
      where: 'account_id = ?',
      whereArgs: [trimmedId],
    );
    if (rows == 0) {
      await db.insert('clinic_profile', {
        'account_id': trimmedId,
        ...updateData,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    await safeIndex('idx_attachments_patient_created', 'attachments', [
      'patientId',
      'createdAt',
    ]);

    await safeIndex('idx_patient_services_patientId', PatientService.table, [
      'patientId',
    ]);
    await safeIndex('idx_patient_services_serviceId', PatientService.table, [
      'serviceId',
    ]);

    await safeIndex('idx_prescriptions_patientId', 'prescriptions', [
      'patientId',
    ]);
    await safeIndex(
      'idx_prescription_items_prescriptionId',
      'prescription_items',
      ['prescriptionId'],
    );

    await safeIndex(
      'idx_service_doctor_share_serviceId',
      'service_doctor_share',
      ['serviceId'],
    );
    await safeIndex(
      'idx_service_doctor_share_doctorId',
      'service_doctor_share',
      ['doctorId'],
    );
    await safeIndex('idx_doctors_userUid', 'doctors', ['userUid']);

    await safeIndex('idx_consumptions_patientId', 'consumptions', [
      'patientId',
    ]);
    await safeIndex('idx_consumptions_itemId', 'consumptions', ['itemId']);

    await safeIndex('idx_items_name', 'items', ['name']);
    await safeIndex('idx_appointments_patientId', 'appointments', [
      'patientId',
    ]);
    await safeIndex('idx_returns_date', 'returns', ['date']);

    await safeIndex('idx_employees_loans_employeeId', 'employees_loans', [
      'employeeId',
    ]);
    await safeIndex('idx_employees_salaries_employeeId', 'employees_salaries', [
      'employeeId',
    ]);
    await safeIndex(
      'idx_employees_discounts_employeeId',
      'employees_discounts',
      ['employeeId'],
    );
    await safeIndex('idx_employees_userUid', 'employees', ['userUid']);

    if (await _tableExists(db, 'employees_salaries')) {
      final hasIsDeleted = await _hasColumn(
        db,
        'employees_salaries',
        'isDeleted',
      );
      try {
        if (hasIsDeleted) {
          await db.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS uix_employees_salaries_employee_month
            ON employees_salaries(employeeId, year, month)
            WHERE ifnull(isDeleted,0)=0
          ''');
        } else {
          await db.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS uix_employees_salaries_employee_month
            ON employees_salaries(employeeId, year, month)
          ''');
        }
      } catch (_) {
        // تجاهل الخطأ إذا كان الفهرس موجودًا أو السكيمة غير جاهزة بعد
      }
    }

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

    // 🧪 فهرس فريد لأنواع الأصناف لكل حساب (يتسامح مع اختلاف حالة الأحرف)
    await safeUniqueIndex(
      'uix_item_types_name_per_account',
      'item_types',
      'CREATE UNIQUE INDEX IF NOT EXISTS uix_item_types_name_per_account ON item_types(account_id, lower(name))',
    );
    // تراجع آمن عن الفهرس القديم لو كان موجودًا (كان يسبب تعارضات عبر الحسابات)
    try {
      await db.execute('DROP INDEX IF EXISTS uix_item_types_lower_name');
    } catch (_) {}

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

  Future<void> _ensureItemTypesNoUniqueName(Database db) {
    final inFlight = _ensureItemTypesNoUniqueNameInFlight;
    if (inFlight != null) return inFlight;
    final future = _ensureItemTypesNoUniqueNameImpl(db);
    _ensureItemTypesNoUniqueNameInFlight = future;
    return future.whenComplete(() {
      _ensureItemTypesNoUniqueNameInFlight = null;
    });
  }

  Future<void> _ensureItemTypesNoUniqueNameImpl(Database db) async {
    try {
      if (!await _tableExists(db, ItemType.table)) return;
      final idx = await db.rawQuery("PRAGMA index_list('${ItemType.table}')");
      final hasUniqueName = idx.any((r) {
        final unique = (r['unique'] as int? ?? 0) == 1;
        final name = (r['name'] ?? '').toString().toLowerCase();
        return unique && name.contains('item_types') && name.contains('name');
      });
      // sqlite_autoindex_item_types_1 يشير لقيّد UNIQUE(name)
      final hasAutoUnique = idx.any((r) {
        final unique = (r['unique'] as int? ?? 0) == 1;
        final name = (r['name'] ?? '').toString().toLowerCase();
        return unique && name.contains('sqlite_autoindex_item_types');
      });
      if (!(hasUniqueName || hasAutoUnique)) return;

      final colsInfo = await db.rawQuery(
        "PRAGMA table_info('${ItemType.table}')",
      );
      final existingCols = colsInfo
          .map((c) => (c['name'] ?? '').toString())
          .where((c) => c.isNotEmpty)
          .toSet();

      // جدول جديد بدون UNIQUE(name)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS item_types_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          isDeleted INTEGER NOT NULL DEFAULT 0,
          deletedAt TEXT,
          account_id TEXT,
          device_id TEXT,
          local_id INTEGER,
          updated_at TEXT
        )
      ''');

      final targetCols = [
        'id',
        'name',
        'isDeleted',
        'deletedAt',
        'account_id',
        'device_id',
        'local_id',
        'updated_at',
      ];

      final insertCols = <String>[];
      final selectCols = <String>[];
      for (final col in targetCols) {
        insertCols.add(col);
        if (existingCols.contains(col)) {
          selectCols.add(col);
        } else if (col == 'isDeleted') {
          selectCols.add('0');
        } else if (col == 'deletedAt') {
          selectCols.add('NULL');
        } else {
          selectCols.add('NULL');
        }
      }

      await db.execute('''
        INSERT INTO item_types_new (${insertCols.join(',')})
        SELECT ${selectCols.join(',')} FROM ${ItemType.table};
      ''');

      await db.execute('DROP TABLE ${ItemType.table};');
      await db.execute(
        'ALTER TABLE item_types_new RENAME TO ${ItemType.table};',
      );
    } catch (e) {
      print('ensureItemTypesNoUniqueName: $e');
    }
  }

  Future<void> _postOpenChecks(Database db) async {
    await db.rawQuery('PRAGMA foreign_keys = ON');
    await _ensureSyncIdentityTable(db);
    await _ensureClinicProfileTable(db);
    await _ensureAlertSettingsColumns(db);
    await _ensurePatientCollateralColumn(db);
    await _ensureItemTypesNoUniqueName(db);
    await _ensureSoftDeleteColumns(db);
    await _ensureSyncMetaColumns(db); // ← snake_case (متوافق مع parity v3)
    await _ensureFinancialLogsColumns(db);
    await _ensureEmployeeSalariesColumns(db);
    await _ensureReturnsAttendanceColumns(db);
    await _ensureLoansSettlementColumns(db);
    await _ensureSyncFkMappingTable(db);
    // ضروري لقواعد البيانات القديمة: SyncService يعتمد على sync_uuid_mapping
    // في pull/push، وغياب الجدول بعد upgrade يسبب فشل مزامنة وقت التشغيل.
    await _ensureUuidMappingTable(db);
    await _ensureCommonIndexes(db);
    await _ensureSyncDirtyTable(db);
    await _ensureClinicSyncInfrastructure(db);
    await _runPatientPaymentBackfillIfNeeded(db: db);
    if (Platform.isWindows) {
      try {
        final root = await AppPaths.dataRoot();
        await AppPaths.cleanupLegacyWindowsDirs(activeRoot: root.path);
      } catch (_) {}
    }
  }

  /*──────────────── إنشاء الجداول ───────────────*/
  Future<void> _onCreate(Database db, int version) async {
    await _ensureSyncIdentityTable(db);
    await _ensureSyncFkMappingTable(db);
    await _ensureSyncDirtyTable(db);
    await _ensureClinicSyncInfrastructure(db);
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
    collateral TEXT,
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
    itemNameSnapshot TEXT,
    itemTypeNameSnapshot TEXT,
    unitPriceSnapshot REAL,
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
      'CREATE UNIQUE INDEX IF NOT EXISTS uix_drugs_lower_name ON drugs(lower(name))',
    );

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
    totalDiscounts REAL,
    netPay REAL,
    isPaid INTEGER DEFAULT 0,
    paymentDate TEXT,
    periodStart TEXT,
    periodEnd TEXT,
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
    patient_id           INTEGER,
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
    await _ensureFinancialLogsColumns(db);

    // فهارس عامة
    await _ensureCommonIndexes(db);

    await _ensureUuidMappingTable(db);
    await _ensureClinicSyncInfrastructure(db);
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
      await db.execute(
        'ALTER TABLE patients ADD COLUMN doctorSpecialization TEXT',
      );
    }

    if (oldVersion < 7) {
      await db.execute("ALTER TABLE returns ADD COLUMN age INTEGER DEFAULT 0");
      await db.execute("ALTER TABLE returns ADD COLUMN doctor TEXT DEFAULT ''");
      await db.execute("ALTER TABLE returns ADD COLUMN notes  TEXT DEFAULT ''");
    }

    if (oldVersion < 8) {
      await db.execute(
        "ALTER TABLE doctors ADD COLUMN printCounter INTEGER DEFAULT 0",
      );
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
          totalDiscounts REAL,
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
        db,
        'patients',
        'doctorShare',
        'REAL DEFAULT 0',
      );
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
        db,
        'patients',
        'doctorInput',
        'REAL DEFAULT 0',
      );
    }

    if (oldVersion < 14) {
      await _addColumnIfMissing(
        db,
        'service_doctor_share',
        'towerSharePercentage',
        'REAL DEFAULT 0',
      );
      await _addColumnIfMissing(db, 'patients', 'towerShare', 'REAL DEFAULT 0');
    }

    if (oldVersion < 15) {
      await _addColumnIfMissing(
        db,
        'patients',
        'departmentShare',
        'REAL DEFAULT 0',
      );
    }

    if (oldVersion < 16) {
      await _addColumnIfMissing(
        db,
        'employees',
        'isDoctor',
        'INTEGER DEFAULT 0',
      );
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
        db,
        'financial_logs',
        'operation',
        "TEXT NOT NULL DEFAULT 'create'",
      );
      await _addColumnIfMissing(
        db,
        'financial_logs',
        'modification_details',
        'TEXT',
      );
    }

    if (oldVersion < 20) {
      try {
        await db.execute("ALTER TABLE items RENAME COLUMN typeId TO type_id");
      } catch (_) {}
      try {
        await db.execute(
          "ALTER TABLE items RENAME COLUMN quantityAvailable TO stock",
        );
      } catch (_) {}
      await _addColumnIfMissing(db, 'consumptions', 'patientId', 'TEXT');
      await _addColumnIfMissing(db, 'consumptions', 'itemId', 'TEXT');
      await _addColumnIfMissing(
        db,
        'consumptions',
        'quantity',
        'INTEGER DEFAULT 0',
      );
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
        await _addColumnIfMissing(db, 'patients', 'doctorReviewedAt', 'TEXT');
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
        "SELECT name FROM sqlite_master WHERE type='table' AND name='stats_dirty'",
      );
      if (chk.isEmpty) {
        await _createStatsDirtyStructure(db);
      }
    }

    if (oldVersion < 22) {
      await db.execute(PatientService.createTable);
    }

    if (oldVersion < 23) {
      await _addColumnIfMissing(
        db,
        'service_doctor_share',
        'isHidden',
        'INTEGER NOT NULL DEFAULT 0',
      );
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
        'complaints',
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
        db,
      ); // camel + snake + ترحيل + تريجر + notifyTime
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

    if (oldVersion < 35) {
      await _addColumnIfMissing(db, 'purchases', 'item_name_snapshot', 'TEXT');
      await _addColumnIfMissing(
        db,
        'purchases',
        'item_type_name_snapshot',
        'TEXT',
      );
      await _addColumnIfMissing(db, 'consumptions', 'itemNameSnapshot', 'TEXT');
      await _addColumnIfMissing(
        db,
        'consumptions',
        'itemTypeNameSnapshot',
        'TEXT',
      );
      await _addColumnIfMissing(
        db,
        'consumptions',
        'unitPriceSnapshot',
        'REAL',
      );
      await _addColumnIfMissing(
        db,
        'consumptions',
        'item_name_snapshot',
        'TEXT',
      );
      await _addColumnIfMissing(
        db,
        'consumptions',
        'item_type_name_snapshot',
        'TEXT',
      );
      await _addColumnIfMissing(
        db,
        'consumptions',
        'unit_price_snapshot',
        'REAL',
      );
    }

    if (oldVersion < 36) {
      await _ensureUuidMappingTable(db);
      await _ensureSyncFkMappingTable(db);
      await _ensureSyncDirtyTable(db);
      await _ensureClinicSyncInfrastructure(db);
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
    String table,
    String where,
    List<Object?> whereArgs,
  ) async {
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
    final name = t.name.trim();
    if (name.isEmpty) {
      throw ArgumentError(_tr('اسم نوع الصنف فارغ'));
    }
    final accountId = await _currentAccountId();
    if (accountId == null || accountId.trim().isEmpty) {
      throw StateError(_tr('لا يوجد حساب نشط لحفظ نوع الصنف'));
    }
    // إن وُجد نوع بنفس الاسم: استرجع/أعد استخدامه
    final exists = await db.query(
      ItemType.table,
      where: 'lower(name)=lower(?) AND account_id = ?',
      whereArgs: [name, accountId],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      final row = exists.first;
      final id = (row['id'] as num).toInt();
      final isDel = (row['isDeleted'] as int? ?? 0) == 1;
      if (isDel) {
        await db.update(
          ItemType.table,
          {'name': name, 'isDeleted': 0, 'deletedAt': null},
          where: 'id = ?',
          whereArgs: [id],
        );
        await _enqueueClinicOutboxForRow(
          db,
          table: ItemType.table,
          entityId: id,
          operationType: 'update_item_type',
        );
      }
      await _markChanged(ItemType.table);
      return id;
    }
    final data = await prepareInsert(ItemType.table, {
      ...t.toMap(),
      'name': name,
    }, executor: db);
    final id = await db.insert(ItemType.table, data);
    await _enqueueClinicOutboxForRow(
      db,
      table: ItemType.table,
      entityId: id,
      operationType: 'create_item_type',
    );
    await _markChanged(ItemType.table);
    return id;
  }

  Future<List<ItemType>> getAllItemTypes() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, ItemType.table, 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      ItemType.table,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'name ASC',
    );
    return res.map((r) => ItemType.fromMap(r)).toList();
  }

  Future<int> updateItemType(int id, String name) async {
    final db = await database;
    final sanitized = name.trim();
    if (sanitized.isEmpty) {
      throw ArgumentError(_tr('اسم نوع الصنف فارغ'));
    }
    final rows = await db.update(
      ItemType.table,
      {'name': sanitized},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: ItemType.table,
        entityId: id,
        operationType: 'update_item_type',
      );
    }
    await _markChanged(ItemType.table);
    return rows;
  }

  Future<int> deleteItemType(int id) async {
    final db = await database;
    final itemRows = await db.query(
      Item.table,
      columns: const ['id'],
      where: 'type_id = ?',
      whereArgs: [id],
    );
    final itemIds = itemRows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    final alertRows = itemIds.isEmpty
        ? const <Map<String, Object?>>[]
        : await db.query(
            AlertSetting.table,
            columns: const ['id'],
            where: 'item_id IN (${List.filled(itemIds.length, '?').join(',')})',
            whereArgs: itemIds,
          );
    final alertIds = alertRows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    if (itemIds.isNotEmpty) {
      final itemArgs = <Object?>[...itemIds];
      final inClause = List.filled(itemIds.length, '?').join(',');
      final pAcc = await _accountFilterClause(
        db,
        Purchase.table,
        alias: 'p',
        args: itemArgs,
      );
      final cAcc = await _accountFilterClause(
        db,
        Consumption.table,
        alias: 'c',
        args: itemArgs,
      );

      final hasPurchases = await db.rawQuery('''
        SELECT 1 FROM ${Purchase.table} p
         WHERE p.item_id IN ($inClause)
           AND ifnull(p.isDeleted,0)=0
           $pAcc
         LIMIT 1
      ''', itemArgs);
      if (hasPurchases.isNotEmpty) {
        throw StateError(_tr('لا يمكن حذف نوع الصنف لوجود مشتريات مرتبطة به'));
      }

      final hasConsumptions = await db.rawQuery('''
        SELECT 1 FROM ${Consumption.table} c
         WHERE c.itemId IN ($inClause)
           AND ifnull(c.isDeleted,0)=0
           $cAcc
         LIMIT 1
      ''', itemArgs);
      if (hasConsumptions.isNotEmpty) {
        throw StateError(
          _tr('لا يمكن حذف نوع الصنف لوجود استهلاكات مرتبطة به'),
        );
      }

      final args = List<Object?>.filled(itemIds.length, 0);
      for (var i = 0; i < itemIds.length; i++) {
        args[i] = itemIds[i];
      }
      await _softDeleteWhere(
        Item.table,
        'id IN (${List.filled(itemIds.length, '?').join(',')})',
        args,
      );
      await _enqueueClinicOutboxForRows(
        db,
        table: Item.table,
        entityIds: itemIds,
        operationType: 'delete_item_soft',
      );
      await _markChanged(Item.table);

      // احذف أي تنبيهات مرتبطة بهذه الأصناف
      await _softDeleteWhere(
        AlertSetting.table,
        'item_id IN (${List.filled(itemIds.length, '?').join(',')})',
        args,
      );
      await _enqueueClinicOutboxForRows(
        db,
        table: AlertSetting.table,
        entityIds: alertIds,
        operationType: 'delete_alert_setting_soft',
      );
      await _markChanged(AlertSetting.table);
    }

    final rows = await _softDeleteById(ItemType.table, id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: ItemType.table,
        entityId: id,
        operationType: 'delete_item_type_soft',
      );
    }
    await _markChanged(ItemType.table);
    return rows;
  }

  /*=============================== items ===============================*/
  Future<int> insertItem(Item i) async {
    final db = await database;
    final name = i.name.trim();
    if (name.isEmpty) {
      throw ArgumentError(_tr('اسم الصنف فارغ'));
    }
    final accountId = await _currentAccountId();
    if (accountId == null || accountId.trim().isEmpty) {
      throw StateError(_tr('لا يوجد حساب نشط لحفظ الصنف'));
    }
    // إن وُجد صنف بنفس (type_id + name): استرجعه/أعد استخدامه
    final exists = await db.query(
      Item.table,
      where: 'type_id = ? AND lower(name)=lower(?) AND account_id = ?',
      whereArgs: [i.typeId, name, accountId],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      final row = exists.first;
      final id = (row['id'] as num).toInt();
      final isDel = (row['isDeleted'] as int? ?? 0) == 1;
      if (isDel) {
        await db.update(
          Item.table,
          {...i.toMap(), 'name': name, 'isDeleted': 0, 'deletedAt': null},
          where: 'id = ?',
          whereArgs: [id],
        );
        await _enqueueClinicOutboxForRow(
          db,
          table: Item.table,
          entityId: id,
          operationType: 'update_item',
        );
      }
      await _markChanged(Item.table);
      return id;
    }
    final data = await prepareInsert(Item.table, {
      ...i.toMap(),
      'name': name,
    }, executor: db);
    final id = await db.insert(Item.table, data);
    await _enqueueClinicOutboxForRow(
      db,
      table: Item.table,
      entityId: id,
      operationType: 'create_item',
    );
    await _markChanged(Item.table);
    return id;
  }

  Future<List<Item>> getAllItems() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, Item.table, 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      Item.table,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'name ASC',
    );
    return res.map((r) => Item.fromMap(r)).toList();
  }

  Future<List<Item>> getLowStockItems() async {
    final db = await database;
    final args = <Object?>[];
    final itemAccount = await _accountFilterClause(
      db,
      Item.table,
      alias: 'i',
      args: args,
    );
    final alertAccount = await _accountFilterClause(
      db,
      AlertSetting.table,
      alias: 'a',
      args: args,
    );
    final rows = await db.rawQuery('''
      SELECT i.*
      FROM ${Item.table}         AS i
      JOIN ${AlertSetting.table} AS a ON a.item_id = i.id
      WHERE a.is_enabled = 1
        AND ifnull(a.isDeleted, 0) = 0
        AND i.stock     <= a.threshold
        AND ifnull(i.isDeleted, 0) = 0
        $itemAccount$alertAccount
      ORDER BY i.stock ASC
    ''', args);
    return rows.map(Item.fromMap).toList();
  }

  Future<bool> hasLowStockAlert() async {
    final db = await database;
    final args = <Object?>[];
    final itemAccount = await _accountFilterClause(
      db,
      Item.table,
      alias: 'i',
      args: args,
    );
    final alertAccount = await _accountFilterClause(
      db,
      AlertSetting.table,
      alias: 'a',
      args: args,
    );
    final result = await db.rawQuery('''
      SELECT 1
      FROM ${AlertSetting.table} AS a
      JOIN ${Item.table}         AS i ON i.id = a.item_id
      WHERE a.is_enabled = 1
        AND ifnull(a.isDeleted, 0) = 0
        AND i.stock     <= a.threshold
        AND ifnull(i.isDeleted, 0) = 0
        $itemAccount$alertAccount
      LIMIT 1
    ''', args);
    return result.isNotEmpty;
  }

  Future<int> updateItem(Item i) async {
    final db = await database;
    final data = i.toMap();
    final name = (data['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      throw ArgumentError(_tr('اسم الصنف فارغ'));
    }
    data['name'] = name;
    final rows = await db.update(
      Item.table,
      data,
      where: 'id = ?',
      whereArgs: [i.id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Item.table,
        entityId: i.id,
        operationType: 'update_item',
      );
    }
    await _markChanged(Item.table);
    return rows;
  }

  Future<int> deleteItem(int id) async {
    final db = await database;
    final itemArgs = <Object?>[id];
    final pAcc = await _accountFilterClause(
      db,
      Purchase.table,
      alias: 'p',
      args: itemArgs,
    );
    final cAcc = await _accountFilterClause(
      db,
      Consumption.table,
      alias: 'c',
      args: itemArgs,
    );

    final hasPurchases = await db.rawQuery('''
      SELECT 1 FROM ${Purchase.table} p
       WHERE p.item_id = ?
         AND ifnull(p.isDeleted,0)=0
         $pAcc
       LIMIT 1
    ''', itemArgs);
    if (hasPurchases.isNotEmpty) {
      throw StateError(_tr('لا يمكن حذف الصنف لوجود مشتريات مرتبطة به'));
    }

    final hasConsumptions = await db.rawQuery('''
      SELECT 1 FROM ${Consumption.table} c
       WHERE c.itemId = ?
         AND ifnull(c.isDeleted,0)=0
         $cAcc
       LIMIT 1
    ''', itemArgs);
    if (hasConsumptions.isNotEmpty) {
      throw StateError(_tr('لا يمكن حذف الصنف لوجود استهلاكات مرتبطة به'));
    }

    final alertRows = await db.query(
      AlertSetting.table,
      columns: const ['id'],
      where: 'item_id = ?',
      whereArgs: [id],
    );
    final alertIds = alertRows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();

    // احذف أي تنبيهات مرتبطة بالصنف
    await _softDeleteWhere(AlertSetting.table, 'item_id = ?', [id]);
    await _enqueueClinicOutboxForRows(
      db,
      table: AlertSetting.table,
      entityIds: alertIds,
      operationType: 'delete_alert_setting_soft',
    );
    await _markChanged(AlertSetting.table);

    final rows = await _softDeleteById(Item.table, id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Item.table,
        entityId: id,
        operationType: 'delete_item_soft',
      );
    }
    await _markChanged(Item.table);
    return rows;
  }

  //=============================== patient_services ===============================
  Future<int> insertPatientService(PatientService ps) async {
    final db = await database;
    final data = ps.toMap();
    data.remove('id'); // always autoincrement to avoid UNIQUE conflicts
    final id = await db.insert(PatientService.table, data);
    await _enqueueClinicOutboxForRow(
      db,
      table: PatientService.table,
      entityId: id,
      operationType: 'attach_service_to_patient',
    );
    await _markChanged(PatientService.table);
    return id;
  }

  Future<List<PatientService>> getPatientServices(int patientId) async {
    final db = await database;
    final args = <Object?>[patientId];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) {
        return const <PatientService>[];
      }
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
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
      $psAccount$msAccount
    ORDER BY ps.id ASC
  ''', args);

    return rows.map((m) => PatientService.fromMap(m)).toList();
  }

  Future<int> deletePatientServices(int patientId) async {
    final db = await database;
    final rows = await db.query(
      PatientService.table,
      columns: const ['id'],
      where: 'patientId=? AND ifnull(isDeleted,0)=0',
      whereArgs: [patientId],
    );
    final ids = rows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    await _softDeleteWhere(PatientService.table, 'patientId=?', [patientId]);
    await _enqueueClinicOutboxForRows(
      db,
      table: PatientService.table,
      entityIds: ids,
      operationType: 'delete_patient_service_soft',
    );
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
            'deletedAt': null,
          },
          where: 'id=?',
          whereArgs: [id],
        );
        await _enqueueClinicOutboxForRow(
          db,
          table: Drug.table,
          entityId: id,
          operationType: 'update_drug',
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
    await _enqueueClinicOutboxForRow(
      db,
      table: Drug.table,
      entityId: id,
      operationType: 'create_drug',
    );
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
    final db = await database;
    final rows = await db.update(
      Drug.table,
      d.toMap(),
      where: 'id = ?',
      whereArgs: [d.id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Drug.table,
        entityId: d.id,
        operationType: 'update_drug',
      );
    }
    await _markChanged(Drug.table);
    return rows;
  }

  Future<int> deleteDrug(int id) async {
    final db = await database;
    final rows = await _softDeleteById(Drug.table, id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Drug.table,
        entityId: id,
        operationType: 'delete_drug_soft',
      );
    }
    await _markChanged(Drug.table);
    return rows;
  }

  /*=============================== prescriptions ===============================*/
  Future<int> insertPrescription(Prescription p) async {
    final db = await database;
    final id = await db.insert(Prescription.table, p.toMap());
    await _enqueueClinicOutboxForRow(
      db,
      table: Prescription.table,
      entityId: id,
      operationType: 'create_prescription',
    );
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
    final db = await database;
    final rows = await db.update(
      Prescription.table,
      p.toMap(),
      where: 'id = ?',
      whereArgs: [p.id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Prescription.table,
        entityId: p.id,
        operationType: 'update_prescription',
      );
    }
    await _markChanged(Prescription.table);
    return rows;
  }

  Future<int> deletePrescription(int id) async {
    final db = await database;
    final rows = await _softDeleteById(Prescription.table, id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Prescription.table,
        entityId: id,
        operationType: 'delete_prescription_soft',
      );
    }
    await _markChanged(Prescription.table);
    return rows;
  }

  /*=============================== prescription_items ===============================*/
  Future<int> insertPrescriptionItem(PrescriptionItem pi) async {
    final db = await database;
    final id = await db.insert(PrescriptionItem.table, pi.toMap());
    await _enqueueClinicOutboxForRow(
      db,
      table: PrescriptionItem.table,
      entityId: id,
      operationType: 'add_prescription_item',
    );
    await _markChanged(PrescriptionItem.table);
    return id;
  }

  Future<List<PrescriptionItem>> getItemsOfPrescription(
    int prescriptionId,
  ) async {
    final res = await (await database).query(
      PrescriptionItem.table,
      where: 'prescriptionId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [prescriptionId],
    );
    return res.map((m) => PrescriptionItem.fromMap(m)).toList();
  }

  Future<int> deleteItemsOfPrescription(int prescriptionId) async {
    final db = await database;
    final rows = await db.query(
      PrescriptionItem.table,
      columns: const ['id'],
      where: 'prescriptionId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [prescriptionId],
    );
    final ids = rows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    await _softDeleteWhere(PrescriptionItem.table, 'prescriptionId=?', [
      prescriptionId,
    ]);
    await _enqueueClinicOutboxForRows(
      db,
      table: PrescriptionItem.table,
      entityIds: ids,
      operationType: 'delete_prescription_item_soft',
    );
    await _markChanged(PrescriptionItem.table);
    return 1;
  }

  //=============================== purchases ===============================
  Future<int> insertPurchase(Purchase p) async {
    final db = await database;
    final data = await prepareInsert(Purchase.table, p.toMap(), executor: db);
    final id = await db.insert(Purchase.table, data);
    await _enqueueClinicOutboxForRow(
      db,
      table: Purchase.table,
      entityId: id,
      operationType: 'create_purchase',
    );
    await _markChanged(Purchase.table);
    return id;
  }

  Future<List<Purchase>> getAllPurchases() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, Purchase.table, 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      Purchase.table,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC', // ✅ العمود محليًا هو snake_case
    );
    return res.map((r) => Purchase.fromMap(r)).toList();
  }

  Future<int> updatePurchase(Purchase p) async {
    final db = await database;
    final rows = await db.update(
      Purchase.table,
      p.toMap(),
      where: 'id = ?',
      whereArgs: [p.id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Purchase.table,
        entityId: p.id,
        operationType: 'update_purchase',
      );
    }
    await _markChanged(Purchase.table);
    return rows;
  }

  Future<int> deletePurchase(int id) async {
    final db = await database;
    final rows = await _softDeleteById(Purchase.table, id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: Purchase.table,
        entityId: id,
        operationType: 'reverse_purchase',
      );
    }
    await _markChanged(Purchase.table);
    return rows;
  }

  //=============================== alert_settings ===============================
  Future<int> insertAlert(AlertSetting a) async {
    final db = await database;
    final id = await db.insert(AlertSetting.table, a.toMap());
    // مزامنة أعمدة camel/snake بعد الإدراج
    await _ensureAlertSettingsColumns(db);
    await _enqueueClinicOutboxForRow(
      db,
      table: AlertSetting.table,
      entityId: id,
      operationType: 'create_alert_setting',
    );
    await _markChanged(AlertSetting.table);
    return id;
  }

  Future<List<AlertSetting>> getAllAlerts() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, AlertSetting.table, 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      AlertSetting.table,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );
    return res.map((r) => AlertSetting.fromMap(r)).toList();
  }

  Future<int> updateAlert(AlertSetting a) async {
    final db = await database;
    final rows = await db.update(
      AlertSetting.table,
      a.toMap(),
      where: 'id = ?',
      whereArgs: [a.id],
    );
    await _ensureAlertSettingsColumns(db);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: AlertSetting.table,
        entityId: a.id,
        operationType: 'update_alert_setting',
      );
    }
    await _markChanged(AlertSetting.table);
    return rows;
  }

  Future<int> deleteAlert(int id) async {
    final db = await database;
    final rows = await _softDeleteById(AlertSetting.table, id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: AlertSetting.table,
        entityId: id,
        operationType: 'delete_alert_setting_soft',
      );
    }
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

  /// تسديد مبلغ لمريض (يحدّث paidAmount/remaining + يسجّل في financial_logs)
  Future<void> applyPatientPayment({
    required int patientId,
    required double amount,
    bool settleAll = false,
    String? note,
    DateTime? when,
  }) async {
    final db = await database;
    final accountId = await _currentAccountId();
    final hasAccCol = await _hasColumn(db, 'patients', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      throw StateError(_tr('لا يوجد حساب نشط لتسجيل الدفعة'));
    }

    final args = <Object?>[patientId];
    var where = 'id = ? AND ifnull(isDeleted,0)=0';
    if (hasAccCol && accountId != null) {
      where += ' AND account_id = ?';
      args.add(accountId);
    }

    var paymentChanged = false;
    int? financialLogId;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'patients',
        where: where,
        whereArgs: args,
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError(_tr('المريض غير موجود أو غير تابع للحساب'));
      }

      final p = Patient.fromMap(Map<String, dynamic>.from(rows.first));
      final total = (p.paidAmount + p.remaining);
      if (total <= 0) return;

      double pay = amount;
      if (settleAll) {
        pay = p.remaining;
      }
      if (pay <= 0) return;
      if (pay > p.remaining) pay = p.remaining;

      final newPaid = p.paidAmount + pay;
      final newRemaining = (total - newPaid).clamp(0.0, total);
      final ts = (when ?? DateTime.now()).toIso8601String();

      await txn.update(
        'patients',
        {'paidAmount': newPaid, 'remaining': newRemaining, 'updated_at': ts},
        where: where,
        whereArgs: args,
      );

      final fData = await prepareInsert('financial_logs', {
        'transaction_type': 'PatientPayment',
        'operation': 'settle',
        'amount': pay,
        'employee_id': null,
        'patient_id': patientId,
        'description': 'تسديد مريض: ${p.name} (ID: ${p.id})',
        'modification_details': note ?? '',
        'timestamp': ts,
      }, executor: txn);
      financialLogId = await txn.insert('financial_logs', fData);
      paymentChanged = true;
    });

    if (paymentChanged) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'patients',
        entityId: patientId,
        operationType: 'update_patient',
      );
      await _enqueueClinicOutboxForRow(
        db,
        table: 'financial_logs',
        entityId: financialLogId,
        operationType: 'create_financial_log',
      );
    }
    await _markChanged('patients');
    await _markChanged('financial_logs');
  }

  /// حذف منطقي للمريض وكل العناصر التابعة + عكس المخزون + قيد مالي سالب
  /// الآن داخل معاملة واحدة لضمان الذرّية.
  Future<int> deletePatient(int id, {bool restoreStock = true}) =>
      patients.deletePatient(id, restoreStock: restoreStock);

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
    await _enqueueClinicOutboxForRow(
      db,
      table: 'returns',
      entityId: id,
      operationType: 'create_return',
    );
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
    final rows = await db.update(
      'returns',
      entry.toMap(),
      where: 'id = ?',
      whereArgs: [entry.id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'returns',
        entityId: entry.id,
        operationType: 'update_return',
      );
    }
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
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'returns',
        entityId: id,
        operationType: 'update_return',
      );
    }
    await _markChanged('returns');
    return rows;
  }

  Future<void> setReturnsAttendedBulk(List<int> ids, bool attended) async {
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
    await _enqueueClinicOutboxForRows(
      db,
      table: 'returns',
      entityIds: ids,
      operationType: 'update_return',
    );
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
    if (rows > 0) {
      final db = await database;
      await _enqueueClinicOutboxForRow(
        db,
        table: 'returns',
        entityId: id,
        operationType: 'delete_return_soft',
      );
    }
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
    final data = await prepareInsert('consumptions', {
      ...c.toMap(),
      'amount': amount,
    }, executor: db);
    final id = await db.insert('consumptions', data);
    await _enqueueClinicOutboxForRow(
      db,
      table: 'consumptions',
      entityId: id,
      operationType: 'create_consumption',
    );
    await _markChanged('consumptions');
    return id;
  }

  Future<List<Consumption>> getAllConsumption() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final hasAccCol = await _hasColumn(db, 'consumptions', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    final hasAcc = accountId != null && hasAccCol;
    final args = <Object?>[];
    final accClause = hasAcc ? ' AND c.account_id = ?' : '';
    if (hasAcc) args.add(accountId);
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
      $accClause
      ORDER BY c.date DESC
    ''', args);
    return res.map((row) => Consumption.fromMap(row)).toList();
  }

  Future<int> deleteConsumption(int id) async {
    final db = await database;
    final rows = await _softDeleteById('consumptions', id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'consumptions',
        entityId: id,
        operationType: 'reverse_consumption',
      );
    }
    await _markChanged('consumptions');
    return rows;
  }

  //=============================== المواعيد ===============================
  Future<int> saveAppointment(Appointment appointment) async {
    final db = await database;
    if (appointment.id == null) {
      final data = await prepareInsert(
        'appointments',
        appointment.toMap(),
        executor: db,
      );
      final id = await db.insert('appointments', data);
      await _enqueueClinicOutboxForRow(
        db,
        table: 'appointments',
        entityId: id,
        operationType: ClinicSyncDomains.foundationOperationFor(
          table: 'appointments',
          isCreate: true,
          isDelete: false,
          status: appointment.status,
        ),
      );
      await _markChanged('appointments');
      return id;
    } else {
      final data = Map<String, dynamic>.from(appointment.toMap());
      if (await _hasColumn(db, 'appointments', 'account_id') &&
          !data.containsKey('account_id')) {
        final accountId = await _currentAccountIdFrom(db);
        if (accountId != null && accountId.trim().isNotEmpty) {
          data['account_id'] = accountId.trim();
        }
      }
      if (await _hasColumn(db, 'appointments', 'device_id') &&
          !data.containsKey('device_id')) {
        final deviceId = await _currentDeviceIdFrom(db);
        if (deviceId != null && deviceId.trim().isNotEmpty) {
          data['device_id'] = deviceId.trim();
        }
      }
      final rows = await db.update(
        'appointments',
        data,
        where: 'id = ?',
        whereArgs: [appointment.id],
      );
      if (rows > 0) {
        await _enqueueClinicOutboxForRow(
          db,
          table: 'appointments',
          entityId: appointment.id,
          operationType: ClinicSyncDomains.foundationOperationFor(
            table: 'appointments',
            isCreate: false,
            isDelete: false,
            status: appointment.status,
          ),
        );
      }
      await _markChanged('appointments');
      return rows;
    }
  }

  Future<List<Appointment>> getAllAppointments() async {
    final db = await database;
    if (await _hasColumn(db, 'appointments', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return [];
      final res = await db.query(
        'appointments',
        where: 'ifnull(isDeleted,0)=0 AND account_id = ?',
        whereArgs: [accountId],
        orderBy: 'appointmentTime DESC',
      );
      return res.map((row) => Appointment.fromMap(row)).toList();
    }
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
    final toIso = DateTime(
      now.year,
      now.month,
      now.day,
      23,
      59,
      59,
      999,
    ).toIso8601String();

    if (await _hasColumn(db, 'appointments', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return [];
      final res = await db.query(
        'appointments',
        where:
            'appointmentTime BETWEEN ? AND ? AND ifnull(isDeleted,0)=0 AND account_id = ?',
        whereArgs: [fromIso, toIso, accountId],
        orderBy: 'appointmentTime DESC',
      );
      return res.map((row) => Appointment.fromMap(row)).toList();
    }
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
    if (rows > 0) {
      final db = await database;
      await _enqueueClinicOutboxForRow(
        db,
        table: 'appointments',
        entityId: id,
        operationType: 'delete_appointment_soft',
      );
    }
    await _markChanged('appointments');
    return rows;
  }

  //=============================== الأطباء ===============================
  Future<int> insertDoctor(Doctor doctor) async {
    final db = await database;
    final map = doctor.toMap();
    final uidRaw = (map['userUid'] ?? map['user_uid'] ?? '').toString().trim();
    final cols = <String>{};
    try {
      final info = await db.rawQuery('PRAGMA table_info(doctors)');
      for (final row in info) {
        final name = row['name']?.toString();
        if (name != null && name.isNotEmpty) cols.add(name);
      }
    } catch (_) {}

    if (uidRaw.isNotEmpty) {
      final hasIsDeleted = cols.contains('isDeleted');
      final hasIsDeletedSnake = !hasIsDeleted && cols.contains('is_deleted');
      final selectCols = <String>['id'];
      if (hasIsDeleted) selectCols.add('isDeleted');
      if (hasIsDeletedSnake) selectCols.add('is_deleted');
      final existing = await db.query(
        'doctors',
        columns: selectCols,
        where: 'userUid = ?',
        whereArgs: [uidRaw],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final id = (existing.first['id'] as num).toInt();
        // إلغاء الحذف إن كان محذوفًا
        final updateMap = <String, dynamic>{}..addAll(map);
        updateMap.remove('id');
        if (hasIsDeleted) {
          updateMap['isDeleted'] = 0;
        } else if (hasIsDeletedSnake) {
          updateMap['is_deleted'] = 0;
        }
        await db.update('doctors', updateMap, where: 'id = ?', whereArgs: [id]);
        await _enqueueClinicOutboxForRow(
          db,
          table: 'doctors',
          entityId: id,
          operationType: 'update_doctor',
        );
        await _markChanged('doctors');
        return id;
      }
    }

    final id = await db.insert(
      'doctors',
      map,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (id == 0 && uidRaw.isNotEmpty) {
      final fallback = await db.query(
        'doctors',
        columns: const ['id'],
        where: 'userUid = ?',
        whereArgs: [uidRaw],
        limit: 1,
      );
      if (fallback.isNotEmpty) {
        final existingId = (fallback.first['id'] as num).toInt();
        await _markChanged('doctors');
        return existingId;
      }
    }
    if (id > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'doctors',
        entityId: id,
        operationType: 'create_doctor',
      );
    }
    await _markChanged('doctors');
    return id;
  }

  Future<List<Doctor>> getAllDoctors() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, 'doctors', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      'doctors',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );
    return res.map((row) => Doctor.fromMap(row)).toList();
  }

  Future<Doctor?> getDoctorByUserUid(String userUid) async {
    final trimmed = userUid.trim();
    if (trimmed.isEmpty) return null;
    final db = await database;
    final accountId = await _currentAccountId();
    final hasAccCol = await _hasColumn(db, 'doctors', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return null;
    }
    final whereArgs = <Object?>[trimmed];
    var where = 'userUid = ? AND ifnull(isDeleted,0)=0';
    if (hasAccCol && accountId != null) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final rows = await db.query(
      'doctors',
      where: where,
      whereArgs: whereArgs,
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Doctor.fromMap(rows.first);
  }

  Future<Set<String>> getDoctorUserUids() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final hasAccCol = await _hasColumn(db, 'doctors', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return <String>{};
    }
    final whereArgs = <Object?>[];
    var where =
        "userUid IS NOT NULL AND TRIM(userUid) <> '' AND ifnull(isDeleted,0)=0";
    if (hasAccCol && accountId != null) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final rows = await db.query(
      'doctors',
      columns: const ['userUid'],
      where: where,
      whereArgs: whereArgs,
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
    final rows = await db.update(
      'doctors',
      doctor.toMap(),
      where: 'id = ?',
      whereArgs: [doctor.id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'doctors',
        entityId: doctor.id,
        operationType: 'update_doctor',
      );
    }
    await _markChanged('doctors');
    return rows;
  }

  Future<int> deleteDoctor(int id) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final shareRows = await db.query(
      'service_doctor_share',
      columns: const ['id'],
      where: 'doctorId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [id],
    );
    final shareIds = shareRows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    final rows = await db.transaction((txn) async {
      final r = await txn.update(
        'doctors',
        {'isDeleted': 1, 'deletedAt': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.update(
        'service_doctor_share',
        {'isDeleted': 1, 'deletedAt': now},
        where: 'doctorId = ?',
        whereArgs: [id],
      );
      return r;
    });
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'doctors',
        entityId: id,
        operationType: 'disable_doctor',
      );
    }
    await _enqueueClinicOutboxForRows(
      db,
      table: 'service_doctor_share',
      entityIds: shareIds,
      operationType: 'delete_service_doctor_share_soft',
    );
    await _markChanged('doctors');
    await _markChanged('service_doctor_share');
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

    await db.update(
      'doctors',
      {'printCounter': nextCounter},
      where: 'id = ?',
      whereArgs: [doctorId],
    );
    await _markChanged('doctors');
    return nextCounter;
  }

  Future<void> resetDoctorPrintCounter(int doctorId) async {
    final db = await database;
    await db.update(
      'doctors',
      {'printCounter': 0},
      where: 'id = ?',
      whereArgs: [doctorId],
    );
    await _markChanged('doctors');
  }

  Future<int> updateDoctorByEmployeeId(
    int employeeId,
    Map<String, dynamic> updatedData,
  ) async {
    final db = await database;
    final rows = await db.update(
      'doctors',
      updatedData,
      where: 'employeeId = ?',
      whereArgs: [employeeId],
    );
    if (rows > 0) {
      final changed = await db.query(
        'doctors',
        columns: const ['id'],
        where: 'employeeId = ?',
        whereArgs: [employeeId],
      );
      await _enqueueClinicOutboxForRows(
        db,
        table: 'doctors',
        entityIds: changed
            .map((r) => (r['id'] as num?)?.toInt())
            .whereType<int>(),
        operationType: 'update_doctor',
      );
    }
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
    final data = await prepareInsert('medical_services', {
      'name': name,
      'cost': cost,
      'serviceType': serviceType,
    }, executor: db);
    final id = await db.insert('medical_services', data);
    await _enqueueClinicOutboxForRow(
      db,
      table: 'medical_services',
      entityId: id,
      operationType: 'create_service',
    );
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
    final data = <String, dynamic>{
      'name': name,
      'cost': cost,
      'serviceType': serviceType,
    };
    if (await _hasColumn(db, 'medical_services', 'updated_at')) {
      data['updated_at'] = DateTime.now().toIso8601String();
    }
    final rows = await db.update(
      'medical_services',
      data,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'medical_services',
        entityId: id,
        operationType: 'update_service',
      );
    }
    await _markChanged('medical_services');
    return rows;
  }

  Future<int> deleteMedicalService(int id) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final shareRows = await db.query(
      'service_doctor_share',
      columns: const ['id'],
      where: 'serviceId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [id],
    );
    final shareIds = shareRows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    final rows = await db.transaction((txn) async {
      final r = await txn.update(
        'medical_services',
        {'isDeleted': 1, 'deletedAt': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.update(
        'service_doctor_share',
        {'isDeleted': 1, 'deletedAt': now},
        where: 'serviceId = ?',
        whereArgs: [id],
      );
      return r;
    });
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'medical_services',
        entityId: id,
        operationType: 'delete_service_soft',
      );
    }
    await _enqueueClinicOutboxForRows(
      db,
      table: 'service_doctor_share',
      entityIds: shareIds,
      operationType: 'delete_service_doctor_share_soft',
    );
    await _markChanged('medical_services');
    await _markChanged('service_doctor_share');
    return rows;
  }

  Future<List<Map<String, dynamic>>> getServicesByType(
    String serviceType,
  ) async {
    final db = await database;
    final accountId = await _currentAccountId();
    final whereArgs = <Object?>[serviceType];
    var where = 'serviceType = ? AND ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, 'medical_services', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      'medical_services',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'name',
    );
    return res;
  }

  Future<List<Map<String, dynamic>>> getAllMedicalServices() async {
    final db = await database;
    final accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, 'medical_services', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      'medical_services',
      where: where,
      whereArgs: whereArgs,
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
    double clampPct(double v) {
      if (v.isNaN) return 0.0;
      if (v < 0) return 0.0;
      if (v > 100) return 100.0;
      return v;
    }

    final db = await database;
    final data = await prepareInsert('service_doctor_share', {
      'serviceId': serviceId,
      'doctorId': doctorId,
      'sharePercentage': clampPct(sharePercentage),
      'towerSharePercentage': clampPct(towerSharePercentage),
    }, executor: db);
    final id = await db.insert('service_doctor_share', data);
    await _enqueueClinicOutboxForRow(
      db,
      table: 'service_doctor_share',
      entityId: id,
      operationType: 'create_service_doctor_share',
    );
    await _markChanged('service_doctor_share');
    return id;
  }

  Future<List<Map<String, dynamic>>> getDoctorSharesForService(
    int serviceId,
  ) async {
    final db = await database;
    final accountId = await _currentAccountId();
    final hasAccCol = await _hasColumn(
      db,
      'service_doctor_share',
      'account_id',
    );
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    final whereArgs = <Object?>[serviceId];
    var where = 'serviceId = ? AND ifnull(isDeleted,0)=0';
    if (hasAccCol && accountId != null) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    return db.query('service_doctor_share', where: where, whereArgs: whereArgs);
  }

  Future<double?> getDoctorShareForService({
    required int doctorId,
    required int serviceId,
  }) async {
    final db = await database;
    final accountId = await _currentAccountId();
    final hasAccCol = await _hasColumn(
      db,
      'service_doctor_share',
      'account_id',
    );
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return null;
    }
    final whereArgs = <Object?>[doctorId, serviceId];
    var where = 'doctorId = ? AND serviceId = ? AND ifnull(isDeleted,0)=0';
    if (hasAccCol && accountId != null) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    final res = await db.query(
      'service_doctor_share',
      columns: ['sharePercentage'],
      where: where,
      whereArgs: whereArgs,
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
    double clampPct(double v) {
      if (v.isNaN) return 0.0;
      if (v < 0) return 0.0;
      if (v > 100) return 100.0;
      return v;
    }

    final db = await database;
    final updateData = <String, dynamic>{};
    if (sharePercentage != null) {
      updateData['sharePercentage'] = clampPct(sharePercentage);
    }
    if (towerSharePercentage != null) {
      updateData['towerSharePercentage'] = clampPct(towerSharePercentage);
    }
    if (await _hasColumn(db, 'service_doctor_share', 'updated_at')) {
      updateData['updated_at'] = DateTime.now().toIso8601String();
    }
    final rows = await db.update(
      'service_doctor_share',
      updateData,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'service_doctor_share',
        entityId: id,
        operationType: 'update_service_doctor_share',
      );
    }
    await _markChanged('service_doctor_share');
    return rows;
  }

  Future<int> deleteServiceDoctorShare(int id) async {
    final db = await database;
    final rows = await _softDeleteById('service_doctor_share', id);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'service_doctor_share',
        entityId: id,
        operationType: 'delete_service_doctor_share_soft',
      );
    }
    await _markChanged('service_doctor_share');
    return rows;
  }

  Future<int> updateServiceDoctorShareHidden({
    required int id,
    required int isHidden,
  }) async {
    final db = await database;
    final rows = await db.update(
      'service_doctor_share',
      {'isHidden': isHidden},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'service_doctor_share',
        entityId: id,
        operationType: 'update_service_doctor_share',
      );
    }
    await _markChanged('service_doctor_share');
    return rows;
  }

  Future<List<Map<String, dynamic>>> getDoctorGeneralServices(
    int doctorId,
  ) async {
    final db = await database;
    final args = <Object?>[doctorId];
    final msAccount = await _accountFilterClause(
      db,
      'medical_services',
      alias: 'ms',
      args: args,
    );
    final sdsAccount = await _accountFilterClause(
      db,
      'service_doctor_share',
      alias: 'sds',
      args: args,
    );
    return db.rawQuery('''
    SELECT ms.id, ms.name, ms.cost
    FROM medical_services ms
    JOIN service_doctor_share sds 
      ON sds.serviceId = ms.id AND sds.doctorId = ? AND ifnull(sds.isDeleted,0)=0
    WHERE ms.serviceType = 'doctorGeneral'
      AND sds.isHidden = 0
      AND ifnull(ms.isDeleted,0)=0
      $msAccount$sdsAccount
    ORDER BY ms.id DESC
  ''', args);
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
    int doctorId,
  ) async {
    final db = await database;
    final args = <Object?>[doctorId];
    final sdsAccount = await _accountFilterClause(
      db,
      'service_doctor_share',
      alias: 'sds',
      args: args,
    );
    final msAccount = await _accountFilterClause(
      db,
      'medical_services',
      alias: 'ms',
      args: args,
    );
    return db.rawQuery('''
      SELECT
        ms.id   AS serviceId,
        ms.name AS serviceName,
        ms.serviceType,
        ms.cost,
        sds.sharePercentage       AS doctorPercentRaw,
        sds.towerSharePercentage  AS clinicPercentRaw,
        CASE
          WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
            THEN (100 - COALESCE(sds.towerSharePercentage, 0))
          ELSE COALESCE(sds.sharePercentage, 0)
        END AS doctorPercentComputed,
        CASE
          WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
            THEN COALESCE(sds.towerSharePercentage, 0)
          ELSE (100 - COALESCE(sds.sharePercentage, 0))
        END AS clinicPercentComputed
      FROM service_doctor_share sds
      JOIN medical_services ms ON ms.id = sds.serviceId
      WHERE sds.doctorId = ?
        AND (sds.isDeleted IS NULL OR sds.isDeleted = 0)
        AND (ms.isDeleted  IS NULL OR ms.isDeleted  = 0)
        AND sds.isHidden = 0
        $sdsAccount$msAccount
      ORDER BY ms.name COLLATE NOCASE;
    ''', args);
  }

  /// تفصيل فترة: عدد المرات + إجمالي مبالغ الطبيب والمركز لكل خدمة للطبيب
  Future<List<Map<String, dynamic>>> getDoctorServiceBreakdownBetween(
    int doctorId,
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[
      doctorId,
      from.toIso8601String(),
      to.toIso8601String(),
    ];
    final sdsAccount = await _accountFilterClause(
      db,
      'service_doctor_share',
      alias: 'sds',
      args: args,
    );
    final msAccount = await _accountFilterClause(
      db,
      'medical_services',
      alias: 'ms',
      args: args,
    );
    String psAccount = '';
    if (await _hasColumn(db, PatientService.table, 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return const [];
      psAccount = ' AND (ps.account_id = ? OR ps.id IS NULL)';
      args.add(accountId);
    }
    String pAccount = '';
    if (await _hasColumn(db, 'patients', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return const [];
      pAccount = ' AND (p.account_id = ? OR p.id IS NULL)';
      args.add(accountId);
    }
    return db.rawQuery('''
      SELECT 
        ms.id   AS serviceId,
        ms.name AS serviceName,
        ms.serviceType,
        ms.cost,
        sds.sharePercentage      AS doctorPercentRaw,
        sds.towerSharePercentage AS clinicPercentRaw,
        CASE
          WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
            THEN (100 - COALESCE(sds.towerSharePercentage, 0))
          ELSE COALESCE(sds.sharePercentage, 0)
        END AS doctorPercentComputed,
        CASE
          WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
            THEN COALESCE(sds.towerSharePercentage, 0)
          ELSE (100 - COALESCE(sds.sharePercentage, 0))
        END AS clinicPercentComputed,
        COUNT(ps.id)                      AS times,
        COALESCE(SUM(ps.serviceCost), 0)  AS totalRevenue,
        COALESCE(SUM(
          ps.serviceCost * (CASE
            WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
              THEN (100 - COALESCE(sds.towerSharePercentage, 0))
            ELSE COALESCE(sds.sharePercentage, 0)
          END / 100.0)
        ), 0) AS doctorTotalAmount,
        COALESCE(SUM(
          ps.serviceCost * (CASE
            WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
              THEN COALESCE(sds.towerSharePercentage, 0)
            ELSE (100 - COALESCE(sds.sharePercentage, 0))
          END / 100.0)
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
        AND (date(p.registerDate) BETWEEN date(?) AND date(?) OR p.registerDate IS NULL)
        $sdsAccount$msAccount$psAccount$pAccount
      GROUP BY ms.id, ms.name, ms.serviceType, ms.cost, sds.sharePercentage, sds.towerSharePercentage
      ORDER BY ms.name COLLATE NOCASE;
    ''', args);
  }

  /// نسبة محسوبة لخدمة محددة لطبيب معيّن (مفيد للواجهات عند عرض خدمة واحدة).
  Future<Map<String, double>> getComputedPercentsForDoctorService({
    required int doctorId,
    required int serviceId,
  }) async {
    final db = await database;
    final args = <Object?>[doctorId, serviceId];
    final sdsAccount = await _accountFilterClause(
      db,
      'service_doctor_share',
      alias: 'sds',
      args: args,
    );
    final msAccount = await _accountFilterClause(
      db,
      'medical_services',
      alias: 'ms',
      args: args,
    );
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
        $sdsAccount$msAccount
      LIMIT 1;
    ''', args);

    if (rows.isEmpty) {
      return {'doctor': 0.0, 'clinic': 0.0};
    }
    final r = rows.first;
    final double shareP = (r['shareP'] as num).toDouble();
    final double towerP = (r['towerP'] as num).toDouble();
    final String type = (r['serviceType'] ?? '').toString();

    double clampPct(double v) => v < 0 ? 0 : (v > 100 ? 100 : v);

    if (type == 'doctor' || type == 'doctorGeneral' || type == 'طبيب') {
      final clinic = clampPct(towerP);
      final doctor = clampPct(100 - clinic);
      return {'doctor': doctor, 'clinic': clinic};
    }

    final doctor = clampPct(shareP);
    final clinic = clampPct(100 - doctor);
    return {'doctor': doctor, 'clinic': clinic};
  }

  //=============================== إدارة الموظفين ===============================
  Future<int> insertEmployee(Map<String, dynamic> employeeData) async {
    final db = await database;
    final id = await db.insert('employees', employeeData);
    await _enqueueClinicOutboxForRow(
      db,
      table: 'employees',
      entityId: id,
      operationType: 'create_employee',
    );
    await _markChanged('employees');
    await _ensureDoctorForEmployeeId(id, dataHint: employeeData);
    return id;
  }

  Future<void> repairEmployeeAccountIds() async {
    final db = await database;
    var accountId = await _currentAccountId();
    if (accountId == null || accountId.trim().isEmpty) {
      accountId = await _fallbackAccountIdFromLocal(db);
      if (accountId != null && accountId.trim().isNotEmpty) {
        _cachedAccountId = accountId;
      }
    }
    if (accountId == null || accountId.trim().isEmpty) return;
    try {
      await runQueuedWrite(() async {
        await runWithDbRetry(() async {
          await db.transaction((txn) async {
            Future<void> backfill(String table) async {
              final cols = await _getTableColumns(txn, table);
              if (!cols.contains('account_id')) return;
              await txn.update(table, {
                'account_id': accountId,
              }, where: "account_id IS NULL OR length(trim(account_id)) = 0");
            }

            await backfill('employees');
            await backfill('employees_loans');
            await backfill('employees_discounts');
            await backfill('employees_salaries');
          });
        });
      });
    } on UnsupportedError {
      // قاعدة البيانات مفتوحة بوضع القراءة فقط (بعض البيئات/النسخ الاحتياطية)
      // نتجاهل الإصلاح الكتابي ونكمل القراءة بدون فشل الشاشة.
      return;
    } catch (_) {
      return;
    }
  }

  Future<List<Map<String, dynamic>>> getAllEmployees() async {
    final db = await database;
    var accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, 'employees', 'account_id');
    if (hasAccCol) {
      await repairEmployeeAccountIds();
    }
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      accountId = await _fallbackAccountIdFromLocal(db);
      if (accountId != null && accountId.trim().isNotEmpty) {
        _cachedAccountId = accountId;
      } else {
        return <Map<String, dynamic>>[];
      }
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    return db.query(
      'employees',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );
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
    int employeeId,
    Map<String, dynamic> newData,
  ) async {
    final db = await database;
    final rows = await db.update(
      'employees',
      newData,
      where: 'id = ?',
      whereArgs: [employeeId],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees',
        entityId: employeeId,
        operationType: 'update_employee',
      );
    }
    await _markChanged('employees');
    await _ensureDoctorForEmployeeId(employeeId, dataHint: newData);
    return rows;
  }

  Future<int> deleteEmployee(int employeeId) async {
    final db = await database;
    final rows = await _softDeleteById('employees', employeeId);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees',
        entityId: employeeId,
        operationType: 'delete_employee_soft',
      );
    }
    await _markChanged('employees');
    await _softDeleteDoctorsForEmployee(employeeId);
    return rows;
  }

  Future<Map<String, dynamic>?> getEmployeeById(int employeeId) async {
    final db = await database;
    final res = await db.query(
      'employees',
      where: 'id = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [employeeId],
      limit: 1,
    );
    return res.isEmpty ? null : res.first;
  }

  Future<void> _ensureDoctorForEmployeeId(
    int employeeId, {
    Map<String, dynamic>? dataHint,
  }) async {
    try {
      final db = await database;
      Map<String, dynamic>? emp = dataHint;
      if (emp == null ||
          !(emp.containsKey('isDoctor') ||
              emp.containsKey('isDoctor'.toLowerCase()))) {
        final rows = await db.query(
          'employees',
          where: 'id = ? AND ifnull(isDeleted,0)=0',
          whereArgs: [employeeId],
          limit: 1,
        );
        if (rows.isEmpty) return;
        emp = rows.first;
      }

      final isDoctor = (emp['isDoctor'] as num?)?.toInt() == 1;
      if (!isDoctor) {
        await _softDeleteDoctorsForEmployee(employeeId, dataHint: emp);
        return;
      }

      final userUid = (emp['userUid'] ?? '').toString().trim();
      final name = (emp['name'] ?? '').toString().trim();
      final specialization = (emp['jobTitle'] ?? '').toString().trim();
      final phone = (emp['phoneNumber'] ?? '').toString().trim();

      // 1) Try by employeeId
      final existingByEmp = await db.query(
        'doctors',
        where: 'employeeId = ? AND ifnull(isDeleted,0)=0',
        whereArgs: [employeeId],
        limit: 1,
      );
      if (existingByEmp.isNotEmpty) {
        final row = existingByEmp.first;
        final doc = Doctor.fromMap(row).copyWith(
          userUid: userUid.isEmpty ? row['userUid']?.toString() : userUid,
          name: name.isEmpty ? row['name']?.toString() ?? 'طبيب' : name,
          specialization: specialization.isEmpty
              ? row['specialization']?.toString() ?? 'عام'
              : specialization,
          phoneNumber: phone.isEmpty
              ? row['phoneNumber']?.toString() ?? ''
              : phone,
        );
        await updateDoctor(doc);
        return;
      }

      // 2) Try by userUid
      if (userUid.isNotEmpty) {
        final existingByUid = await db.query(
          'doctors',
          where: 'userUid = ? AND ifnull(isDeleted,0)=0',
          whereArgs: [userUid],
          limit: 1,
        );
        if (existingByUid.isNotEmpty) {
          final row = existingByUid.first;
          final doc = Doctor.fromMap(row).copyWith(employeeId: employeeId);
          await updateDoctor(doc);
          return;
        }
      }

      // 3) Create new doctor record
      final doctor = Doctor(
        employeeId: employeeId,
        userUid: userUid.isEmpty ? null : userUid,
        name: name.isEmpty ? 'طبيب' : name,
        specialization: specialization.isEmpty ? 'عام' : specialization,
        phoneNumber: phone,
        startTime: '08:00',
        endTime: '16:00',
      );
      await insertDoctor(doctor);
    } catch (_) {
      // ignore to avoid blocking employee save
    }
  }

  Future<void> _softDeleteDoctorsForEmployee(
    int employeeId, {
    Map<String, dynamic>? dataHint,
  }) async {
    try {
      final db = await database;
      final now = DateTime.now().toIso8601String();
      final ids = <int>{};

      final rowsByEmp = await db.query(
        'doctors',
        columns: const ['id'],
        where: 'employeeId = ? AND ifnull(isDeleted,0)=0',
        whereArgs: [employeeId],
      );
      for (final r in rowsByEmp) {
        final id = (r['id'] as num?)?.toInt();
        if (id != null) ids.add(id);
      }

      String? userUid;
      if (dataHint != null) {
        userUid = (dataHint['userUid'] ?? '').toString().trim();
      }
      if (userUid == null || userUid.isEmpty) {
        final empRows = await db.query(
          'employees',
          columns: const ['userUid'],
          where: 'id = ?',
          whereArgs: [employeeId],
          limit: 1,
        );
        if (empRows.isNotEmpty) {
          userUid = (empRows.first['userUid'] ?? '').toString().trim();
        }
      }

      if (userUid != null && userUid.isNotEmpty) {
        final rowsByUid = await db.query(
          'doctors',
          columns: const ['id'],
          where: 'userUid = ? AND ifnull(isDeleted,0)=0',
          whereArgs: [userUid],
        );
        for (final r in rowsByUid) {
          final id = (r['id'] as num?)?.toInt();
          if (id != null) ids.add(id);
        }
      }

      if (ids.isEmpty) return;

      final idArgs = ids.toList();
      final whereIn = 'id IN (${List.filled(idArgs.length, '?').join(',')})';
      final shareRows = await db.query(
        'service_doctor_share',
        columns: const ['id'],
        where:
            'doctorId IN (${List.filled(idArgs.length, '?').join(',')}) AND ifnull(isDeleted,0)=0',
        whereArgs: idArgs,
      );
      final shareIds = shareRows
          .map((r) => (r['id'] as num?)?.toInt())
          .whereType<int>()
          .toList();
      await _softDeleteWhere('doctors', whereIn, idArgs);
      await _enqueueClinicOutboxForRows(
        db,
        table: 'doctors',
        entityIds: idArgs,
        operationType: 'disable_doctor',
      );
      await _markChanged('doctors');

      final shareWhere =
          'doctorId IN (${List.filled(idArgs.length, '?').join(',')})';
      await _softDeleteWhere('service_doctor_share', shareWhere, idArgs);
      await _enqueueClinicOutboxForRows(
        db,
        table: 'service_doctor_share',
        entityIds: shareIds,
        operationType: 'delete_service_doctor_share_soft',
      );
      await _markChanged('service_doctor_share');

      await db.update(
        'doctors',
        {'deletedAt': now},
        where: whereIn,
        whereArgs: idArgs,
      );
      await db.update(
        'service_doctor_share',
        {'deletedAt': now},
        where: shareWhere,
        whereArgs: idArgs,
      );
    } catch (_) {}
  }

  Future<Set<String>> getLinkedUserUids() async {
    final db = await database;
    final linked = <String>{};
    final accountId = await _currentAccountId();
    final hasDocAcc = await _hasColumn(db, 'doctors', 'account_id');
    final hasEmpAcc = await _hasColumn(db, 'employees', 'account_id');
    if ((hasDocAcc || hasEmpAcc) &&
        (accountId == null || accountId.trim().isEmpty)) {
      return linked;
    }

    final docWhereArgs = <Object?>[];
    var docWhere = 'ifnull(isDeleted,0)=0';
    if (hasDocAcc && accountId != null) {
      docWhere += ' AND account_id = ?';
      docWhereArgs.add(accountId);
    }
    final doctors = await db.query(
      'doctors',
      columns: const ['userUid'],
      where: docWhere,
      whereArgs: docWhereArgs,
    );
    for (final row in doctors) {
      final raw = row['userUid'] ?? row['user_uid'];
      final uid = (raw ?? '').toString().trim();
      if (uid.isNotEmpty) linked.add(uid);
    }

    final empWhereArgs = <Object?>[];
    var empWhere = 'ifnull(isDeleted,0)=0';
    if (hasEmpAcc && accountId != null) {
      empWhere += ' AND account_id = ?';
      empWhereArgs.add(accountId);
    }
    final employees = await db.query(
      'employees',
      columns: const ['userUid'],
      where: empWhere,
      whereArgs: empWhereArgs,
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
    await _enqueueClinicOutboxForRow(
      db,
      table: 'employees_loans',
      entityId: id,
      operationType: 'create_loan',
    );
    await _markChanged('employees_loans');
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllEmployeeLoans() async {
    final db = await database;
    var accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, 'employees_loans', 'account_id');
    if (hasAccCol) {
      await repairEmployeeAccountIds();
    }
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      accountId = await _fallbackAccountIdFromLocal(db);
      if (accountId != null && accountId.trim().isNotEmpty) {
        _cachedAccountId = accountId;
      } else {
        return <Map<String, dynamic>>[];
      }
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    return db.query(
      'employees_loans',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'loanDateTime DESC',
    );
  }

  Future<int> updateEmployeeLoan(
    int loanId,
    Map<String, dynamic> newData,
  ) async {
    final db = await database;
    final rows = await db.update(
      'employees_loans',
      newData,
      where: 'id = ?',
      whereArgs: [loanId],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees_loans',
        entityId: loanId,
        operationType: 'update_loan',
      );
    }
    await _markChanged('employees_loans');
    return rows;
  }

  Future<int> deleteEmployeeLoan(int loanId) async {
    final db = await database;
    final rows = await _softDeleteById('employees_loans', loanId);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees_loans',
        entityId: loanId,
        operationType: 'delete_loan_soft',
      );
    }
    await _markChanged('employees_loans');
    return rows;
  }

  Future<int> markEmployeeLoansSettled({
    required int employeeId,
    required int year,
    required int month,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final selectArgs = <Object?>[
      employeeId,
      year.toString(),
      month.toString().padLeft(2, '0'),
    ];
    final selectAccountClause = await _accountFilterClause(
      db,
      'employees_loans',
      args: selectArgs,
    );
    final affectedRows = await db.rawQuery('''
        SELECT id FROM employees_loans
        WHERE employeeId = ?
          AND strftime('%Y', loanDateTime) = ?
          AND strftime('%m', loanDateTime) = ?
          AND ifnull(isDeleted,0)=0
          $selectAccountClause
      ''', selectArgs);
    final affectedIds = affectedRows
        .map((r) => (r['id'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    final args = <Object?>[
      now,
      employeeId,
      year.toString(),
      month.toString().padLeft(2, '0'),
    ];
    final accountClause = await _accountFilterClause(
      db,
      'employees_loans',
      args: args,
    );
    final rows = await db.rawUpdate('''
        UPDATE employees_loans
        SET isSettled = 1,
            settledAt = ?,
            leftover = 0
        WHERE employeeId = ?
          AND strftime('%Y', loanDateTime) = ?
          AND strftime('%m', loanDateTime) = ?
          AND ifnull(isDeleted,0)=0
          $accountClause
      ''', args);
    if (rows > 0) {
      await _enqueueClinicOutboxForRows(
        db,
        table: 'employees_loans',
        entityIds: affectedIds,
        operationType: 'settle_loan',
      );
    }
    await _markChanged('employees_loans');
    return rows;
  }

  Future<double> getEmployeeLoansSumBetween({
    required int employeeId,
    required DateTime from,
    required DateTime to,
  }) async {
    final db = await database;
    final args = <Object?>[
      employeeId,
      from.toIso8601String(),
      to.toIso8601String(),
    ];
    final accountClause = await _accountFilterClause(
      db,
      'employees_loans',
      args: args,
    );
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(loanAmount), 0) AS total
      FROM employees_loans
      WHERE employeeId = ?
        AND date(loanDateTime) BETWEEN date(?) AND date(?)
        AND ifnull(isSettled,0)=0
        AND ifnull(isDeleted,0)=0
        $accountClause
    ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  //=============================== رواتب الموظفين ===============================
  Future<int> insertEmployeeSalary(Map<String, dynamic> salaryData) async {
    final db = await database;
    final normalized = _normalizeEmployeeSalaryData(salaryData);
    final id = await db.insert('employees_salaries', normalized);
    await _enqueueClinicOutboxForRow(
      db,
      table: 'employees_salaries',
      entityId: id,
      operationType: 'create_salary',
    );
    await _markChanged('employees_salaries');
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllEmployeeSalaries() async {
    final db = await database;
    var accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, 'employees_salaries', 'account_id');
    if (hasAccCol) {
      await repairEmployeeAccountIds();
    }
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      accountId = await _fallbackAccountIdFromLocal(db);
      if (accountId != null && accountId.trim().isNotEmpty) {
        _cachedAccountId = accountId;
      } else {
        return <Map<String, dynamic>>[];
      }
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    return db.query(
      'employees_salaries',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );
  }

  Future<int> updateEmployeeSalary(
    int salaryId,
    Map<String, dynamic> newData,
  ) async {
    final db = await database;
    final normalized = _normalizeEmployeeSalaryData(newData);
    final rows = await db.update(
      'employees_salaries',
      normalized,
      where: 'id = ?',
      whereArgs: [salaryId],
    );
    if (rows > 0) {
      final paidRaw = normalized['isPaid'];
      final isPaid =
          paidRaw == true ||
          (paidRaw is num && paidRaw.toInt() == 1) ||
          paidRaw?.toString().trim() == '1';
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees_salaries',
        entityId: salaryId,
        operationType: isPaid ? 'mark_salary_paid' : 'update_salary',
      );
    }
    await _markChanged('employees_salaries');
    return rows;
  }

  Future<int> deleteEmployeeSalary(int salaryId) async {
    final db = await database;
    final rows = await _softDeleteById('employees_salaries', salaryId);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees_salaries',
        entityId: salaryId,
        operationType: 'delete_salary_soft',
      );
    }
    await _markChanged('employees_salaries');
    return rows;
  }

  //=============================== خصومات الموظفين ===============================
  Future<int> insertEmployeeDiscount(Map<String, dynamic> discountData) async {
    final db = await database;
    final id = await db.insert('employees_discounts', discountData);
    await _enqueueClinicOutboxForRow(
      db,
      table: 'employees_discounts',
      entityId: id,
      operationType: 'create_discount',
    );
    await _markChanged('employees_discounts');
    return id;
  }

  Future<List<Map<String, dynamic>>> getAllEmployeeDiscounts() async {
    final db = await database;
    var accountId = await _currentAccountId();
    final whereArgs = <Object?>[];
    var where = 'ifnull(isDeleted,0)=0';
    final hasAccCol = await _hasColumn(db, 'employees_discounts', 'account_id');
    if (hasAccCol) {
      await repairEmployeeAccountIds();
    }
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      accountId = await _fallbackAccountIdFromLocal(db);
      if (accountId != null && accountId.trim().isNotEmpty) {
        _cachedAccountId = accountId;
      } else {
        return <Map<String, dynamic>>[];
      }
    }
    if (accountId != null && hasAccCol) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    return db.query(
      'employees_discounts',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'discountDateTime DESC',
    );
  }

  Future<double> getEmployeeDiscountsSumBetween({
    required int employeeId,
    required DateTime from,
    required DateTime to,
  }) async {
    final db = await database;
    final args = <Object?>[
      employeeId,
      from.toIso8601String(),
      to.toIso8601String(),
    ];
    final accountClause = await _accountFilterClause(
      db,
      'employees_discounts',
      args: args,
    );
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM employees_discounts
      WHERE employeeId = ?
        AND date(discountDateTime) BETWEEN date(?) AND date(?)
        AND ifnull(isDeleted,0)=0
        $accountClause
    ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// إصلاح سجلات السلف/الخصومات التي فقدت employeeId أثناء المزامنة.
  /// يعتمد على مطابقة المبلغ ونطاق زمني قريب من سجل financial_logs.
  Future<void> repairEmployeeLoansDiscountsMissingEmployeeId({
    Duration tolerance = const Duration(minutes: 10),
  }) async {
    final db = await database;
    var fixedLoans = false;
    var fixedDiscounts = false;

    final accountId = await _currentAccountId();
    final logsHasAccCol = await _hasColumn(db, 'financial_logs', 'account_id');
    if (logsHasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return;
    }
    final logsWhereArgs = <Object?>['Loan', 'Discount'];
    var logsWhere = 'employee_id IS NOT NULL AND transaction_type IN (?,?)';
    if (logsHasAccCol && accountId != null) {
      logsWhere += ' AND account_id = ?';
      logsWhereArgs.add(accountId);
    }
    final logs = await db.query(
      'financial_logs',
      columns: const ['transaction_type', 'amount', 'employee_id', 'timestamp'],
      where: logsWhere,
      whereArgs: logsWhereArgs,
    );

    if (logs.isEmpty) return;

    DateTime? _parseTs(String? v) {
      if (v == null || v.trim().isEmpty) return null;
      try {
        return DateTime.parse(v);
      } catch (_) {
        return null;
      }
    }

    final loanLogs = <Map<String, dynamic>>[];
    final discountLogs = <Map<String, dynamic>>[];
    for (final l in logs) {
      final type = (l['transaction_type'] ?? '').toString();
      if (type == 'Loan') {
        loanLogs.add(l);
      } else if (type == 'Discount') {
        discountLogs.add(l);
      }
    }

    final loansHasAccCol = await _hasColumn(
      db,
      'employees_loans',
      'account_id',
    );
    if (loansHasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return;
    }
    final missingLoansWhereArgs = <Object?>[];
    var missingLoansWhere = 'employeeId IS NULL';
    if (loansHasAccCol && accountId != null) {
      missingLoansWhere += ' AND account_id = ?';
      missingLoansWhereArgs.add(accountId);
    }
    final missingLoans = await db.query(
      'employees_loans',
      columns: const ['id', 'loanAmount', 'loanDateTime', 'employeeId'],
      where: missingLoansWhere,
      whereArgs: missingLoansWhereArgs,
    );
    for (final row in missingLoans) {
      final loanId = (row['id'] as num?)?.toInt();
      if (loanId == null) continue;
      final amount = (row['loanAmount'] as num?)?.toDouble() ?? 0.0;
      final dt = _parseTs(row['loanDateTime']?.toString());
      if (dt == null) continue;

      Map<String, dynamic>? best;
      Duration? bestDiff;
      for (final l in loanLogs) {
        final lAmt = (l['amount'] as num?)?.toDouble() ?? 0.0;
        if ((lAmt - amount).abs() > 0.0001) continue;
        final lTs = _parseTs(l['timestamp']?.toString());
        if (lTs == null) continue;
        final diff = lTs.difference(dt).abs();
        if (diff > tolerance) continue;
        if (bestDiff == null || diff < bestDiff) {
          bestDiff = diff;
          best = l;
        }
      }
      final empIdRaw = best?['employee_id'];
      final empId = empIdRaw is num
          ? empIdRaw.toInt()
          : int.tryParse('$empIdRaw');
      if (empId != null && empId > 0) {
        await db.update(
          'employees_loans',
          {'employeeId': empId},
          where: 'id = ?',
          whereArgs: [loanId],
        );
        fixedLoans = true;
      }
    }

    final discountsHasAccCol = await _hasColumn(
      db,
      'employees_discounts',
      'account_id',
    );
    if (discountsHasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return;
    }
    final missingDiscountsWhereArgs = <Object?>[];
    var missingDiscountsWhere = 'employeeId IS NULL';
    if (discountsHasAccCol && accountId != null) {
      missingDiscountsWhere += ' AND account_id = ?';
      missingDiscountsWhereArgs.add(accountId);
    }
    final missingDiscounts = await db.query(
      'employees_discounts',
      columns: const ['id', 'amount', 'discountDateTime', 'employeeId'],
      where: missingDiscountsWhere,
      whereArgs: missingDiscountsWhereArgs,
    );
    for (final row in missingDiscounts) {
      final discId = (row['id'] as num?)?.toInt();
      if (discId == null) continue;
      final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
      final dt = _parseTs(row['discountDateTime']?.toString());
      if (dt == null) continue;

      Map<String, dynamic>? best;
      Duration? bestDiff;
      for (final l in discountLogs) {
        final lAmt = (l['amount'] as num?)?.toDouble() ?? 0.0;
        if ((lAmt - amount).abs() > 0.0001) continue;
        final lTs = _parseTs(l['timestamp']?.toString());
        if (lTs == null) continue;
        final diff = lTs.difference(dt).abs();
        if (diff > tolerance) continue;
        if (bestDiff == null || diff < bestDiff) {
          bestDiff = diff;
          best = l;
        }
      }
      final empIdRaw = best?['employee_id'];
      final empId = empIdRaw is num
          ? empIdRaw.toInt()
          : int.tryParse('$empIdRaw');
      if (empId != null && empId > 0) {
        await db.update(
          'employees_discounts',
          {'employeeId': empId},
          where: 'id = ?',
          whereArgs: [discId],
        );
        fixedDiscounts = true;
      }
    }

    if (fixedLoans) await _markChanged('employees_loans');
    if (fixedDiscounts) await _markChanged('employees_discounts');
  }

  Future<List<Map<String, dynamic>>> getDiscountsByEmployee(int empId) async {
    final db = await database;
    final accountId = await _currentAccountId();
    final hasAccCol = await _hasColumn(db, 'employees_discounts', 'account_id');
    if (hasAccCol && (accountId == null || accountId.trim().isEmpty)) {
      return const [];
    }
    final whereArgs = <Object?>[empId];
    var where = 'employeeId = ? AND ifnull(isDeleted,0)=0';
    if (hasAccCol && accountId != null) {
      where += ' AND account_id = ?';
      whereArgs.add(accountId);
    }
    return db.query(
      'employees_discounts',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'discountDateTime DESC',
    );
  }

  Future<int> updateEmployeeDiscount(
    int discountId,
    Map<String, dynamic> newData,
  ) async {
    final db = await database;
    final rows = await db.update(
      'employees_discounts',
      newData,
      where: 'id = ?',
      whereArgs: [discountId],
    );
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees_discounts',
        entityId: discountId,
        operationType: 'update_discount',
      );
    }
    await _markChanged('employees_discounts');
    return rows;
  }

  Future<int> deleteEmployeeDiscount(int discountId) async {
    final db = await database;
    final rows = await _softDeleteById('employees_discounts', discountId);
    if (rows > 0) {
      await _enqueueClinicOutboxForRow(
        db,
        table: 'employees_discounts',
        entityId: discountId,
        operationType: 'delete_discount_soft',
      );
    }
    await _markChanged('employees_discounts');
    return rows;
  }

  //=============================== الإحصائيات ===============================
  Future<int> getTotalPatients() async {
    final db = await database;
    final args = <Object?>[];
    final accountClause = await _accountFilterClause(
      db,
      'patients',
      args: args,
    );
    final res = await db.rawQuery(
      'SELECT COUNT(*) as count FROM patients WHERE ifnull(isDeleted,0)=0$accountClause',
      args,
    );
    return Sqflite.firstIntValue(res) ?? 0;
  }

  Future<int> getSuccessfulAppointments() async {
    final db = await database;
    final args = <Object?>[];
    final accountClause = await _accountFilterClause(
      db,
      'appointments',
      args: args,
    );
    final res = await db.rawQuery(
      "SELECT COUNT(*) as count FROM appointments WHERE status = 'مؤكد' AND ifnull(isDeleted,0)=0$accountClause",
      args,
    );
    return Sqflite.firstIntValue(res) ?? 0;
  }

  Future<int> getFollowUpCount() async {
    final db = await database;
    final args = <Object?>[];
    final accountClause = await _accountFilterClause(
      db,
      'appointments',
      args: args,
    );
    final res = await db.rawQuery(
      "SELECT COUNT(*) as count FROM appointments WHERE status = 'متابعة' AND ifnull(isDeleted,0)=0$accountClause",
      args,
    );
    return Sqflite.firstIntValue(res) ?? 0;
  }

  Future<double> getFinancialTotal() async {
    final db = await database;
    final args = <Object?>[];
    final accountClause = await _accountFilterClause(
      db,
      'patients',
      args: args,
    );
    final res = await db.rawQuery(
      'SELECT SUM(paidAmount) as total FROM patients WHERE ifnull(isDeleted,0)=0$accountClause',
      args,
    );
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
    _cachedAccountId = null;
    _cachedDeviceId = null;
    _tableColumnsCache.clear();
  }

  @visibleForTesting
  Future<String> debugAccountFilterClause(String table, {String? alias}) async {
    final db = await database;
    final args = <Object?>[];
    return _accountFilterClause(db, table, alias: alias, args: args);
  }

  /// مسح كل الجداول المحلية (لما تغيّر الحساب) ثم تعليم الإحصاءات كـ Dirty.
  Future<void> clearAllLocalTables() async {
    final db = await database;
    await db.rawQuery('PRAGMA foreign_keys = OFF');
    try {
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
    } finally {
      await db.rawQuery('PRAGMA foreign_keys = ON');
    }
  }

  /// تحقّق هل توجد صفوف محليًا تخص حسابًا مختلفًا عن الحساب الحالي.
  /// هذا يُستخدم لتجنب مسح البيانات عند تغيّر الحساب المؤقت أو قراءة خاطئة.
  Future<bool> hasRowsForOtherAccount(String accountId) async {
    final db = await database;
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
    ];
    for (final t in tables) {
      try {
        final cols = await db
            .rawQuery("PRAGMA table_info($t)")
            .then((rows) => rows.map((r) => r['name'] as String).toSet());
        if (!cols.contains('account_id')) continue;
        final rows = await db.rawQuery(
          'SELECT 1 FROM $t WHERE account_id IS NOT NULL AND account_id != ? LIMIT 1',
          [accountId],
        );
        if (rows.isNotEmpty) return true;
      } catch (_) {
        // تجاهل أي جدول غير موجود أو خطأ عارض
      }
    }
    return false;
  }

  //=============================== دوال إضافية للإحصاء ===============================
  Future<double> getSumPatientsBetween(DateTime from, DateTime to) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final accountClause = await _accountFilterClause(
      db,
      'patients',
      args: args,
    );
    final res = await db.rawQuery('''
        SELECT SUM(paidAmount) as total
        FROM patients
        WHERE date(registerDate) BETWEEN date(?) AND date(?)
          AND ifnull(isDeleted,0)=0
          $accountClause
      ''', args);
    return res.first['total'] == null
        ? 0.0
        : (res.first['total'] as num).toDouble();
  }

  /// إجمالي مدفوعات المرضى خلال الفترة (تحصيل فعلي).
  Future<double> getSumPatientPaymentsBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final accountClause = await _accountFilterClause(
      db,
      'financial_logs',
      args: args,
    );
    final res = await db.rawQuery('''
        SELECT COALESCE(SUM(amount), 0) as total
        FROM financial_logs
        WHERE date(timestamp) BETWEEN date(?) AND date(?)
          AND ifnull(isDeleted,0)=0
          AND transaction_type = 'PatientPayment'
          $accountClause
      ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<bool> _hasPatientPaymentsBetween(DateTime from, DateTime to) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final accountClause = await _accountFilterClause(
      db,
      'financial_logs',
      args: args,
    );
    final res = await db.rawQuery('''
        SELECT COUNT(1) as cnt
        FROM financial_logs
        WHERE date(timestamp) BETWEEN date(?) AND date(?)
          AND ifnull(isDeleted,0)=0
          AND transaction_type = 'PatientPayment'
          $accountClause
      ''', args);
    final cnt = (res.first['cnt'] as num?)?.toInt() ?? 0;
    return cnt > 0;
  }

  /// دخل الخدمات حسب اليوم (احتياط للأنظمة القديمة قبل توحيد التحصيل).
  Future<Map<String, double>> getServiceRevenueByDateBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountIdFrom(db);
      if (accountId == null || accountId.trim().isEmpty) return {};
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
    final rows = await db.rawQuery('''
      SELECT date(p.registerDate) AS dayKey,
             COALESCE(SUM(
               COALESCE(ps.serviceCost, ms.cost, 0)
             ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
        $psAccount$pAccount$msAccount
      GROUP BY date(p.registerDate)
    ''', args);
    final out = <String, double>{};
    for (final row in rows) {
      final key = row['dayKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  /// دخل المرضى حسب اليوم اعتمادًا على التحصيل الفعلي (financial_logs).
  Future<Map<String, double>> getPatientPaymentsByDateBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final accountClause = await _accountFilterClause(
      db,
      'financial_logs',
      args: args,
    );
    final rows = await db.rawQuery('''
      SELECT date(timestamp) AS dayKey,
             COALESCE(SUM(amount), 0) AS total
      FROM financial_logs
      WHERE date(timestamp) BETWEEN date(?) AND date(?)
        AND ifnull(isDeleted,0)=0
        AND transaction_type = 'PatientPayment'
        $accountClause
      GROUP BY date(timestamp)
    ''', args);
    final out = <String, double>{};
    for (final row in rows) {
      final key = row['dayKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  /// دخل المرضى حسب الطبيب خلال الفترة (تحصيل فعلي).
  Future<Map<String, double>> getPatientPaymentsByDoctorBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final hasPatientId = await _hasColumn(db, 'financial_logs', 'patient_id');
    final hasAccCol = await _hasColumn(db, 'financial_logs', 'account_id');
    final accountId = await _currentAccountIdFrom(db);

    if (hasPatientId) {
      final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
      var accClause = '';
      if (hasAccCol) {
        if (accountId == null || accountId.trim().isEmpty) return {};
        accClause = ' AND fl.account_id = ?';
        args.add(accountId);
      }
      final rows = await db.rawQuery('''
        SELECT COALESCE(NULLIF(TRIM(p.doctorName), ''), 'الأشعة/المختبر') AS docKey,
               COALESCE(SUM(fl.amount), 0) AS total
        FROM financial_logs fl
        JOIN patients p ON p.id = fl.patient_id
        WHERE date(fl.timestamp) BETWEEN date(?) AND date(?)
          AND ifnull(fl.isDeleted,0)=0
          AND ifnull(p.isDeleted,0)=0
          AND fl.transaction_type = 'PatientPayment'
          $accClause
        GROUP BY docKey
      ''', args);
      final out = <String, double>{};
      for (final row in rows) {
        final key = row['docKey']?.toString() ?? '';
        if (key.isEmpty) continue;
        out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
      }
      return out;
    }

    // مسار احتياطي: حاول استخراج patientId من الوصف (ID: X)
    final logArgs = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final logAccClause = await _accountFilterClause(
      db,
      'financial_logs',
      args: logArgs,
    );
    final logs = await db.rawQuery('''
      SELECT amount, description
      FROM financial_logs
      WHERE date(timestamp) BETWEEN date(?) AND date(?)
        AND ifnull(isDeleted,0)=0
        AND transaction_type = 'PatientPayment'
        $logAccClause
    ''', logArgs);

    if (logs.isEmpty) return {};
    final patients = await getAllPatients();
    final byId = <int, Patient>{};
    for (final p in patients) {
      if (p.id != null) byId[p.id!] = p;
    }
    final reg = RegExp(r'ID:\\s*(\\d+)');
    final out = <String, double>{};
    for (final row in logs) {
      final desc = (row['description'] ?? '').toString();
      final m = reg.firstMatch(desc);
      if (m == null) continue;
      final pid = int.tryParse(m.group(1) ?? '');
      if (pid == null) continue;
      final p = byId[pid];
      if (p == null) continue;
      final doc = (p.doctorName == null || p.doctorName!.trim().isEmpty)
          ? 'الأشعة/المختبر'
          : p.doctorName!.trim();
      final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
      out[doc] = (out[doc] ?? 0) + amount;
    }
    return out;
  }

  /// دخل الفترة: تحصيل فعلي إن وجد، وإلا fallback لخدمات المرضى (legacy).
  Future<double> getIncomeTotalBetween(DateTime from, DateTime to) async {
    final hasPayments = await _hasPatientPaymentsBetween(from, to);
    if (hasPayments) {
      return getSumPatientPaymentsBetween(from, to);
    }
    // fallback للأنظمة القديمة قبل توحيد التحصيل
    return getSumPatientServicesBetween(from, to);
  }

  /// دخل حسب اليوم: تحصيل فعلي إن وجد، وإلا fallback لخدمات المرضى (legacy).
  Future<Map<String, double>> getIncomeByDateBetween(
    DateTime from,
    DateTime to,
  ) async {
    final hasPayments = await _hasPatientPaymentsBetween(from, to);
    if (hasPayments) {
      return getPatientPaymentsByDateBetween(from, to);
    }
    return getServiceRevenueByDateBetween(from, to);
  }

  /// إجمالي المبالغ المتبقية على المرضى خلال الفترة.
  Future<double> getSumPatientsRemainingBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final accountClause = await _accountFilterClause(
      db,
      'patients',
      args: args,
    );
    final res = await db.rawQuery('''
        SELECT COALESCE(SUM(remaining), 0) as total
        FROM patients
        WHERE date(registerDate) BETWEEN date(?) AND date(?)
          AND ifnull(isDeleted,0)=0
          $accountClause
      ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// إجمالي قيمة الخدمات المقدمة خلال الفترة (يُستخدم كدخل عند عدم تسجيل الدفعات).
  Future<double> getSumPatientServicesBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
    final res = await db.rawQuery('''
        SELECT COALESCE(SUM(
          COALESCE(ps.serviceCost, ms.cost, 0)
        ), 0) as total
        FROM ${PatientService.table} ps
        JOIN patients p ON p.id = ps.patientId
        LEFT JOIN medical_services ms ON ms.id = ps.serviceId
        WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
          AND ifnull(ps.isDeleted,0)=0
          AND ifnull(p.isDeleted,0)=0
          AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
          $psAccount$pAccount$msAccount
      ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getSumConsumptionBetween(DateTime from, DateTime to) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final cAccount = await _accountFilterClause(
      db,
      'consumptions',
      alias: 'c',
      args: args,
    );
    String iAccount = '';
    if (await _hasColumn(db, 'items', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      iAccount = ' AND (i.account_id = ? OR i.id IS NULL)';
      args.add(accountId);
    }
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
          $cAccount$iAccount
      ''', args);
    return res.first['total'] == null
        ? 0.0
        : (res.first['total'] as num).toDouble();
  }

  /// إجمالي المشتريات خلال الفترة (تحسب تكلفة المواد عند الشراء).
  Future<double> getSumPurchasesBetween(DateTime from, DateTime to) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final accountClause = await _accountFilterClause(
      db,
      'purchases',
      args: args,
    );
    final res = await db.rawQuery('''
        SELECT COALESCE(SUM(
          COALESCE(quantity, 0) * COALESCE(unit_price, 0)
        ), 0) as total
        FROM purchases
        WHERE date(created_at) BETWEEN date(?) AND date(?)
          AND ifnull(isDeleted,0)=0
          $accountClause
      ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getSumReturnsRemainingBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final accountClause = await _accountFilterClause(db, 'returns', args: args);
    final res = await db.rawQuery('''
        SELECT SUM(remaining) as total
        FROM returns
        WHERE date BETWEEN ? AND ?
          AND ifnull(isDeleted,0)=0
          $accountClause
      ''', args);
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
    int doctorId,
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[
      doctorId,
      from.toIso8601String(),
      to.toIso8601String(),
    ];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    final msAccount = await _accountFilterClause(
      db,
      'medical_services',
      alias: 'ms',
      args: args,
    );
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
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
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND ms.serviceType IN ('radiology','lab','الأشعة','المختبر')
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND ifnull(ms.isDeleted,0)=0
        $psAccount$pAccount$msAccount$sdsAccount
    ''', args);
    return (res.first['ratioSum'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getEffectiveDoctorDirectInputSum(
    int doctorId,
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[
      doctorId,
      doctorId,
      doctorId,
      from.toIso8601String(),
      to.toIso8601String(),
    ];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
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
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
        $psAccount$pAccount$msAccount$sdsAccount
    ''', args);
    return (res.first['docInput'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getDoctorTowerShareSum(
    int doctorId,
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[
      doctorId,
      doctorId,
      from.toIso8601String(),
      to.toIso8601String(),
    ];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
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
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
        $psAccount$pAccount$msAccount$sdsAccount
    ''', args);
    return (res.first['towerShare'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getEffectiveSumAllDoctorInputBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        CASE
          -- سطور حرّة تُحسب لطبيب المريض
          WHEN ps.serviceId IS NULL THEN
            CASE WHEN p.doctorId IS NOT NULL THEN ps.serviceCost ELSE 0 END
          -- خدمات طبيب مُعرّفة تُنسب لطبيب الخدمة عبر sds (إن وُجد)
          WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب')
            THEN CASE
              WHEN sds.towerSharePercentage IS NULL
                THEN ps.serviceCost
              ELSE ps.serviceCost * (1.0 - COALESCE(sds.towerSharePercentage, 0) / 100.0)
            END
          ELSE 0
        END
      ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND ifnull(sds.isDeleted,0)=0
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND (ps.serviceId IS NULL OR ms.serviceType IN ('doctor','doctorGeneral','طبيب'))
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
        $psAccount$pAccount$msAccount$sdsAccount
    ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getSumAllDoctorShareBetween(DateTime from, DateTime to) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    final msAccount = await _accountFilterClause(
      db,
      'medical_services',
      alias: 'ms',
      args: args,
    );
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        ps.serviceCost * (COALESCE(sds.sharePercentage, 0) / 100.0)
      ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND ifnull(sds.isDeleted,0)=0
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND ms.serviceType IN ('radiology','lab','الأشعة','المختبر')
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND ifnull(ms.isDeleted,0)=0
        $psAccount$pAccount$msAccount$sdsAccount
    ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getSumAllDoctorInputBetween(DateTime from, DateTime to) async {
    return getEffectiveSumAllDoctorInputBetween(from, to);
  }

  Future<double> getSumAllTowerShareBetween(DateTime from, DateTime to) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(
        CASE
          WHEN ps.serviceId IS NULL THEN 0
          WHEN ms.serviceType IN ('radiology','lab','doctor','doctorGeneral','الأشعة','المختبر','طبيب')
            THEN ps.serviceCost * (COALESCE(sds.towerSharePercentage, 0) / 100.0)
          ELSE 0
        END
      ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND ifnull(sds.isDeleted,0)=0
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND (ps.serviceId IS NULL OR ms.serviceType IN ('radiology','lab','doctor','doctorGeneral','الأشعة','المختبر','طبيب'))
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
        $psAccount$pAccount$msAccount$sdsAccount
    ''', args);
    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<Map<String, double>> getDoctorShareByDateBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    final msAccount = await _accountFilterClause(
      db,
      'medical_services',
      alias: 'ms',
      args: args,
    );
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return {};
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
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
       AND ifnull(sds.isDeleted,0)=0
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND ms.serviceType IN ('radiology','lab','الأشعة','المختبر')
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND ifnull(ms.isDeleted,0)=0
        $psAccount$pAccount$msAccount$sdsAccount
      GROUP BY date(p.registerDate)
      ORDER BY dayKey ASC
    ''', args);
    final out = <String, double>{};
    for (final row in rows) {
      final key = row['dayKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  /// تقرير مستحقات الأطباء (من آخر صرف وحتى تاريخ محدد).
  Future<List<Map<String, dynamic>>> getDoctorOutstandingBalances({
    DateTime? asOf,
  }) async {
    final now = asOf ?? DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final doctors = await getAllDoctors();
    final db = await database;
    final hasEmpAccCol = await _hasColumn(db, 'employees', 'account_id');
    final accountId = await _currentAccountId();

    Future<int?> resolveEmployeeId(Doctor d) async {
      if (d.employeeId != null) return d.employeeId;
      final uid = (d.userUid ?? '').trim();
      if (uid.isEmpty) return null;
      if (hasEmpAccCol && (accountId == null || accountId.trim().isEmpty)) {
        return null;
      }
      final whereArgs = <Object?>[uid];
      var where = 'userUid = ? AND ifnull(isDeleted,0)=0';
      if (hasEmpAccCol && accountId != null) {
        where += ' AND account_id = ?';
        whereArgs.add(accountId);
      }
      final res = await db.query(
        'employees',
        columns: const ['id'],
        where: where,
        whereArgs: whereArgs,
        limit: 1,
      );
      if (res.isEmpty) return null;
      return (res.first['id'] as num).toInt();
    }

    final out = <Map<String, dynamic>>[];
    for (final d in doctors) {
      final doctorId = d.id;
      if (doctorId == null) continue;
      final employeeId = await resolveEmployeeId(d);
      final lastPaidAt = employeeId == null
          ? null
          : await getLastSalaryPaymentDate(employeeId);
      var from = monthStart;
      if (lastPaidAt != null) {
        final after = lastPaidAt.add(const Duration(seconds: 1));
        if (after.isAfter(from)) from = after;
      }
      final to = now;
      if (from.isAfter(to)) {
        out.add({
          'doctorId': doctorId,
          'employeeId': employeeId,
          'doctorName': d.name,
          'periodStart': from.toIso8601String(),
          'periodEnd': to.toIso8601String(),
          'ratioSum': 0.0,
          'directInput': 0.0,
          'totalLoans': 0.0,
          'totalDiscounts': 0.0,
          'netPay': 0.0,
          'lastPaidAt': lastPaidAt?.toIso8601String(),
        });
        continue;
      }

      final ratioSum = await getDoctorRatioSum(doctorId, from, to);
      final directInput = await getEffectiveDoctorDirectInputSum(
        doctorId,
        from,
        to,
      );
      double loans = 0.0;
      double discounts = 0.0;
      if (employeeId != null) {
        loans = await getEmployeeLoansSumBetween(
          employeeId: employeeId,
          from: from,
          to: to,
        );
        discounts = await getEmployeeDiscountsSumBetween(
          employeeId: employeeId,
          from: from,
          to: to,
        );
      }
      final net = (ratioSum + directInput) - (loans + discounts);
      out.add({
        'doctorId': doctorId,
        'employeeId': employeeId,
        'doctorName': d.name,
        'periodStart': from.toIso8601String(),
        'periodEnd': to.toIso8601String(),
        'ratioSum': ratioSum,
        'directInput': directInput,
        'totalLoans': loans,
        'totalDiscounts': discounts,
        'netPay': net,
        'lastPaidAt': lastPaidAt?.toIso8601String(),
      });
    }
    return out;
  }

  Future<Map<String, double>> getDoctorInputByDateBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final psAccount = await _accountFilterClause(
      db,
      PatientService.table,
      alias: 'ps',
      args: args,
    );
    final pAccount = await _accountFilterClause(
      db,
      'patients',
      alias: 'p',
      args: args,
    );
    String msAccount = '';
    if (await _hasColumn(db, 'medical_services', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return {};
      msAccount = ' AND (ms.account_id = ? OR ms.id IS NULL)';
      args.add(accountId);
    }
    String sdsAccount = '';
    if (await _hasColumn(db, 'service_doctor_share', 'account_id')) {
      final accountId = await _currentAccountId();
      if (accountId == null || accountId.trim().isEmpty) return {};
      sdsAccount = ' AND (sds.account_id = ? OR sds.id IS NULL)';
      args.add(accountId);
    }
    final rows = await db.rawQuery('''
      SELECT 
        date(p.registerDate) AS dayKey,
        COALESCE(SUM(
          CASE
            WHEN ps.serviceId IS NULL THEN
              CASE WHEN p.doctorId IS NOT NULL THEN ps.serviceCost ELSE 0 END
            WHEN ms.serviceType IN ('doctor','doctorGeneral','طبيب') THEN
              CASE
                WHEN sds.towerSharePercentage IS NULL
                  THEN ps.serviceCost
                ELSE ps.serviceCost * (1.0 - COALESCE(sds.towerSharePercentage, 0) / 100.0)
              END
            ELSE 0
          END
        ), 0) AS total
      FROM ${PatientService.table} ps
      JOIN patients p ON p.id = ps.patientId
      LEFT JOIN medical_services ms ON ms.id = ps.serviceId
      LEFT JOIN service_doctor_share sds
        ON sds.serviceId = ps.serviceId
       AND ifnull(sds.isDeleted,0)=0
      WHERE date(p.registerDate) BETWEEN date(?) AND date(?)
        AND (ps.serviceId IS NULL OR ms.serviceType IN ('doctor','doctorGeneral','طبيب'))
        AND ifnull(ps.isDeleted,0)=0
        AND ifnull(p.isDeleted,0)=0
        AND (ps.serviceId IS NULL OR ifnull(ms.isDeleted,0)=0)
        $psAccount$pAccount$msAccount$sdsAccount
      GROUP BY date(p.registerDate)
      ORDER BY dayKey ASC
    ''', args);
    final out = <String, double>{};
    for (final row in rows) {
      final key = row['dayKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  Future<Map<String, double>> getConsumptionByDateBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final consumptionAccount = await _accountFilterClause(
      db,
      'consumptions',
      alias: 'c',
      args: args,
    );
    String itemsAccount = '';
    if (await _hasColumn(db, 'items', 'account_id')) {
      final accountId = await _currentAccountIdFrom(db);
      if (accountId == null || accountId.trim().isEmpty) return {};
      itemsAccount = ' AND (i.account_id = ? OR i.id IS NULL)';
      args.add(accountId);
    }

    final rows = await db.rawQuery('''
      SELECT date(c.date) AS dayKey,
             COALESCE(SUM(
               CASE
                 WHEN (c.amount IS NULL OR c.amount = 0)
                   THEN COALESCE(i.price, 0) * COALESCE(c.quantity, 0)
                 ELSE c.amount
               END
             ), 0) AS total
      FROM consumptions c
      LEFT JOIN items i ON i.id = c.itemId
      WHERE date(c.date) BETWEEN date(?) AND date(?)
        AND ifnull(c.isDeleted,0)=0
        $consumptionAccount$itemsAccount
      GROUP BY date(c.date)
      ORDER BY dayKey ASC
    ''', args);

    final out = <String, double>{};
    for (final row in rows) {
      final key = row['dayKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  Future<Map<String, double>> getConsumptionByTypeBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final consumptionAccount = await _accountFilterClause(
      db,
      'consumptions',
      alias: 'c',
      args: args,
    );
    String itemsAccount = '';
    if (await _hasColumn(db, 'items', 'account_id')) {
      final accountId = await _currentAccountIdFrom(db);
      if (accountId == null || accountId.trim().isEmpty) return {};
      itemsAccount = ' AND (i.account_id = ? OR i.id IS NULL)';
      args.add(accountId);
    }

    final rows = await db.rawQuery('''
      SELECT COALESCE(NULLIF(TRIM(c.note), ''), 'غير محدد') AS typeKey,
             COALESCE(SUM(
               CASE
                 WHEN (c.amount IS NULL OR c.amount = 0)
                   THEN COALESCE(i.price, 0) * COALESCE(c.quantity, 0)
                 ELSE c.amount
               END
             ), 0) AS total
      FROM consumptions c
      LEFT JOIN items i ON i.id = c.itemId
      WHERE date(c.date) BETWEEN date(?) AND date(?)
        AND ifnull(c.isDeleted,0)=0
        $consumptionAccount$itemsAccount
      GROUP BY typeKey
      ORDER BY total DESC, typeKey ASC
    ''', args);

    final out = <String, double>{};
    for (final row in rows) {
      final key = row['typeKey']?.toString() ?? '';
      if (key.isEmpty) continue;
      out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return out;
  }

  Future<Map<String, double>> getNetProfitByDateBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final income = await getIncomeByDateBetween(from, to);

    final consArgs = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final purchasesAccount = await _accountFilterClause(
      db,
      'purchases',
      args: consArgs,
    );
    final consRows = await db.rawQuery('''
      SELECT date(created_at) AS dayKey,
             COALESCE(SUM(
               COALESCE(quantity, 0) * COALESCE(unit_price, 0)
             ), 0) AS total
      FROM purchases
      WHERE date(created_at) BETWEEN date(?) AND date(?)
        AND ifnull(isDeleted,0)=0
        $purchasesAccount
      GROUP BY date(created_at)
    ''', consArgs);

    final facilityArgs = <Object?>[
      from.toIso8601String(),
      to.toIso8601String(),
    ];
    final consumptionAccount = await _accountFilterClause(
      db,
      'consumptions',
      alias: 'c',
      args: facilityArgs,
    );
    String itemsAccount = '';
    if (await _hasColumn(db, 'items', 'account_id')) {
      final accountId = await _currentAccountIdFrom(db);
      if (accountId == null || accountId.trim().isEmpty) return {};
      itemsAccount = ' AND (i.account_id = ? OR i.id IS NULL)';
      facilityArgs.add(accountId);
    }
    final facilityRows = await db.rawQuery('''
      SELECT date(c.date) AS dayKey,
             COALESCE(SUM(
               CASE 
                 WHEN (c.amount IS NULL OR c.amount = 0)
                   THEN COALESCE(i.price, 0) * COALESCE(c.quantity, 0)
                 ELSE c.amount
               END
             ), 0) AS total
      FROM consumptions c
      LEFT JOIN items i ON i.id = c.itemId
      WHERE date(c.date) BETWEEN date(?) AND date(?)
        AND ifnull(c.isDeleted,0)=0
        $consumptionAccount$itemsAccount
      GROUP BY date(c.date)
    ''', facilityArgs);

    final salArgs = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final salariesAccount = await _accountFilterClause(
      db,
      'employees_salaries',
      args: salArgs,
    );
    final salRows = await db.rawQuery('''
      SELECT date(paymentDate) AS dayKey,
             COALESCE(SUM(netPay), 0) AS total
      FROM employees_salaries
      WHERE paymentDate BETWEEN ? AND ?
        AND ifnull(isDeleted,0)=0
        $salariesAccount
      GROUP BY date(paymentDate)
    ''', salArgs);

    Map<String, double> mapFromRows(List<Map<String, dynamic>> rows) {
      final out = <String, double>{};
      for (final row in rows) {
        final key = row['dayKey']?.toString() ?? '';
        if (key.isEmpty) continue;
        out[key] = (row['total'] as num?)?.toDouble() ?? 0.0;
      }
      return out;
    }

    final cons = mapFromRows(consRows);
    final facility = mapFromRows(facilityRows);
    final salaries = mapFromRows(salRows);
    final days = <String>{}
      ..addAll(income.keys)
      ..addAll(cons.keys)
      ..addAll(facility.keys)
      ..addAll(salaries.keys);

    final net = <String, double>{};
    for (final k in days) {
      net[k] =
          (income[k] ?? 0) -
          (cons[k] ?? 0) -
          (facility[k] ?? 0) -
          (salaries[k] ?? 0);
    }
    return net;
  }

  Future<double> getNetProfitTotalBetween(DateTime from, DateTime to) async {
    final map = await getNetProfitByDateBetween(from, to);
    return map.values.fold<double>(0.0, (sum, v) => sum + v);
  }

  Future<double> getSumConsumptionsBetween(DateTime from, DateTime to) async {
    final db = await database;
    final args = <Object?>[from.toIso8601String(), to.toIso8601String()];
    final consumptionAccount = await _accountFilterClause(
      db,
      'consumptions',
      alias: 'c',
      args: args,
    );
    String itemsAccount = '';
    if (await _hasColumn(db, 'items', 'account_id')) {
      final accountId = await _currentAccountIdFrom(db);
      if (accountId == null || accountId.trim().isEmpty) return 0.0;
      itemsAccount = ' AND (i.account_id = ? OR i.id IS NULL)';
      args.add(accountId);
    }
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(
        CASE 
          WHEN (c.amount IS NULL OR c.amount = 0)
            THEN COALESCE(i.price, 0) * COALESCE(c.quantity, 0)
          ELSE c.amount
        END
      ), 0) AS total
      FROM consumptions c
      LEFT JOIN items i ON i.id = c.itemId
      WHERE date(c.date) BETWEEN date(?) AND date(?)
        AND ifnull(c.isDeleted,0)=0
        $consumptionAccount$itemsAccount
    ''', args);
    return (rows.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<int> insertConsumptionType(String type) async {
    final db = await database;
    final id = await db.insert('consumption_types', {
      'type': type,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _markChanged('consumption_types'); // ← ضمان الدفع
    return id;
  }

  Future<List<String>> getAllConsumptionTypes() async {
    final db = await database;
    final res = await db.query(
      'consumption_types',
      where: 'ifnull(isDeleted,0)=0',
      orderBy: 'id ASC',
    );
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
        [table],
      );
      return res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _columnExists(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
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
    DatabaseExecutor db,
    String table,
    String column,
    String sqlType,
  ) async {
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

  Future<void> _createIndexIfMissing(
    DatabaseExecutor db,
    String indexName,
    String table,
    List<String> columns,
  ) async {
    if (!await _tableExists(db, table)) {
      return;
    }
    final cols = columns.join(',');
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS $indexName ON $table($cols)',
      );
    } catch (_) {
      // قد يُستدعى أثناء ترقية دفاعية قبل إنشاء الجدول، لذا نتجاهل الخطأ.
    }
  }
}

class InventoryRepairReport {
  InventoryRepairReport();

  bool createdFallbackType = false;
  int orphanItemsFixed = 0;
  String? skippedReason;

  InventoryRepairReport.skipped(this.skippedReason);

  bool get skipped => skippedReason != null;

  Map<String, dynamic> toMap() => {
    'createdFallbackType': createdFallbackType,
    'orphanItemsFixed': orphanItemsFixed,
    'skippedReason': skippedReason,
  };

  @override
  String toString() {
    if (skipped) return 'InventoryRepairReport(skipped: $skippedReason)';
    return 'InventoryRepairReport(createdFallbackType: $createdFallbackType, '
        'orphanItemsFixed: $orphanItemsFixed)';
  }
}
