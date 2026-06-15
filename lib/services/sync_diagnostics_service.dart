import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/network_status_service.dart';
import 'package:aelmamclinic/services/sync_outbox_service.dart';
import 'package:aelmamclinic/services/sync_service.dart';
import 'package:aelmamclinic/utils/app_paths.dart';

typedef JsonMap = Map<String, Object?>;

class SyncDiagnosticsExportResult {
  const SyncDiagnosticsExportResult({
    required this.fileName,
    required this.path,
    required this.jsonPreview,
  });

  final String fileName;
  final String path;
  final String jsonPreview;
}

class SyncDiagnosticsSnapshot {
  const SyncDiagnosticsSnapshot({
    required this.generatedAt,
    required this.scope,
    required this.auth,
    required this.network,
    required this.runtime,
    required this.database,
    required this.tableDiagnostics,
    required this.mappingDiagnostics,
    required this.outboxDiagnostics,
    required this.syncHealthEvents,
    required this.recentEvents,
    required this.appErrorLogs,
    required this.issues,
    required this.summary,
  });

  final DateTime generatedAt;
  final String scope;
  final JsonMap auth;
  final JsonMap network;
  final JsonMap? runtime;
  final JsonMap database;
  final List<JsonMap> tableDiagnostics;
  final JsonMap mappingDiagnostics;
  final JsonMap outboxDiagnostics;
  final List<JsonMap> syncHealthEvents;
  final List<JsonMap> recentEvents;
  final List<JsonMap> appErrorLogs;
  final List<JsonMap> issues;
  final JsonMap summary;

  bool get hasDanger => issues.any((issue) => issue['severity'] == 'danger');
  bool get hasWarning => issues.any((issue) => issue['severity'] == 'warning');
  int get pendingDirtyTableCount =>
      (summary['dirty_table_count'] as num?)?.toInt() ?? 0;

  JsonMap toJson() {
    return <String, Object?>{
      'schema': 'aelmamclinic.sync_diagnostics.v1',
      'generated_at': generatedAt.toIso8601String(),
      'scope': scope,
      'summary': summary,
      'auth': auth,
      'network': network,
      'sync_runtime': runtime,
      'database': database,
      'sync_tables': tableDiagnostics,
      'mapping_diagnostics': mappingDiagnostics,
      'clinic_outbox': outboxDiagnostics,
      'clinic_sync_health_events': syncHealthEvents,
      'recent_runtime_events': recentEvents,
      'app_error_logs': appErrorLogs,
      'issues': issues,
    };
  }
}

class SyncDiagnosticsService {
  const SyncDiagnosticsService();

  static const int _recentEventLimit = 140;
  static const int _tableSampleLimit = 80;

  Future<SyncDiagnosticsSnapshot> collect({required AuthProvider auth}) async {
    final generatedAt = DateTime.now();
    final db = await DBService.instance.database;
    final dbPath = await DBService.instance.getDatabasePath();
    final sync = auth.sync;
    final runtimeSnapshot = sync?.runtimeSnapshot;
    final networkSnapshot = _networkSnapshot();
    final inspectClinicState = auth.canEnterClinicShell;
    final syncDirtyRows = inspectClinicState
        ? await _syncDirtyRows(db)
        : const <JsonMap>[];
    final syncDirtyByTable = <String, JsonMap>{
      for (final row in syncDirtyRows)
        (row['table_name'] ?? '').toString(): row,
    };
    final tables = inspectClinicState
        ? await _discoverSyncTables(db)
        : const <String>[];
    final tableDiagnostics = <JsonMap>[];
    for (final table in tables) {
      tableDiagnostics.add(
        await _tableDiagnostics(
          db: db,
          table: table,
          auth: auth,
          dirtyRow: syncDirtyByTable[table],
        ),
      );
    }
    final mappingDiagnostics = inspectClinicState
        ? await _mappingDiagnostics(db: db, syncTables: tables)
        : <String, Object?>{
            'checked': false,
            'skipped_reason': 'not_clinic_account_scope',
          };
    const outboxService = SyncOutboxService();
    final outboxDiagnostics = inspectClinicState
        ? await outboxService.diagnostics(accountId: auth.accountId)
        : <String, Object?>{
            'exists': await _tableExists(db, SyncOutboxService.tableName),
            'checked': false,
            'skipped_reason': 'not_clinic_account_scope',
          };
    final syncHealthEvents = inspectClinicState
        ? await outboxService.recentHealthEvents(accountId: auth.accountId, limit: 20)
        : const <JsonMap>[];
    final chatOutbox = (auth.accountId ?? '').trim().isNotEmpty
        ? await _chatOutboxDiagnostics(auth.accountId)
        : <String, Object?>{
            'checked': false,
            'skipped_reason': 'missing_account_scope',
          };
    final runtimeEvents = await _recentRuntimeEvents();
    final recentEvents = <JsonMap>[
      ...syncHealthEvents,
      ...runtimeEvents,
    ];
    final appErrorLogs = await _recentAppErrorLogEntries();
    final authSnapshot = _authSnapshot(auth);
    final clinicSyncState = inspectClinicState
        ? await _clinicSyncStateRows(db)
        : const <JsonMap>[];
    final databaseSnapshot = <String, Object?>{
      'path': dbPath,
      'diagnostic_scope': _scopeFor(auth),
      'clinic_local_state_checked': inspectClinicState,
      'sync_dirty_rows': syncDirtyRows,
      'sync_table_count': tables.length,
      'stats_dirty': inspectClinicState ? await _statsDirty(db) : null,
      'sync_identity': inspectClinicState ? await _syncIdentity(db) : null,
      'clinic_sync_state': clinicSyncState,
      'clinic_outbox': outboxDiagnostics,
      'chat_outbox': chatOutbox,
    };
    final issues = _deriveIssues(
      auth: auth,
      network: networkSnapshot,
      runtime: runtimeSnapshot,
      dirtyRows: syncDirtyRows,
      tableDiagnostics: tableDiagnostics,
      mappingDiagnostics: mappingDiagnostics,
      outboxDiagnostics: outboxDiagnostics,
      chatOutbox: chatOutbox,
      recentEvents: recentEvents,
      appErrorLogs: appErrorLogs,
    );
    final summary = _summary(
      auth: auth,
      runtime: runtimeSnapshot,
      network: networkSnapshot,
      dirtyRows: syncDirtyRows,
      tableDiagnostics: tableDiagnostics,
      mappingDiagnostics: mappingDiagnostics,
      outboxDiagnostics: outboxDiagnostics,
      chatOutbox: chatOutbox,
      recentEvents: recentEvents,
      appErrorLogs: appErrorLogs,
      issues: issues,
    );

    return SyncDiagnosticsSnapshot(
      generatedAt: generatedAt,
      scope: _scopeFor(auth),
      auth: authSnapshot,
      network: networkSnapshot,
      runtime: runtimeSnapshot?.toJson(),
      database: databaseSnapshot,
      tableDiagnostics: tableDiagnostics,
      mappingDiagnostics: mappingDiagnostics,
      outboxDiagnostics: outboxDiagnostics,
      syncHealthEvents: syncHealthEvents,
      recentEvents: recentEvents,
      appErrorLogs: appErrorLogs,
      issues: issues,
      summary: summary,
    );
  }

