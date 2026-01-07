import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'support/native_sqlite.dart';

void main() {
  late Directory tempDir;
  late String testDbPath;

  setUpAll(() {
    ensureNativeSqlite();
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_fk_mapping_test_');
    databaseFactoryFfi.setDatabasesPath(tempDir.path);
    testDbPath = p.join(tempDir.path, 'clinic.db');
    await DBService.instance.resetForTesting(databasePath: testDbPath);
  });

  tearDown(() async {
    DBService.instance.onLocalChange = null;
    await DBService.instance.flushAndClose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    DBService.setTestDatabasePath(null);
  });

  test('sync_fk_mapping table exists and upserts via replace', () async {
    final db = await DBService.instance.database;

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_fk_mapping'",
    );
    expect(tables, isNotEmpty,
        reason: 'sync_fk_mapping table should be created');

    const tableName = 'patients';
    const localId = 1;

    Future<Map<String, Object?>> fetchRow() async {
      final rows = await db.query(
        'sync_fk_mapping',
        where: 'table_name = ? AND local_id = ?',
        whereArgs: [tableName, localId],
        limit: 1,
      );
      return rows.isEmpty ? <String, Object?>{} : rows.first;
    }

    await db.insert(
      'sync_fk_mapping',
      {
        'table_name': tableName,
        'local_id': localId,
        'remote_id': 'initial-uuid',
        'remote_device_id': 'device-a',
        'remote_local_id': 99,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    var stored = await fetchRow();
    expect(stored['remote_id'], equals('initial-uuid'));

    await db.insert(
      'sync_fk_mapping',
      {
        'table_name': tableName,
        'local_id': localId,
        'remote_id': 'updated-uuid',
        'remote_device_id': 'device-b',
        'remote_local_id': 101,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    stored = await fetchRow();
    expect(stored['remote_id'], equals('updated-uuid'));
    expect(stored['remote_device_id'], equals('device-b'));
    expect(stored['remote_local_id'], equals(101));
  });
}
