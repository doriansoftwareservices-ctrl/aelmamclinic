// lib/models/prescription.dart
/*───────────────────────────────────────────────────────────────────────────
  نموذج: Prescription (الوصفات)
  محليًا (SQLite - camelCase): patientId, doctorId, recordDate, createdAt
  سحابيًا (Remote - snake_case عبر toCloudMap/SyncService):
    account_id, device_id, local_id, patient_id, doctor_id,
    record_date, created_at, updated_at
  fromMap يدعم camel + snake مع تحويلات آمنة للأنواع.
───────────────────────────────────────────────────────────────────────────*/

class Prescription {
  /*──────────── ثوابت ────────────*/
  static const String table = 'prescriptions';

  /*──────── SQL (اختياري - محلي SQLite) ────────*/
  static const String createTable = '''
    CREATE TABLE IF NOT EXISTS $table (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      patientId   INTEGER NOT NULL,
      doctorId    INTEGER,
      recordDate  TEXT    NOT NULL,
      createdAt   TEXT    NOT NULL,
      FOREIGN KEY (patientId) REFERENCES patients(id),
      FOREIGN KEY (doctorId)  REFERENCES doctors(id)
    );
  ''';

  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_patientId  ON $table(patientId);
    CREATE INDEX IF NOT EXISTS idx_${table}_recordDate ON $table(recordDate);
  ''';

  /*──────────── الحقول (محلي) ────────────*/
  final int? id; // NULL قبل الإدراج
  final int patientId; // مطلوب
  final int? doctorId; // اختياري
  final DateTime recordDate; // تاريخ الوصفة
  final DateTime createdAt; // وقت الإنشاء

  /*──────── حقول مزامنة اختيارية (لا تُحفَظ محليًا) ────────*/
  final String? accountId; // Remote → accounts.id
  final String? deviceId; // معرّف الجهاز
  final int? localId; // مرجع السجل المحلي عند الرفع (إن لم يُمرّر نستخدم id)
  final DateTime? updatedAt; // آخر تعديل في السحابة

  /*──────────── الباني ────────────*/
  Prescription({
    this.id,
    required this.patientId,
    this.doctorId,
    required this.recordDate,
    DateTime? createdAt,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /*──────── helpers للتحويل الآمن ─────────*/
  static int? _asIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _asInt0(dynamic v) => _asIntN(v) ?? 0;

  static DateTime _epochToDate(num n) {
    // <1e12: ثوانٍ، <1e16: ميلي ثانية، غير ذلك: مايكروثانية
    if (n < 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt() * 1000);
    } else if (n < 10000000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt());
    } else {
      return DateTime.fromMicrosecondsSinceEpoch(n.toInt());
    }
  }

  static DateTime _asDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    if (v is num) return _epochToDate(v);
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  static DateTime? _asDateN(dynamic v) {
    if (v == null) return null;
    return _asDate(v);
  }

  static String? _asStrN(dynamic v) => v == null ? null : v.toString();

  /*──────────── من/إلى خريطة (SQLite محلي) ────────────*/
  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'doctorId': doctorId,
        'recordDate': recordDate.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  Map<String, dynamic> toJson() => toMap();

  /// يدعم مفاتيح camelCase و snake_case (قادمة من Remote أو مصادر قديمة)
  factory Prescription.fromMap(Map<String, dynamic> row) => Prescription(
        id: _asIntN(row['id']),
        patientId: _asInt0(row['patientId'] ?? row['patient_id']),
        doctorId: _asIntN(row['doctorId'] ?? row['doctor_id']),
        recordDate: _asDate(row['recordDate'] ?? row['record_date']),
        createdAt: _asDate(row['createdAt'] ?? row['created_at']),
        // حقول المزامنة (camel + snake)
        accountId: _asStrN(row['accountId'] ?? row['account_id']),
        deviceId: _asStrN(row['deviceId'] ?? row['device_id']),
        localId: row['localId'] is int
            ? row['localId'] as int
            : (row['local_id'] is int
                ? row['local_id'] as int
                : row['id'] as int?),
        updatedAt: _asDateN(row['updatedAt'] ?? row['updated_at']),
      );

  /*──────── تمثيل سحابي (snake_case) — يستخدمه SyncService عند الرفع ────────*/
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'patient_id': patientId,
        'doctor_id': doctorId,
        'record_date': recordDate.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  /*──────────── copyWith ────────────*/
  Prescription copyWith({
    int? id,
    int? patientId,
    int? doctorId,
    DateTime? recordDate,
    DateTime? createdAt,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      Prescription(
        id: id ?? this.id,
        patientId: patientId ?? this.patientId,
        doctorId: doctorId ?? this.doctorId,
        recordDate: recordDate ?? this.recordDate,
        createdAt: createdAt ?? this.createdAt,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /*──────────── تشخيص ────────────*/
  @override
  String toString() =>
      'Prescription(id: $id, patientId: $patientId, doctorId: $doctorId, '
      'recordDate: $recordDate, createdAt: $createdAt, '
      'accountId: $accountId, deviceId: $deviceId, localId: $localId, updatedAt: $updatedAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Prescription &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          patientId == other.patientId &&
          doctorId == other.doctorId &&
          recordDate == other.recordDate &&
          createdAt == other.createdAt &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(id, patientId, doctorId, recordDate,
      createdAt, accountId, deviceId, localId, updatedAt);
}