  Future<SyncDiagnosticsExportResult> export(
    SyncDiagnosticsSnapshot snapshot,
  ) async {
    final root = await AppPaths.dataRoot();
    final directory = Directory(p.join(root.path, 'sync_diagnostics'));
    await directory.create(recursive: true);
    final stamp = snapshot.generatedAt.toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final role = _safeFilePart('${snapshot.auth['role'] ?? snapshot.scope}');
    final fileName = 'elmamclinic_sync_status_${role}_$stamp.json';
    final jsonText = const JsonEncoder.withIndent(
      '  ',
    ).convert(snapshot.toJson());
    final file = File(p.join(directory.path, fileName));
    await file.writeAsString(jsonText, encoding: utf8, flush: true);
    return SyncDiagnosticsExportResult(
      fileName: fileName,
      path: file.path,
      jsonPreview: jsonText.length <= 6000
          ? jsonText
          : '${jsonText.substring(0, 6000)}\n__truncated_preview__',
    );
  }

  JsonMap _authSnapshot(AuthProvider auth) {
    final allowedFeatures = auth.allowedFeatures.toList(growable: false)
      ..sort();
    return <String, Object?>{
      'is_logged_in': auth.isLoggedIn,
      'uid': auth.uid,
      'email': auth.email,
      'role': auth.role,
      'is_super_admin': auth.isSuperAdmin,
      'account_id': auth.accountId,
      'has_account_context': auth.hasAccountContext,
      'has_nhost_session': auth.hasNhostSession,
      'has_super_admin_session_role': auth.hasSuperAdminSessionRole,
      'is_offline_session': auth.isOffline,
      'is_disabled': auth.isDisabled,
      'requires_local_isolation_wipe': auth.requiresLocalIsolationWipe,
      'has_pending_local_wipe': auth.hasPendingLocalWipe,
      'can_enter_clinic_shell': auth.canEnterClinicShell,
      'can_enter_remote_admin_shell': auth.canEnterRemoteAdminShell,
      'can_run_remote_bound_services': auth.canRunRemoteBoundServices,
      'session_topology_state': auth.sessionTopologyState,
      'plan_code': auth.planCode,
      'plan_end_at': auth.planEndAt?.toIso8601String(),
      'permissions_loaded': auth.permissionsLoaded,
      'permissions_error': auth.permissionsError,
      'allow_all_features': auth.allowAllFeatures,
      'allowed_features': auth.isSuperAdmin
          ? const <String>[]
          : allowedFeatures,
      'can_create': auth.canCreate,
      'can_update': auth.canUpdate,
      'can_delete': auth.canDelete,
    };
  }

  JsonMap _networkSnapshot() {
    final network = NetworkStatusService.instance;
    return <String, Object?>{
      'is_online': network.isOnline,
      'status': network.status.name,
      'last_checked_at': network.lastCheckedAt?.toIso8601String(),
      'last_reachable_at': network.lastReachableAt?.toIso8601String(),
      'last_error': network.lastError,
    };
  }

  Future<List<String>> _discoverSyncTables(Database db) async {
    final rows = await db.rawQuery('''
      SELECT name
        FROM sqlite_master
       WHERE type = 'table'
         AND name NOT LIKE 'sqlite_%'
         AND name NOT LIKE 'android_%'
       ORDER BY name
    ''');
    final tables = <String>[];
    for (final row in rows) {
      final name = (row['name'] ?? '').toString();
      if (name.isEmpty || _isInternalTable(name)) continue;
      final columns = await _columnsFor(db, name);
      final lower = columns.map((column) => column.toLowerCase()).toSet();
      if (lower.contains('account_id') &&
          lower.contains('device_id') &&
          lower.contains('local_id') &&
          lower.contains('updated_at')) {
        tables.add(name);
      }
    }
    return tables;
  }

