class Complaint {
  final String id;
  final String accountId;
  final String userUid;
  final String status;
  final String message;
  final String? subject;
  final String? replyMessage;
  final DateTime? repliedAt;
  final String? repliedBy;
  final DateTime? createdAt;

  const Complaint({
    required this.id,
    required this.accountId,
    required this.userUid,
    required this.status,
    required this.message,
    this.subject,
    this.replyMessage,
    this.repliedAt,
    this.repliedBy,
    this.createdAt,
  });

  factory Complaint.fromMap(Map<String, dynamic> map) {
    return Complaint(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      userUid: (map['user_uid'] ?? '').toString(),
      status: (map['status'] ?? '').toString(),
      message: (map['message'] ?? '').toString(),
      subject: map['subject']?.toString(),
      replyMessage: map['reply_message']?.toString(),
      repliedAt: DateTime.tryParse(map['replied_at']?.toString() ?? ''),
      repliedBy: map['replied_by']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    );
  }
}
