// lib/models/employee_seat_request.dart
class EmployeeSeatRequest {
  final String id;
  final String accountId;
  final String requestedByUid;
  final String employeeUserUid;
  final String employeeEmail;
  final String status;
  final String? receiptFileId;
  final String? adminNote;
  final DateTime? createdAt;

  const EmployeeSeatRequest({
    required this.id,
    required this.accountId,
    required this.requestedByUid,
    required this.employeeUserUid,
    required this.employeeEmail,
    required this.status,
    required this.receiptFileId,
    required this.adminNote,
    required this.createdAt,
  });

  factory EmployeeSeatRequest.fromMap(Map<String, dynamic> map) {
    DateTime? createdAt;
    final raw = map['created_at'] ?? map['createdAt'];
    if (raw is DateTime) {
      createdAt = raw;
    } else if (raw != null) {
      createdAt = DateTime.tryParse(raw.toString());
    }
    return EmployeeSeatRequest(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      requestedByUid: (map['requested_by_uid'] ?? '').toString(),
      employeeUserUid: (map['employee_user_uid'] ?? '').toString(),
      employeeEmail: (map['employee_email'] ?? '').toString(),
      status: (map['status'] ?? '').toString(),
      receiptFileId: map['receipt_file_id']?.toString(),
      adminNote: map['admin_note']?.toString(),
      createdAt: createdAt,
    );
  }
}