  Future<JsonMap> _tableDiagnostics({
    required Database db,
    required String table,
    required AuthProvider auth,
    required JsonMap? dirtyRow,
  }) async {
    final quoted = _quoteIdent(table);
    final columns = await _columnsFor(db, table);
    final lowerColumns = columns.map((column) => column.toLowerCase()).toSet();
    final hasIdColumn = lowerColumns.contains('id');
    final currentAccountId = (auth.accountId ?? '').trim();
    final diagnostics = <String, Object?>{
      'table': table,
      'columns': columns,
      'row_count': await _count(db, 'SELECT COUNT(*) AS c FROM $quoted'),
      'dirty': _truthy(dirtyRow?['dirty']),
      'dirty_updated_at': dirtyRow?['updated_at']?.toString(),
      'missing_account_id_count': await _count(
        db,
        "SELECT COUNT(*) AS c FROM $quoted WHERE account_id IS NULL OR TRIM(CAST(account_id AS TEXT)) = ''",
      ),
      'missing_device_id_count': await _count(
        db,
        "SELECT COUNT(*) AS c FROM $quoted WHERE device_id IS NULL OR TRIM(CAST(device_id AS TEXT)) = ''",
      ),
      'missing_local_id_count': await _count(
        db,
        'SELECT COUNT(*) AS c FROM $quoted WHERE local_id IS NULL OR local_id <= 0',
      ),
      'missing_updated_at_count': await _count(
        db,
        "SELECT COUNT(*) AS c FROM $quoted WHERE updated_at IS NULL OR TRIM(CAST(updated_at AS TEXT)) = ''",
      ),
      'duplicate_sync_key_groups': await _count(db, '''
        SELECT COUNT(*) AS c
          FROM (
            SELECT account_id, device_id, local_id, COUNT(*) AS n
              FROM $quoted
             WHERE account_id IS NOT NULL
               AND device_id IS NOT NULL
               AND local_id IS NOT NULL
          GROUP BY account_id, device_id, local_id
            HAVING n > 1
          ) duplicate_keys
        '''),
      'oldest_updated_at': await _scalarText(
        db,
        'SELECT MIN(updated_at) AS v FROM $quoted',
      ),
      'newest_updated_at': await _scalarText(
        db,
        'SELECT MAX(updated_at) AS v FROM $quoted',
      ),
    };
    if (currentAccountId.isNotEmpty) {
      diagnostics['other_account_rows_count'] = await _count(
        db,
        '''
        SELECT COUNT(*) AS c
          FROM $quoted
         WHERE account_id IS NOT NULL
           AND TRIM(CAST(account_id AS TEXT)) <> ''
           AND account_id <> ?
        ''',
        <Object?>[currentAccountId],
      );
    }
    if (hasIdColumn) {
      diagnostics['max_local_row_id'] = await _count(
        db,
        'SELECT COALESCE(MAX(id), 0) AS c FROM $quoted',
      );
    }
    return diagnostics;
  }

  Future<JsonMap> _mappingDiagnostics({
    required Database db,
    required List<String> syncTables,
  }) async {
    final uuid = await _mappingTableSummary(
      db: db,
      tableName: 'sync_uuid_mapping',
      groupColumn: 'table_name',
    );
    final fk = await _mappingTableSummary(
      db: db,
      tableName: 'sync_fk_mapping',
      groupColumn: 'table_name',
    );
    final remote = await _mappingTableSummary(
      db: db,
      tableName: 'remote_id_map',
      groupColumn: 'table_name',
    );
    final orphanUuidRows = <JsonMap>[];
    if (await _tableExists(db, 'sync_uuid_mapping')) {
      for (final table in syncTables.take(_tableSampleLimit)) {
        if (!await _hasColumn(db, table, 'id')) continue;
        final quoted = _quoteIdent(table);
        final orphanCount = await _count(
          db,
          '''
          SELECT COUNT(*) AS c
            FROM sync_uuid_mapping m
           WHERE m.table_name = ?
             AND NOT EXISTS (
               SELECT 1 FROM $quoted t WHERE t.id = m.record_id
             )
          ''',
          <Object?>[table],
        );
        if (orphanCount > 0) {
          orphanUuidRows.add(<String, Object?>{
            'table': table,
            'orphan_uuid_mapping_count': orphanCount,
          });
        }
      }
    }
    return <String, Object?>{
      'sync_uuid_mapping': uuid,
      'sync_fk_mapping': fk,
      'remote_id_map': remote,
      'orphan_uuid_mappings': orphanUuidRows,
    };
  }

  Future<JsonMap> _mappingTableSummary({
    required Database db,
    required String tableName,
    required String groupColumn,
  }) async {
    if (!await _tableExists(db, tableName)) {
      return <String, Object?>{'exists': false, 'row_count': 0};
    }
    final quotedTable = _quoteIdent(tableName);
    final rowCount = await _count(db, 'SELECT COUNT(*) AS c FROM $quotedTable');
    if (!await _hasColumn(db, tableName, groupColumn)) {
      return <String, Object?>{
        'exists': true,
        'row_count': rowCount,
        'missing_group_column': groupColumn,
      };
    }
    final quotedGroup = _quoteIdent(groupColumn);
    List<Map<String, Object?>> rows = const <Map<String, Object?>>[];
    try {
      rows = await db.rawQuery('''
        SELECT $quotedGroup AS key, COUNT(*) AS c
          FROM $quotedTable
      GROUP BY $quotedGroup
      ORDER BY c DESC, key ASC
      LIMIT $_tableSampleLimit
      ''');
    } catch (error) {
      return <String, Object?>{
        'exists': true,
        'row_count': rowCount,
        'error': '$error',
      };
    }
    return <String, Object?>{
      'exists': true,
      'row_count': rowCount,
      'by_table': rows
          .map(
            (row) => <String, Object?>{
              'table': row['key']?.toString(),
              'count': (row['c'] as num?)?.toInt() ?? 0,
            },
          )
          .toList(growable: false),
    };
  }

