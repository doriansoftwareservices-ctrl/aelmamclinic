// lib/models/medical_service.dart

/// نموذج خدمة طبية.
/// متوافق مع:
/// - SQLite محليًا: medical_services بالأعمدة (id, name, cost, serviceType)
/// - Remote: نفس القيم لكن تتحول المفاتيح تلقائيًا إلى snake_case عبر SyncService (service_type).
class MedicalService {
  static const String table = 'medical_services';

  /// إنشاء الجدول محليًا (مطابق لتعريفك في DBService)
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    cost REAL NOT NULL,
    serviceType TEXT NOT NULL
  );
  ''';

  /// (اختياري) فهرس على الاسم لتحسين البحث
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_name ON $table(name);
  ''';

  /* ─── الحقول الأساسية (محلي) ─── */
  final int? id;
  final String name;
  final double cost;

  /// النوع: 'radiology' | 'lab' | 'doctorGeneral' (حر نصيًا)
  final String serviceType;

  /* ─── حقول مزامنة اختيارية (لا تُحفَظ محليًا) ─── */
  final String? accountId; // Remote → accounts.id
  final String? deviceId; // للتتبّع حسب الجهاز
  final int? localId; // مرجع السجل المحلي عند الرفع (defaults to id)
  final DateTime? updatedAt; // آخر تحديث (اختياري)

  const MedicalService({
    this.id,
    required this.name,
    required this.cost,
    required this.serviceType,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  });

  /*──────────── Helpers آمنة ────────────*/
  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static double _toDouble(dynamic v, [double fallback = 0.0]) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  static String _toStr(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  static String? _toStrN(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  /*──────────── إنشاء من Map (يدعم camel/snake) ────────────*/
  factory MedicalService.fromMap(Map<String, dynamic> map) => MedicalService(
        id: _toIntN(map['id']),
        name: _toStr(map['name']),
        cost: _toDouble(map['cost']),
        // محليًا: serviceType — سحابيًا قد تصل service_type
        serviceType: _toStr(map['serviceType'] ?? map['service_type']),
        // حقول مزامنة (camel + snake)
        accountId: _toStrN(map['accountId'] ?? map['account_id']),
        deviceId: _toStrN(map['deviceId'] ?? map['device_id']),
        localId: map['localId'] is int
            ? map['localId'] as int
            : (map['local_id'] is int
                ? map['local_id'] as int
                : map['id'] as int?),
        updatedAt: _toDateN(map['updatedAt'] ?? map['updated_at']),
      );

  factory MedicalService.fromJson(Map<String, dynamic> json) =>
      MedicalService.fromMap(json);

  /*──────────── إلى Map (لـ SQLite) ────────────*/
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'cost': cost,
        'serviceType':
            serviceType, // سيحوّله SyncService إلى service_type عند الرفع
      };

  /*──────────── تمثيل السحابة (snake_case) ────────────*/
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        // تعقيم القيم الفارغة حتى لا تُرسل كسلاسل فارغة
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'name': name,
        'cost': cost,
        'service_type': serviceType,
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  Map<String, dynamic> toJson() => toCloudMap();

  MedicalService copyWith({
    int? id,
    String? name,
    double? cost,
    String? serviceType,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      MedicalService(
        id: id ?? this.id,
        name: name ?? this.name,
        cost: cost ?? this.cost,
        serviceType: serviceType ?? this.serviceType,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'MedicalService(id: $id, name: $name, cost: $cost, serviceType: $serviceType)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MedicalService &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          cost == other.cost &&
          serviceType == other.serviceType &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
      id, name, cost, serviceType, accountId, deviceId, localId, updatedAt);
}
