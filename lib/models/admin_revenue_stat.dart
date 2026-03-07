class AdminRevenueStat {
  final DateTime month;
  final double value;

  const AdminRevenueStat({
    required this.month,
    required this.value,
  });

  factory AdminRevenueStat.fromMap(Map<String, dynamic> map) {
    final rawMonth = map['month']?.toString();
    final dt = rawMonth == null ? DateTime(1970) : DateTime.parse(rawMonth);
    final v = map['mrr'] ?? map['arr'] ?? map['value'] ?? 0;
    return AdminRevenueStat(
      month: dt,
      value: (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0,
    );
  }
}