  Future<List<JsonMap>> _syncDirtyRows(Database db) async {
    if (!await _tableExists(db, 'sync_dirty')) {
      return const <JsonMap>[];
    }
    final rows = await db.rawQuery('''
      SELECT table_name, dirty, updated_at
        FROM sync_dirty
    ORDER BY dirty DESC, updated_at DESC, table_name ASC
    ''');
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  Future<JsonMap> _chatOutboxDiagnostics(String? accountId) async {
    try {
      final rows = await ChatLocalStore.instance.getOutbox(
        accountId: accountId,
        limit: 200,
      );
      final byStatus = <String, int>{};
      for (final row in rows) {
        final status = (row['status'] ?? 'unknown').toString().trim();
        byStatus[status.isEmpty ? 'unknown' : status] =
            (byStatus[status.isEmpty ? 'unknown' : status] ?? 0) + 1;
      }
      return <String, Object?>{
        'checked': true,
        'sample_limit': 200,
        'sample_count': rows.length,
        'by_status': byStatus,
        'recent_sample': rows
            .take(20)
            .map((row) {
              return <String, Object?>{
                'local_id': row['local_id']?.toString(),
                'conversation_id': row['conversation_id']?.toString(),
                'account_id': row['account_id']?.toString(),
                'kind': row['kind']?.toString(),
                'created_at': row['created_at']?.toString(),
                'status': row['status']?.toString(),
                if ((row['error'] ?? '').toString().trim().isNotEmpty)
                  'error': _trimDiagnosticText(row['error']?.toString()),
                'has_attachments': (row['attachments_json'] ?? '')
                    .toString()
                    .trim()
                    .isNotEmpty,
                'has_mentions': (row['mentions_json'] ?? '')
                    .toString()
                    .trim()
                    .isNotEmpty,
              };
            })
            .toList(growable: false),
      };
    } catch (error) {
      return <String, Object?>{'checked': false, 'error': '$error'};
    }
  }

  Future<JsonMap?> _syncIdentity(Database db) async {
    if (!await _tableExists(db, 'sync_identity')) return null;
    final rows = await db.rawQuery('SELECT * FROM sync_identity LIMIT 5');
    return <String, Object?>{
      'row_count': await _count(db, 'SELECT COUNT(*) AS c FROM sync_identity'),
      'rows': rows.map((row) => Map<String, Object?>.from(row)).toList(),
    };
  }

  Future<List<JsonMap>> _clinicSyncStateRows(Database db) async {
    if (!await _tableExists(db, 'clinic_sync_state')) return const <JsonMap>[];
    final rows = await db.query(
      'clinic_sync_state',
      orderBy: 'updated_at DESC',
      limit: 40,
    );
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  Future<bool> _statsDirty(Database db) async {
    try {
      if (!await _tableExists(db, 'stats_dirty')) return true;
      final rows = await db.rawQuery(
        'SELECT dirty FROM stats_dirty WHERE id = 1 LIMIT 1',
      );
      if (rows.isEmpty) return true;
      return _truthy(rows.first['dirty']);
    } catch (_) {
      return true;
    }
  }

  Future<List<JsonMap>> _recentRuntimeEvents() async {
    final dir = await AppPaths.logsDir();
    final file = File(p.join(dir.path, 'app_runtime_events.jsonl'));
    if (!await file.exists()) {
      return const <JsonMap>[];
    }
    final events = <JsonMap>[];
    try {
      final stream = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final parsed = jsonDecode(trimmed);
        if (parsed is! Map) continue;
        final event = _redactJsonMap(Map<String, Object?>.from(parsed));
        event['sync_related'] = _isSyncRelatedEvent(event);
        events.add(event);
        if (events.length > _recentEventLimit) {
          events.removeAt(0);
        }
      }
    } catch (error) {
      events.add(<String, Object?>{
        'level': 'warn',
        'scope': 'DIAGNOSTICS',
        'code': 'RUNTIME_EVENTS_READ_FAILED',
        'message': '$error',
      });
    }
    return events;
  }

  Future<List<JsonMap>> _recentAppErrorLogEntries() async {
    final dir = await AppPaths.logsDir();
    final file = File(p.join(dir.path, 'app_errors.log'));
    if (!await file.exists()) return const <JsonMap>[];
    final entries = <JsonMap>[];
    try {
      final lines = await file.readAsLines();
      final pattern = RegExp(r'^\[(.*?)\]\[(.*?)\]\s*(.*)$');
      for (final raw in lines.reversed) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        final match = pattern.firstMatch(line);
        if (match == null) {
          if (entries.isNotEmpty) {
            final previous = entries.last;
            previous['message'] = _trimDiagnosticText(
              '${previous['message'] ?? ''}\n${_redactFreeText(line)}',
            );
          }
          continue;
        }
        entries.add(<String, Object?>{
          'ts': match.group(1),
          'level': match.group(2),
          'message': _trimDiagnosticText(_redactFreeText(match.group(3) ?? '')),
        });
        if (entries.length >= _recentEventLimit) break;
      }
    } catch (error) {
      return <JsonMap>[
        <String, Object?>{
          'level': 'WARN',
          'message': 'APP_ERRORS_LOG_READ_FAILED: $error',
        },
      ];
    }
    return entries.reversed.toList(growable: false);
  }

