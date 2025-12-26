class PaymentPlanStat {
  final String? planCode;
  final double totalAmount;
  final int paymentsCount;

  const PaymentPlanStat({
    required this.planCode,
    required this.totalAmount,
    required this.paymentsCount,
  });

  factory PaymentPlanStat.fromMap(Map<String, dynamic> map) {
    return PaymentPlanStat(
      planCode: map['plan_code']?.toString(),
      totalAmount: _toDouble(map['total_amount']),
      paymentsCount: (map['payments_count'] as num?)?.toInt() ?? 0,
    );
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }
}
