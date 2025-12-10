import 'package:flutter_test/flutter_test.dart';

import 'package:aelmamclinic/models/chat_invitation.dart';

void main() {
  group('ChatGroupInvitation model', () {
    test('parses Supabase view rows with normalized email', () {
      final inv = ChatGroupInvitation.fromMap({
        'id': '1',
        'conversation_id': 'conv-1',
        'inviter_uid': 'inviter-uid',
        'invitee_uid': 'invitee-uid',
        'invitee_email': 'USER@example.com',
        'status': 'pending',
        'created_at': '2025-11-07T00:00:00Z',
        'responded_at': null,
        'response_note': null,
        'title': 'Group A',
        'is_group': true,
        'account_id': 'acc-1',
        'created_by': 'owner-uid',
      });

      expect(inv.id, '1');
      expect(inv.conversationId, 'conv-1');
      expect(inv.inviterUid, 'inviter-uid');
      expect(inv.inviteeUid, 'invitee-uid');
      expect(inv.inviteeEmail, 'user@example.com');
      expect(inv.conversationTitle, 'Group A');
      expect(inv.isGroup, isTrue);
    });

    test(
        'accepts legacy inviter/invitee columns and lowercases email on output',
        () {
      final createdAt = DateTime.parse('2025-11-07T01:02:03Z');
      final inv = ChatGroupInvitation.fromMap({
        'id': '2',
        'conversation_id': 'conv-2',
        'inviter': 'legacy-inviter',
        'invitee_user': null,
        'invitee_email': 'MiXeD@Email.COM',
        'status': 'declined',
        'created_at': createdAt.toIso8601String(),
      });

      expect(inv.inviterUid, 'legacy-inviter');
      expect(inv.inviteeUid, isNull);
      expect(inv.inviteeEmail, 'mixed@email.com');
      expect(inv.isDeclined, isTrue);

      final serialized = inv.toMap();
      expect(serialized['inviter_uid'], 'legacy-inviter');
      expect(serialized['invitee_email'], 'mixed@email.com');
      expect(serialized['status'], 'declined');
      expect(serialized['conversation_id'], 'conv-2');
    });
  });
}
