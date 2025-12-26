// lib/services/sync_service.dart
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/enums.dart';
import 'package:uuid/uuid.dart';

import 'package:aelmamclinic/data/sync/alert_settings_sync_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

/// كلاس مساعد اختياري لتحويل الحقول عند الدفع/السحب.
/// ضع أي من الدالتين إن كنت تحتاج مسار تحويل مخصص لهذا الجدول.
class EntityMapper {
  final Map<String, dynamic> Function(Map<String, dynamic> localRow)?
      toCloudMap;
  final Map<String, dynamic> Function(
    Map<String, dynamic> remoteRow,
    Set<String> allowedLocalColumns,
  )? fromCloudMap;

  const EntityMapper({this.toCloudMap, this.fromCloudMap});
}

class _RowIdentity {
  final String deviceId;
  final int localId;
  final int recordId;

  const _RowIdentity({
    required this.deviceId,
    required this.localId,
    required this.recordId,
  });
}

class _LocalSyncTriple {
  final String accountId;
  final String deviceId;
  final int localId;

  const _LocalSyncTriple({
    required this.accountId,
    required this.deviceId,
    required this.localId,
  });
}

class RemoteIdMapper {
  RemoteIdMapper(this._db);

  final Database _db;

  static const String _tableName = 'sync_uuid_mapping';