  bool _isSyncRelatedEvent(JsonMap event) {
    final scope = (event['scope'] ?? '').toString().toUpperCase();
    final code = (event['code'] ?? '').toString().toUpperCase();
    return scope == 'SYNC' ||
        scope == 'DB' ||
        scope == 'AUTH' ||
        scope == 'CHAT' ||
        code.contains('SYNC') ||
        code.contains('REALTIME') ||
        code.contains('OUTBOX') ||
        code.startsWith('DB_');
  }

  List<JsonMap> _deriveIssues({
    required AuthProvider auth,
    required JsonMap network,
    required SyncRuntimeSnapshot? runtime,
    required List<JsonMap> dirtyRows,
    required List<JsonMap> tableDiagnostics,
    required JsonMap mappingDiagnostics,
    required JsonMap outboxDiagnostics,
    required JsonMap chatOutbox,
    required List<JsonMap> recentEvents,
    required List<JsonMap> appErrorLogs,
  }) {
    final issues = <JsonMap>[];
    void addIssue({
      required String severity,
      required String code,
      required String title,
      required String recommendation,
      Object? evidence,
    }) {
      issues.add(<String, Object?>{
        'severity': severity,
        'code': code,
        'title': title,
        'recommendation': recommendation,
        if (evidence != null) 'evidence': evidence,
      });
    }

    if (!auth.isLoggedIn) {
      addIssue(
        severity: 'danger',
        code: 'auth_signed_out',
        title: 'لا توجد جلسة مستخدم نشطة.',
        recommendation: 'سجل الدخول ثم افتح حالة المزامنة مرة أخرى.',
      );
    }
    if (auth.requiresLocalIsolationWipe || auth.hasPendingLocalWipe) {
      addIssue(
        severity: 'danger',
        code: 'local_isolation_wipe_required',
        title: 'توجد بيانات محلية مرتبطة بحساب آخر وتحتاج عزلًا.',
        recommendation:
            'لا تبدأ مزامنة جديدة قبل إكمال إجراء عزل/تنظيف البيانات المحلي.',
        evidence: <String, Object?>{
          'account_id': auth.accountId,
          'session_topology_state': auth.sessionTopologyState,
        },
      );
    }
    if (!auth.isSuperAdmin && auth.isLoggedIn && !auth.hasAccountContext) {
      addIssue(
        severity: 'danger',
        code: 'missing_account_context',
        title: 'المستخدم الحالي لا يملك account_id جاهزًا.',
        recommendation:
            'أعد مزامنة الجلسة أو تحقق من ربط المستخدم بحساب العيادة في الخادم.',
      );
    }
    if (auth.isOffline || auth.needsRemoteSessionRecovery) {
      addIssue(
        severity: 'warning',
        code: 'offline_or_remote_session_missing',
        title: 'الجلسة محلية أو تحتاج استعادة اتصال بالخادم.',
        recommendation:
            'اتصل بالإنترنت ثم نفذ تحديث الآن لتجديد الجلسة وتشغيل pull/push.',
        evidence: auth.sessionTopologyState,
      );
    }
    if (network['is_online'] != true) {
      addIssue(
        severity: 'warning',
        code: 'network_offline',
        title: 'فحص الاتصال الفعلي لا يرى اتصالًا بالخادم.',
        recommendation:
            'تحقق من الشبكة أو الخادم، ثم استخدم تحديث الآن بعد عودة الاتصال.',
        evidence: network,
      );
    }
    if (!auth.isSuperAdmin && auth.canEnterClinicShell && runtime == null) {
      addIssue(
        severity: 'danger',
        code: 'sync_runtime_not_bound',
        title: 'محرك المزامنة غير مربوط رغم أن واجهة العيادة جاهزة.',
        recommendation:
            'اضغط تحديث الآن. إذا استمر ذلك، راجع bootstrapSync وربط DBService.bindSyncPush.',
      );
    }
    if (runtime != null) {
      if (!runtime.syncEnabled || runtime.phase == 'blocked') {
        addIssue(
          severity: 'danger',
          code: 'sync_runtime_blocked',
          title: 'محرك المزامنة متوقف أو محجوب.',
          recommendation:
              'راجع سبب الحجب ثم نفذ تحديث الآن بعد حل الاشتراك/الجلسة/الاتصال.',
          evidence: runtime.toJson(),
        );
      } else if (runtime.phase == 'paused' || runtime.manualPauseDepth > 0) {
        addIssue(
          severity: 'warning',
          code: 'sync_runtime_paused',
          title: 'محرك المزامنة موقوف مؤقتًا.',
          recommendation:
              'استأنف المزامنة أو أعد فتح التطبيق ثم نفذ تحديث الآن.',
          evidence: runtime.toJson(),
        );
      }
      if (runtime.pullRetryScheduled || runtime.pullRetryCount > 0) {
        addIssue(
          severity: 'warning',
          code: 'pull_retry_pending',
          title: 'توجد إعادة محاولة مجدولة لعملية السحب.',
          recommendation:
              'اترك التطبيق متصلًا، أو نفذ تحديث الآن إذا بقيت المحاولة معلقة.',
          evidence: runtime.toJson(),
        );
      }
      if (runtime.pendingPushTimers.isNotEmpty ||
          runtime.activePushTables.isNotEmpty ||
          runtime.queuedPushTables.isNotEmpty) {
        addIssue(
          severity: 'warning',
          code: 'push_work_pending',
          title: 'توجد عمليات دفع نشطة أو مؤجلة.',
          recommendation:
              'انتظر حتى تصبح الحالة جاهزة. إذا بقيت الجداول نفسها، صدّر التقرير للفحص.',
          evidence: <String, Object?>{
            'active': runtime.activePushTables,
            'queued': runtime.queuedPushTables,
            'timers': runtime.pendingPushTimers,
          },
        );
      }
      if (runtime.disabledRemoteTables.isNotEmpty) {
        addIssue(
          severity: 'danger',
          code: 'remote_tables_disabled',
          title: 'بعض الجداول السحابية عُطلت داخل محرك المزامنة.',
          recommendation:
              'راجع توافق GraphQL/Hasura للجداول المعطلة قبل الاعتماد على المزامنة.',
          evidence: runtime.disabledRemoteTables,
        );
      }
      final lastPull = runtime.lastPullAt;
      if (lastPull == null && auth.canEnterClinicShell) {
        addIssue(
          severity: 'warning',
          code: 'no_successful_pull_seen',
          title: 'لا توجد عملية سحب ناجحة مسجلة في runtime الحالي.',
          recommendation: 'نفذ تحديث الآن بعد التأكد من الاتصال والجلسة.',
        );
      } else if (lastPull != null &&
          network['is_online'] == true &&
          DateTime.now().difference(lastPull) > const Duration(hours: 2)) {
        addIssue(
          severity: 'warning',
          code: 'last_pull_stale',
          title: 'آخر سحب أصبح قديمًا.',
          recommendation:
              'نفذ تحديث الآن للتأكد من سحب آخر بيانات الخادم لهذا الدور.',
          evidence: lastPull.toIso8601String(),
        );
      }
    }

    final dirty = dirtyRows.where((row) => _truthy(row['dirty'])).toList();
    if (dirty.isNotEmpty) {
      addIssue(
        severity: 'warning',
        code: 'dirty_tables_pending_push',
        title: 'توجد جداول معلقة للدفع.',
        recommendation:
            'اضغط تحديث الآن. إذا بقيت dirty بعد الاتصال فراجع تفاصيل الجداول في التقرير.',
        evidence: dirty,
      );
    }

    final identityProblems = tableDiagnostics.where((table) {
      return _num(table['missing_account_id_count']) > 0 ||
          _num(table['missing_device_id_count']) > 0 ||
          _num(table['missing_local_id_count']) > 0 ||
          _num(table['missing_updated_at_count']) > 0;
    }).toList();
    if (identityProblems.isNotEmpty) {
      addIssue(
        severity: 'danger',
        code: 'sync_identity_columns_missing_values',
        title: 'توجد سجلات محلية ناقصة أعمدة هوية المزامنة.',
        recommendation:
            'شغل parity/backfill قبل الدفع حتى لا تفشل عمليات upsert أو mapping.',
        evidence: identityProblems,
      );
    }

    final duplicateKeys = tableDiagnostics
        .where((table) => _num(table['duplicate_sync_key_groups']) > 0)
        .toList();
    if (duplicateKeys.isNotEmpty) {
      addIssue(
        severity: 'danger',
        code: 'duplicate_local_sync_keys',
        title: 'توجد مفاتيح مزامنة محلية مكررة.',
        recommendation:
            'يجب إصلاح التكرار قبل الدفع لأنه قد يسبب تعارضًا أو استبدال سجلات خاطئة.',
        evidence: duplicateKeys,
      );
    }

    final otherAccountRows = tableDiagnostics
        .where((table) => _num(table['other_account_rows_count']) > 0)
        .toList();
    if (otherAccountRows.isNotEmpty) {
      addIssue(
        severity: 'danger',
        code: 'foreign_account_rows_present',
        title: 'توجد سجلات محلية لحساب مختلف عن المستخدم الحالي.',
        recommendation:
            'لا تزامن قبل التحقق من عزل البيانات المحلي حتى لا تختلط بيانات الحسابات.',
        evidence: otherAccountRows,
      );
    }

    final orphanUuid =
        (mappingDiagnostics['orphan_uuid_mappings'] as List?) ?? const [];
    if (orphanUuid.isNotEmpty) {
      addIssue(
        severity: 'warning',
        code: 'orphan_uuid_mappings',
        title: 'توجد mappings تشير إلى سجلات محلية غير موجودة.',
        recommendation:
            'راجع sync_uuid_mapping مقابل الجداول المحلية؛ قد تحتاج تنظيف mapping بعد حذف سجلات.',
        evidence: orphanUuid,
      );
    }

    final outboxExists = outboxDiagnostics['exists'] == true;
    if (outboxExists) {
      final terminalFailed = _num(outboxDiagnostics['terminal_failed_count']);
      final conflicts = _num(outboxDiagnostics['conflict_count']);
      final failed = _num(outboxDiagnostics['failed_count']);
      final pending = _num(outboxDiagnostics['pending_count']);
      if (terminalFailed > 0 || conflicts > 0) {
        addIssue(
          severity: 'danger',
          code: 'clinic_outbox_terminal_or_conflict',
          title: 'توجد عمليات مزامنة محلية وصلت إلى فشل نهائي أو تعارض.',
          recommendation:
              'لا تحذف البيانات محليًا. صدّر تقرير حالة المزامنة وراجع recent_sample لمعرفة العملية والسبب.',
          evidence: outboxDiagnostics,
        );
      } else if (failed > 0) {
        addIssue(
          severity: 'warning',
          code: 'clinic_outbox_failed_retry_pending',
          title: 'توجد عمليات Outbox فشلت مؤقتًا وتنتظر إعادة المحاولة.',
          recommendation:
              'اترك التطبيق متصلًا أو استخدم إعادة المحاولة بعد استقرار الشبكة.',
          evidence: outboxDiagnostics,
        );
      } else if (pending > 0) {
        addIssue(
          severity: 'warning',
          code: 'clinic_outbox_pending',
          title: 'توجد عمليات محلية بانتظار الرفع عبر Outbox.',
          recommendation:
              'تأكد من الاتصال ثم استخدم مزامنة الآن. ستبقى البيانات محفوظة محليًا حتى نجاح الرفع.',
          evidence: outboxDiagnostics,
        );
      }
    }

    final chatByStatus =
        (chatOutbox['by_status'] as Map?) ?? const <Object?, Object?>{};
    final failedChatOutbox = _num(chatByStatus['failed']);
    final queuedChatOutbox =
        _num(chatByStatus['queued']) + _num(chatByStatus['sending']);
    if (failedChatOutbox > 0) {
      addIssue(
        severity: 'danger',
        code: 'chat_outbox_failed',
        title: 'توجد رسائل دردشة فشلت في outbox المحلي.',
        recommendation:
            'راجع chat_outbox.recent_sample في JSON لمعرفة الخطأ ثم أعد المحاولة عند استقرار الاتصال.',
        evidence: chatOutbox,
      );
    } else if (queuedChatOutbox > 0) {
      addIssue(
        severity: 'warning',
        code: 'chat_outbox_pending',
        title: 'توجد رسائل دردشة بانتظار الإرسال.',
        recommendation:
            'اترك التطبيق متصلًا أو افتح الدردشة لإتاحة flush للرسائل المعلقة.',
        evidence: chatOutbox,
      );
    }

    final warnOrErrorEvents = recentEvents.where((event) {
      final level = (event['level'] ?? '').toString().toLowerCase();
      return level == 'warn' || level == 'error';
    }).toList();
    if (warnOrErrorEvents.isNotEmpty) {
      addIssue(
        severity:
            warnOrErrorEvents.any(
              (event) =>
                  (event['level'] ?? '').toString().toLowerCase() == 'error',
            )
            ? 'danger'
            : 'warning',
        code: 'recent_runtime_warn_or_error_events',
        title: 'توجد أحداث runtime تحذيرية أو خطرة.',
        recommendation:
            'افتح recent_runtime_events في JSON لمعرفة الكود والسبب والسياق، سواء كانت مزامنة أو شاشة أو خدمة أخرى.',
        evidence: warnOrErrorEvents.take(25).toList(),
      );
    }

    if (appErrorLogs.isNotEmpty) {
      addIssue(
        severity: 'danger',
        code: 'app_error_log_entries_present',
        title: 'توجد أخطاء عامة مسجلة في التطبيق.',
        recommendation:
            'افتح app_error_logs في JSON لمعرفة الشاشة أو العملية التي أبلغت عن الخطأ، حتى لو لم يكن الخطأ متعلقًا بالمزامنة.',
        evidence: appErrorLogs.take(25).toList(),
      );
    }

    if (issues.isEmpty) {
      addIssue(
        severity: 'success',
        code: 'no_visible_sync_issue',
        title: 'لا توجد مشكلة مزامنة ظاهرة في الفحص الحالي.',
        recommendation:
            'استمر بالمراقبة، وصدّر التقرير إذا ظهر اختلاف بيانات بين الأجهزة.',
      );
    }
    return issues;
  }

