// lib/models/patient_service.dart
/* ── نموذج خدمات المريض (محلي + متوافق مع المزامنة لسحابة Supabase)
   - محليًا (SQLite): مفاتيح camelCase
   - سحابيًا (Supabase): تتحول للمفاتيح snake_case عبر toCloudMap()/SyncService
   - fromMap يدعم camelCase و snake_case لمرونة القراءة
──────────────────────────────────────────────────────────────*/

class PatientService {
  static const String table = 'patient_services';

  /*──────── SQL (محلي SQLite) ────────*/
  static const String createTable = '''
    CREATE TABLE IF NOT EXISTS $table (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      patientId    INTEGER NOT NULL,
      serviceId    INTEGER,
      serviceName  TEXT    NOT NULL,
      serviceCost  REAL    NOT NULL,
      FOREIGN KEY(patientId) REFERENCES patients(id) ON DELETE CASCADE,
      FOREIGN KEY(serviceId) REFERENCES medical_services(id) ON DELETE SET NULL
    );
  ''';

  /// (اختياري) فهارس لتحسين الاستعلامات
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_patientId ON $table(patientId);
    CREATE INDEX IF NOT EXISTS idx_${table}_serviceId ON $table(serviceId);
  ''';

  /*──────── الحقول الأساسية (محلي) ────────*/
  final int? id;
  final int patientId;
  final int? serviceId; // قد تكون null إذا كانت الحالة نصية فقط
  final String serviceName;
  final double serviceCost;

  /*──────── حقول مزامنة اختيارية (لا تُحفَظ محليًا) ────────*/
  final String? accountId; // Supabase → accounts.id
  final String? deviceId; // معرّف الجهاز
  final int? localId; // مرجع السجل المحلي عند الرفع (إن لم يُمرّر نستخدم id)
  final DateTime? updatedAt;

  PatientService({
    this.id,
    required this.patientId,
    this.serviceId,
    required this.serviceName,
    required this.serviceCost,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  });

  /*──────── Helpers آمنة ────────*/
  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _toInt0(dynamic v) => _toIntN(v) ?? 0;

  static double _toDouble0(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  static String _toStr0(dynamic v) => v?.toString() ?? '';
  static String? _toStrN(dynamic v) => v == null ? null : v.toString();

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  /*──────── تحويلات (محلي) ────────*/
  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'serviceId': serviceId,
        'serviceName': serviceName,
        'serviceCost': serviceCost,
      };

  /*──────── تمثيل سحابي (snake_case) — يستخدمه SyncService عند الرفع ────────*/
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        // تعقيم السلاسل الفارغة/المسافات
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'patient_id': patientId,
        'service_id': serviceId,
        'service_name': serviceName,
        'service_cost': serviceCost,
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  Map<String, dynamic> toJson() => toCloudMap();

  /// يدعم camelCase (محلي) و snake_case (قادمة من السحابة)
  factory PatientService.fromMap(Map<String, dynamic> m) => PatientService(
        id: _toIntN(m['id']),
        patientId: _toInt0(m['patientId'] ?? m['patient_id']),
        serviceId: _toIntN(m['serviceId'] ?? m['service_id']),
        serviceName: _toStr0(m['serviceName'] ?? m['service_name']),
        serviceCost: _toDouble0(m['serviceCost'] ?? m['service_cost']),
        // حقول مزامنة اختيارية (إن وُجدت في المصدر)
        accountId: _toStrN(m['accountId'] ?? m['account_id']),
        deviceId: _toStrN(m['deviceId'] ?? m['device_id']),
        localId: m['localId'] is int
            ? m['localId'] as int
            : (m['local_id'] is int ? m['local_id'] as int : m['id'] as int?),
        updatedAt: _toDateN(m['updatedAt'] ?? m['updated_at']),
      );

  factory PatientService.fromJson(Map<String, dynamic> m) =>
      PatientService.fromMap(m);

  PatientService copyWith({
    int? id,
    int? patientId,
    int? serviceId,
    String? serviceName,
    double? serviceCost,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      PatientService(
        id: id ?? this.id,
        patientId: patientId ?? this.patientId,
        serviceId: serviceId ?? this.serviceId,
        serviceName: serviceName ?? this.serviceName,
        serviceCost: serviceCost ?? this.serviceCost,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'PatientService(id: $id, patientId: $patientId, serviceId: $serviceId, '
      'serviceName: $serviceName, serviceCost: $serviceCost)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PatientService &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          patientId == other.patientId &&
          serviceId == other.serviceId &&
          serviceName == other.serviceName &&
          serviceCost == other.serviceCost &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        patientId,
        serviceId,
        serviceName,
        serviceCost,
        accountId,
        deviceId,
        localId,
        updatedAt,
      );
}
