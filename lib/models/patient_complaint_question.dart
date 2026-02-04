class PatientComplaintQuestion {
  final String id;
  final String accountId;
  final String complaintId;
  final String questionText;
  final bool isActive;
  final int sortOrder;
  final String? createdBy;
  final String? updatedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const PatientComplaintQuestion({
    required this.id,
    required this.accountId,
    required this.complaintId,
    required this.questionText,
    required this.isActive,
    required this.sortOrder,
    this.createdBy,
    this.updatedBy,
    this.createdAt,
    this.updatedAt,
  });

  factory PatientComplaintQuestion.fromMap(Map<String, dynamic> map) {
    return PatientComplaintQuestion(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      complaintId: (map['complaint_id'] ?? '').toString(),
      questionText: (map['question_text'] ?? '').toString(),
      isActive: map['is_active'] == true,
      sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
      createdBy: map['created_by']?.toString(),
      updatedBy: map['updated_by']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
    );
  }
}
