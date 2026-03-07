// lib/models/support_rating_entry.dart

class SupportRatingEntry {
  final String conversationId;
  final String? accountId;
  final String? ownerUid;
  final String sessionId;
  final int rating; // 1..5
  final String? note;
  final DateTime submittedAt; // UTC

  const SupportRatingEntry({
    required this.conversationId,
    required this.sessionId,
    required this.rating,
    required this.submittedAt,
    this.accountId,
    this.ownerUid,
    this.note,
  });
}
