// lib/local/chat_local_store.dart
//
// كاش محلي بسيط للرسائل باستخدام SQLite (sqflite).
// - تخزين الرسائل فقط (مع المرفقات كنص JSON داخل العمود attachments_json).
// - استرجاع صفحات رسائل حسب conversation_id وترتيب زمني تنازلي.
// - upsert للرسائل (INSERT OR REPLACE) + تحديث حالة الفشل.
// - دعم reply_to_message_id / reply_to_snippet / mentions_json.
// - ترقية مخطط DB إلى v3 مع جدول conv_meta لتخزين last_read_at لكل محادثة.
// - حد أعلى للكاش لكل محادثة (500) + pruning تلقائي بعد كل upsert.
//
// ملاحظة: التخزين محلي فقط للرسائل. يمكن التوسيع لاحقًا (conversations/reads/participants).

import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:aelmamclinic/models/chat_models.dart';

class ChatLocalStore {
  ChatLocalStore._();
  static final ChatLocalStore instance = ChatLocalStore._();

  static const _dbName = 'chat_cache.db';
  static const _dbVersion = 3; // ترقية للإصدار 3 (أضفنا conv_meta)
  static const _table = 'messages';
  static const _tableMeta = 'conv_meta';

  /// الحد الأعلى للرسائل المحتفظ بها لكل محادثة.
  static const int _maxPerConversation = 500;

  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onOpen: (db) async {
        try {
          await db.execute('PRAGMA journal_mode=WAL;');
          await db.execute('PRAGMA foreign_keys=ON;');
        } catch (_) {}
      },
      onCreate: (db, v) async {
        await _createV2Tables(db);
        await _createV3Tables(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await _tryAddColumn(db, _table, 'reply_to_message_id', 'TEXT');
          await _tryAddColumn(db, _table, 'reply_to_snippet', 'TEXT');
          await _tryAddColumn(db, _table, 'mentions_json', 'TEXT');
          try {
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_messages_conv_created ON $_table(conversation_id, created_at DESC)',
            );
          } catch (_) {}
        }
        if (oldV < 3) {
          await _createV3Tables(db);
        }
      },
    );
    return _db!;
  }

  Future<void> _createV2Tables(Database db) async {
    await db.execute('''
CREATE TABLE $_table(
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  sender_uid TEXT,
  sender_email TEXT,
  kind TEXT,
  body TEXT,
  edited INTEGER,
  deleted INTEGER,
  created_at TEXT,
  edited_at TEXT,
  deleted_at TEXT,
  status TEXT,
  local_id_client TEXT,
  account_id TEXT,
  device_id TEXT,
  local_seq INTEGER,
  attachments_json TEXT,
  -- v2:
  reply_to_message_id TEXT,
  reply_to_snippet TEXT,
  mentions_json TEXT
);
''');
    await db.execute(
      'CREATE INDEX idx_messages_conv_created ON $_table(conversation_id, created_at DESC)',
    );
  }

  Future<void> _createV3Tables(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $_tableMeta(
  conversation_id TEXT PRIMARY KEY,
  last_read_at TEXT
);
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_meta_conv ON $_tableMeta(conversation_id)',
    );
  }

  static Future<void> _tryAddColumn(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Upsert مجموعة رسائل (+ pruning تلقائي)
  // ---------------------------------------------------------------------------
  Future<void> upsertMessages(List<ChatMessage> msgs) async {
    if (msgs.isEmpty) return;
    final db = await _open();

    final touched = <String>{};

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final m in msgs) {
        final attachmentsJson =
            jsonEncode(m.attachments.map((e) => e.toMap()).toList());
        final mentionsJson =
            (m.mentions == null) ? null : jsonEncode(m.mentions);

        batch.insert(
          _table,
          {
            'id': m.id,
            'conversation_id': m.conversationId,
            'sender_uid': m.senderUid,
            'sender_email': m.senderEmail,
            'kind': m.kind.dbValue,
            'body': m.body,
            'edited': m.edited ? 1 : 0,
            'deleted': m.deleted ? 1 : 0,
            'created_at': m.createdAt.toUtc().toIso8601String(),
            'edited_at': m.editedAt?.toUtc().toIso8601String(),
            'deleted_at': m.deletedAt?.toUtc().toIso8601String(),
            'status': m.status.nameDb,
            'local_id_client': m.localId,
            'account_id': m.accountId,
            'device_id': m.deviceId,
            'local_seq': m.localSeq,
            'attachments_json': attachmentsJson,
            // v2:
            'reply_to_message_id': m.replyToMessageId,
            'reply_to_snippet': m.replyToSnippet,
            'mentions_json': mentionsJson,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        if (m.conversationId.isNotEmpty) {
          touched.add(m.conversationId);
        }
      }
      await batch.commit(noResult: true);
    });

    for (final cid in touched) {
      await pruneConversation(cid, keep: _maxPerConversation);
    }
  }

  Future<void> upsertMessage(ChatMessage m) => upsertMessages([m]);

  // ---------------------------------------------------------------------------
  // جلب صفحة رسائل
  // ---------------------------------------------------------------------------
  Future<List<ChatMessage>> getMessages(
    String conversationId, {
    String? beforeIso,
    int limit = 30,
    bool includeDeleted = false,
  }) async {
    final db = await _open();
    final where = StringBuffer('conversation_id = ?');
    final args = <Object?>[conversationId];

    if (!includeDeleted) {
      where.write(' AND (deleted IS NULL OR deleted = 0)');
    }
    if (beforeIso != null && beforeIso.trim().isNotEmpty) {
      where.write(' AND created_at < ?');
      args.add(beforeIso);
    }

    final rows = await db.query(
      _table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: limit,
    );

    final list = <ChatMessage>[];
    for (final r in rows) {
      // المرفقات
      List<ChatAttachment> atts = const [];
      try {
        final aj = r['attachments_json'] as String?;
        if ((aj)?.isNotEmpty == true) {
          final arr = jsonDecode(aj!) as List<dynamic>;
          atts = arr
              .whereType<Map<String, dynamic>>()
              .map(ChatAttachment.fromMap)
              .toList();
        }
      } catch (_) {}

      // mentions
      List<String>? mentions;
      try {
        final mj = r['mentions_json'] as String?;
        if ((mj)?.isNotEmpty == true) {
          final arr = jsonDecode(mj!) as List<dynamic>;
          mentions = arr
              .map((e) => e?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .toList();
          if (mentions.isEmpty) mentions = null;
        }
      } catch (_) {}

      list.add(
        ChatMessage(
          id: (r['id'] as String?) ?? '',
          conversationId: (r['conversation_id'] as String?) ?? '',
          senderUid: (r['sender_uid'] as String?) ?? '',
          senderEmail: r['sender_email'] as String?,
          kind: ChatMessageKindX.fromDb(r['kind'] as String?),
          body: r['body'] as String?,
          attachments: atts,
          edited: (r['edited'] as int? ?? 0) == 1,
          deleted: (r['deleted'] as int? ?? 0) == 1,
          createdAt:
              DateTime.tryParse((r['created_at'] as String?) ?? '')?.toUtc() ??
                  DateTime.now().toUtc(),
          editedAt: (r['edited_at'] as String?) != null
              ? DateTime.tryParse(r['edited_at'] as String)?.toUtc()
              : null,
          deletedAt: (r['deleted_at'] as String?) != null
              ? DateTime.tryParse(r['deleted_at'] as String)?.toUtc()
              : null,
          status: ChatMessageStatusX.fromDb(r['status'] as String?),
          localId: r['local_id_client'] as String?,
          accountId: r['account_id'] as String?,
          deviceId: r['device_id'] as String?,
          localSeq: (r['local_seq'] as int?),
          // v2:
          replyToMessageId: r['reply_to_message_id'] as String?,
          replyToSnippet: r['reply_to_snippet'] as String?,
          mentions: mentions,
        ),
      );
    }
    return list;
  }

  // ---------------------------------------------------------------------------
  // تحديثات محلية
  // ---------------------------------------------------------------------------
  Future<void> updateMessageStatus({
    required String messageId,
    required ChatMessageStatus status,
  }) async {
    final db = await _open();
    await db.update(
      _table,
      {'status': status.nameDb},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> updateMessageBody({
    required String messageId,
    required String newBody,
    DateTime? editedAt,
  }) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'body': newBody,
        'edited': 1,
        'edited_at': (editedAt ?? DateTime.now().toUtc()).toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> markMessageDeleted({
    required String messageId,
    DateTime? deletedAt,
  }) async {
    final db = await _open();
    await db.update(
      _table,
      {
        'deleted': 1,
        'deleted_at': (deletedAt ?? DateTime.now().toUtc()).toIso8601String(),
        'body': null,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> deleteMessage(String messageId) async {
    final db = await _open();
    await db.delete(_table, where: 'id = ?', whereArgs: [messageId]);
  }

  // ---------------------------------------------------------------------------
  // مسح/قراءة meta (last_read_at)
  // ---------------------------------------------------------------------------
  Future<void> clearConversation(String conversationId) async {
    final db = await _open();
    await db.delete(_table,
        where: 'conversation_id = ?', whereArgs: [conversationId]);
    await db.delete(_tableMeta,
        where: 'conversation_id = ?', whereArgs: [conversationId]);
  }

  Future<void> clearAll() async {
    final db = await _open();
    await db.delete(_table);
    await db.delete(_tableMeta);
  }

  Future<void> upsertRead(String conversationId, DateTime lastReadAt) async {
    final db = await _open();
    await db.insert(
      _tableMeta,
      {
        'conversation_id': conversationId,
        'last_read_at': lastReadAt.toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<DateTime?> getLastRead(String conversationId) async {
    final db = await _open();
    final row = (await db.query(
      _tableMeta,
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      limit: 1,
    ))
        .firstOrNull;
    if (row == null) return null;
    final s = row['last_read_at'] as String?;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toUtc();
  }

  // ---------------------------------------------------------------------------
  // Pruning: إبقاء آخر N من الرسائل لكل محادثة
  // ---------------------------------------------------------------------------
  Future<void> pruneConversation(String conversationId,
      {int keep = _maxPerConversation}) async {
    final db = await _open();
    if (keep <= 0) return;

    final cntRow = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM $_table WHERE conversation_id = ?',
      [conversationId],
    ));
    final count = (cntRow ?? 0);
    if (count <= keep) return;

    final cutRows = await db.rawQuery('''
SELECT created_at FROM $_table
WHERE conversation_id = ?
ORDER BY created_at DESC
LIMIT 1 OFFSET ?
''', [conversationId, keep - 1]);

    if (cutRows.isEmpty) return;
    final cutoff = (cutRows.first['created_at'] as String?) ?? '';
    if (cutoff.isEmpty) return;

    await db.delete(
      _table,
      where: 'conversation_id = ? AND created_at < ?',
      whereArgs: [conversationId, cutoff],
    );
  }

  Future<int> countMessages(String conversationId) async {
    final db = await _open();
    final v = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM $_table WHERE conversation_id = ?',
      [conversationId],
    ));
    return v ?? 0;
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
