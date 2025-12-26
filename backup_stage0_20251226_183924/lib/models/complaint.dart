class Complaint {
  final String id;
  final String accountId;
  final String userUid;
  final String status;
  final String message;
  final String? subject;
  final DateTime? createdAt;

  const Complaint({
    required this.id,
    required this.accountId,
    required this.userUid,
    required this.status,
    required this.message,
    this.subject,
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
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    );
  }
}
