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
  static const _dbVersion = 4; // v4: conversations/participants/reads/outbox
  static const _table = 'messages';
  static const _tableMeta = 'conv_meta';
  static const _tableConvs = 'conversations';
  static const _tableParts = 'participants';
  static const _tableReads = 'read_states';
  static const _tableOutbox = 'outbox';

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
        await _createV4Tables(db);
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
        if (oldV < 4) {
          await _createV4Tables(db);
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

  Future<void> _createV4Tables(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS $_tableConvs(
  id TEXT PRIMARY KEY,
  account_id TEXT,
  is_group INTEGER,
  title TEXT,
  created_by TEXT,
  created_at TEXT,
  updated_at TEXT,
  last_msg_at TEXT,
  last_msg_snippet TEXT,
  unread_count INTEGER,
  is_frozen INTEGER,
  admins_only INTEGER,
  is_deleted INTEGER
);
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_convs_last_msg ON $_tableConvs(last_msg_at DESC)',
    );

    await db.execute('''
CREATE TABLE IF NOT EXISTS $_tableParts(
  conversation_id TEXT NOT NULL,
  user_uid TEXT NOT NULL,
  email TEXT,
  nickname TEXT,
  joined_at TEXT,
  role TEXT,
  archived INTEGER,
  pinned INTEGER,
  blocked INTEGER,
  is_deleted INTEGER,
  deleted_at TEXT,
  PRIMARY KEY (conversation_id, user_uid)
);
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_parts_conv ON $_tableParts(conversation_id)',
    );

    await db.execute('''
CREATE TABLE IF NOT EXISTS $_tableReads(
  conversation_id TEXT NOT NULL,
  user_uid TEXT NOT NULL,
  last_delivered_message_id TEXT,
  last_delivered_at TEXT,
  last_read_message_id TEXT,
  last_read_at TEXT,
  PRIMARY KEY (conversation_id, user_uid)
);
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reads_conv ON $_tableReads(conversation_id)',
    );

    await db.execute('''
CREATE TABLE IF NOT EXISTS $_tableOutbox(
  local_id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  kind TEXT,
  body TEXT,
  created_at TEXT,
  reply_to_message_id TEXT,
  reply_to_snippet TEXT,
  mentions_json TEXT,
  attachments_json TEXT,
  status TEXT,
  error TEXT
);
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_outbox_conv_created ON $_tableOutbox(conversation_id, created_at DESC)',
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
  // Conversations / Participants / Read states (v4)
  // ---------------------------------------------------------------------------
  int _b(bool v) => v ? 1 : 0;

  Future<void> upsertConversations(List<ChatConversation> convs) async {
    if (convs.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final c in convs) {
        batch.insert(
          _tableConvs,
          {
            'id': c.id,
            'account_id': c.accountId,
            'is_group': c.isGroup ? 1 : 0,
            'title': c.title,
            'created_by': c.createdBy,
            'created_at': c.createdAt.toUtc().toIso8601String(),
            'updated_at': c.updatedAt?.toUtc().toIso8601String(),
            'last_msg_at': c.lastMsgAt?.toUtc().toIso8601String(),
            'last_msg_snippet': c.lastMsgSnippet,
            'unread_count': c.unreadCount ?? 0,
            'is_frozen': _b(c.isFrozen),
            'admins_only': _b(c.adminsOnly),
            'is_deleted': _b(c.isDeleted),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<ChatConversation>> getConversations() async {
    final db = await _open();
    final rows = await db.query(
      _tableConvs,
      orderBy: 'last_msg_at DESC',
    );
    return rows
        .map((r) => ChatConversation.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> upsertParticipants(List<Map<String, dynamic>> participants) async {
    if (participants.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final p in participants) {
        batch.insert(
          _tableParts,
          {
            'conversation_id': p['conversation_id']?.toString(),
            'user_uid': p['user_uid']?.toString(),
            'email': p['email']?.toString(),
            'nickname': p['nickname']?.toString(),
            'joined_at': p['joined_at']?.toString(),
            'role': p['role']?.toString(),
            'archived': _b((p['archived'] == true) || p['archived'] == 1),
            'pinned': _b((p['pinned'] == true) || p['pinned'] == 1),
            'blocked': _b((p['blocked'] == true) || p['blocked'] == 1),
            'is_deleted': _b((p['is_deleted'] == true) || p['is_deleted'] == 1),
            'deleted_at': p['deleted_at']?.toString(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Map<String, dynamic>>> getParticipants(String conversationId) async {
    final db = await _open();
    final rows = await db.query(
      _tableParts,
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'joined_at ASC',
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<void> upsertReadStates(List<ChatReadState> states) async {
    if (states.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final s in states) {
        batch.insert(
          _tableReads,
          {
            'conversation_id': s.conversationId,
            'user_uid': s.userUid,
            'last_delivered_message_id': s.lastDeliveredMessageId,
            'last_delivered_at': s.lastDeliveredAt?.toUtc().toIso8601String(),
            'last_read_message_id': s.lastReadMessageId,
            'last_read_at': s.lastReadAt?.toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<ChatReadState>> getReadStates(String conversationId) async {
    final db = await _open();
    final rows = await db.query(
      _tableReads,
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    return rows
        .map((r) => ChatReadState.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Outbox (offline-first)
  // ---------------------------------------------------------------------------
  Future<void> upsertOutboxMessage(Map<String, dynamic> payload) async {
    final db = await _open();
    await db.insert(_tableOutbox, payload,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getOutbox({int limit = 200}) async {
    final db = await _open();
    final rows = await db.query(
      _tableOutbox,
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<void> deleteOutboxMessage(String localId) async {
    final db = await _open();
    await db.delete(_tableOutbox, where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<void> clearOutbox() async {
    final db = await _open();
    await db.delete(_tableOutbox);
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
