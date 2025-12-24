class PaymentStat {
  final String? paymentMethodId;
  final String? paymentMethodName;
  final double totalAmount;
  final int paymentsCount;

  const PaymentStat({
    required this.paymentMethodId,
    required this.paymentMethodName,
    required this.totalAmount,
    required this.paymentsCount,
  });

  factory PaymentStat.fromMap(Map<String, dynamic> map) {
    return PaymentStat(
      paymentMethodId: map['payment_method_id']?.toString(),
      paymentMethodName: map['payment_method_name']?.toString(),
      totalAmount: _toDouble(map['total_amount']),
      paymentsCount: (map['payments_count'] as num?)?.toInt() ?? 0,
    );
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }
}
