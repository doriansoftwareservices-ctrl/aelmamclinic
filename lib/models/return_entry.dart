// lib/models/return_entry.dart

/// نموذج "العودات" (ReturnEntry)
/// محليًا: نخزّن camelCase في SQLite.
/// سحابيًا (Remote): نرسل snake_case عبر toCloudMap()
/// وندعم القراءة من camelCase و/أو snake_case عبر fromMap().
class ReturnEntry {
  static const String table = 'returns';

  final int? id;
  final DateTime date;
  final String patientName;
  final String phoneNumber;
  final String diagnosis;
  final double remaining;
  final int age;
  final String doctor;
  final String notes;

  /* ─── حقول مزامنة اختيارية (للسحابة) ─── */
  final String? accountId; // Remote → accounts.id
  final String? deviceId; // معرّف الجهاز
  final int? localId; // بصمة السجل المحلي عند الرفع (id إن لم يُمرّر)
  final DateTime? updatedAt; // آخر تحديث للسحابة

  ReturnEntry({
    this.id,
    required this.date,
    required this.patientName,
    required this.phoneNumber,
    required this.diagnosis,
    required this.remaining,
    required this.age,
    required this.doctor,
    required this.notes,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  });

  /*──────────────── SQL (محلي SQLite) ─────────────────*/
  /// إنشاء الجدول محليًا (camelCase)
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    date         TEXT    NOT NULL,
    patientName  TEXT    NOT NULL,
    phoneNumber  TEXT    NOT NULL,
    diagnosis    TEXT    NOT NULL,
    remaining    REAL    NOT NULL,
    age          INTEGER NOT NULL DEFAULT 0,
    doctor       TEXT    NOT NULL DEFAULT '',
    notes        TEXT    NOT NULL DEFAULT ''
  );
  ''';

  /// (اختياري) فهارس للأداء
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_date ON $table(date);
  ''';

  /*──────────────── Helpers آمنة ────────────────*/
  static int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  static double _toDouble(dynamic v, {double fallback = 0.0}) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? fallback;
  }

  static String _toStr(dynamic v, {String fallback = ''}) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  static DateTime _epochToDate(num n) {
    // يدعم ثوانٍ/ميلي/مايكرو
    if (n < 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt() * 1000);
    } else if (n < 10000000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt());
    } else {
      return DateTime.fromMicrosecondsSinceEpoch(n.toInt());
    }
  }

  static DateTime _toDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    if (v is num) return _epochToDate(v);
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  static String? _toStrN(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    return _toDate(v);
  }

  /*──────────────── تحويل ↔︎ خريطة ────────────────*/
  /// يدعم مفاتيح camelCase (محلي) و snake_case (سحابي)
  factory ReturnEntry.fromMap(Map<String, dynamic> map) => ReturnEntry(
        id: map['id'] as int?,
        // نقبل: date أو return_date أو created_at
        date: _toDate(map['date'] ?? map['return_date'] ?? map['created_at']),
        patientName: _toStr(map['patientName'] ?? map['patient_name']),
        phoneNumber: _toStr(map['phoneNumber'] ?? map['phone_number']),
        diagnosis: _toStr(map['diagnosis']),
        remaining: _toDouble(map['remaining']),
        age: _toInt(map['age']),
        // في السحابة أبقينا الحقل "doctor"، وندعم doctor_name احتياطًا
        doctor: _toStr(map['doctor'] ?? map['doctor_name']),
        notes: _toStr(map['notes']),
        // حقول المزامنة (camel + snake)
        accountId: _toStrN(map['accountId'] ?? map['account_id']),
        deviceId: _toStrN(map['deviceId'] ?? map['device_id']),
        localId: _toIntN(map['localId'] ?? map['local_id'] ?? map['id']),
        updatedAt: _toDateN(map['updatedAt'] ?? map['updated_at']),
      );

  /// نخزّن محليًا بصيغة camelCase
  Map<String, dynamic> toMap() => {
        'id': id,
        'date': date.toIso8601String(),
        'patientName': patientName,
        'phoneNumber': phoneNumber,
        'diagnosis': diagnosis,
        'remaining': remaining,
        'age': age,
        'doctor': doctor,
        'notes': notes,
      };

  /// خريطة سحابية (snake_case) للمزامنة عبر SyncService
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        // تعقيم السلاسل الفارغة/المسافات
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        // نُرسِل date كما هو (هو تاريخ السجل في هذا الموديل)
        'date': date.toIso8601String(),
        'patient_name': patientName,
        'phone_number': phoneNumber,
        'diagnosis': diagnosis,
        'remaining': remaining,
        'age': age,
        'doctor': doctor, // متروك كما هو، وندعم doctor_name عند القراءة
        'notes': notes,
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  /// JSON عام — نُعيد خريطة السحابة افتراضيًا
  Map<String, dynamic> toJson() => toCloudMap();

  ReturnEntry copyWith({
    int? id,
    DateTime? date,
    String? patientName,
    String? phoneNumber,
    String? diagnosis,
    double? remaining,
    int? age,
    String? doctor,
    String? notes,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      ReturnEntry(
        id: id ?? this.id,
        date: date ?? this.date,
        patientName: patientName ?? this.patientName,
        phoneNumber: phoneNumber ?? this.phoneNumber,
        diagnosis: diagnosis ?? this.diagnosis,
        remaining: remaining ?? this.remaining,
        age: age ?? this.age,
        doctor: doctor ?? this.doctor,
        notes: notes ?? this.notes,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'ReturnEntry(id:$id, date:$date, patient:$patientName, remaining:$remaining, '
      'age:$age, doctor:$doctor, accountId:$accountId, deviceId:$deviceId, '
      'localId:$localId, updatedAt:$updatedAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReturnEntry &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          date == other.date &&
          patientName == other.patientName &&
          phoneNumber == other.phoneNumber &&
          diagnosis == other.diagnosis &&
          remaining == other.remaining &&
          age == other.age &&
          doctor == other.doctor &&
          notes == other.notes &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        date,
        patientName,
        phoneNumber,
        diagnosis,
        remaining,
        age,
        doctor,
        notes,
        accountId,
        deviceId,
        localId,
        updatedAt,
      );
}
