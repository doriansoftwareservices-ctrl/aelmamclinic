import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/data/chat/chat_participant_repository.dart';
import 'package:aelmamclinic/domain/chat/models/chat_participant.dart';

bool _supabaseReady = false;

void main() {
  setUpAll(() async {
    if (_supabaseReady) return;
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'public-anon-key',
    );
    _supabaseReady = true;
  });

  group('ChatParticipantFields', () {
    test('remoteColumns includes expected keys', () {
      expect(ChatParticipantFields.remoteColumns, containsAll(<String>[
        ChatParticipantFields.conversationId,
        ChatParticipantFields.userUid,
        ChatParticipantFields.email,
        ChatParticipantFields.displayName,
        ChatParticipantFields.joinedAt,
        ChatParticipantFields.lastReadAt,
        ChatParticipantFields.muted,
        ChatParticipantFields.pinned,
        ChatParticipantFields.archived,
        ChatParticipantFields.blocked,
      ]));
    });
  });

  group('ChatParticipantMapper', () {
    test('toRemote normalises values and defaults missing flags to false', () {
      final payload = ChatParticipantMapper.toRemote(<String, dynamic>{
        'conversationId': ' conv-123 ',
        'user_uid': 'user-456',
        'email': 'USER@Example.com',
        'displayName': '  Alice  ',
        'role': ' member ',
        'joined_at': '2024-10-12T12:00:00+02:00',
        'lastReadAt': DateTime.utc(2024, 10, 12, 10),
        'pinned': '1',
        'archived': 'false',
      });

      expect(payload[ChatParticipantFields.conversationId], 'conv-123');
      expect(payload[ChatParticipantFields.userUid], 'user-456');
      expect(payload[ChatParticipantFields.email], 'user@example.com');
      expect(payload[ChatParticipantFields.displayName], 'Alice');
      expect(payload[ChatParticipantFields.role], 'member');
      expect(payload[ChatParticipantFields.joinedAt], '2024-10-12T10:00:00.000Z');
      expect(payload[ChatParticipantFields.lastReadAt], '2024-10-12T10:00:00.000Z');
      expect(payload[ChatParticipantFields.muted], isFalse);
      expect(payload[ChatParticipantFields.pinned], isTrue);
      expect(payload[ChatParticipantFields.archived], isFalse);
      expect(payload[ChatParticipantFields.blocked], isFalse);
    });

    test('fromRemote uses fallbacks and parses booleans/dates', () {
      final local = ChatParticipantMapper.fromRemote(<String, dynamic>{
        'conversation_id': 'conv-001',
        'user_uid': 'user-001',
        'nickname': ' Nick ',
        'muted': 1,
        'pinned': 'true',
        'archived': null,
        'blocked': '0',
        'last_read_at': '2024-10-12T12:00:00+02:00',
      });

      expect(local[ChatParticipantFields.conversationIdCamel], 'conv-001');
      expect(local[ChatParticipantFields.userUidCamel], 'user-001');
      expect(local[ChatParticipantFields.displayNameCamel], 'Nick');
      expect(local[ChatParticipantFields.mutedCamel], isTrue);
      expect(local[ChatParticipantFields.pinnedCamel], isTrue);
      expect(local[ChatParticipantFields.archivedCamel], isFalse);
      expect(local[ChatParticipantFields.blockedCamel], isFalse);
      expect(
        local[ChatParticipantFields.lastReadAtCamel],
        equals(DateTime.utc(2024, 10, 12, 10)),
      );
    });

    test('toRemote throws when identifiers are missing', () {
      expect(
        () => ChatParticipantMapper.toRemote(<String, dynamic>{}),
        throwsArgumentError,
      );
      expect(
        () => ChatParticipantMapper.toRemote(<String, dynamic>{
              'conversation_id': 'conv',
            }),
        throwsArgumentError,
      );
    });
  });

  group('ChatParticipantRepository', () {
    test('save delegates to runner with normalised payload', () async {
      final repo = ChatParticipantRepository();
      Map<String, dynamic>? captured;

      await repo.save(
        <String, dynamic>{
          'conversation_id': 'abc',
          'userUid': 'xyz',
          'pinned': true,
        },
        runUpsert: (Map<String, dynamic> values) async {
          captured = values;
        },
      );

      expect(captured, isNotNull);
      expect(captured![ChatParticipantFields.pinned], isTrue);
      expect(captured![ChatParticipantFields.archived], isFalse);
      expect(captured![ChatParticipantFields.blocked], isFalse);
    });

    test('setPinned sends trimmed identifiers to runner', () async {
      final repo = ChatParticipantRepository();
      Map<String, dynamic>? values;
      Map<String, dynamic>? match;

      await repo.setPinned(
        conversationId: ' conv ',
        userUid: ' uid ',
        pinned: true,
        runUpdate: (Map<String, dynamic> v, Map<String, dynamic> m) async {
          values = v;
          match = m;
        },
      );

      expect(values, equals(<String, dynamic>{ChatParticipantFields.pinned: true}));
      expect(
        match,
        equals(<String, dynamic>{
          ChatParticipantFields.conversationId: 'conv',
          ChatParticipantFields.userUid: 'uid',
        }),
      );
    });

    test('setArchived updates archived flag', () async {
      final repo = ChatParticipantRepository();
      Map<String, dynamic>? values;

      await repo.setArchived(
        conversationId: 'conv',
        userUid: 'user',
        archived: true,
        runUpdate: (Map<String, dynamic> v, Map<String, dynamic> _) async {
          values = v;
        },
      );

      expect(values, equals(<String, dynamic>{ChatParticipantFields.archived: true}));
    });

    test('updateLastReadAt forwards ISO payload', () async {
      final repo = ChatParticipantRepository();
      Map<String, dynamic>? values;

      final ts = DateTime.utc(2024, 1, 1, 12, 30, 45);
      await repo.updateLastReadAt(
        conversationId: 'conv',
        userUid: 'user',
        timestamp: ts,
        runUpdate: (Map<String, dynamic> v, Map<String, dynamic> _) async {
          values = v;
        },
      );

      expect(
        values,
        equals(<String, dynamic>{
          ChatParticipantFields.lastReadAt: '2024-01-01T12:30:45.000Z',
        }),
      );
    });

    test('setPinned throws when identifiers are empty', () async {
      final repo = ChatParticipantRepository();

      await expectLater(
        repo.setPinned(
          conversationId: ' ',
          userUid: 'user',
          pinned: true,
          runUpdate: (Map<String, dynamic> _, Map<String, dynamic> __) async {},
        ),
        throwsArgumentError,
      );

      await expectLater(
        repo.setPinned(
          conversationId: 'conv',
          userUid: '',
          pinned: true,
          runUpdate: (Map<String, dynamic> _, Map<String, dynamic> __) async {},
        ),
        throwsArgumentError,
      );
    });
  });
}
