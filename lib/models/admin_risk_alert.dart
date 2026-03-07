class AdminRiskAlert {
  final String code;
  final String severity;
  final String title;
  final int count;
  final String? hint;

  const AdminRiskAlert({
    required this.code,
    required this.severity,
    required this.title,
    required this.count,
    this.hint,
  });

  factory AdminRiskAlert.fromJson(Map<String, dynamic> json) {
    int _toInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
    return AdminRiskAlert(
      code: json['code']?.toString() ?? '',
      severity: json['severity']?.toString() ?? 'low',
      title: json['title']?.toString() ?? '',
      count: _toInt(json['count']),
      hint: json['hint']?.toString(),
    );
  }
}
