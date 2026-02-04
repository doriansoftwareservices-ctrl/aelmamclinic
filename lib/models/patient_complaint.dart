class PatientComplaint {
  final String id;
  final String accountId;
  final String patientId;
  final String? complaintId;
  final String? complaintTitleCustom;
  final String status;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const PatientComplaint({
    required this.id,
    required this.accountId,
    required this.patientId,
    this.complaintId,
    this.complaintTitleCustom,
    required this.status,
    this.createdBy,
    this.createdAt,
    this.updatedAt,
  });

  factory PatientComplaint.fromMap(Map<String, dynamic> map) {
    return PatientComplaint(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      patientId: (map['patient_id'] ?? '').toString(),
      complaintId: map['complaint_id']?.toString(),
      complaintTitleCustom: map['complaint_title_custom']?.toString(),
      status: (map['status'] ?? '').toString(),
      createdBy: map['created_by']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
    );
  }
}
