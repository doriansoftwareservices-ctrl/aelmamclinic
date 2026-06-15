import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:aelmamclinic/core/sync/clinic_sync_models.dart';
import 'package:aelmamclinic/services/db_service.dart';

class SyncOutboxService {
  const SyncOutboxService();

  static const String tableName = 'clinic_sync_outbox';
  static const String stateTableName = 'clinic_sync_state';
  static const String conflictTableName = 'clinic_sync_conflicts';
  static const String healthEventsTableName = 'clinic_sync_health_events';
  static const int defaultClaimLimit = 25;
  static const _uuid = Uuid();

  Future<String> enqueueLocalMutation({
    required String operationType,
    required String entityTable,
    required String accountId,
    required String deviceId,
    required Map<String, Object?> payload,
    int? entityId,
    String? remoteId,
    int? localId,
    Map<String, Object?>? localReference,
    String? clientMutationId,
  }) async {
    final db = await DBService.instance.database;
    final now = DateTime.now().toIso8601String();
    final id = _uuid.v4();
    final mutationId =
        clientMutationId ??
        _buildClientMutationId(
          accountId: accountId,
          deviceId: deviceId,
          entityTable: entityTable,
          entityId: entityId,
          operationType: operationType,
        );
    await db.insert(tableName, <String, Object?>{
      'id': id,
      'operation_type': operationType,
      'entity_table': entityTable,
      'entity_id': entityId,
      'remote_id': remoteId,
      'client_mutation_id': mutationId,
      'account_id': accountId,
      'device_id': deviceId,
      'local_id': localId,
      'payload_json': jsonEncode(payload),
      'local_reference_json': localReference == null
          ? null
          : jsonEncode(localReference),
      'status': ClinicOutboxStatusCodec.encode(ClinicOutboxStatus.queued),
      'retry_count': 0,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return mutationId;
  }

  Future<List<ClinicOutboxEntry>> claimReadyEntries({
    String? accountId,
    int limit = defaultClaimLimit,
  }) async {
    final db = await DBService.instance.database;
    final now = DateTime.now().toIso8601String();
    final where = StringBuffer(
      "(status = 'queued' OR status = 'failed') "
      "AND (next_retry_at IS NULL OR next_retry_at <= ?)",
    );
    final args = <Object?>[now];
    if (accountId != null && accountId.trim().isNotEmpty) {
      where.write(' AND account_id = ?');
      args.add(accountId.trim());
    }
    final rows = await db.query(
      tableName,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'created_at ASC',
      limit: limit,
    );
    if (rows.isEmpty) return const <ClinicOutboxEntry>[];

    final claimTime = DateTime.now().toIso8601String();
    final claimed = <ClinicOutboxEntry>[];
    await db.transaction((txn) async {
      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final updated = await txn.update(
          tableName,
          <String, Object?>{
            'status': 'in_flight',
            'locked_at': claimTime,
            'last_attempt_at': claimTime,
            'updated_at': claimTime,
          },
          where:
              "id = ? AND (status = 'queued' OR status = 'failed') AND "
              "(next_retry_at IS NULL OR next_retry_at <= ?)",
          whereArgs: <Object?>[id, claimTime],
        );
        if (updated > 0) {
          final claimedRows = await txn.query(
            tableName,
            where: 'id = ?',
            whereArgs: <Object?>[id],
            limit: 1,
          );
          if (claimedRows.isNotEmpty) {
            claimed.add(_entryFromRow(claimedRows.first));
          }
        }
      }
    });
    return claimed;
  }

  Future<void> markSucceeded({
    required String id,
    String? remoteId,
    Map<String, Object?>? response,
  }) async {
    final db = await DBService.instance.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      tableName,
      <String, Object?>{
        'status': 'succeeded',
        'remote_id': remoteId,
        'last_response_json': response == null ? null : jsonEncode(response),
        'last_error_code': null,
        'last_error_message': null,
        'locked_at': null,
        'updated_at': now,
        'completed_at': now,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> markFailed({
    required String id,
    required String errorCode,
    required String errorMessage,
    Duration? retryAfter,
  }) async {
    final db = await DBService.instance.database;
    final rows = await db.query(
      tableName,
      columns: const <String>['retry_count'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    final retryRaw = rows.isEmpty ? null : rows.first['retry_count'];
    final retryCount = (retryRaw as num?)?.toInt() ?? 0;
    final nextRetryCount = retryCount + 1;
    final delay = retryAfter ?? _backoffForAttempt(nextRetryCount);
    final now = DateTime.now();
    await db.update(
      tableName,
      <String, Object?>{
        'status': 'failed',
        'retry_count': nextRetryCount,
        'next_retry_at': now.add(delay).toIso8601String(),
        'locked_at': null,
        'last_error_code': errorCode,
        'last_error_message': errorMessage,
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> markTerminal({
    required String id,
    required String errorCode,
    required String errorMessage,
    bool conflict = false,
    Map<String, Object?>? response,
  }) async {
    final db = await DBService.instance.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      tableName,
      <String, Object?>{
        'status': conflict ? 'conflict' : 'terminal_failed',
        'locked_at': null,
        'last_error_code': errorCode,
        'last_error_message': errorMessage,
        'last_response_json': response == null ? null : jsonEncode(response),
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }


  Future<int> pendingCount({String? accountId}) async {
    final db = await DBService.instance.database;
    if (!await _tableExists(db, tableName)) return 0;
    final where = StringBuffer(
      "status IN ('queued', 'failed', 'in_flight')",
    );
    final args = <Object?>[];
    if (accountId != null && accountId.trim().isNotEmpty) {
      where.write(' AND account_id = ?');
      args.add(accountId.trim());
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $tableName WHERE $where',
      args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> forceRetryPending({String? accountId}) async {
    final db = await DBService.instance.database;
    if (!await _tableExists(db, tableName)) return 0;
    final now = DateTime.now().toIso8601String();
    final where = StringBuffer("status = 'failed'");
    final args = <Object?>[];
    if (accountId != null && accountId.trim().isNotEmpty) {
      where.write(' AND account_id = ?');
      args.add(accountId.trim());
    }
    return db.update(
      tableName,
      <String, Object?>{
        'status': 'queued',
        'next_retry_at': null,
        'locked_at': null,
        'updated_at': now,
      },
      where: where.toString(),
      whereArgs: args,
    );
  }

  Future<int> requeueStaleInFlight({
    Duration staleAfter = const Duration(minutes: 15),
  }) async {
    final db = await DBService.instance.database;
    final cutoff = DateTime.now().subtract(staleAfter).toIso8601String();
    final now = DateTime.now().toIso8601String();
    return db.update(
      tableName,
      <String, Object?>{
        'status': 'failed',
        'locked_at': null,
        'last_error_code': 'stale_in_flight',
        'last_error_message':
            'تمت إعادة العملية لأنها بقيت in_flight مدة طويلة.',
        'updated_at': now,
      },
      where: "status = 'in_flight' AND locked_at IS NOT NULL AND locked_at < ?",
      whereArgs: <Object?>[cutoff],
    );
  }

  Future<bool> hasEntriesForTable({
    required String accountId,
    required String entityTable,
    bool includeCompleted = true,
  }) async {
    final db = await DBService.instance.database;
    if (!await _tableExists(db, tableName)) return false;
    final where = StringBuffer('account_id = ? AND entity_table = ?');
    final args = <Object?>[accountId.trim(), entityTable.trim()];
    if (!includeCompleted) {
      where.write(" AND status <> 'succeeded'");
    }
    final rows = await db.rawQuery(
      'SELECT 1 FROM $tableName WHERE $where LIMIT 1',
      args,
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasPendingForTable({
    required String accountId,
    required String entityTable,
  }) {
    return hasEntriesForTable(
      accountId: accountId,
      entityTable: entityTable,
      includeCompleted: false,
    );
  }

  Future<Map<String, Object?>> diagnostics({String? accountId}) async {
    final db = await DBService.instance.database;
    if (!await _tableExists(db, tableName)) {
      return <String, Object?>{'exists': false};
    }
    final where = StringBuffer('1=1');
    final args = <Object?>[];
    if (accountId != null && accountId.trim().isNotEmpty) {
      where.write(' AND account_id = ?');
      args.add(accountId.trim());
    }
    final byStatusRows = await db.rawQuery('''
      SELECT status, COUNT(*) AS c
        FROM $tableName
       WHERE $where
    GROUP BY status
    ORDER BY status
      ''', args);
    final byStatus = <String, int>{};
    for (final row in byStatusRows) {
      byStatus[(row['status'] ?? 'unknown').toString()] =
          (row['c'] as num?)?.toInt() ?? 0;
    }
    final recentRows = await db.query(
      tableName,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'updated_at DESC',
      limit: 20,
    );
    final nextRetryRows = await db.rawQuery('''
      SELECT MIN(next_retry_at) AS next_retry_at
        FROM $tableName
       WHERE $where
         AND status IN ('queued', 'failed')
         AND next_retry_at IS NOT NULL
      ''', args);
    final maxRetryRows = await db.rawQuery('''
      SELECT MAX(retry_count) AS retry_count
        FROM $tableName
       WHERE $where
      ''', args);
    return <String, Object?>{
      'exists': true,
      'by_status': byStatus,
      'pending_count':
          (byStatus['queued'] ?? 0) +
          (byStatus['failed'] ?? 0) +
          (byStatus['in_flight'] ?? 0),
      'failed_count': byStatus['failed'] ?? 0,
      'conflict_count': byStatus['conflict'] ?? 0,
      'terminal_failed_count': byStatus['terminal_failed'] ?? 0,
      'next_retry_at': nextRetryRows.isEmpty
          ? null
          : nextRetryRows.first['next_retry_at']?.toString(),
      'max_retry_count':
          ((maxRetryRows.isEmpty ? null : maxRetryRows.first['retry_count'])
                  as num?)
              ?.toInt() ??
          0,
      'recent_sample': recentRows.map(_diagnosticRow).toList(growable: false),
    };
  }

  Future<List<Map<String, Object?>>> recentHealthEvents({
    String? accountId,
    int limit = 20,
  }) async {
    final db = await DBService.instance.database;
    if (!await _tableExists(db, healthEventsTableName)) {
      return const <Map<String, Object?>>[];
    }
    final where = StringBuffer('1=1');
    final args = <Object?>[];
    if (accountId != null && accountId.trim().isNotEmpty) {
      where.write(' AND account_id = ?');
      args.add(accountId.trim());
    }
    final rows = await db.query(
      healthEventsTableName,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  ClinicOutboxEntry _entryFromRow(Map<String, Object?> row) {
    return ClinicOutboxEntry(
      id: row['id']?.toString() ?? '',
      operationType: row['operation_type']?.toString() ?? '',
      entityTable: row['entity_table']?.toString() ?? '',
      entityId: _toInt(row['entity_id']),
      remoteId: _blankToNull(row['remote_id']),
      clientMutationId: row['client_mutation_id']?.toString() ?? '',
      accountId: row['account_id']?.toString() ?? '',
      deviceId: row['device_id']?.toString() ?? '',
      localId: _toInt(row['local_id']),
      payload: _decodeJsonMap(row['payload_json']),
      localReference: _decodeJsonMapOrNull(row['local_reference_json']),
      status: ClinicOutboxStatusCodec.decode(row['status']),
      retryCount: _toInt(row['retry_count']) ?? 0,
      nextRetryAt: _parseDate(row['next_retry_at']),
      lastAttemptAt: _parseDate(row['last_attempt_at']),
      lockedAt: _parseDate(row['locked_at']),
      lastErrorCode: _blankToNull(row['last_error_code']),
      lastErrorMessage: _blankToNull(row['last_error_message']),
      lastResponse: _decodeJsonMapOrNull(row['last_response_json']),
      createdAt: _parseDate(row['created_at']) ?? DateTime.now(),
      updatedAt: _parseDate(row['updated_at']) ?? DateTime.now(),
      completedAt: _parseDate(row['completed_at']),
    );
  }

  Map<String, Object?> _diagnosticRow(Map<String, Object?> row) {
    return <String, Object?>{
      'id': row['id']?.toString(),
      'operation_type': row['operation_type']?.toString(),
      'entity_table': row['entity_table']?.toString(),
      'entity_id': row['entity_id'],
      'remote_id': row['remote_id']?.toString(),
      'client_mutation_id': row['client_mutation_id']?.toString(),
      'status': row['status']?.toString(),
      'retry_count': row['retry_count'],
      'next_retry_at': row['next_retry_at']?.toString(),
      'last_attempt_at': row['last_attempt_at']?.toString(),
      'locked_at': row['locked_at']?.toString(),
      'last_error_code': row['last_error_code']?.toString(),
      'last_error_message': row['last_error_message']?.toString(),
      'created_at': row['created_at']?.toString(),
      'updated_at': row['updated_at']?.toString(),
      'completed_at': row['completed_at']?.toString(),
    };
  }

  static String _buildClientMutationId({
    required String accountId,
    required String deviceId,
    required String entityTable,
    required int? entityId,
    required String operationType,
  }) {
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '$accountId:$deviceId:$entityTable:${entityId ?? 0}:'
        '$operationType:$stamp:${_uuid.v4()}';
  }

  static Duration _backoffForAttempt(int retryCount) {
    final capped = retryCount < 1 ? 1 : (retryCount > 8 ? 8 : retryCount);
    return Duration(seconds: 2 << (capped - 1));
  }

  static int? _toInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _blankToNull(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static DateTime? _parseDate(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  static Map<String, Object?> _decodeJsonMap(Object? value) {
    return _decodeJsonMapOrNull(value) ?? <String, Object?>{};
  }

  static Map<String, Object?>? _decodeJsonMapOrNull(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
    return null;
  }

  static Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    return rows.isNotEmpty;
  }
}
