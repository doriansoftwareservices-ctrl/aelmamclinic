class SubscriptionPlan {
  final String code;
  final String name;
  final double priceUsd;
  final int durationMonths;
  final bool isActive;

  const SubscriptionPlan({
    required this.code,
    required this.name,
    required this.priceUsd,
    required this.durationMonths,
    required this.isActive,
  });

  factory SubscriptionPlan.fromMap(Map<String, dynamic> map) {
    return SubscriptionPlan(
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      priceUsd: _toDouble(map['price_usd']),
      durationMonths: (map['duration_months'] as num?)?.toInt() ?? 0,
      isActive: map['is_active'] == true,
    );
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }
}