  JsonMap _summary({
    required AuthProvider auth,
    required SyncRuntimeSnapshot? runtime,
    required JsonMap network,
    required List<JsonMap> dirtyRows,
    required List<JsonMap> tableDiagnostics,
    required JsonMap mappingDiagnostics,
    required JsonMap outboxDiagnostics,
    required JsonMap chatOutbox,
    required List<JsonMap> recentEvents,
    required List<JsonMap> appErrorLogs,
    required List<JsonMap> issues,
  }) {
    final dangerCount = issues
        .where((issue) => issue['severity'] == 'danger')
        .length;
    final warningCount = issues
        .where((issue) => issue['severity'] == 'warning')
        .length;
    final dirtyCount = dirtyRows.where((row) => _truthy(row['dirty'])).length;
    final missingIdentityTables = tableDiagnostics.where((table) {
      return _num(table['missing_account_id_count']) > 0 ||
          _num(table['missing_device_id_count']) > 0 ||
          _num(table['missing_local_id_count']) > 0 ||
          _num(table['missing_updated_at_count']) > 0;
    }).length;
    final duplicateKeyTables = tableDiagnostics
        .where((table) => _num(table['duplicate_sync_key_groups']) > 0)
        .length;
    final eventWarnCount = recentEvents.where((event) {
      final level = (event['level'] ?? '').toString().toLowerCase();
      return level == 'warn';
    }).length;
    final eventErrorCount = recentEvents.where((event) {
      final level = (event['level'] ?? '').toString().toLowerCase();
      return level == 'error';
    }).length;
    final chatByStatus =
        (chatOutbox['by_status'] as Map?) ?? const <Object?, Object?>{};
    final outboxByStatus =
        (outboxDiagnostics['by_status'] as Map?) ?? const <Object?, Object?>{};
    final overall = dangerCount > 0
        ? 'danger'
        : warningCount > 0
        ? 'warning'
        : 'success';

    return <String, Object?>{
      'overall': overall,
      'scope': _scopeFor(auth),
      'role': auth.role,
      'is_super_admin': auth.isSuperAdmin,
      'session_topology_state': auth.sessionTopologyState,
      'network_status': network['status'],
      'sync_phase': runtime?.phase,
      'sync_phase_reason': runtime?.phaseReason,
      'sync_runtime_bound': runtime != null,
      'sync_has_pending_work': runtime?.hasPendingWork ?? false,
      'dirty_table_count': dirtyCount,
      'clinic_outbox_pending_count': outboxDiagnostics['pending_count'] ?? 0,
      'clinic_outbox_queued_count': _num(outboxByStatus['queued']),
      'clinic_outbox_in_flight_count': _num(outboxByStatus['in_flight']),
      'clinic_outbox_failed_count': outboxDiagnostics['failed_count'] ?? 0,
      'clinic_outbox_conflict_count': outboxDiagnostics['conflict_count'] ?? 0,
      'clinic_outbox_terminal_failed_count':
          outboxDiagnostics['terminal_failed_count'] ?? 0,
      'clinic_outbox_retry_count': outboxDiagnostics['max_retry_count'] ?? 0,
      'clinic_outbox_next_retry_at': outboxDiagnostics['next_retry_at'],
      'sync_table_count': tableDiagnostics.length,
      'missing_identity_table_count': missingIdentityTables,
      'duplicate_sync_key_table_count': duplicateKeyTables,
      'recent_runtime_event_count': recentEvents.length,
      'app_error_log_count': appErrorLogs.length,
      'recent_warning_event_count': eventWarnCount,
      'recent_error_event_count': eventErrorCount,
      'chat_outbox_sample_count': chatOutbox['sample_count'],
      'chat_outbox_failed_count': _num(chatByStatus['failed']),
      'chat_outbox_pending_count':
          _num(chatByStatus['queued']) + _num(chatByStatus['sending']),
      'issue_count': issues.length,
      'danger_issue_count': dangerCount,
      'warning_issue_count': warningCount,
      'clinic_local_state_checked': auth.canEnterClinicShell,
      'mapping_orphan_uuid_table_count':
          ((mappingDiagnostics['orphan_uuid_mappings'] as List?) ?? const [])
              .length,
    };
  }

