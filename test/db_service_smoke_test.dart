import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'support/native_sqlite.dart';

void main() {
  final hasNativeSqlite = ensureNativeSqlite();
  if (!hasNativeSqlite) {
    test(
      'db_service_smoke_test skipped when sqlite3.dll is unavailable',
      () {},
      skip: 'Missing native sqlite3 library; install sqlite3.dll or set PATH.',
    );
    return;
  }

  late Directory tempDir;
  late String testDbPath;

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('db_service_test_');
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

  test('insertPatient persists and emits change notification', () async {
    final events = <String>[];
    DBService.instance.onLocalChange = (table) async {
      events.add(table);
    };

    final resolvedPath = await DBService.instance.getDatabasePath();
    expect(resolvedPath, equals(testDbPath));

    final patient = Patient(
      name: 'Test Patient',
      age: 30,
      diagnosis: 'Initial',
      paidAmount: 100,
      remaining: 50,
      registerDate: DateTime.utc(2024, 1, 1),
      phoneNumber: '123456789',
    );

    final id = await DBService.instance.insertPatient(patient);
    final db = await DBService.instance.database;
    final rows =
        await db.query(Patient.table, where: 'id = ?', whereArgs: [id]);

    expect(rows, isNotEmpty);
    expect(rows.first['name'], equals('Test Patient'));

    // allow debounce (220ms) inside DBService to trigger.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(events.contains(Patient.table), isTrue);
  });

  test('migration upgrades alert_settings.threshold to REAL', () async {
    final factory = databaseFactoryFfi;
    final legacyDb = await factory.openDatabase(
      testDbPath,
      options: sqflite.OpenDatabaseOptions(
        version: 28,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE ${AlertSetting.table} (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              item_id INTEGER NOT NULL UNIQUE,
              threshold INTEGER NOT NULL,
              is_enabled INTEGER NOT NULL DEFAULT 1,
              last_triggered TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
          ''');
          await db.insert(AlertSetting.table, {
            'item_id': 42,
            'threshold': 5,
            'is_enabled': 1,
            'created_at': DateTime.utc(2024, 1, 1).toIso8601String(),
          });
        },
      ),
    );
    await legacyDb.close();

    final db = await DBService.instance.database;
    final pragma = await db.rawQuery("PRAGMA table_info(${AlertSetting.table})");
    final thresholdCol = pragma.firstWhere(
      (row) => ((row['name'] ?? '') as String).toLowerCase() == 'threshold',
      orElse: () => {},
    );
    expect(((thresholdCol['type'] ?? '') as String).toUpperCase(), contains('REAL'));

    final rows = await db.query(AlertSetting.table);
    expect(rows, isNotEmpty);
    expect((rows.first['threshold'] as num).toDouble(), equals(5.0));
  });
}
