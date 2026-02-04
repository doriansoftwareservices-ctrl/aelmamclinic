class PatientReport {
  final String id;
  final String accountId;
  final String patientId;
  final String? patientComplaintId;
  final String reportText;
  final String status;
  final Map<String, dynamic> snapshot;
  final String createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const PatientReport({
    required this.id,
    required this.accountId,
    required this.patientId,
    this.patientComplaintId,
    required this.reportText,
    required this.status,
    required this.snapshot,
    required this.createdBy,
    this.createdAt,
    this.updatedAt,
  });

  factory PatientReport.fromMap(Map<String, dynamic> map) {
    final snap = map['snapshot'];
    return PatientReport(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      patientId: (map['patient_id'] ?? '').toString(),
      patientComplaintId: map['patient_complaint_id']?.toString(),
      reportText: (map['report_text'] ?? '').toString(),
      status: (map['status'] ?? '').toString(),
      snapshot: snap is Map<String, dynamic>
          ? snap
          : (snap is Map ? Map<String, dynamic>.from(snap) : <String, dynamic>{}),
      createdBy: (map['created_by'] ?? '').toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
    );
  }
}
