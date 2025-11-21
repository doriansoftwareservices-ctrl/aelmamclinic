import 'package:flutter_test/flutter_test.dart';

import 'package:aelmamclinic/models/chat_models.dart';

void main() {
  group('ChatMessage delivery receipts', () {
    test('marks my messages as delivered when another user acknowledges', () {
      final msg = ChatMessage.fromMap({
        'id': 'm-1',
        'conversation_id': 'c-1',
        'sender_uid': 'me-uid',
        'kind': 'text',
        'body': 'hi',
        'created_at': '2025-11-08T00:00:00Z',
        'delivery_receipts': [
          {'user_uid': 'other-uid', 'delivered_at': '2025-11-08T00:00:01Z'},
        ],
      }, currentUid: 'me-uid');

      expect(msg.status, ChatMessageStatus.delivered);
      expect(msg.deliveryReceipts, hasLength(1));
      expect(msg.deliveryReceipts.first.userUid, 'other-uid');
    });

    test('serializes delivery receipts roundtrip', () {
      final receipt = ChatDeliveryReceipt(
        userUid: 'a-user',
        deliveredAt: DateTime.utc(2025, 11, 8, 12, 0, 0),
      );

      final msg = ChatMessage(
        id: 'm-2',
        conversationId: 'c-1',
        senderUid: 'other',
        kind: ChatMessageKind.text,
        body: 'payload',
        createdAt: DateTime.utc(2025, 11, 8, 12, 0, 0),
        deliveryReceipts: [receipt],
      );

      final serialized = msg.toMap();
      expect(serialized['delivery_receipts'], isA<List>());

      final restored = ChatMessage.fromMap(serialized, currentUid: 'someone');
      expect(restored.deliveryReceipts, hasLength(1));
      expect(restored.deliveryReceipts.first.userUid, receipt.userUid);
    });
  });
}
