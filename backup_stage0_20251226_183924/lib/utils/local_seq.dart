// lib/utils/local_seq.dart
//
// مُولِّد تسلسلات محلية (Monotonic Local Sequence) يعتمد على SQLite (sqflite).
// - آمن للسباقات عبر المعاملات.
// - يدعم مفاتيح/Scopes متعددة: عام، لكل محادثة، أو لكل (accountId, deviceId).
// - مناسب لعمود local_id/localSeq ورسائل التفاؤل.

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalSeq {
  LocalSeq._();
  static final LocalSeq instance = LocalSeq._();

  static const String _dbName = 'local_seq.db';
  static const String _table = 'counters';

  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    _db = await openDatabase(
      path,
      version: 1,
      onOpen: (db) async {
        try {
          await db.execute('PRAGMA journal_mode=WAL;');
          await db.execute('PRAGMA foreign_keys=ON;');
        } catch (_) {}
      },
      onCreate: (db, v) async {
        await db.execute('''
CREATE TABLE $_table(
  key TEXT PRIMARY KEY,
  val INTEGER NOT NULL
);
''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_counters_key ON $_table(key);');
      },
    );
    return _db!;
  }

  static String buildKey({
    String namespace = 'msg',
    String? conversationId,
    String? accountId,
    String? deviceId,
  }) {
    final parts = <String>['ns:$namespace'];
    if (accountId != null && accountId.trim().isNotEmpty)
      parts.add('acc:${accountId.trim()}');
    if (deviceId != null && deviceId.trim().isNotEmpty)
      parts.add('dev:${deviceId.trim()}');
    if (conversationId != null && conversationId.trim().isNotEmpty) {
      parts.add('conv:${conversationId.trim()}');
    }
    return parts.join('|');
  }

  Future<int?> currentRawKey(String key) async {
    final db = await _open();
    final row =
        (await db.query(_table, where: 'key = ?', whereArgs: [key], limit: 1))
            .firstOrNull;
    if (row == null) return null;
    final v = row['val'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  Future<void> seedRawKey(String key, int value) async {
    final db = await _open();
    await db.transaction((txn) async {
      final row = (await txn.query(_table,
              where: 'key = ?', whereArgs: [key], limit: 1))
          .firstOrNull;
      if (row == null) {
        await txn.insert(_table, {'key': key, 'val': value});
        return;
      }
      final cur = (row['val'] is int)
          ? row['val'] as int
          : int.tryParse(row['val']?.toString() ?? '') ?? 0;
      if (value > cur) {
        await txn.update(_table, {'val': value},
            where: 'key = ?', whereArgs: [key]);
      }
    });
  }

  Future<void> resetRawKey(String key, {int to = 0}) async {
    final db = await _open();
    await db.insert(
      _table,
      {'key': key, 'val': to},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> nextRawKey(
    String key, {
    int step = 1,
    int startAt = 1,
  }) async {
    final db = await _open();
    return await db.transaction((txn) async {
      final row = (await txn.query(_table,
              where: 'key = ?', whereArgs: [key], limit: 1))
          .firstOrNull;
      if (row == null) {
        final init = (startAt <= 0) ? 1 : startAt;
        await txn.insert(_table, {'key': key, 'val': init});
        return init;
      }
      final cur = (row['val'] is int)
          ? row['val'] as int
          : int.tryParse(row['val']?.toString() ?? '') ?? 0;
      final next = cur + (step <= 0 ? 1 : step);
      await txn.update(_table, {'val': next},
          where: 'key = ?', whereArgs: [key]);
      return next;
    });
  }

  // واجهات مريحة
  Future<int> nextGlobal({String namespace = 'msg'}) {
    final key = buildKey(namespace: namespace);
    return nextRawKey(key);
  }

  Future<int?> currentGlobal({String namespace = 'msg'}) {
    final key = buildKey(namespace: namespace);
    return currentRawKey(key);
  }

  Future<int> nextForConversation(String conversationId,
      {String namespace = 'msg'}) {
    final key = buildKey(namespace: namespace, conversationId: conversationId);
    return nextRawKey(key);
  }

  Future<int?> currentForConversation(String conversationId,
      {String namespace = 'msg'}) {
    final key = buildKey(namespace: namespace, conversationId: conversationId);
    return currentRawKey(key);
  }

  Future<int> nextForTriplet({
    required String deviceId,
    String? accountId,
    String namespace = 'msg',
  }) {
    final key = buildKey(
        namespace: namespace, accountId: accountId, deviceId: deviceId);
    return nextRawKey(key);
  }

  Future<int?> currentForTriplet({
    required String deviceId,
    String? accountId,
    String namespace = 'msg',
  }) {
    final key = buildKey(
        namespace: namespace, accountId: accountId, deviceId: deviceId);
    return currentRawKey(key);
  }

  Future<void> close() async {
    final db = _db;
    if (db != null && db.isOpen) {
      await db.close();
    }
    _db = null;
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