  Future<List<String>> _columnsFor(Database db, String table) async {
    try {
      final rows = await db.rawQuery(
        'PRAGMA table_info(${_quoteIdent(table)})',
      );
      return rows
          .map((row) => (row['name'] ?? '').toString())
          .where((name) => name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<bool> _hasColumn(Database db, String table, String column) async {
    final columns = await _columnsFor(db, table);
    return columns.any((name) => name.toLowerCase() == column.toLowerCase());
  }

  Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    return rows.isNotEmpty;
  }

  Future<int> _count(
    Database db,
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    try {
      final rows = await db.rawQuery(sql, args);
      if (rows.isEmpty) return 0;
      final value = rows.first.values.first;
      return _num(value);
    } catch (_) {
      return 0;
    }
  }

  Future<String?> _scalarText(Database db, String sql) async {
    try {
      final rows = await db.rawQuery(sql);
      if (rows.isEmpty) return null;
      return rows.first.values.first?.toString();
    } catch (_) {
      return null;
    }
  }

  bool _truthy(Object? value) {
    if (value is bool) return value;
    if (value is num) return value.toInt() != 0;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == '1' || text == 'true' || text == 'yes';
  }

  int _num(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _isInternalTable(String table) {
    return table == 'sync_dirty' ||
        table == 'sync_identity' ||
        table == 'sync_uuid_mapping' ||
        table == 'sync_fk_mapping' ||
        table == 'clinic_sync_outbox' ||
        table == 'clinic_sync_state' ||
        table == 'clinic_sync_conflicts' ||
        table == 'clinic_sync_health_events' ||
        table == 'remote_id_map' ||
        table == 'stats_dirty';
  }

  String _quoteIdent(String value) {
    return '"${value.replaceAll('"', '""')}"';
  }

  String _scopeFor(AuthProvider auth) {
    if (auth.isSuperAdmin) return 'superadmin';
    final role = auth.role?.trim().toLowerCase();
    return role == null || role.isEmpty ? 'unknown_role' : role;
  }

  String _safeFilePart(String raw) {
    final safe = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return safe.isEmpty ? 'role' : safe;
  }

  JsonMap _redactJsonMap(JsonMap input) {
    final output = <String, Object?>{};
    for (final entry in input.entries) {
      output[entry.key] = _redactValue(entry.key, entry.value);
    }
    return output;
  }

  Object? _redactValue(String key, Object? value) {
    final lowerKey = key.toLowerCase();
    if (lowerKey.contains('token') ||
        lowerKey.contains('password') ||
        lowerKey.contains('secret') ||
        lowerKey.contains('authorization') ||
        lowerKey.contains('cookie')) {
      return '__redacted__';
    }
    if (value is Map) {
      final nested = <String, Object?>{};
      for (final entry in value.entries) {
        nested['${entry.key}'] = _redactValue('${entry.key}', entry.value);
      }
      return nested;
    }
    if (value is List) {
      return value
          .map((item) => _redactValue(key, item as Object?))
          .toList(growable: false);
    }
    if (value is String) {
      final redacted = _redactFreeText(value);
      if (redacted.length > 4000) {
        return '${redacted.substring(0, 4000)}\n__truncated__';
      }
      return redacted;
    }
    return value;
  }

  String _redactFreeText(String value) {
    var text = value;
    text = text.replaceAll(
      RegExp(
        r'(authorization|cookie|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]\s*[^\s,;}]+',
        caseSensitive: false,
      ),
      r'$1=__redacted__',
    );
    text = text.replaceAll(
      RegExp(r'bearer\s+[a-z0-9._\-]+', caseSensitive: false),
      'Bearer __redacted__',
    );
    return text;
  }

  String? _trimDiagnosticText(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    if (text.length <= 1000) return text;
    return '${text.substring(0, 1000)}\n__truncated__';
  }
}
