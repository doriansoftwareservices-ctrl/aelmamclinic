class PatientComplaintTemplate {
  final String id;
  final String accountId;
  final String title;
  final String? description;
  final bool isActive;
  final int sortOrder;
  final String? createdBy;
  final String? updatedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const PatientComplaintTemplate({
    required this.id,
    required this.accountId,
    required this.title,
    this.description,
    required this.isActive,
    required this.sortOrder,
    this.createdBy,
    this.updatedBy,
    this.createdAt,
    this.updatedAt,
  });

  factory PatientComplaintTemplate.fromMap(Map<String, dynamic> map) {
    return PatientComplaintTemplate(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      description: map['description']?.toString(),
      isActive: map['is_active'] == true,
      sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
      createdBy: map['created_by']?.toString(),
      updatedBy: map['updated_by']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
    );
  }
}