  String _normalizeDeviceId(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.isEmpty || normalized.toLowerCase() == 'app-unknown') {
      return 'app-unknown';
    }
    return normalized;
  }

  Future<String?> remoteUuidForLocal({
    required String tableName,
    required String accountId,
    required String deviceId,
    required int localId,
  }) async {
    if (localId <= 0 || accountId.trim().isEmpty) return null;
    final rows = await _db.query(
      _tableName,
      columns: const ['uuid'],
      where:
          'table_name = ? AND account_id = ? AND device_id = ? AND local_sync_id = ?',
      whereArgs: [
        tableName,
        accountId.trim(),
        _normalizeDeviceId(deviceId),
        localId
      ],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['uuid'];
    final uuid = raw?.toString().trim() ?? '';
    return uuid.isEmpty ? null : uuid;
  }

  Future<_LocalSyncTriple?> tripleForRemoteUuid({
    required String tableName,
    required String remoteUuid,
  }) async {
    final normalized = remoteUuid.trim();
    if (normalized.isEmpty) return null;
    final rows = await _db.query(
      _tableName,
      columns: const ['account_id', 'device_id', 'local_sync_id'],
      where: 'table_name = ? AND uuid = ?',
      whereArgs: [tableName, normalized],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final account = (row['account_id'] ?? '').toString().trim();
    final device = _normalizeDeviceId(row['device_id']?.toString());
    final rawLocal = row['local_sync_id'];
    final localId = rawLocal is num
        ? rawLocal.toInt()
        : int.tryParse('${rawLocal ?? ''}') ?? 0;
    if (localId <= 0) return null;
    return _LocalSyncTriple(
        accountId: account, deviceId: device, localId: localId);
  }
}

class MissingRemoteMappingException implements Exception {
  final String remoteTable;
  final String parentTable;
  final String childColumn;
  final int parentLocalId;
  final String reason;

  const MissingRemoteMappingException({
    required this.remoteTable,
    required this.parentTable,
    required this.childColumn,
    required this.parentLocalId,
    required this.reason,
  });

  @override
  String toString() {
    return 'MissingRemoteMappingException('
        'remoteTable: $remoteTable, '
        'parentTable: $parentTable, '
        'childColumn: $childColumn, '
        'parentLocalId: $parentLocalId, '
        'reason: $reason)';
  }
}

/// خدمة للمزامنة بين SQLite المحلي و Nhost/Hasura عبر GraphQL.
///
/// المتطلبات السحابية:
/// - أعمدة التزامن: account_id, device_id, local_id, updated_at
/// - فهرس فريد مركّب: unique(account_id,device_id,local_id)
/// - RLS على account_id.
///
/// ملاحظات:
/// - لا نفلتر device_id عند السحب: المالك يرى كل أجهزة حسابه.
/// - لمنع تصادم id محليًا: نركّب id = hash(device_id)*1e9 + local_id.
/// - attachments محلية فقط.
/// - حذف منطقي محلي، مع حذف سحابي فعلي لسجلات هذا الجهاز (id < 1e9).
class SyncService {
  GraphQLClient get _client => NhostGraphqlService.client;
  final Database _db;
  final RemoteIdMapper _remoteIds;

  /// ⚠️ قابلة لإعادة الربط (rebind) بعد معرفة الحساب/الجهاز.
  String accountId;
  String? deviceId;
  final bool enableLogs;

  /// تأخير دفع التغييرات المتتالية لنفس الجدول (دمجها بعد 1 ثانية).
  final Duration pushDebounce;

  static const int _pushChunkSize = 500;
  static const int _pullPageSize = 1000;

  /// نفس الثابت المستخدم في تركيب المعرف محليًا
  static const int _composeBlock = 1000000000; // 1e9

  static const Set<String> _reservedCols = {
    'account_id',
    'local_id',
    'device_id',
    'updated_at',
    'id',
  };

  static const String _uuidMappingTable = 'sync_uuid_mapping';
  static final Uuid _uuidGen = const Uuid();

  final Map<String, Set<String>> _localColsCache = {};
  final Map<String, Map<String, String>> _localColTypeCache = {};

  /// قفل دفع مخصص لكل جدول لمنع تكرار الدفع بالتوازي
  final Map<String, bool> _pushBusy = {};

  /// مؤقّتات دفع مجمّعة لكل جدول (debounce)
  final Map<String, Timer> _pushTimers = {};

  /// مخازن خرائط المعرفات المرجعية (محلي ↔ سحابي)
  final Map<String, Map<int, String>> _fkRemoteIdCache = {};
  final Map<String, Map<String, int>> _fkRemoteReverseCache = {};
  bool _fkMappingTableEnsured = false;

  /// allow-list للحقلـات المسموح إرسالها لكل جدول (snake_case على السحابة).
  /// تُستخدم كمسار احتياطي حتى ننتقل كليًا إلى mappers (toCloudMap/fromMap).
  static final Map<String, Set<String>> _remoteAllow = {
    'patients': {
      'name',
      'age',
      'diagnosis',
      'paid_amount',
      'remaining',
      'register_date',
      'phone_number',
      'health_status',
      'preferences',
      'doctor_id',
      'doctor_name',
      'doctor_specialization',
      'notes',
      'service_type',
      'service_id',
      'service_name',
      'service_cost',
      'doctor_share',
      'doctor_input',
      'tower_share',
      'department_share',
      'doctor_review_pending',
      'doctor_reviewed_at',
    },
    'returns': {
      'date',
      'patient_name',
      'phone_number',
      'diagnosis',
      'remaining',
      'age',
      'doctor',
      'notes',
    },
    'consumptions': {
      'patient_id',
      'item_id',
      'quantity',
      'date',
      'amount',
      'note'
    },
    'drugs': {'name', 'notes', 'created_at'},
    'prescriptions': {'patient_id', 'doctor_id', 'record_date', 'created_at'},
    'prescription_items': {
      'prescription_id',
      'drug_id',
      'days',
      'times_per_day'
    },
    'complaints': {'title', 'description', 'status', 'created_at'},
    'appointments': {'patient_id', 'appointment_time', 'status', 'notes'},
    'doctors': {
      'employee_id',
      'user_uid',
      'name',
      'specialization',
      'phone_number',
      'start_time',
      'end_time',
      'print_counter'
    },
    'consumption_types': {'type'},
    'medical_services': {'name', 'cost', 'service_type'},
    'service_doctor_share': {
      'service_id',
      'doctor_id',
      'share_percentage',
      'tower_share_percentage',
      'is_hidden'
    },
    'employees': {
      'name',
      'identity_number',
      'phone_number',
      'job_title',
      'address',
      'marital_status',
      'basic_salary',
      'final_salary',
      'is_doctor',
      'user_uid'
    },
    'employees_loans': {
      'employee_id',
      'loan_date_time',
      'final_salary',
      'ratio_sum',
      'loan_amount',
      'leftover'
    },
    'employees_salaries': {
      'employee_id',
      'year',
      'month',
      'final_salary',
      'ratio_sum',
      'total_loans',
      'net_pay',
      'is_paid',
      'payment_date'
    },
    'employees_discounts': {
      'employee_id',
      'discount_date_time',
      'amount',
      'notes'
    },
    'items': {'type_id', 'name', 'price', 'stock', 'created_at'},
    'item_types': {'name'},
    // نرسل total بدل unit_price + نضيف date
    'purchases': {'item_id', 'quantity', 'total', 'created_at', 'date'},
    // نضيف notify_time
    'alert_settings': {
      'item_id',
      'item_uuid',
      'threshold',
      'is_enabled',
      'last_triggered',
      'created_at',
      'notify_time'
    },
    'financial_logs': {
      'transaction_type',
      'operation',
      'amount',
      'employee_id',
      'description',
      'modification_details',
      'timestamp'
    },
    'patient_services': {
      'patient_id',
      'service_id',
      'service_name',
      'service_cost'
    },
  };

  /// أسماء قيود unique المركّبة المستخدمة في on_conflict
  /// (متطابقة مع migration: 20251220090000_add_sync_unique_constraints).
  static const Map<String, String> _syncConstraints = {
    'patients': 'patients_account_id_device_id_local_id_key',
    'returns': 'returns_account_id_device_id_local_id_key',
    'consumptions': 'consumptions_account_id_device_id_local_id_key',
    'drugs': 'drugs_account_id_device_id_local_id_key',
    'prescriptions': 'prescriptions_account_id_device_id_local_id_key',
    'prescription_items': 'prescription_items_account_id_device_id_local_id_key',
    'complaints': 'complaints_account_id_device_id_local_id_key',
    'appointments': 'appointments_account_id_device_id_local_id_key',
    'doctors': 'doctors_account_id_device_id_local_id_key',
    'consumption_types': 'consumption_types_account_id_device_id_local_id_key',
    'medical_services': 'medical_services_account_id_device_id_local_id_key',
    'service_doctor_share': 'service_doctor_share_account_id_device_id_local_id_key',
    'employees': 'employees_account_id_device_id_local_id_key',
    'employees_loans': 'employees_loans_account_id_device_id_local_id_key',
    'employees_salaries': 'employees_salaries_account_id_device_id_local_id_key',
    'employees_discounts': 'employees_discounts_account_id_device_id_local_id_key',
    'item_types': 'item_types_account_id_device_id_local_id_key',
    'items': 'items_account_id_device_id_local_id_key',
    'purchases': 'purchases_account_id_device_id_local_id_key',
    'alert_settings': 'alert_settings_account_id_device_id_local_id_key',
    'financial_logs': 'financial_logs_account_id_device_id_local_id_key',
    'patient_services': 'patient_services_account_id_device_id_local_id_key',
  };

  /// أعمدة Boolean على السحابة (نحوّل 0/1 المحلي إلى true/false عند الدفع).
  static final Map<String, Set<String>> _remoteBooleanCols = {
    'service_doctor_share': {'is_hidden'},
    'alert_settings': {'is_enabled'},
    'employees_salaries': {'is_paid'},
    'employees': {'is_doctor'},
    'patients': {'doctor_review_pending'},
  };

  /// خريطة مفاتيح FK لكل جدول (snake_case → parentLocalTable).
  static const Map<String, Map<String, String>> _fkMap = {
    'patients': {
      'doctor_id': 'doctors',
      'service_id': 'medical_services',
    },
    'consumptions': {
      'patient_id': 'patients',
      'item_id': 'items',
    },
    'prescriptions': {
      'patient_id': 'patients',
      'doctor_id': 'doctors',
    },
    'prescription_items': {
      'prescription_id': 'prescriptions',
      'drug_id': 'drugs',
    },
    'appointments': {
      'patient_id': 'patients',
    },
    'doctors': {
      'employee_id': 'employees',
    },
    'service_doctor_share': {
      'service_id': 'medical_services',
      'doctor_id': 'doctors',
    },
    'employees_loans': {
      'employee_id': 'employees',
    },
    'employees_salaries': {
      'employee_id': 'employees',
    },
    'employees_discounts': {
      'employee_id': 'employees',
    },
    'items': {
      'type_id': 'item_types',
    },
    'purchases': {
      'item_id': 'items',
    },
    'alert_settings': {
      'item_id': 'items',
    },
    'patient_services': {
      'patient_id': 'patients',
      'service_id': 'medical_services',
    },
    'financial_logs': {
      'employee_id': 'employees',
    },
  };

  /// Mapperات اختيارية لكل جدول — إن لم تُضبط، يُستخدم المسار الاحتياطي.
  final Map<String, EntityMapper> _mappers = {
    // purchases: حساب total ...
    'purchases': EntityMapper(
      toCloudMap: (local) {
        final out = <String, dynamic>{}..addAll(local);
        final q = out['quantity'];
        final up =
            out.containsKey('unitPrice') ? out['unitPrice'] : out['unit_price'];
        double? qty = (q is num) ? q.toDouble() : double.tryParse('${q ?? ''}');
        double? unit =
            (up is num) ? up.toDouble() : double.tryParse('${up ?? ''}');
        if (qty != null && unit != null) {
          out['total'] = qty * unit;
        }
        out.remove('unitPrice');
        out.remove('unit_price');

        DateTime? parseDate(dynamic v) {
          if (v == null) return null;
          if (v is DateTime) return v.toUtc();
          final s = v.toString().trim();
          if (s.isEmpty) return null;
          return DateTime.tryParse(s)?.toUtc();
        }

        final createdAt = parseDate(out['created_at']);
        if (createdAt != null) {
          out['created_at'] = createdAt.toIso8601String();
        }

        final existingDate = parseDate(out['date']);
        final DateTime effectiveDate =
            existingDate ?? createdAt ?? DateTime.now().toUtc();
        out['date'] = effectiveDate.toIso8601String();

        return out;
      },
      fromCloudMap: (remote, allowed) {
        final map = <String, dynamic>{}..addAll(remote);
        final hasTotalLocally = allowed.contains('total');
        if (!hasTotalLocally) {
          final rq = remote['quantity'];
          final rt = remote['total'];
          final double? qty =
              (rq is num) ? rq.toDouble() : double.tryParse('${rq ?? ''}');
          final double? tot =
              (rt is num) ? rt.toDouble() : double.tryParse('${rt ?? ''}');
          if (tot != null && qty != null && qty > 0) {
            if (allowed.contains('unitPrice')) {
              map['unitPrice'] = tot / qty;
            } else if (allowed.contains('unit_price')) {
              map['unit_price'] = tot / qty;
            }
          }
        }
        return map;
      },
    ),

    'alert_settings': EntityMapper(
      toCloudMap: AlertSettingsSyncService.toCloudMap,
      fromCloudMap: AlertSettingsSyncService.fromCloudMap,
    ),

    // doctors: تحويل HH:mm إلى timestamptz متوافق عند الدفع، والعكس عند السحب.
    'doctors': EntityMapper(
      toCloudMap: (local) {
        final out = <String, dynamic>{}..addAll(local);

        String? timeToTz(dynamic v) {
          final s = v?.toString().trim();
          if (s == null || s.isEmpty) return s;
          final re = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$'); // HH:mm أو HH:mm:ss
          if (re.hasMatch(s)) {
            final parts = s.split(':');
            final hh = parts[0].padLeft(2, '0');
            final mm = (parts.length > 1 ? parts[1] : '00').padLeft(2, '0');
            final ss = (parts.length > 2 ? parts[2] : '00').padLeft(2, '0');
            // ✅ إصلاح: يجب استخدام ${ss}Z
            return '1970-01-01T$hh:$mm:${ss}Z';
          }
          return s;
        }

        // احترم camel/snake وأعد كتابة snake النهائي
        final st = out.remove('startTime') ?? out['start_time'];
        final et = out.remove('endTime') ?? out['end_time'];
        if (st != null) out['start_time'] = timeToTz(st);
        if (et != null) out['end_time'] = timeToTz(et);
        return out;
      },
      fromCloudMap: (remote, allowed) {
        final map = <String, dynamic>{}..addAll(remote);

        String tzToHHmm(dynamic v) {
          final s = v?.toString() ?? '';
          final dt = DateTime.tryParse(s);
          if (dt != null) {
            final hh = dt.hour.toString().padLeft(2, '0');
            final mm = dt.minute.toString().padLeft(2, '0');
            return '$hh:$mm';
          }
          return s; // إذا كان نص جاهز "14:00" أو لم يُحلّل
        }

        if (allowed.contains('startTime') && map.containsKey('start_time')) {
          map['startTime'] = tzToHHmm(map['start_time']);
        }
        if (allowed.contains('endTime') && map.containsKey('end_time')) {
          map['endTime'] = tzToHHmm(map['end_time']);
        }
        return map;
      },
    ),
  };

  void setMapper(String remoteTable, EntityMapper mapper) {
    _mappers[remoteTable] = mapper;
  }

  SyncService(
    Database database,
    this.accountId, {
    this.deviceId,
    this.enableLogs = false,
    this.pushDebounce = const Duration(seconds: 1),
  })  : _db = database,
        _remoteIds = RemoteIdMapper(database) {
    _validateConstraintMap();
    _clientListener = _handleClientRefresh;
    NhostGraphqlService.buildNotifier().addListener(_clientListener!);
  }

  void _log(String msg) {
    if (enableLogs) {
      // ignore: avoid_print
      print('[SYNC] $msg');
    }
  }

  void _validateConstraintMap() {
    for (final table in _remoteAllow.keys) {
      if (!_syncConstraints.containsKey(table)) {
        _log(
          'Missing sync constraint mapping for table=$table. '
          'Add a UNIQUE (account_id, device_id, local_id) constraint in Nhost.',
        );
      }
    }
  }

  bool get _hasAccount => accountId.trim().isNotEmpty;
  bool get _hasDevice =>
      deviceId != null &&
      deviceId!.trim().isNotEmpty &&
      deviceId!.trim().toLowerCase() != 'app-unknown';

  String get _safeDeviceId => (deviceId != null && deviceId!.trim().isNotEmpty)
      ? deviceId!.trim()
      : 'app-unknown';

  String _normalizeDeviceId(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.isEmpty || normalized.toLowerCase() == 'app-unknown') {
      return _safeDeviceId;
    }
    return normalized;
  }

  String _uuidKey(String table, String device, int local) {
    final normalizedDevice =
        device.trim().isEmpty ? 'app-unknown' : device.trim();
    return '$table|$accountId|$normalizedDevice|$local';
  }

  Future<String?> _getUuidForRecord(String table, int recordId) async {
    if (recordId <= 0) return null;
    final rows = await _db.query(
      _uuidMappingTable,
      columns: const ['uuid'],
      where: 'table_name = ? AND record_id = ?',
      whereArgs: [table, recordId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['uuid'];
    final uuid = raw?.toString().trim() ?? '';
    return uuid.isEmpty ? null : uuid;
  }

  Future<String?> _getUuidForSyncKey(
      String table, String device, int local) async {
    if (local <= 0) return null;
    final rows = await _db.query(
      _uuidMappingTable,
      columns: const ['uuid'],
      where:
          'table_name = ? AND account_id = ? AND device_id = ? AND local_sync_id = ?',
      whereArgs: [table, accountId, device, local],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['uuid'];
    final uuid = raw?.toString().trim() ?? '';
    return uuid.isEmpty ? null : uuid;
  }

  Future<void> _saveUuidMapping({
    required String table,
    required int recordId,
    required String uuid,
    required String device,
    required int local,
  }) async {
    if (uuid.trim().isEmpty || recordId <= 0) return;
    final normalizedDevice = _normalizeDeviceId(device);
    final normalizedUuid = uuid.trim();
    final now = DateTime.now().toIso8601String();
    await _db.insert(
      _uuidMappingTable,
      {
        'table_name': table,
        'record_id': recordId,
        'account_id': accountId,
        'device_id': normalizedDevice,
        'local_sync_id': local,
        'uuid': normalizedUuid,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<_RowIdentity?> _loadRowIdentity(
    String table,
    int recordId, {
    String? device,
    int? local,
  }) async {
    if (recordId <= 0) return null;

    String resolvedDevice = _normalizeDeviceId(device);
    int? resolvedLocal = local;

    if (resolvedLocal == null || resolvedLocal <= 0 || device == null) {
      final cols = await _getLocalColumns(table);
      final deviceCol =
          device == null ? _col(cols, 'deviceId', 'device_id') : null;
      final localCol = (resolvedLocal == null || resolvedLocal <= 0)
          ? _col(cols, 'localId', 'local_id')
          : null;

      final queryCols = <String>[];
      if (deviceCol != null) queryCols.add(deviceCol);
      if (localCol != null) queryCols.add(localCol);

      if (queryCols.isNotEmpty) {
        final res = await _db.query(
          table,
          columns: queryCols,
          where: 'id = ?',
          whereArgs: [recordId],
          limit: 1,
        );
        if (res.isNotEmpty) {
          final row = res.first;
          if (deviceCol != null) {
            final dv = row[deviceCol]?.toString();
            if (dv != null && dv.trim().isNotEmpty) {
              resolvedDevice = _normalizeDeviceId(dv);
            }
          }
          if (localCol != null) {
            final li = row[localCol];
            final parsed =
                (li is num) ? li.toInt() : int.tryParse('${li ?? ''}');
            if (parsed != null && parsed > 0) {
              resolvedLocal = parsed;
            }
          }
        }
      }
    }

    final int safeLocal =
        (resolvedLocal != null && resolvedLocal > 0) ? resolvedLocal : recordId;
    return _RowIdentity(
      deviceId: resolvedDevice,
      localId: safeLocal,
      recordId: recordId,
    );
  }

  Future<String?> _ensureUuidForRecord({
    required String table,
    required int recordId,
    String? device,
    int? local,
  }) async {
    if (recordId <= 0) return null;

    final existing = await _getUuidForRecord(table, recordId);
    if (existing != null) return existing;

    final identity =
        await _loadRowIdentity(table, recordId, device: device, local: local);
    if (identity == null) return null;

    final cached =
        await _getUuidForSyncKey(table, identity.deviceId, identity.localId);
    final uuid = cached ??
        _uuidGen.v5(
          Namespace.url.value,
          _uuidKey(table, identity.deviceId, identity.localId),
        );

    await _saveUuidMapping(
      table: table,
      recordId: identity.recordId,
      uuid: uuid,
      device: identity.deviceId,
      local: identity.localId,
    );
    return uuid;
  }

  Future<void> _deleteUuidMapping({
    required String table,
    int? recordId,
    String? uuid,
  }) async {
    final clauses = <String>['table_name = ?'];
    final args = <Object?>[table];
    if (recordId != null) {
      clauses.add('record_id = ?');
      args.add(recordId);
    }
    if (uuid != null && uuid.trim().isNotEmpty) {
      clauses.add('uuid = ?');
      args.add(uuid.trim());
    }
    if (clauses.length == 1) return;
    await _db.delete(
      _uuidMappingTable,
      where: clauses.join(' AND '),
      whereArgs: args,
    );
  }

  Future<String?> _uuidForLocalForeignKey(
      String table, dynamic rawValue) async {
    if (rawValue == null) return null;
    final str = rawValue.toString().trim();
    if (_looksLikeUuid(str)) {
      return str;
    }
    final int? recordId =
        (rawValue is num) ? rawValue.toInt() : int.tryParse(str);
    if (recordId == null || recordId <= 0) return null;
    return _ensureUuidForRecord(table: table, recordId: recordId);
  }

  /*──────────────────── أدوات مساعدة ────────────────────*/

  // يختار اسم العمود المتاح محليًا (camel أو snake)
  String? _col(Set<String> cols, String camel, String snake) =>
      cols.contains(camel) ? camel : (cols.contains(snake) ? snake : null);

  Future<Set<String>> _getLocalColumns(String table) async {
    if (_localColsCache.containsKey(table)) return _localColsCache[table]!;
    final rows = await _db.rawQuery("PRAGMA table_info($table)");
    final cols = rows.map((r) => (r['name'] as String)).toSet();
    _localColsCache[table] = cols;
    final types = <String, String>{};
    for (final r in rows) {
      final name = (r['name'] as String);
      final type = (r['type'] ?? '').toString().toUpperCase();
      types[name] = type;
    }
    _localColTypeCache[table] = types;
    return cols;
  }

  Future<String?> _getLocalColumnType(String table, String column) async {
    if (!_localColTypeCache.containsKey(table)) {
      await _getLocalColumns(table);
    }
    return _localColTypeCache[table]?[column];
  }

  Future<_LocalSyncTriple?> _readLocalSyncTriple({
    required String table,
    required int localPrimaryId,
  }) async {
    if (localPrimaryId <= 0) return null;
    final cols = await _getLocalColumns(table);
    final accCol = _col(cols, 'accountId', 'account_id');
    final devCol = _col(cols, 'deviceId', 'device_id');
    final locCol = _col(cols, 'localId', 'local_id');
    final wanted = <String>{};
    if (accCol != null) wanted.add(accCol);
    if (devCol != null) wanted.add(devCol);
    if (locCol != null) wanted.add(locCol);
    final rows = await _db.query(
      table,
      columns: wanted.isEmpty ? null : wanted.toList(),
      where: 'id = ?',
      whereArgs: [localPrimaryId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final accVal = accCol != null ? '${row[accCol] ?? ''}'.trim() : accountId;
    final devVal =
        devCol != null ? '${row[devCol] ?? ''}'.trim() : _safeDeviceId;
    final locVal = locCol != null ? row[locCol] : null;
    final resolvedLocalId = locVal is num
        ? locVal.toInt()
        : int.tryParse('${locVal ?? ''}') ?? localPrimaryId;
    final acc = accVal.isEmpty ? accountId : accVal;
    final dev = devVal.isEmpty ? _safeDeviceId : devVal;
    return _LocalSyncTriple(
        accountId: acc, deviceId: dev, localId: resolvedLocalId);
  }

  Future<int?> _findLocalRowIdByTriple({
    required String table,
    required String accountIdForRow,
    required String deviceIdForRow,
    required int remoteLocalId,
  }) async {
    if (remoteLocalId <= 0) return null;
    final cols = await _getLocalColumns(table);
    final accCol = _col(cols, 'accountId', 'account_id');
    final devCol = _col(cols, 'deviceId', 'device_id');
    final locCol = _col(cols, 'localId', 'local_id');
    if (accCol == null || devCol == null || locCol == null) return null;
    final rows = await _db.query(
      table,
      columns: const ['id'],
      where: '$accCol = ? AND $devCol = ? AND $locCol = ?',
      whereArgs: [accountIdForRow, deviceIdForRow, remoteLocalId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['id'];
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}');
  }

  String _toSnake(String key) {
    if (key.contains('_')) return key;
    final sb = StringBuffer();
    for (int i = 0; i < key.length; i++) {
      final c = key[i];
      final isLetter = c.toLowerCase() != c.toUpperCase();
      if (i > 0 && isLetter && c.toUpperCase() == c) sb.write('_');
      sb.write(c.toLowerCase());
    }
    return sb.toString();
  }

  String _toCamel(String key) {
    if (!key.contains('_')) return key;
    final parts = key.split('_');
    if (parts.isEmpty) return key;
    final head = parts.first;
    final tail = parts
        .skip(1)
        .map((p) => p.isEmpty ? '' : (p[0].toUpperCase() + p.substring(1)))
        .join();
    return head + tail;
  }

  Map<String, dynamic> _mapKeysToSnake(Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    data.forEach((k, v) {
      if (_reservedCols.contains(k)) {
        out[k] = v;
      } else {
        out[_toSnake(k)] = v;
      }
    });
    return out;
  }

  bool _looksLikeUuid(String? value) {
    if (value == null) return false;
    final s = value.trim();
    if (s.length != 36) return false;
    const hyphenPositions = {8, 13, 18, 23};
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (hyphenPositions.contains(i)) {
        if (c != '-') return false;
      } else {
        final code = c.codeUnitAt(0);
        final isDigit = code >= 48 && code <= 57;
        final isUpperHex = code >= 65 && code <= 70;
        final isLowerHex = code >= 97 && code <= 102;
        if (!(isDigit || isUpperHex || isLowerHex)) return false;
      }
    }
    return true;
  }

  Future<void> _ensureFkMappingStore() async {
    if (_fkMappingTableEnsured) return;
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS sync_fk_mapping (
        table_name TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        remote_id TEXT NOT NULL,
        remote_device_id TEXT,
        remote_local_id INTEGER,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (table_name, local_id)
      )
    ''');
    await _db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_fk_mapping_table_remote '
      'ON sync_fk_mapping(table_name, remote_id)',
    );
    _fkMappingTableEnsured = true;
  }

  Future<void> _cacheRemoteMapping(
    String table, {
    required int localPk,
    required String remoteId,
    String? remoteDeviceId,
    int? remoteLocalId,
  }) async {
    if (remoteId.trim().isEmpty) return;
    await _ensureFkMappingStore();
    final now = DateTime.now().toIso8601String();
    await _db.insert(
      'sync_fk_mapping',
      {
        'table_name': table,
        'local_id': localPk,
        'remote_id': remoteId,
        'remote_device_id': remoteDeviceId,
        'remote_local_id': remoteLocalId,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _fkRemoteIdCache.putIfAbsent(table, () => {})[localPk] = remoteId;
    _fkRemoteReverseCache.putIfAbsent(table, () => {})[remoteId] = localPk;
  }

  Future<String?> _resolveRemoteIdForLocal(String table, int localPk) async {
    if (localPk <= 0) return null;
    final cached = _fkRemoteIdCache[table]?[localPk];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    await _ensureFkMappingStore();
    final rows = await _db.query(
      'sync_fk_mapping',
      columns: const ['remote_id'],
      where: 'table_name = ? AND local_id = ?',
      whereArgs: [table, localPk],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final remoteId = (rows.first['remote_id'] ?? '').toString();
      if (remoteId.isNotEmpty) {
        _fkRemoteIdCache.putIfAbsent(table, () => {})[localPk] = remoteId;
        _fkRemoteReverseCache.putIfAbsent(table, () => {})[remoteId] = localPk;
        return remoteId;
      }
    }

    if (!_hasAccount) return null;
    return await _fetchRemoteIdFromCloud(table, localPk);
  }

  Future<int?> _resolveLocalPkForRemoteId(String table, String remoteId) async {
    if (remoteId.trim().isEmpty) return null;
    final tableCache = _fkRemoteReverseCache[table];
    if (tableCache != null) {
      final cachedLocal = tableCache[remoteId];
      if (cachedLocal != null) return cachedLocal;
    }

    await _ensureFkMappingStore();
    final rows = await _db.query(
      'sync_fk_mapping',
      columns: const ['local_id'],
      where: 'table_name = ? AND remote_id = ?',
      whereArgs: [table, remoteId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final int localPk = (rows.first['local_id'] as num).toInt();
      _fkRemoteReverseCache.putIfAbsent(table, () => {})[remoteId] = localPk;
      _fkRemoteIdCache.putIfAbsent(table, () => {})[localPk] = remoteId;
      return localPk;
    }

    if (!_hasAccount) return null;
    try {
      final query = '''
        query ResolveLocalPk(\$accountId: uuid!, \$id: uuid!) {
          $table(where: {account_id: {_eq: \$accountId}, id: {_eq: \$id}}, limit: 1) {
            device_id
            local_id
          }
        }
      ''';
      final data = await _withRetry(() async {
        return await _runQuery(
          query,
          {'accountId': accountId, 'id': remoteId},
        );
      });
      final remoteRows = (data[table] as List?) ?? const [];
      if (remoteRows.isEmpty) return null;
      final remote = Map<String, dynamic>.from(remoteRows.first as Map);
      final String deviceId = (remote['device_id'] ?? '').toString();
      final dynamic localDyn = remote['local_id'];
      final int? remoteLocal = localDyn is num
          ? localDyn.toInt()
          : int.tryParse('${localDyn ?? ''}');
      if (remoteLocal == null) return null;
      int? localPk = await _lookupLocalPkFromMeta(table, deviceId, remoteLocal);
      localPk ??= await _findLocalIdByRawFk(table, remoteLocal);
      if (localPk != null) {
        await _cacheRemoteMapping(
          table,
          localPk: localPk,
          remoteId: remoteId,
          remoteDeviceId: deviceId,
          remoteLocalId: remoteLocal,
        );
        return localPk;
      }
    } catch (e) {
      _log('resolve local pk failed for $table → $remoteId: $e');
    }
    return null;
  }

  Future<String?> _fetchRemoteIdFromCloud(String table, int localPk) async {
    try {
      final cols = await _getLocalColumns(table);
      final devCol = _col(cols, 'deviceId', 'device_id');
      final locCol = _col(cols, 'localId', 'local_id');

      String deviceId = '';
      int? rawLocal;

      final rows = await _db.query(
        table,
        columns: [if (devCol != null) devCol, if (locCol != null) locCol],
        where: 'id = ?',
        whereArgs: [localPk],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final row = rows.first;
        if (devCol != null) {
          deviceId = (row[devCol] ?? '').toString().trim();
        }
        if (locCol != null) {
          final dynamic locVal = row[locCol];
          rawLocal =
              locVal is num ? locVal.toInt() : int.tryParse('${locVal ?? ''}');
        }
      }

      if (deviceId.isEmpty) {
        deviceId = _safeDeviceId;
      }
      rawLocal ??= (localPk > 0 && localPk < _composeBlock) ? localPk : null;

      if (rawLocal == null) return null;

      final query = '''
        query ResolveRemoteId(\$accountId: uuid!, \$deviceId: String!, \$localId: bigint!) {
          $table(
            where: {
              account_id: {_eq: \$accountId},
              device_id: {_eq: \$deviceId},
              local_id: {_eq: \$localId}
            },
            limit: 1
          ) {
            id
          }
        }
      ''';
      final data = await _withRetry(() async {
        return await _runQuery(
          query,
          {'accountId': accountId, 'deviceId': deviceId, 'localId': rawLocal},
        );
      });
      final remoteRows = (data[table] as List?) ?? const [];
      if (remoteRows.isEmpty) return null;
      final remote = Map<String, dynamic>.from(remoteRows.first as Map);
      final remoteId = (remote['id'] ?? '').toString();
      if (remoteId.isEmpty) return null;

      await _cacheRemoteMapping(
        table,
        localPk: localPk,
        remoteId: remoteId,
        remoteDeviceId: deviceId,
        remoteLocalId: rawLocal,
      );
      return remoteId;
    } catch (e) {
      _log('fetch remote id failed for $table#$localPk: $e');
      return null;
    }
  }

  Future<int?> _lookupLocalPkFromMeta(
    String table,
    String deviceId,
    int remoteLocalId,
  ) async {
    final cols = await _getLocalColumns(table);
    final devCol = _col(cols, 'deviceId', 'device_id');
    final locCol = _col(cols, 'localId', 'local_id');
    if (locCol == null) return null;

    final clauses = <String>[];
    final args = <Object?>[];

    clauses.add('IFNULL($locCol,0)=?');
    args.add(remoteLocalId);

    if (devCol != null) {
      clauses.add('IFNULL($devCol,"")=?');
      args.add(deviceId);
    }

    final rows = await _db.query(
      table,
      columns: const ['id'],
      where: clauses.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['id'] as num).toInt();
  }

  Future<void> _ensureChunkRemoteMappings(
    String table,
    List<Map<String, dynamic>> metaChunk,
  ) async {
    for (final meta in metaChunk) {
      final int? localPk = meta['pk'] as int?;
      if (localPk == null) continue;
      await _resolveRemoteIdForLocal(table, localPk);
    }
  }

  Future<void> _cacheRemoteIdsFromResponse(
    String table,
    List<dynamic> responseRows,
    List<Map<String, dynamic>> metaChunk,
  ) async {
    if (responseRows.isEmpty) return;
    final pkByDeviceLocal = <String, int>{};
    for (final meta in metaChunk) {
      final int? pk = meta['pk'] as int?;
      final int? localId = meta['localId'] as int?;
      final String deviceId = (meta['deviceId'] ?? '').toString();
      if (pk != null && localId != null) {
        pkByDeviceLocal['$deviceId::$localId'] = pk;
      }
    }

    for (var i = 0; i < responseRows.length; i++) {
      final dynamic row = responseRows[i];
      if (row is! Map<String, dynamic>) continue;
      final String remoteId = (row['id'] ?? '').toString();
      if (remoteId.isEmpty) continue;
      final String deviceId = (row['device_id'] ?? '').toString();
      final dynamic localDyn = row['local_id'];
      final int? remoteLocal = localDyn is num
          ? localDyn.toInt()
          : int.tryParse('${localDyn ?? ''}');

      int? localPk;
      if (remoteLocal != null) {
        localPk = pkByDeviceLocal['$deviceId::$remoteLocal'];
      }
      localPk ??= i < metaChunk.length ? metaChunk[i]['pk'] as int? : null;
      if (localPk == null && remoteLocal != null) {
        localPk = await _lookupLocalPkFromMeta(table, deviceId, remoteLocal);
        localPk ??= await _findLocalIdByRawFk(table, remoteLocal);
      }

      if (localPk != null) {
        await _cacheRemoteMapping(
          table,
          localPk: localPk,
          remoteId: remoteId,
          remoteDeviceId: deviceId,
          remoteLocalId: remoteLocal,
        );
      }
    }
  }

  Future<String?> _mapLocalFkToRemote({
    required String parentLocalTable,
    required dynamic rawValue,
  }) async {
    if (rawValue == null) return null;
    if (rawValue is String) {
      final trimmed = rawValue.trim();
      if (_looksLikeUuid(trimmed)) {
        return trimmed;
      }
    }

    final int? localPk =
        rawValue is num ? rawValue.toInt() : int.tryParse(rawValue.toString());
    if (localPk == null || localPk <= 0) return null;
    return await _resolveRemoteIdForLocal(parentLocalTable, localPk);
  }

  Future<void> _remapOutgoingForeignKeys(
    String remoteTable,
    List<Map<String, dynamic>> rows, {
    List<String>? errors,
  }) async {
    final fkParentTables = _fkMap[remoteTable];
    if (fkParentTables == null || fkParentTables.isEmpty) return;

    for (final row in rows) {
      for (final entry in fkParentTables.entries) {
        final fkSnake = entry.key;
        if (!row.containsKey(fkSnake)) continue;
        final originalValue = row[fkSnake];
        final remoteId = await _mapLocalFkToRemote(
          parentLocalTable: entry.value,
          rawValue: originalValue,
        );
        if (remoteId == null && originalValue != null) {
          errors?.add(
            'FK $remoteTable.${entry.key} -> ${entry.value} (value=$originalValue)',
          );
        }
        row[fkSnake] = remoteId;
      }
    }
  }

  String _buildSelectClause(
    Set<String> allowedCols, {
    Iterable<String> extraCols = const [],
    Set<String>? remoteAllowed,
  }) {
    final allowSnake = <String>{};
    for (final col in allowedCols) {
      final snake = _toSnake(col).trim();
      if (snake.isNotEmpty) allowSnake.add(snake);
    }
    for (final col in extraCols) {
      final snake = _toSnake(col).trim();
      if (snake.isNotEmpty) allowSnake.add(snake);
    }

    final cols = <String>{};
    for (final col in allowSnake) {
      if (col.isEmpty) continue;
      if (_reservedCols.contains(col)) continue; // ستُضاف لاحقًا
      if (remoteAllowed != null && !remoteAllowed.contains(col)) continue;
      cols.add(col);
    }

    cols.addAll(_reservedCols);
    cols.add('id');

    if (remoteAllowed != null) {
      cols.retainWhere((c) =>
          _reservedCols.contains(c) || remoteAllowed.contains(c) || c == 'id');
    }

    cols.removeWhere((element) => element.trim().isEmpty);
    if (cols.isEmpty) {
      cols.addAll(_reservedCols);
      cols.add('id');
    }
    return cols.join(' ');
  }

  String _formatGqlError(OperationException error) {
    if (error.graphqlErrors.isNotEmpty) {
      return error.graphqlErrors.map((e) => e.message).join(' | ');
    }
    return error.toString();
  }

  bool _isUniqueViolation(OperationException error, List<String> hints) {
    final text = _formatGqlError(error).toLowerCase();
    if (!text.contains('duplicate') && !text.contains('unique')) {
      return false;
    }
    for (final hint in hints) {
      if (text.contains(hint.toLowerCase())) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> _runQuery(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _client.query(
      QueryOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _runMutation(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _client.mutate(
      MutationOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  Stream<QueryResult> _runSubscription(
    String doc,
    Map<String, dynamic> variables,
  ) {
    return _client.subscribe(
      SubscriptionOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
  }

  String _compositeConstraintName(String table) {
    final explicit = _syncConstraints[table];
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    final fallback = '${table}_account_id_device_id_local_id_key';
    _log('Using fallback constraint name for $table -> $fallback');
    return fallback;
  }

  String _insertFieldName(String table) => 'insert_$table';

  String _updateFieldName(String table) => 'update_$table';

  String _deleteFieldName(String table) => 'delete_$table';

  Set<String> _updateColumnsForTable(String table) {
    final allowed = _remoteAllow[table] ?? <String>{};
    final cols = <String>{...allowed, 'updated_at'};
    cols.remove('account_id');
    cols.remove('device_id');
    cols.remove('local_id');
    cols.remove('id');
    return cols;
  }

  Future<List<Map<String, dynamic>>> _upsertRemoteRows(
    String table,
    List<Map<String, dynamic>> objects,
  ) async {
    final updateCols = _updateColumnsForTable(table);
    final safeUpdateCols =
        updateCols.isEmpty ? const <String>{'updated_at'} : updateCols;
    final updateClause = safeUpdateCols.join(', ');
    final mutation = '''
      mutation Upsert(\$objects: [${table}_insert_input!]!) {
        ${_insertFieldName(table)}(
          objects: \$objects,
          on_conflict: {
            constraint: ${_compositeConstraintName(table)},
            update_columns: [$updateClause]
          }
        ) {
          returning { id device_id local_id }
        }
      }
    ''';
    final data = await _runMutation(mutation, {'objects': objects});
    final payload = data[_insertFieldName(table)] as Map?;
    final rows = (payload?['returning'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<int> _updateRemoteWhere(
    String table, {
    required Map<String, dynamic> where,
    required Map<String, dynamic> set,
  }) async {
    final mutation = '''
      mutation UpdateRows(\$where: ${table}_bool_exp!, \$_set: ${table}_set_input!) {
        ${_updateFieldName(table)}(where: \$where, _set: \$_set) {
          affected_rows
        }
      }
    ''';
    final data = await _runMutation(mutation, {'where': where, '_set': set});
    final payload = data[_updateFieldName(table)] as Map?;
    return (payload?['affected_rows'] as num?)?.toInt() ?? 0;
  }

  Future<int> _deleteRemoteWhere(
    String table, {
    required Map<String, dynamic> where,
  }) async {
    final mutation = '''
      mutation DeleteRows(\$where: ${table}_bool_exp!) {
        ${_deleteFieldName(table)}(where: \$where) {
          affected_rows
        }
      }
    ''';
    final data = await _runMutation(mutation, {'where': where});
    final payload = data[_deleteFieldName(table)] as Map?;
    return (payload?['affected_rows'] as num?)?.toInt() ?? 0;
  }

  dynamic _toRemoteValue(String table, String snakeKey, dynamic value) {
    final boolCols = _remoteBooleanCols[table];
    if (boolCols != null && boolCols.contains(snakeKey)) {
      if (value == null) return null;
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final s = value.trim().toLowerCase();
        return (s == '1' || s == 'true' || s == 't' || s == 'yes');
      }
    }
    return value;
  }

  dynamic _toLocalValue(String table, String key, dynamic value) {
    if (value is bool) return value ? 1 : 0; // sqflite بلا bool
    return value;
  }

  int _hash32(String s) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < s.length; i++) {
      hash ^= s.codeUnitAt(i);
      hash = (hash * 16777619) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  int _composeCrossDeviceId(String remoteDeviceId, int remoteLocalId) {
    final h = _hash32(remoteDeviceId); // 31-bit
    return h * _composeBlock + remoteLocalId;
  }

  /// توليد localId عشوائي (1..1e9-1) مع تحقّق تصادُم بسيط داخل الجدول/الجهاز الحالي.
  /// ✅ يدعم camelCase و snake_case تلقائيًا ولا يحتاج لمعرفة مسبقة بأسماء الأعمدة.
  Future<int> _newLocalId31(
    String table, {
    required String myDeviceId,
  }) async {
    final cols = await _getLocalColumns(table);
    final locCol = cols.contains('local_id')
        ? 'local_id'
        : (cols.contains('localId') ? 'localId' : null);
    final devCol = cols.contains('device_id')
        ? 'device_id'
        : (cols.contains('deviceId') ? 'deviceId' : null);

    final rng = Random.secure();
    for (int i = 0; i < 20; i++) {
      final candidate =
          1 + rng.nextInt(_composeBlock - 2); // 1.._composeBlock-1

      if (locCol == null) {
        // لو ما في عمود local_id محليًا، ارجع المرشح مباشرة (لن نكتبه أصلاً لاحقًا).
        return candidate;
      }

      List<Map<String, Object?>> rows;
      if (devCol != null) {
        rows = await _db.query(
          table,
          columns: const ['id'],
          where: 'IFNULL($locCol,0)=? AND IFNULL($devCol,"")=?',
          whereArgs: [candidate, myDeviceId],
          limit: 1,
        );
      } else {
        rows = await _db.query(
          table,
          columns: const ['id'],
          where: 'IFNULL($locCol,0)=?',
          whereArgs: [candidate],
          limit: 1,
        );
      }
      if (rows.isEmpty) return candidate;
    }
    // في أسوأ الأحوال: استخدم جزءًا من الـ timestamp
    final ts = DateTime.now().millisecondsSinceEpoch % (_composeBlock - 1);
    return ts == 0 ? 1 : ts.toInt();
  }

  /// يضمن أن الـ AUTOINCREMENT سيُنتج دائمًا id < 1e9 للصفوف المحلية الجديدة
  Future<void> _clampAutoincrement(String table) async {
    try {
      final r = await _db.rawQuery(
        'SELECT COALESCE(MAX(id),0) AS m FROM $table WHERE id < ?',
        [_composeBlock],
      );
      final maxOwn = (r.isNotEmpty && r.first['m'] != null)
          ? (r.first['m'] as num).toInt()
          : 0;

      // اضبط عدّاد AUTOINCREMENT ليقف عند آخر id محلي (التالي سيكون maxOwn+1)
      await _db.rawQuery(
        'UPDATE sqlite_sequence SET seq = ? WHERE name = ?',
        [maxOwn, table],
      );

      _log('clamp autoinc [$table] -> $maxOwn');
    } catch (e) {
      // الجدول قد لا يكون AUTOINCREMENT أو sqlite_sequence غير موجودة بعد — نتجاهل
      _log('clamp autoinc [$table] skipped: $e');
    }
  }

  /// ⚠️ Upsert محلي غير مُدمِّر:
  /// - يُحدّث الأعمدة الموجودة فقط (لا يلمس الأعمدة غير الممرَّرة).
  /// - إن لم يوجد الصف، يُدرج (IGNORE لتفادي السباقات) ثم يُحدّث.
  Future<void> _upsertLocalNonDestructive(
    String table,
    Map<String, dynamic> row, {
    required int id,
  }) async {
    final updateMap = Map<String, dynamic>.from(row)..remove('id');

    final updated = await _db.update(
      table,
      updateMap,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (updated == 0) {
      // ⬇️ إصلاح هنا: لا يجوز استخدام cascade مع تعيين بواسطة الفهرس.
      final data = Map<String, dynamic>.from(row);
      data['id'] = id;
      await _db.insert(
        table,
        data,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await _db.update(
        table,
        updateMap,
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  /// تنفيذ مع إعادة محاولة Backoff بسيطة (3 محاولات إجمالًا).
  Future<T> _withRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
    Duration firstDelay = const Duration(milliseconds: 350),
  }) async {
    int attempt = 0;
    while (true) {
      try {
        return await action();
      } on OperationException catch (e) {
        attempt++;
        if (attempt >= maxAttempts) rethrow;
        final d = firstDelay * attempt;
        _log(
          'Retry after GraphQL error (attempt $attempt/$maxAttempts): ${_formatGqlError(e)}',
        );
        await Future.delayed(d);
      } catch (e) {
        attempt++;
        if (attempt >= maxAttempts) rethrow;
        final d = firstDelay * attempt;
        _log(
          'Retry after error (attempt $attempt/$maxAttempts): $e',
        );
        await Future.delayed(d);
      }
    }
  }

  /*──────────────────── Push (رفع) ────────────────────*/

  /// كتابة أعمدة التزامن محليًا (إن وُجدت) قبل الدفع — مع **عدم** الكتابة فوق deviceId/localId إن كانت محفوظة.
  Future<void> _stampLocalSyncMeta({
    required String localTable,
    required int localId,
    required String devId,
  }) async {
    final cols = await _getLocalColumns(localTable);

    final hasAnyMeta = [
      'accountId',
      'account_id',
      'deviceId',
      'device_id',
      'localId',
      'local_id',
      'updatedAt',
      'updated_at',
    ].any(cols.contains);

    if (!hasAnyMeta) return;

    // اقرأ القيم الحالية لتجنب الكتابة فوق origin device/local القادمة من pull
    Map<String, Object?>? existing;
    try {
      existing = (await _db.query(
        localTable,
        columns: [
          if (cols.contains('deviceId')) 'deviceId',
          if (cols.contains('device_id')) 'device_id',
          if (cols.contains('localId')) 'localId',
          if (cols.contains('local_id')) 'local_id',
          if (cols.contains('updatedAt')) 'updatedAt',
          if (cols.contains('updated_at')) 'updated_at',
          if (cols.contains('accountId')) 'accountId',
          if (cols.contains('account_id')) 'account_id',
        ],
        where: 'id = ?',
        whereArgs: [localId],
        limit: 1,
      ))
          .firstOrNull;
    } catch (_) {
      existing = null;
    }

    int? currentLocalId;
    String? currentDeviceId;

    if (existing != null) {
      final vDev = existing['deviceId'] ?? existing['device_id'];
      if (vDev != null) {
        final dv = vDev.toString().trim();
        currentDeviceId =
            dv.isEmpty || dv.toLowerCase() == 'app-unknown' ? null : dv;
      }

      final vLoc = existing['localId'] ?? existing['local_id'];
      if (vLoc != null) {
        final li = (vLoc is num) ? vLoc.toInt() : int.tryParse('$vLoc');
        if (li != null && li > 0) currentLocalId = li;
      }
    }

    // حدد deviceId المناسب: أبقِ الموجود إن كان صالحًا وإلا استخدم devId الحالي
    final writeDeviceId = currentDeviceId ?? devId;

    // حدد localId المناسب
    int? writeLocalId = currentLocalId;
    if (writeLocalId == null) {
      if (localId > 0 && localId < _composeBlock) {
        writeLocalId = localId;
      } else {
        writeLocalId = await _newLocalId31(
          localTable,
          myDeviceId: writeDeviceId,
        );
      }
    }

    final row = <String, dynamic>{};
    final accCol = _col(cols, 'accountId', 'account_id');
    final devCol = _col(cols, 'deviceId', 'device_id');
    final locCol = _col(cols, 'localId', 'local_id');
    final updCol = _col(cols, 'updatedAt', 'updated_at');

    if (accCol != null) row[accCol] = accountId;
    if (devCol != null) row[devCol] = writeDeviceId;
    if (locCol != null) row[locCol] = writeLocalId;
    if (updCol != null) row[updCol] = DateTime.now().toIso8601String();

    if (row.isEmpty) return;

    try {
      await _db.update(localTable, row, where: 'id = ?', whereArgs: [localId]);
    } catch (_) {/* صامت */}
  }

  /// تحويل صف محلي إلى صف سحابي (snake_case) + حقن أعمدة التزامن.
  /// ✅ نرسل **أصل السجل** deviceId/localId إن وُجدا محليًا (قادمين من pull) دون استبدال.
  Future<Map<String, dynamic>> _toRemoteRow({
    required String localTable,
    required String remoteTable,
    required Map<String, dynamic> localRow,
  }) async {
    final data = Map<String, dynamic>.from(localRow);

    final dynamic localIdDyn = data['id'];
    int localPk;
    if (localIdDyn is num) {
      localPk = localIdDyn.toInt();
    } else if (localIdDyn != null) {
      localPk = int.tryParse(localIdDyn.toString()) ?? 0;
    } else {
      localPk = 0;
    }

    // fallback لـ localId عند غيابه
    int fallbackLocalId = localPk;
    if (fallbackLocalId <= 0) {
      fallbackLocalId = DateTime.now().millisecondsSinceEpoch % 2147483647;
    }
    if (localPk <= 0) {
      localPk = fallbackLocalId;
    }

    // استخدم أصل السجل إن وُجد (من pull السابق)، وإلا fallback لهذا الجهاز
    final String devForRow = (() {
      final dv = (data['deviceId'] ?? data['device_id'])?.toString().trim();
      return _normalizeDeviceId(dv);
    })();

    final int locForRow = (() {
      final li = data['localId'] ?? data['local_id'];
      if (li is num) return li.toInt();
      if (li == null) return fallbackLocalId;
      return int.tryParse(li.toString()) ?? fallbackLocalId;
    })();

    final uuid = await _ensureUuidForRecord(
          table: remoteTable,
          recordId: localPk,
          device: devForRow,
          local: locForRow,
        ) ??
        _uuidGen.v5(
          Namespace.url.value,
          _uuidKey(remoteTable, devForRow, locForRow),
        );

    await _saveUuidMapping(
      table: remoteTable,
      recordId: localPk,
      uuid: uuid,
      device: devForRow,
      local: locForRow,
    );

    final fkParentMap = _fkMap[remoteTable];
    if (fkParentMap != null && fkParentMap.isNotEmpty) {
      for (final entry in fkParentMap.entries) {
        final fkSnake = entry.key;
        final parentTable = entry.value;
        final fkCamel = _toCamel(fkSnake);

        if (data.containsKey(fkCamel)) {
          data[fkCamel] =
              await _uuidForLocalForeignKey(parentTable, data[fkCamel]);
        } else if (data.containsKey(fkSnake)) {
          data[fkSnake] =
              await _uuidForLocalForeignKey(parentTable, data[fkSnake]);
        }
      }
    }

    // إزالة أعمدة محلية لا نرسلها للسحابة (النسختين camel+snake)
    for (final k in const [
      'id',
      'isDeleted',
      'deletedAt',
      'deviceId',
      'localId',
      'accountId',
      'updatedAt',
      'is_deleted',
      'deleted_at',
      'device_id',
      'local_id',
      'account_id',
      'updated_at',
    ]) {
      data.remove(k);
    }

    // camel->snake (مبدئي)
    var snake = _mapKeysToSnake(data);

    // إن وُجد Mapper مخصص للجدول، طبّقه
    final mapper = _mappers[remoteTable];
    if (mapper?.toCloudMap != null) {
      snake = _mapKeysToSnake(mapper!.toCloudMap!(snake));
    }

    if (fkParentMap != null && fkParentMap.isNotEmpty) {
      for (final entry in fkParentMap.entries) {
        final fkSnake = entry.key;
        if (!snake.containsKey(fkSnake)) continue;
        final rawValue = snake[fkSnake];
        if (rawValue == null) {
          snake[fkSnake] = null;
          continue;
        }

        final int parentLocalId = rawValue is num
            ? rawValue.toInt()
            : int.tryParse('${rawValue}') ?? 0;
        if (parentLocalId <= 0) {
          snake[fkSnake] = null;
          continue;
        }

        final parentTable = entry.value;
        final parentTriple = await _readLocalSyncTriple(
          table: parentTable,
          localPrimaryId: parentLocalId,
        );
        if (parentTriple == null) {
          throw MissingRemoteMappingException(
            remoteTable: remoteTable,
            parentTable: parentTable,
            childColumn: fkSnake,
            parentLocalId: parentLocalId,
            reason: 'parent row missing locally',
          );
        }

        final remoteUuid = await _remoteIds.remoteUuidForLocal(
          tableName: parentTable,
          accountId: parentTriple.accountId,
          deviceId: parentTriple.deviceId,
          localId: parentTriple.localId,
        );

        if (remoteUuid == null || remoteUuid.isEmpty) {
          throw MissingRemoteMappingException(
            remoteTable: remoteTable,
            parentTable: parentTable,
            childColumn: fkSnake,
            parentLocalId: parentLocalId,
            reason: 'remote UUID mapping missing',
          );
        }

        snake[fkSnake] = remoteUuid;
      }
    }

    // فلترة allow-list كمسار احتياطي
    final tableAllow = _remoteAllow[remoteTable];
    if (tableAllow != null && tableAllow.isNotEmpty) {
      snake.removeWhere(
          (k, _) => !_reservedCols.contains(k) && !tableAllow.contains(k));
    }

    // حقول التزامن — نرسل أصل السجل
    snake['id'] = uuid;
    snake['account_id'] = accountId;
    snake['device_id'] = devForRow;
    snake['local_id'] = locForRow;
    snake['updated_at'] = DateTime.now().toIso8601String();

    // تحويل القيم البوليانية
    final normalized = <String, dynamic>{};
    snake.forEach((k, v) {
      normalized[k] = _toRemoteValue(remoteTable, k, v);
    });

    return normalized;
  }

  Future<void> _pushTable(String localTable, String remoteTable) async {
    if (!_hasAccount) {
      _log('PUSH $remoteTable skipped (no accountId)');
      return;
    }
    if (!_hasDevice) {
      _log(
        'PUSH $remoteTable skipped (no deviceId). Set a real deviceId to avoid cross-device conflicts.',
      );
      return;
    }
    while (_pushBusy[remoteTable] == true) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    _pushBusy[remoteTable] = true;
    try {
      // 0) دفع حذف السجلات المعلّمة محليًا
      await _pushDeletedRows(localTable, remoteTable);

      // 1) نرفع الصفوف غير المحذوفة منطقيًا
      final cols = await _getLocalColumns(localTable);
      final hasIsDeletedSnake = cols.contains('is_deleted');
      final hasIsDeletedCamel = cols.contains('isDeleted');
      final delCol = hasIsDeletedSnake
          ? 'is_deleted'
          : (hasIsDeletedCamel ? 'isDeleted' : null);

      final whereClause = delCol != null ? 'IFNULL($delCol,0)=0' : null;

      final localRows = await _db.query(
        localTable,
        where: whereClause,
        whereArgs: null,
      );
      if (localRows.isEmpty) return;

      // وسم أعمدة المزامنة محليًا (إن وُجدت) — دون الكتابة فوق origin device/local
      final devId = _safeDeviceId;
      for (final r in localRows) {
        final int id = (r['id'] as num).toInt();
        await _stampLocalSyncMeta(
            localTable: localTable, localId: id, devId: devId);
      }

      // تجهيز ودفع
      final prepared = <Map<String, dynamic>>[];
      final outgoingMeta = <Map<String, dynamic>>[];
      final fkErrors = <String>[];
      for (final row in localRows) {
        final remoteMap = await _toRemoteRow(
          localTable: localTable,
          remoteTable: remoteTable,
          localRow: row,
        );
        prepared.add(remoteMap);
        final pk = (row['id'] as num).toInt();
        final dynamic localIdDyn = remoteMap['local_id'];
        final meta = <String, dynamic>{
          'pk': pk,
          'deviceId': (remoteMap['device_id'] ?? '').toString(),
          'localId': localIdDyn is num
              ? localIdDyn.toInt()
              : (localIdDyn == null
                  ? null
                  : int.tryParse(localIdDyn.toString())),
        };
        outgoingMeta.add(meta);
      }

      int offset = 0;
      while (offset < prepared.length) {
        final end = offset + _pushChunkSize <= prepared.length
            ? offset + _pushChunkSize
            : prepared.length;
        final chunk = prepared.sublist(offset, end);
        final metaChunk = outgoingMeta.sublist(offset, end);
        offset = end;

        await _remapOutgoingForeignKeys(remoteTable, chunk, errors: fkErrors);

        try {
          _log(
              'PUSH $remoteTable: ${chunk.length} rows (acc=$accountId, dev=$_safeDeviceId)');
          final response = await _withRetry(() async {
            return await _upsertRemoteRows(remoteTable, chunk);
          });
          await _cacheRemoteIdsFromResponse(remoteTable, response, metaChunk);
        } on OperationException catch (e) {
          final bool isNameUniqueConflict = (remoteTable == 'drugs') &&
              _isUniqueViolation(e, const [
                'drugs_unique_name_per_account',
                'uidx_drugs_name_per_account',
                'drugs',
                'name'
              ]);

          if (isNameUniqueConflict) {
            _log(
                'PUSH $remoteTable: unique-name conflict -> merging by (account_id,name)');
            await _mergeByNaturalKey(remoteTable, 'name',
                accountScoped: true, rows: chunk);
            await _ensureChunkRemoteMappings(remoteTable, metaChunk);
            continue;
          }

          final bool isItemsCompositeConflict = (remoteTable == 'items') &&
              _isUniqueViolation(e, const [
                'items_type_name',
                'items',
                'type_id',
                'name'
              ]);

          if (isItemsCompositeConflict) {
            _log(
              'PUSH $remoteTable: composite natural key conflict -> merging by (account_id,type_id,name)',
            );
            await _mergeByCompositeNaturalKeys(
              remoteTable,
              ['type_id', 'name'],
              accountScoped: true,
              rows: chunk,
            );
            await _ensureChunkRemoteMappings(remoteTable, metaChunk);
            continue;
          }

          final bool looksLikeComposite = _isUniqueViolation(e, [
            _compositeConstraintName(remoteTable),
            'account_id',
            'device_id',
            'local_id',
          ]);

          if (looksLikeComposite) {
            _log(
              'PUSH $remoteTable: composite-idx conflict -> fallback UPDATE by (account_id,device_id,local_id)',
            );
            await _fallbackUpdateByComposite(remoteTable, chunk);
            await _ensureChunkRemoteMappings(remoteTable, metaChunk);
            continue;
          }

          _log('PUSH FAILED for $remoteTable: ${_formatGqlError(e)}');
          await _ensureChunkRemoteMappings(remoteTable, metaChunk);
          continue;
        } catch (e) {
          _log('PUSH FAILED for $remoteTable: $e');
          await _ensureChunkRemoteMappings(remoteTable, metaChunk);
          continue;
        }
      }

      if (fkErrors.isNotEmpty) {
        _log(
            'PUSH $remoteTable: ${fkErrors.length} FK mapping errors\n  - ${fkErrors.join('\n  - ')}');
      }
    } finally {
      _pushBusy[remoteTable] = false;
    }
  }

  /// دمج اعتمادًا على مفتاح طبيعي واحد (مثل name) داخل نفس الحساب.
  Future<void> _mergeByNaturalKey(
    String remoteTable,
    String key, {
    required bool accountScoped,
    required List<Map<String, dynamic>> rows,
  }) async {
    for (final row in rows) {
      try {
        final val = (row[key] ?? '').toString();
        if (val.isEmpty) continue;

        final updateMap = Map<String, dynamic>.from(row)
          ..remove('account_id')
          ..remove('device_id')
          ..remove('local_id');

        if (updateMap.isEmpty ||
            (updateMap.keys.length == 1 && updateMap.containsKey(key))) {
          continue;
        }

        final where = accountScoped
            ? {
                'account_id': {'_eq': accountId},
                key: {'_eq': val},
              }
            : {
                key: {'_eq': val},
              };
        await _updateRemoteWhere(
          remoteTable,
          where: where,
          set: updateMap,
        );
      } catch (e) {
        _log('mergeByNaturalKey($remoteTable) failed: $e');
      }
    }
  }

  /// دمج اعتمادًا على عدة مفاتيح طبيعية (مثلاً items: type_id+name) داخل الحساب.
  Future<void> _mergeByCompositeNaturalKeys(
    String remoteTable,
    List<String> keys, {
    required bool accountScoped,
    required List<Map<String, dynamic>> rows,
  }) async {
    for (final row in rows) {
      try {
        // تحقق من وجود كل المفاتيح
        bool hasAll = true;
        for (final k in keys) {
          if ((row[k] ?? '').toString().isEmpty) {
            hasAll = false;
            break;
          }
        }
        if (!hasAll) continue;

        final updateMap = Map<String, dynamic>.from(row)
          ..remove('account_id')
          ..remove('device_id')
          ..remove('local_id');

        // لا معنى للتحديث إذا لم يبق شيء
        for (final k in keys) {
          updateMap.remove(k);
        }
        if (updateMap.isEmpty) continue;

        final where = <String, dynamic>{};
        if (accountScoped) {
          where['account_id'] = {'_eq': accountId};
        }
        for (final k in keys) {
          where[k] = {'_eq': row[k]};
        }
        await _updateRemoteWhere(
          remoteTable,
          where: where,
          set: updateMap,
        );
      } catch (e) {
        _log('mergeByCompositeNaturalKeys($remoteTable) failed: $e');
      }
    }
  }

  /// تراجع عند تعارض الفهرس المركَّب: تحديث الصفوف الموجودة بالمفتاح (account_id,device_id,local_id)
  Future<void> _fallbackUpdateByComposite(
    String remoteTable,
    List<Map<String, dynamic>> rows,
  ) async {
    for (final row in rows) {
      try {
        final acc = (row['account_id'] ?? accountId).toString();
        final dev = (row['device_id'] ?? _safeDeviceId).toString();
        final locDyn = row['local_id'];
        final loc = (locDyn is num)
            ? locDyn.toInt()
            : int.tryParse('${locDyn ?? 0}') ?? 0;

        // حقول التحديث فقط (بدون مفاتيح التعارض)
        final updateMap = Map<String, dynamic>.from(row)
          ..remove('account_id')
          ..remove('device_id')
          ..remove('local_id');

        if (updateMap.isEmpty) {
          // لا يوجد ما يُحدَّث؛ جرّب الإدراج مباشرة
          try {
            await _withRetry(() async {
              await _upsertRemoteRows(remoteTable, [row]);
            });
          } catch (e) {
            _log(
                'fallbackUpdateByComposite[$remoteTable]: insert-only failed: $e');
          }
          continue;
        }

        // 1) UPDATE وقراءة عدد الصفوف المتأثرة
        int updatedCount = 0;
        try {
          updatedCount = await _withRetry(() async {
            return await _updateRemoteWhere(
              remoteTable,
              where: {
                'account_id': {'_eq': acc},
                'device_id': {'_eq': dev},
                'local_id': {'_eq': loc},
              },
              set: updateMap,
            );
          });
        } catch (e) {
          _log('fallbackUpdateByComposite[$remoteTable]: update error → $e');
        }

        // 2) إن لم يوجد سجل لنحدّثه → INSERT كامل
        if (updatedCount == 0) {
          try {
            await _withRetry(() async {
              await _upsertRemoteRows(remoteTable, [row]);
            });
          } on OperationException catch (e) {
            if (_isUniqueViolation(e, const ['account_id', 'device_id', 'local_id'])) {
              try {
                await _updateRemoteWhere(
                  remoteTable,
                  where: {
                    'account_id': {'_eq': acc},
                    'device_id': {'_eq': dev},
                    'local_id': {'_eq': loc},
                  },
                  set: updateMap,
                );
              } catch (_) {/* تجاهل */}
            } else {
              _log(
                  'fallbackUpdateByComposite[$remoteTable]: insert failed: ${_formatGqlError(e)}');
            }
          } catch (e) {
            _log('fallbackUpdateByComposite[$remoteTable]: insert failed: $e');
          }
        }
      } catch (e) {
        _log('fallbackUpdateByComposite[$remoteTable]: failed for one row: $e');
      }
    }
  }

  /// ✅ حذف الصفوف من Nhost التي وُسمت محليًا isDeleted=1 (بغض النظر عن id < 1e9)
  /// الحذف يتم حسب أصل السجل (deviceId/localId) إن وُجدا محليًا.
  Future<void> _pushDeletedRows(String localTable, String remoteTable) async {
    if (!_hasAccount) return;

    final cols = await _getLocalColumns(localTable);
    final hasIsDeletedSnake = cols.contains('is_deleted');
    final hasIsDeletedCamel = cols.contains('isDeleted');
    final delCol = hasIsDeletedSnake
        ? 'is_deleted'
        : (hasIsDeletedCamel ? 'isDeleted' : null);
    if (delCol == null) return; // الجدول لا يدعم الحذف المنطقي محليًا

    final rows = await _db.query(
      localTable,
      columns: [
        'id',
        if (cols.contains('deviceId')) 'deviceId',
        if (cols.contains('device_id')) 'device_id',
        if (cols.contains('localId')) 'localId',
        if (cols.contains('local_id')) 'local_id',
      ],
      where: 'IFNULL($delCol,0)=1',
    );
    if (rows.isEmpty) return;

    for (final r in rows) {
      try {
        final String originDev = (() {
          final dv = (r['deviceId'] ?? r['device_id'])?.toString().trim();
          return (dv != null && dv.isNotEmpty) ? dv : _safeDeviceId;
        })();

        final int originLocal = (() {
          final li = r['localId'] ?? r['local_id'];
          final parsed = (li is num) ? li.toInt() : int.tryParse('${li ?? ''}');
          return parsed ?? (r['id'] as num).toInt();
        })();

        _log(
            'PUSH DELETE $remoteTable: (acc=$accountId, dev=$originDev, local=$originLocal)');
        await _withRetry(() async {
          await _deleteRemoteWhere(
            remoteTable,
            where: {
              'account_id': {'_eq': accountId},
              'device_id': {'_eq': originDev},
              'local_id': {'_eq': originLocal},
            },
          );
        });
        await _deleteUuidMapping(
          table: remoteTable,
          recordId: (r['id'] as num?)?.toInt(),
        );
      } catch (e) {
        _log('PUSH DELETE FAILED for $remoteTable: $e');
      }
    }
  }

  /*──────────────────── Pull (سحب) ────────────────────*/

  /// تطبيق تحويل fromMap على سجل سحابي إلى سجل محلي، مع احترام الأعمدة المتاحة محليًا.
  Map<String, dynamic> _fromRemoteRow({
    required String localTable,
    required String remoteTable,
    required Map<String, dynamic> remoteRowSnake,
    required Set<String> allowedCols,
  }) {
    // مسار Mapper مخصص (يماثل model.fromMap())
    final mapper = _mappers[remoteTable];
    Map<String, dynamic> working = Map<String, dynamic>.from(remoteRowSnake);
    if (mapper?.fromCloudMap != null) {
      working = mapper!.fromCloudMap!(working, allowedCols);
    }

    // تصفية snake/camel + تحويل Bool → 0/1
    final filtered = <String, dynamic>{};
    working.forEach((snakeKey, value) {
      final camelKey = _toCamel(snakeKey);
      if (allowedCols.contains(snakeKey)) {
        filtered[snakeKey] = _toLocalValue(localTable, snakeKey, value);
      } else if (allowedCols.contains(camelKey)) {
        filtered[camelKey] = _toLocalValue(localTable, camelKey, value);
      }
    });
    return filtered;
  }

  Future<void> _pullTable(String localTable, String remoteTable) async {
    if (!_hasAccount) {
      _log('PULL $remoteTable skipped (no accountId)');
      return;
    }

    final allowedCols = await _getLocalColumns(localTable);
    final selectClause = _buildSelectClause(
      allowedCols,
      remoteAllowed: _remoteAllow[remoteTable],
    );

    int from = 0;
    final myDeviceId = _safeDeviceId;

    while (true) {
      List<dynamic> remoteRows;
      try {
        final query = '''
          query PullTable(\$accountId: uuid!, \$limit: Int!, \$offset: Int!) {
            $remoteTable(
              where: {account_id: {_eq: \$accountId}},
              order_by: [{local_id: asc}, {id: asc}],
              limit: \$limit,
              offset: \$offset
            ) {
              $selectClause
            }
          }
        ''';
        final data = await _withRetry(() async {
          return await _runQuery(query, {
            'accountId': accountId,
            'limit': _pullPageSize,
            'offset': from,
          });
        });
        remoteRows = (data[remoteTable] as List?) ?? const [];
      } catch (e) {
        _log('PULL FAILED for $remoteTable: $e');
        break;
      }
      if (remoteRows.isEmpty) break;

      _log('PULL $remoteTable: got ${remoteRows.length} rows');

      for (final dynamic row in remoteRows) {
        final raw = Map<String, dynamic>.from(row);

        final String? remoteUuid = (() {
          final dynamic idVal = raw['id'];
          if (idVal == null) return null;
          final str = idVal.toString().trim();
          return str.isEmpty ? null : str;
        })();

        final dynamic rawLocalId = raw['local_id'];
        final int? rawLocalInt = rawLocalId is num
            ? rawLocalId.toInt()
            : int.tryParse(rawLocalId.toString());
        final int sourceLocalId = rawLocalInt ?? 0;

        final String remoteDeviceIdRaw =
            (raw['device_id'] ?? '').toString().trim();
        final String remoteDeviceId =
            remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;

        final String? remoteUpdatedAt =
            (raw['updated_at'] ?? '').toString().isNotEmpty
                ? raw['updated_at'].toString()
                : null;

        int? localId = await _findLocalRowIdByTriple(
          table: localTable,
          accountIdForRow: accountId,
          deviceIdForRow: remoteDeviceId,
          remoteLocalId: sourceLocalId,
        );

        if (localId == null) {
          localId = sourceLocalId;
          if (remoteDeviceId.isNotEmpty &&
              myDeviceId.isNotEmpty &&
              remoteDeviceId != myDeviceId) {
            localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
          }
        }

        final int resolvedLocalId = localId;

        final String remoteId = remoteUuid ?? '';
        if (remoteId.isNotEmpty && resolvedLocalId > 0) {
          await _cacheRemoteMapping(
            remoteTable,
            localPk: resolvedLocalId,
            remoteId: remoteId,
            remoteDeviceId: remoteDeviceId,
            remoteLocalId: rawLocalInt,
          );
        }

        raw.remove('account_id');
        raw.remove('local_id');
        raw.remove('device_id');
        raw.remove('id');

        final filtered = _fromRemoteRow(
          localTable: localTable,
          remoteTable: remoteTable,
          remoteRowSnake: raw,
          allowedCols: allowedCols,
        );

        final accCol = _col(allowedCols, 'accountId', 'account_id');
        final devCol = _col(allowedCols, 'deviceId', 'device_id');
        final locCol = _col(allowedCols, 'localId', 'local_id');
        final updCol = _col(allowedCols, 'updatedAt', 'updated_at');

        if (accCol != null) filtered[accCol] = accountId;
        if (devCol != null) filtered[devCol] = remoteDeviceId;
        if (locCol != null) {
          filtered[locCol] = rawLocalInt;
        }
        if (updCol != null && remoteUpdatedAt != null) {
          filtered[updCol] = remoteUpdatedAt;
        }

        await _upsertLocalNonDestructive(localTable, filtered,
            id: resolvedLocalId);

        if (remoteUuid != null && remoteUuid.isNotEmpty) {
          final int syncLocal = (rawLocalId is num)
              ? rawLocalId.toInt()
              : int.tryParse('$rawLocalId') ?? resolvedLocalId;
          await _saveUuidMapping(
            table: remoteTable,
            recordId: resolvedLocalId,
            uuid: remoteUuid,
            device: _normalizeDeviceId(remoteDeviceId),
            local: syncLocal,
          );
        }

        DBService.instance.emitPassiveChange(localTable);
      }

      await _clampAutoincrement(localTable);

      from += remoteRows.length;
      if (remoteRows.length < _pullPageSize) break;
    }
  }

  Future<int?> _findLocalIdByRawFk(String parentLocalTable, int rawFk) async {
    final direct = await _db.rawQuery(
      'SELECT id FROM $parentLocalTable WHERE id = ? LIMIT 1',
      [rawFk],
    );
    if (direct.isNotEmpty) return (direct.first['id'] as int);

    final mod = await _db.rawQuery(
      'SELECT id FROM $parentLocalTable WHERE (id % $_composeBlock) = ? LIMIT 1',
      [rawFk],
    );
    if (mod.isNotEmpty) return (mod.first['id'] as int);

    return null;
  }

  Future<dynamic> _remapOneFkValue({
    required String parentLocalTable,
    required String childLocalTable,
    required String childLocalColumnName, // camel أو snake
    required String remoteDeviceIdOfRow,
    required String myDeviceId,
    required dynamic currentValue,
  }) async {
    if (currentValue == null) return null;

    final columnType =
        (await _getLocalColumnType(childLocalTable, childLocalColumnName)) ??
            '';
    final isTextColumn = columnType.contains('TEXT');

    dynamic toLocal(dynamic value) =>
        _toLocalValue(childLocalTable, childLocalColumnName, value);

    final stringValue = currentValue.toString().trim();
    if (stringValue.isEmpty) return null;

    if (_looksLikeUuid(stringValue)) {
      final localPk =
          await _resolveLocalPkForRemoteId(parentLocalTable, stringValue);
      if (localPk != null) {
        return toLocal(isTextColumn ? localPk.toString() : localPk);
      }
      return isTextColumn ? stringValue : null;
    }

    final int? remoteLocalId =
        currentValue is num ? currentValue.toInt() : int.tryParse(stringValue);
    if (remoteLocalId == null || remoteLocalId <= 0) {
      return null;
    }

    int? resolvedLocal =
        await _findLocalIdByRawFk(parentLocalTable, remoteLocalId);

    resolvedLocal ??= await _findLocalRowIdByTriple(
      table: parentLocalTable,
      accountIdForRow: accountId,
      deviceIdForRow: remoteDeviceIdOfRow,
      remoteLocalId: remoteLocalId,
    );

    if (resolvedLocal == null &&
        remoteDeviceIdOfRow.isNotEmpty &&
        myDeviceId.isNotEmpty &&
        remoteDeviceIdOfRow != myDeviceId) {
      resolvedLocal = _composeCrossDeviceId(remoteDeviceIdOfRow, remoteLocalId);
    }

    if (resolvedLocal == null) {
      return null;
    }

    return toLocal(
      isTextColumn ? resolvedLocal.toString() : resolvedLocal,
    );
  }

  Future<void> _pullTableRemapFKs(
    String localTable,
    String remoteTable, {
    required Map<String, String> fkParentTables,
  }) async {
    if (!_hasAccount) {
      _log('PULL $remoteTable skipped (no accountId)');
      return;
    }
    final allowedCols = await _getLocalColumns(localTable);
    final selectClause = _buildSelectClause(
      allowedCols,
      extraCols: fkParentTables.keys,
      remoteAllowed: _remoteAllow[remoteTable],
    );

    int from = 0;
    final myDeviceId = _safeDeviceId;

    while (true) {
      List<dynamic> remoteRows;
      try {
        final query = '''
          query PullTable(\$accountId: uuid!, \$limit: Int!, \$offset: Int!) {
            $remoteTable(
              where: {account_id: {_eq: \$accountId}},
              order_by: [{local_id: asc}, {id: asc}],
              limit: \$limit,
              offset: \$offset
            ) {
              $selectClause
            }
          }
        ''';
        final data = await _withRetry(() async {
          return await _runQuery(query, {
            'accountId': accountId,
            'limit': _pullPageSize,
            'offset': from,
          });
        });
        remoteRows = (data[remoteTable] as List?) ?? const [];
      } catch (e) {
        _log('PULL FAILED for $remoteTable: $e');
        break;
      }
      if (remoteRows.isEmpty) break;

      _log('PULL $remoteTable: got ${remoteRows.length} rows');

      for (final dynamic row in remoteRows) {
        final raw = Map<String, dynamic>.from(row);

        final String? remoteUuid = (() {
          final dynamic idVal = raw['id'];
          if (idVal == null) return null;
          final str = idVal.toString().trim();
          return str.isEmpty ? null : str;
        })();

        // id المحلي للسجل نفسه
        final dynamic rawLocalId = raw['local_id'];
        final int? rawLocalInt = rawLocalId is num
            ? rawLocalId.toInt()
            : int.tryParse(rawLocalId.toString());
        final int sourceLocalId = rawLocalInt ?? 0;

        final String remoteDeviceIdRaw =
            (raw['device_id'] ?? '').toString().trim();
        final String remoteDeviceId =
            remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;

        final String? remoteUpdatedAt =
            (raw['updated_at'] ?? '').toString().isNotEmpty
                ? raw['updated_at'].toString()
                : null;

        int? localId = await _findLocalRowIdByTriple(
          table: localTable,
          accountIdForRow: accountId,
          deviceIdForRow: remoteDeviceId,
          remoteLocalId: sourceLocalId,
        );

        if (localId == null) {
          localId = sourceLocalId;
          if (remoteDeviceId.isNotEmpty &&
              myDeviceId.isNotEmpty &&
              remoteDeviceId != myDeviceId) {
            localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
          }
        }

        final int resolvedLocalId = localId;

        final String remoteId = remoteUuid ?? '';
        if (remoteId.isNotEmpty && resolvedLocalId > 0) {
          await _cacheRemoteMapping(
            remoteTable,
            localPk: resolvedLocalId,
            remoteId: remoteId,
            remoteDeviceId: remoteDeviceId,
            remoteLocalId: rawLocalInt,
          );
        }

        raw.remove('account_id');
        raw.remove('local_id');
        raw.remove('device_id');
        raw.remove('id');

        final filtered = _fromRemoteRow(
          localTable: localTable,
          remoteTable: remoteTable,
          remoteRowSnake: raw,
          allowedCols: allowedCols,
        );

        for (final entry in fkParentTables.entries) {
          final fkSnake = entry.key;
          final parentTable = entry.value;
          final fkCamel = _toCamel(fkSnake);

          if (filtered.containsKey(fkSnake)) {
            filtered[fkSnake] = await _remapOneFkValue(
              parentLocalTable: parentTable,
              childLocalTable: localTable,
              childLocalColumnName: fkSnake,
              remoteDeviceIdOfRow: remoteDeviceId,
              myDeviceId: myDeviceId,
              currentValue: filtered[fkSnake],
            );
          } else if (filtered.containsKey(fkCamel)) {
            filtered[fkCamel] = await _remapOneFkValue(
              parentLocalTable: parentTable,
              childLocalTable: localTable,
              childLocalColumnName: fkCamel,
              remoteDeviceIdOfRow: remoteDeviceId,
              myDeviceId: myDeviceId,
              currentValue: filtered[fkCamel],
            );
          }
        }

        final accCol = _col(allowedCols, 'accountId', 'account_id');
        final devCol = _col(allowedCols, 'deviceId', 'device_id');
        final locCol = _col(allowedCols, 'localId', 'local_id');
        final updCol = _col(allowedCols, 'updatedAt', 'updated_at');

        if (accCol != null) filtered[accCol] = accountId;
        if (devCol != null) filtered[devCol] = remoteDeviceId;
        if (locCol != null) {
          filtered[locCol] = rawLocalInt;
        }
        if (updCol != null && remoteUpdatedAt != null) {
          filtered[updCol] = remoteUpdatedAt;
        }

        await _upsertLocalNonDestructive(localTable, filtered,
            id: resolvedLocalId);

        if (remoteUuid != null && remoteUuid.isNotEmpty) {
          final int syncLocal = (rawLocalId is num)
              ? rawLocalId.toInt()
              : int.tryParse('$rawLocalId') ?? resolvedLocalId;
          await _saveUuidMapping(
            table: remoteTable,
            recordId: resolvedLocalId,
            uuid: remoteUuid,
            device: _normalizeDeviceId(remoteDeviceId),
            local: syncLocal,
          );
        }

        DBService.instance.emitPassiveChange(localTable);
      }

      await _clampAutoincrement(
          localTable); // ← منع قفزة AUTOINCREMENT بعد السحب (FK)

      from += remoteRows.length;
      if (remoteRows.length < _pullPageSize) break;
    }
  }

  /*──────────────────── Realtime (اشتراك لحظي) ────────────────────*/

  final Map<String, StreamSubscription<QueryResult>> _subscriptions = {};
  final Map<String, Map<String, String>> _realtimeRowVersions = {};
  bool _realtimeEnabled = false;
  VoidCallback? _clientListener;

  bool _remoteRowIsDeleted(Map<String, dynamic> row) {
    final v = row.containsKey('is_deleted')
        ? row['is_deleted']
        : row['isDeleted'];
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    return s == '1' || s == 'true';
  }

  Future<void> _handleRealtimeRows(
    String localTable,
    String remoteTable,
    List<dynamic> rows, {
    Map<String, String>? fkParentTables,
  }) async {
    if (rows.isEmpty) return;
    final versions =
        _realtimeRowVersions.putIfAbsent(remoteTable, () => <String, String>{});

    for (final row in rows.whereType<Map>()) {
      final data = Map<String, dynamic>.from(row);
      final id = data['id']?.toString() ?? '';
      final updatedAt = data['updated_at']?.toString() ?? '';
      if (id.isNotEmpty && updatedAt.isNotEmpty) {
        final prev = versions[id];
        if (prev == updatedAt) {
          continue;
        }
        versions[id] = updatedAt;
      }

      if (_remoteRowIsDeleted(data)) {
        await _applyRealtimeDelete(localTable, data);
      } else {
        await _applyRealtimeUpsert(
          localTable,
          remoteTable,
          data,
          fkParentTables,
        );
      }
    }
  }

  Future<void> _subscribeTableRealtime(
    String localTable,
    String remoteTable, {
    Map<String, String>? fkParentTables,
  }) async {
    if (!_hasAccount) return;
    final key = 'rt:$remoteTable:$accountId';

    if (_subscriptions.containsKey(key)) {
      try {
        await _subscriptions[key]!.cancel();
      } catch (_) {}
      _subscriptions.remove(key);
    }

    final allowedCols = await _getLocalColumns(localTable);
    final selectClause = _buildSelectClause(
      allowedCols,
      extraCols: fkParentTables?.keys ?? const [],
      remoteAllowed: _remoteAllow[remoteTable],
    );

    final doc = '''
      subscription SyncTable(\$accountId: uuid!) {
        $remoteTable(where: {account_id: {_eq: \$accountId}}) {
          $selectClause
        }
      }
    ''';

    final sub = _runSubscription(doc, {'accountId': accountId}).listen(
      (result) async {
        if (result.hasException) {
          _log(
              'Realtime subscription error for $remoteTable: ${_formatGqlError(result.exception!)}');
          return;
        }
        final rows = (result.data?[remoteTable] as List?) ?? const [];
        await _handleRealtimeRows(
          localTable,
          remoteTable,
          rows,
          fkParentTables: fkParentTables,
        );
      },
    );

    _subscriptions[key] = sub;
    _log('Realtime subscribed (GraphQL): $remoteTable (acc=$accountId)');
  }

  Future<void> _applyRealtimeUpsert(
    String localTable,
    String remoteTable,
    Map<String, dynamic>? newRecord,
    Map<String, String>? fkParentTables,
  ) async {
    if (newRecord == null || !_hasAccount) return;

    final allowedCols = await _getLocalColumns(localTable);
    final myDeviceId = _safeDeviceId;

    final raw = Map<String, dynamic>.from(newRecord);
    final String? remoteUuid = (() {
      final dynamic idVal = raw['id'];
      if (idVal == null) return null;
      final str = idVal.toString().trim();
      return str.isEmpty ? null : str;
    })();
    final dynamic rawLocalId = raw['local_id'];
    final int? rawLocalInt = rawLocalId is num
        ? rawLocalId.toInt()
        : int.tryParse(rawLocalId.toString());
    final int sourceLocalId = rawLocalInt ?? 0;

    final String remoteDeviceIdRaw = (raw['device_id'] ?? '').toString().trim();
    final String remoteDeviceId =
        remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;

    final String? remoteUpdatedAt =
        (raw['updated_at'] ?? '').toString().isNotEmpty
            ? raw['updated_at'].toString()
            : null;

    int? localId = await _findLocalRowIdByTriple(
      table: localTable,
      accountIdForRow: accountId,
      deviceIdForRow: remoteDeviceId,
      remoteLocalId: sourceLocalId,
    );

    if (localId == null) {
      localId = sourceLocalId;
      if (remoteDeviceId.isNotEmpty &&
          myDeviceId.isNotEmpty &&
          remoteDeviceId != myDeviceId) {
        localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
      }
    }

    final int resolvedLocalId = localId;

    final String remoteId = remoteUuid ?? '';
    if (remoteId.isNotEmpty && resolvedLocalId > 0) {
      await _cacheRemoteMapping(
        remoteTable,
        localPk: resolvedLocalId,
        remoteId: remoteId,
        remoteDeviceId: remoteDeviceId,
        remoteLocalId: rawLocalInt,
      );
    }

    raw.remove('account_id');
    raw.remove('local_id');
    raw.remove('device_id');
    raw.remove('id');

    final filtered = _fromRemoteRow(
      localTable: localTable,
      remoteTable: remoteTable,
      remoteRowSnake: raw,
      allowedCols: allowedCols,
    );

    if (fkParentTables != null) {
      for (final entry in fkParentTables.entries) {
        final fkSnake = entry.key;
        final parentTable = entry.value;
        final fkCamel = _toCamel(fkSnake);

        if (filtered.containsKey(fkSnake)) {
          filtered[fkSnake] = await _remapOneFkValue(
            parentLocalTable: parentTable,
            childLocalTable: localTable,
            childLocalColumnName: fkSnake,
            remoteDeviceIdOfRow: remoteDeviceId,
            myDeviceId: myDeviceId,
            currentValue: filtered[fkSnake],
          );
        } else if (filtered.containsKey(fkCamel)) {
          filtered[fkCamel] = await _remapOneFkValue(
            parentLocalTable: parentTable,
            childLocalTable: localTable,
            childLocalColumnName: fkCamel,
            remoteDeviceIdOfRow: remoteDeviceId,
            myDeviceId: myDeviceId,
            currentValue: filtered[fkCamel],
          );
        }
      }
    }

    final accCol = _col(allowedCols, 'accountId', 'account_id');
    final devCol = _col(allowedCols, 'deviceId', 'device_id');
    final locCol = _col(allowedCols, 'localId', 'local_id');
    final updCol = _col(allowedCols, 'updatedAt', 'updated_at');

    if (accCol != null) filtered[accCol] = accountId;
    if (devCol != null) filtered[devCol] = remoteDeviceId;
    if (locCol != null) {
      filtered[locCol] = rawLocalInt;
    }
    if (updCol != null && remoteUpdatedAt != null) {
      filtered[updCol] = remoteUpdatedAt;
    }

    await _upsertLocalNonDestructive(localTable, filtered, id: resolvedLocalId);

    if (remoteUuid != null && remoteUuid.isNotEmpty) {
      final int syncLocal = (rawLocalId is num)
          ? rawLocalId.toInt()
          : int.tryParse('$rawLocalId') ?? resolvedLocalId;
      await _saveUuidMapping(
        table: remoteTable,
        recordId: resolvedLocalId,
        uuid: remoteUuid,
        device: _normalizeDeviceId(remoteDeviceId),
        local: syncLocal,
      );
    }

    await _clampAutoincrement(
        localTable); // ← منع قفزة AUTOINCREMENT بعد Realtime upsert

    DBService.instance.emitPassiveChange(localTable);
  }

  Future<void> _applyRealtimeDelete(
    String localTable,
    Map<String, dynamic>? oldRecord,
  ) async {
    if (oldRecord == null || !_hasAccount) return;

    final allowedCols = await _getLocalColumns(localTable);
    final myDeviceId = _safeDeviceId;

    final raw = Map<String, dynamic>.from(oldRecord);
    final String? remoteUuid = (() {
      final dynamic idVal = raw['id'];
      if (idVal == null) return null;
      final str = idVal.toString().trim();
      return str.isEmpty ? null : str;
    })();
    final dynamic rawLocalId = raw['local_id'];
    final int sourceLocalId = rawLocalId is num
        ? rawLocalId.toInt()
        : int.tryParse(rawLocalId.toString()) ?? 0;

    final String remoteDeviceIdRaw = (raw['device_id'] ?? '').toString().trim();
    final String remoteDeviceId =
        remoteDeviceIdRaw.isEmpty ? _safeDeviceId : remoteDeviceIdRaw;

    int? localId = await _findLocalRowIdByTriple(
      table: localTable,
      accountIdForRow: accountId,
      deviceIdForRow: remoteDeviceId,
      remoteLocalId: sourceLocalId,
    );

    if (localId == null) {
      localId = sourceLocalId;
      if (remoteDeviceId.isNotEmpty &&
          myDeviceId.isNotEmpty &&
          remoteDeviceId != myDeviceId) {
        localId = _composeCrossDeviceId(remoteDeviceId, sourceLocalId);
      }
    }

    final int resolvedLocalId = localId;

    if (resolvedLocalId <= 0) return;

    // لو الجدول يدعم الحذف المنطقي محليًا، علِّمه محذوفًا، وإلا احذف فعليًا
    if (allowedCols.contains('isDeleted')) {
      await _db.update(
        localTable,
        {
          'isDeleted': 1,
          if (allowedCols.contains('deletedAt'))
            'deletedAt': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [resolvedLocalId],
      );
    } else if (allowedCols.contains('is_deleted')) {
      await _db.update(
        localTable,
        {
          'is_deleted': 1,
          if (allowedCols.contains('deleted_at'))
            'deleted_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [resolvedLocalId],
      );
    } else {
      await _db
          .delete(localTable, where: 'id = ?', whereArgs: [resolvedLocalId]);
    }

    if (remoteUuid != null && remoteUuid.isNotEmpty) {
      await _deleteUuidMapping(
        table: localTable,
        recordId: resolvedLocalId,
        uuid: remoteUuid,
      );
    } else {
      await _deleteUuidMapping(
        table: localTable,
        recordId: resolvedLocalId,
      );
    }
  }

  /// اشترك في كل الجداول (Realtime) لهذا الحساب.
  Future<void> startRealtime() async {
    // ✅ تفادي ازدواج الاشتراكات عند إعادة التهيئة (مثلاً بعد تغيير المستخدم)
    await stopRealtime();
    if (!_hasAccount) {
      _log('Realtime skipped (no accountId)');
      return;
    }

    // لا نُشغّل Realtime للمرفقات (محلي فقط)
    await _subscribeTableRealtime('drugs', 'drugs');
    await _subscribeTableRealtime('item_types', 'item_types');
    await _subscribeTableRealtime(
      'items',
      'items',
      fkParentTables: _fkMap['items'],
    );
    await _subscribeTableRealtime('medical_services', 'medical_services');
    await _subscribeTableRealtime(
      'doctors',
      'doctors',
      fkParentTables: _fkMap['doctors'],
    );
    await _subscribeTableRealtime(
      'service_doctor_share',
      'service_doctor_share',
      fkParentTables: _fkMap['service_doctor_share'],
    );

    await _subscribeTableRealtime(
      'patients',
      'patients',
      fkParentTables: _fkMap['patients'],
    );
    await _subscribeTableRealtime('returns', 'returns');
    await _subscribeTableRealtime(
      'appointments',
      'appointments',
      fkParentTables: _fkMap['appointments'],
    );

    await _subscribeTableRealtime(
      'prescriptions',
      'prescriptions',
      fkParentTables: _fkMap['prescriptions'],
    );
    await _subscribeTableRealtime(
      'prescription_items',
      'prescription_items',
      fkParentTables: _fkMap['prescription_items'],
    );
    await _subscribeTableRealtime('complaints', 'complaints');

    await _subscribeTableRealtime(
      'consumptions',
      'consumptions',
      fkParentTables: _fkMap['consumptions'],
    );
    await _subscribeTableRealtime(
      'purchases',
      'purchases',
      fkParentTables: _fkMap['purchases'],
    );
    await _subscribeTableRealtime(
      'alert_settings',
      'alert_settings',
      fkParentTables: _fkMap['alert_settings'],
    );

    await _subscribeTableRealtime('employees', 'employees');
    await _subscribeTableRealtime(
      'employees_loans',
      'employees_loans',
      fkParentTables: _fkMap['employees_loans'],
    );
    await _subscribeTableRealtime(
      'employees_salaries',
      'employees_salaries',
      fkParentTables: _fkMap['employees_salaries'],
    );
    await _subscribeTableRealtime(
      'employees_discounts',
      'employees_discounts',
      fkParentTables: _fkMap['employees_discounts'],
    );

    await _subscribeTableRealtime('financial_logs', 'financial_logs');
    await _subscribeTableRealtime(
      'patient_services',
      'patient_services',
      fkParentTables: _fkMap['patient_services'],
    );
    _realtimeEnabled = true;
  }

  /// إلغاء جميع الاشتراكات.
  Future<void> stopRealtime() async {
    for (final sub in _subscriptions.values) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    _subscriptions.clear();
    _realtimeRowVersions.clear();
    _realtimeEnabled = false;
    _log('Realtime unsubscribed from all tables');
  }

  /// Bootstrap مريح بعد تسجيل الدخول (سحب أولي + اشتراك لحظي)
  Future<void> bootstrap({bool pull = true, bool realtime = true}) async {
    _log(
        'Bootstrap sync (acc=$accountId, dev=$_safeDeviceId) pull=$pull, rt=$realtime');
    if (!_hasAccount) {
      _log('Bootstrap skipped (no accountId)');
      return;
    }
    if (pull) {
      await pullAll();
    }
    if (realtime) {
      await startRealtime();
    }
  }

  /// إعادة ربط الخدمة عند تغيّر الحساب/الجهاز
  Future<void> rebind({
    required String newAccountId,
    String? newDeviceId,
    bool initialPull = false,
    bool restartRealtime = true,
  }) async {
    final changedAcc = (newAccountId != accountId);
    final changedDev = (newDeviceId != null && newDeviceId != deviceId);

    if (!changedAcc && !changedDev) {
      _log('rebind: nothing changed');
      return;
    }

    _log(
      'rebind → acc: $accountId -> $newAccountId, dev: ${deviceId ?? "null"} -> ${newDeviceId ?? deviceId ?? "null"}',
    );

    // أوقف أي اشتراكات قديمة مربوطة على account_id السابق
    await stopRealtime();

    accountId = newAccountId;
    if (newDeviceId != null) {
      deviceId = newDeviceId;
    }

    if (initialPull) {
      await pullAll();
    }
    if (restartRealtime) {
      await startRealtime();
    }
  }

  /// تنظيف سريع
  Future<void> dispose() async {
    await stopRealtime();
    if (_clientListener != null) {
      NhostGraphqlService.buildNotifier().removeListener(_clientListener!);
      _clientListener = null;
    }
    // أوقف كل مؤقّتات الدفع المؤجّل
    for (final t in _pushTimers.values) {
      t.cancel();
    }
    _pushTimers.clear();
  }

  void _handleClientRefresh() {
    if (!_realtimeEnabled || !_hasAccount) return;
    unawaited(_restartRealtimeForClientRefresh());
  }

  Future<void> _restartRealtimeForClientRefresh() async {
    await stopRealtime();
    await startRealtime();
  }

  /*──────────────────── جداول محددة (واجهات علنية) ───────────────────*/

  Future<void> pushPatients() => _pushTable('patients', 'patients');
  Future<void> pullPatients() => _pullTableRemapFKs(
        'patients',
        'patients',
        fkParentTables: _fkMap['patients']!,
      );

  Future<void> pushReturns() => _pushTable('returns', 'returns');
  Future<void> pullReturns() => _pullTable('returns', 'returns');

  Future<void> pushConsumptions() => _pushTable('consumptions', 'consumptions');
  Future<void> pullConsumptions() => _pullTableRemapFKs(
        'consumptions',
        'consumptions',
        fkParentTables: _fkMap['consumptions']!,
      );

  Future<void> pushDrugs() => _pushTable('drugs', 'drugs');
  Future<void> pullDrugs() => _pullTable('drugs', 'drugs');

  Future<void> pushPrescriptions() =>
      _pushTable('prescriptions', 'prescriptions');
  Future<void> pullPrescriptions() => _pullTableRemapFKs(
        'prescriptions',
        'prescriptions',
        fkParentTables: _fkMap['prescriptions']!,
      );

  Future<void> pushPrescriptionItems() =>
      _pushTable('prescription_items', 'prescription_items');
  Future<void> pullPrescriptionItems() => _pullTableRemapFKs(
        'prescription_items',
        'prescription_items',
        fkParentTables: _fkMap['prescription_items']!,
      );

  Future<void> pushComplaints() => _pushTable('complaints', 'complaints');
  Future<void> pullComplaints() => _pullTable('complaints', 'complaints');

  Future<void> pushAppointments() => _pushTable('appointments', 'appointments');
  Future<void> pullAppointments() => _pullTableRemapFKs(
        'appointments',
        'appointments',
        fkParentTables: _fkMap['appointments']!,
      );

  Future<void> pushDoctors() => _pushTable('doctors', 'doctors');
  Future<void> pullDoctors() => _pullTableRemapFKs(
        'doctors',
        'doctors',
        fkParentTables: _fkMap['doctors']!,
      );

  Future<void> pushConsumptionTypes() =>
      _pushTable('consumption_types', 'consumption_types');
  Future<void> pullConsumptionTypes() =>
      _pullTable('consumption_types', 'consumption_types');

  Future<void> pushMedicalServices() =>
      _pushTable('medical_services', 'medical_services');
  Future<void> pullMedicalServices() =>
      _pullTable('medical_services', 'medical_services');

  Future<void> pushServiceDoctorShares() =>
      _pushTable('service_doctor_share', 'service_doctor_share');
  Future<void> pullServiceDoctorShares() => _pullTableRemapFKs(
        'service_doctor_share',
        'service_doctor_share',
        fkParentTables: _fkMap['service_doctor_share']!,
      );

  Future<void> pushEmployees() => _pushTable('employees', 'employees');
  Future<void> pullEmployees() => _pullTable('employees', 'employees');

  Future<void> pushEmployeeLoans() =>
      _pushTable('employees_loans', 'employees_loans');
  Future<void> pullEmployeeLoans() => _pullTableRemapFKs(
        'employees_loans',
        'employees_loans',
        fkParentTables: _fkMap['employees_loans']!,
      );

  Future<void> pushEmployeeSalaries() =>
      _pushTable('employees_salaries', 'employees_salaries');
  Future<void> pullEmployeeSalaries() => _pullTableRemapFKs(
        'employees_salaries',
        'employees_salaries',
        fkParentTables: _fkMap['employees_salaries']!,
      );

  Future<void> pushEmployeeDiscounts() =>
      _pushTable('employees_discounts', 'employees_discounts');
  Future<void> pullEmployeeDiscounts() => _pullTableRemapFKs(
        'employees_discounts',
        'employees_discounts',
        fkParentTables: _fkMap['employees_discounts']!,
      );

  Future<void> pushItemTypes() => _pushTable('item_types', 'item_types');
  Future<void> pullItemTypes() => _pullTable('item_types', 'item_types');

  Future<void> pushItems() => _pushTable('items', 'items');
  Future<void> pullItems() => _pullTableRemapFKs(
        'items',
        'items',
        fkParentTables: _fkMap['items']!,
      );

  Future<void> pushPurchases() => _pushTable('purchases', 'purchases');
  Future<void> pullPurchases() => _pullTableRemapFKs(
        'purchases',
        'purchases',
        fkParentTables: _fkMap['purchases']!,
      );

  Future<void> pushAlertSettings() =>
      _pushTable('alert_settings', 'alert_settings');
  Future<void> pullAlertSettings() => _pullTableRemapFKs(
        'alert_settings',
        'alert_settings',
        fkParentTables: _fkMap['alert_settings']!,
      );

  Future<void> pushFinancialLogs() =>
      _pushTable('financial_logs', 'financial_logs');
  Future<void> pullFinancialLogs() => _pullTableRemapFKs(
        'financial_logs',
        'financial_logs',
        fkParentTables: _fkMap['financial_logs']!,
      );

  Future<void> pushPatientServices() =>
      _pushTable('patient_services', 'patient_services');
  Future<void> pullPatientServices() => _pullTableRemapFKs(
        'patient_services',
        'patient_services',
        fkParentTables: _fkMap['patient_services']!,
      );

  /*──────────────────── Bulk (مرتَّبة حسب الاعتمادات) ───────────────────*/

  Future<void> pushAll() async {
    // أسس
    await pushItemTypes();
    await pushItems();
    await pushDrugs();
    await pushMedicalServices();
    await pushEmployees();
    await pushDoctors();

    // نسب الأطباء
    await pushServiceDoctorShares();

    // معاملات مرضى
    await pushPatients();
    await pushPatientServices();
    await pushReturns();
    await pushAppointments();
    await pushPrescriptions();
    await pushPrescriptionItems();
    await pushConsumptions();
    await pushPurchases();
    await pushAlertSettings();

    // مالية/موارد بشرية إضافية
    await pushEmployeeLoans();
    await pushEmployeeSalaries();
    await pushEmployeeDiscounts();

    await pushComplaints();
    await pushFinancialLogs();
  }

  Future<void> pullAll() async {
    // أسس
    await pullItemTypes();
    await pullItems();
    await pullDrugs();
    await pullMedicalServices();
    await pullEmployees();
    await pullDoctors();

    // نسب الأطباء
    await pullServiceDoctorShares();

    // معاملات مرضى
    await pullPatients();
    await pullPatientServices();
    await pullReturns();
    await pullAppointments();
    await pullPrescriptions();
    await pullPrescriptionItems();
    await pullConsumptions();
    await pullPurchases();
    await pullAlertSettings();

    // مالية/موارد بشرية إضافية
    await pullEmployeeLoans();
    await pullEmployeeSalaries();
    await pullEmployeeDiscounts();

    await pullComplaints();
    await pullFinancialLogs();
  }

  /*──────────────────── Triggered Push (لـ onLocalChange) ───────────────────*/

  /// جدولة دفع مؤجّل لجدول معيّن. يُدمج عدة تغييرات خلال نافذة pushDebounce.
  Future<void> _schedulePush(String key, Future<void> Function() action) async {
    // ألغِ مؤقّت سابق إن وجد
    _pushTimers[key]?.cancel();
    _pushTimers[key] = Timer(pushDebounce, () async {
      try {
        await action();
      } finally {
        _pushTimers.remove(key);
      }
    });
  }

  Future<void> _pushNow(String table) async {
    switch (table) {
      case 'patients':
        return pushPatients();
      case 'returns':
        return pushReturns();
      case 'consumptions':
        return pushConsumptions();
      case 'drugs':
        return pushDrugs();
      case 'prescriptions':
        return pushPrescriptions();
      case 'prescription_items':
        return pushPrescriptionItems();
      case 'complaints':
        return pushComplaints();
      case 'appointments':
        return pushAppointments();
      case 'doctors':
        return pushDoctors();
      case 'consumption_types':
        return pushConsumptionTypes();
      case 'medical_services':
        return pushMedicalServices();
      case 'service_doctor_share':
        return pushServiceDoctorShares();
      case 'employees':
        return pushEmployees();
      case 'employees_loans':
        return pushEmployeeLoans();
      case 'employees_salaries':
        return pushEmployeeSalaries();
      case 'employees_discounts':
        return pushEmployeeDiscounts();
      case 'items':
        return pushItems();
      case 'item_types':
        return pushItemTypes();
      case 'purchases':
        return pushPurchases();
      case 'alert_settings':
        return pushAlertSettings();
      case 'financial_logs':
        return pushFinancialLogs();
      case 'patient_services':
        return pushPatientServices();
      case 'attachments':
        _log('attachments is local-only. Skipping push.');
        return Future.value();
      default:
        _log('No push handler for table: $table');
        return Future.value();
    }
  }

  /// استدعِ هذه من `DBService.onLocalChange` — ستُجَدول دفعة بعد 1s لكل جدول.
  Future<void> pushFor(String table) async {
    switch (table) {
      case 'attachments':
        _log('attachments is local-only. Skipping push.');
        return;
      default:
        return _schedulePush(table, () => _pushNow(table));
    }
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
