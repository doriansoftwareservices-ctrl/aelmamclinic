class PatientComplaintAnswer {
  final String id;
  final String accountId;
  final String patientComplaintId;
  final String questionId;
  final bool? answerBool;
  final String? noteText;
  final String? answeredBy;
  final DateTime? answeredAt;
  final DateTime? updatedAt;

  const PatientComplaintAnswer({
    required this.id,
    required this.accountId,
    required this.patientComplaintId,
    required this.questionId,
    this.answerBool,
    this.noteText,
    this.answeredBy,
    this.answeredAt,
    this.updatedAt,
  });

  factory PatientComplaintAnswer.fromMap(Map<String, dynamic> map) {
    return PatientComplaintAnswer(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      patientComplaintId: (map['patient_complaint_id'] ?? '').toString(),
      questionId: (map['question_id'] ?? '').toString(),
      answerBool: map['answer_bool'] as bool?,
      noteText: map['note_text']?.toString(),
      answeredBy: map['answered_by']?.toString(),
      answeredAt: DateTime.tryParse(map['answered_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? ''),
    );
  }
}
