class PaymentTimeStat {
  final DateTime? period;
  final double totalAmount;
  final int paymentsCount;

  const PaymentTimeStat({
    required this.period,
    required this.totalAmount,
    required this.paymentsCount,
  });

  factory PaymentTimeStat.fromMap(Map<String, dynamic> map) {
    final raw = map['day'] ?? map['month'] ?? map['period'];
    final period = raw == null ? null : DateTime.tryParse(raw.toString());
    return PaymentTimeStat(
      period: period,
      totalAmount: _toDouble(map['total_amount']),
      paymentsCount: (map['payments_count'] as num?)?.toInt() ?? 0,
    );
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }
}
