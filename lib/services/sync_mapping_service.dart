import 'dart:async';

import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class LocalSyncRef {
  const LocalSyncRef({
    required this.localId,
    required this.deviceId,
  });

  final int localId;
  final String deviceId;
}

class SyncMappingService {
  SyncMappingService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client;

  final GraphQLClient _gql;
  static const int _maxQueryAttempts = 4;

  static const Set<String> _allowedTables = {
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
  };

  bool _isTransientException(OperationException ex) {
    final msg = ex.toString().toLowerCase();
    return msg.contains('responseformatexception') ||
        msg.contains('formatexception') ||
        msg.contains('unexpected character') ||
        msg.contains('503') ||
        msg.contains('502') ||
        msg.contains('bad gateway') ||
        msg.contains('service temporarily unavailable') ||
        msg.contains('eof') ||
        msg.contains('context deadline exceeded');
  }

  Future<QueryResult> _queryWithRetry(
    QueryOptions options, {
    int maxAttempts = _maxQueryAttempts,
  }) async {
    var attempt = 0;
    while (true) {
      attempt += 1;
      final res = await _gql.query(options);
      if (!res.hasException) return res;
      final ex = res.exception!;
      if (attempt >= maxAttempts || !_isTransientException(ex)) {
        throw ex;
      }
      await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
    }
  }

  Future<String?> resolveRemoteId({
    required String table,
    required String accountId,
    required String deviceId,
    required int localId,
  }) async {
    if (!_allowedTables.contains(table)) return null;
    if (accountId.trim().isEmpty || localId <= 0) return null;
    final refs = [LocalSyncRef(localId: localId, deviceId: deviceId)];
    final res = await mapLocalToRemote(
      table: table,
      accountId: accountId,
      refs: refs,
    );
    return res[localId];
  }

  Future<Map<int, String>> mapLocalToRemote({
    required String table,
    required String accountId,
    required List<LocalSyncRef> refs,
  }) async {
    if (!_allowedTables.contains(table)) return {};
    if (refs.isEmpty || accountId.trim().isEmpty) return {};

    final idsByDevice = <String, List<int>>{};
    for (final ref in refs) {
      if (ref.localId <= 0) continue;
      final device = ref.deviceId.trim().isEmpty ? 'app-unknown' : ref.deviceId;
      idsByDevice.putIfAbsent(device, () => []).add(ref.localId);
    }
    if (idsByDevice.isEmpty) return {};

    final db = await DBService.instance.database;
    final out = <int, String>{};
    final missingByDevice = <String, List<int>>{};

    for (final entry in idsByDevice.entries) {
      final deviceId = entry.key;
      final ids = entry.value;
      if (ids.isEmpty) continue;
      final placeholders = List.filled(ids.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT local_sync_id, uuid FROM sync_uuid_mapping '
        'WHERE table_name = ? AND account_id = ? AND device_id = ? '
        'AND local_sync_id IN ($placeholders)',
        [table, accountId, deviceId, ...ids],
      );
      final mapped = <int>{};
      for (final row in rows) {
        final local = (row['local_sync_id'] as num?)?.toInt() ?? 0;
        final uuid = row['uuid']?.toString() ?? '';
        if (local > 0 && uuid.isNotEmpty) {
          out[local] = uuid;
          mapped.add(local);
        }
      }
      final missing = ids.where((id) => !mapped.contains(id)).toList();
      if (missing.isNotEmpty) {
        missingByDevice[deviceId] = missing;
      }
    }

    if (missingByDevice.isNotEmpty) {
      await _backfillMappings(
        db: db,
        table: table,
        accountId: accountId,
        missingByDevice: missingByDevice,
        output: out,
      );
    }

    return out;
  }

  Future<void> _backfillMappings({
    required Database db,
    required String table,
    required String accountId,
    required Map<String, List<int>> missingByDevice,
    required Map<int, String> output,
  }) async {
    final query = '''
      query BackfillLocal(\$acc: uuid!, \$device: String!, \$ids: [Int!]!) {
        $table(
          where: {
            account_id: { _eq: \$acc },
            device_id: { _eq: \$device },
            local_id: { _in: \$ids }
          }
        ) {
          id
          local_id
          device_id
        }
      }
    ''';

    for (final entry in missingByDevice.entries) {
      final deviceId = entry.key;
      final ids = entry.value;
      if (ids.isEmpty) continue;
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
        final res = await _queryWithRetry(
          QueryOptions(
            document: gql(query),
            variables: {
              'acc': accountId,
              'device': deviceId,
              'ids': chunk,
            },
            fetchPolicy: FetchPolicy.networkOnly,
          ),
        );
        final rows = (res.data?[table] as List?) ?? const [];
        if (rows.isEmpty) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          final localRaw = row['local_id'];
          final localId = (localRaw is num)
              ? localRaw.toInt()
              : int.tryParse('${localRaw ?? ''}') ?? 0;
          final uuid = row['id']?.toString() ?? '';
          final rowDevice = row['device_id']?.toString() ?? '';
          if (localId <= 0 || uuid.isEmpty) continue;
          if (rowDevice.trim().isEmpty || rowDevice.trim() != deviceId) {
            continue;
          }
          output[localId] = uuid;
          await _upsertLocalUuidMapping(
            db: db,
            table: table,
            accountId: accountId,
            deviceId: deviceId,
            localId: localId,
            uuid: uuid,
          );
        }
      }
    }
  }

  Future<void> _upsertLocalUuidMapping({
    required Database db,
    required String table,
    required String accountId,
    required String deviceId,
    required int localId,
    required String uuid,
  }) async {
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'sync_uuid_mapping',
      {
        'table_name': table,
        'record_id': localId,
        'account_id': accountId,
        'device_id': deviceId,
        'local_sync_id': localId,
        'uuid': uuid,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
