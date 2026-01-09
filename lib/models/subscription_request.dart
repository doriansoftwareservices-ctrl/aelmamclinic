class SubscriptionRequest {
  final String id;
  final String accountId;
  final String userUid;
  final String planCode;
  final String status;
  final double amount;
  final String? paymentMethodId;
  final String? proofUrl;
  final String? referenceText;
  final String? senderName;
  final String? clinicName;
  final DateTime? createdAt;

  const SubscriptionRequest({
    required this.id,
    required this.accountId,
    required this.userUid,
    required this.planCode,
    required this.status,
    required this.amount,
    this.paymentMethodId,
    this.proofUrl,
    this.referenceText,
    this.senderName,
    this.clinicName,
    this.createdAt,
  });

  factory SubscriptionRequest.fromMap(Map<String, dynamic> map) {
    return SubscriptionRequest(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      userUid: (map['user_uid'] ?? '').toString(),
      planCode: (map['plan_code'] ?? '').toString(),
      status: (map['status'] ?? '').toString(),
      amount: _toDouble(map['amount']),
      paymentMethodId: map['payment_method_id']?.toString(),
      proofUrl: map['proof_url']?.toString(),
      referenceText: map['reference_text']?.toString(),
      senderName: map['sender_name']?.toString(),
      clinicName: map['clinic_name']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    );
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }
}
