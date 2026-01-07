// lib/models/clinic.dart

/// موديل عيادة مطابق لصفوف جدول `accounts` في Remote.
/// الأعمدة المتوقعة:
/// - id (uuid)
/// - name (text)
/// - frozen (bool)
/// - created_at (timestamptz)
/// - plan_code (text)
/// - plan_status (text)
/// - plan_end_at (timestamptz)
class Clinic {
  /// اسم جدول Remote
  static const String table = 'accounts';

  final String id;
  final String name;
  final bool isFrozen;
  final DateTime createdAt;
  final String? planCode;
  final String? planStatus;
  final DateTime? planEndAt;

  Clinic({
    required this.id,
    required this.name,
    required this.isFrozen,
    required this.createdAt,
    this.planCode,
    this.planStatus,
    this.planEndAt,
  });

  // ─── Helpers ───
  static String _toStr(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  static bool _toBool(dynamic v, [bool fallback = false]) {
    if (v == null) return fallback;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().toLowerCase().trim();
    switch (s) {
      case 'true':
      case 't':
      case '1':
      case 'yes':
      case 'y':
        return true;
      case 'false':
      case 'f':
      case '0':
      case 'no':
      case 'n':
        return false;
      default:
        return fallback;
    }
  }

  static DateTime _epochToDate(num n) {
    if (n < 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt() * 1000,
          isUtc: false);
    } else if (n < 10000000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt(), isUtc: false);
    } else {
      return DateTime.fromMicrosecondsSinceEpoch(n.toInt(), isUtc: false);
    }
  }

  static DateTime _toDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    if (v is num) return _epochToDate(v);
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  // ─── التحويلات ───
  factory Clinic.fromJson(Map<String, dynamic> json) => Clinic(
        id: _toStr(json['id']),
        name: _toStr(json['name']),
        isFrozen: _toBool(json['frozen'] ?? json['is_frozen'], false),
        createdAt: _toDate(json['created_at'] ?? json['createdAt']),
        planCode: _toStr(json['plan_code'] ?? json['planCode'], '').isEmpty
            ? null
            : _toStr(json['plan_code'] ?? json['planCode']),
        planStatus:
            _toStr(json['plan_status'] ?? json['planStatus'], '').isEmpty
                ? null
                : _toStr(json['plan_status'] ?? json['planStatus']),
        planEndAt: json['plan_end_at'] == null && json['planEndAt'] == null
            ? null
            : _toDate(json['plan_end_at'] ?? json['planEndAt']),
      );

  factory Clinic.fromMap(Map<String, dynamic> map) => Clinic.fromJson(map);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'frozen': isFrozen,
        'created_at': createdAt.toIso8601String(),
        'plan_code': planCode,
        'plan_status': planStatus,
        'plan_end_at': planEndAt?.toIso8601String(),
      };

  Map<String, dynamic> toMap() => toJson();

  Clinic copyWith({
    String? id,
    String? name,
    bool? isFrozen,
    DateTime? createdAt,
    String? planCode,
    String? planStatus,
    DateTime? planEndAt,
  }) {
    return Clinic(
      id: id ?? this.id,
      name: name ?? this.name,
      isFrozen: isFrozen ?? this.isFrozen,
      createdAt: createdAt ?? this.createdAt,
      planCode: planCode ?? this.planCode,
      planStatus: planStatus ?? this.planStatus,
      planEndAt: planEndAt ?? this.planEndAt,
    );
  }

  int compareByCreatedAtDesc(Clinic other) =>
      other.createdAt.compareTo(createdAt);

  @override
  String toString() =>
      'Clinic(id: $id, name: $name, frozen: $isFrozen, createdAt: $createdAt, planCode: $planCode, planStatus: $planStatus, planEndAt: $planEndAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Clinic &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          isFrozen == other.isFrozen &&
          createdAt == other.createdAt &&
          planCode == other.planCode &&
          planStatus == other.planStatus &&
          planEndAt == other.planEndAt;

  @override
  int get hashCode => Object.hash(
      id, name, isFrozen, createdAt, planCode, planStatus, planEndAt);
}
