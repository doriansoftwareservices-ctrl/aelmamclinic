// lib/models/appointment.dart

class Appointment {
  static const String table = 'appointments';

  /// إنشاء الجدول محليًا (مطابق لتعريف DBService)
  static const String createTable = '''
    CREATE TABLE IF NOT EXISTS $table (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      patientId INTEGER,
      appointmentTime TEXT,
      status TEXT,
      notes TEXT,
      FOREIGN KEY (patientId) REFERENCES patients(id)
    );
  ''';

  /*────────────────────────── الحقول الأساسية (محلي) ─────────────────────────*/
  int? id; // المعرف الفريد (محلي)
  int patientId; // المريض المرتبط
  DateTime appointmentTime; // وقت الموعد
  String status; // "مؤكد" | "ملغي" | "متابعة" ...
  String notes; // ملاحظات

  /*────────────────────────── حقول مزامنة اختيارية ─────────────────────────*/
  String? accountId; // Supabase account
  String? deviceId; // مصدر الجهاز
  int? localId; // مرجع السجل المحلي
  DateTime? updatedAt;

  Appointment({
    this.id,
    required this.patientId,
    required this.appointmentTime,
    this.status = 'مؤكد',
    this.notes = '',
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

  static int _toInt0(dynamic v) => _toIntN(v) ?? 0;

  static DateTime _epochToDate(num n) {
    // أقل من 10^12 ≈ ثوانٍ، أقل من 10^16 ≈ ميلي، غير ذلك مايكرو
    if (n < 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt() * 1000,
          isUtc: false);
    } else if (n < 10000000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt(), isUtc: false);
    } else {
      return DateTime.fromMicrosecondsSinceEpoch(n.toInt(), isUtc: false);
    }
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is num) return _epochToDate(v);
    return DateTime.tryParse(v.toString());
  }

  static DateTime _toDate(dynamic v) => _toDateN(v) ?? DateTime.now();

  static String _toStr(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  /*──────────── fromMap (camel + snake) ────────────*/
  factory Appointment.fromMap(Map<String, dynamic> map) {
    final id = _toIntN(map['id']);
    final patientId = _toInt0(map['patientId'] ?? map['patient_id']);
    final dtRaw =
        map['appointmentTime'] ?? map['appointment_time'] ?? map['time'];
    final appointmentTime = _toDate(dtRaw);
    final status = _toStr(map['status'], 'مؤكد');
    final notes = _toStr(map['notes'], '');

    return Appointment(
      id: id,
      patientId: patientId,
      appointmentTime: appointmentTime,
      status: status,
      notes: notes,
      // حقول المزامنة (camel + snake)
      accountId: _toStr(map['accountId'] ?? map['account_id'], ''),
      deviceId: _toStr(map['deviceId'] ?? map['device_id'], ''),
      localId: _toIntN(map['localId'] ?? map['local_id'] ?? map['id']),
      updatedAt: _toDateN(map['updatedAt'] ?? map['updated_at']),
    );
  }

  /*──────────── للحفظ محليًا (SQLite) ────────────*/
  /// ⚠️ مهم: لا نضع 'id' عند الإدراج إذا كان null/<=0
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{
      'patientId': patientId,
      'appointmentTime': appointmentTime.toIso8601String(),
      'status': status,
      'notes': notes,
    };
    if (id != null && id! > 0) {
      m['id'] = id;
    }
    return m;
  }

  /*──────────── خريطة سحابية (snake_case) للمزامنة ────────────*/
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'patient_id': patientId,
        'appointment_time': appointmentTime.toIso8601String(),
        'status': status,
        'notes': notes,
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  Map<String, dynamic> toJson() => toCloudMap();

  /*──────────── نسخ مع تعديل ────────────*/
  Appointment copyWith({
    int? id,
    int? patientId,
    DateTime? appointmentTime,
    String? status,
    String? notes,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) {
    return Appointment(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      appointmentTime: appointmentTime ?? this.appointmentTime,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      localId: localId ?? this.localId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'Appointment(id: $id, patientId: $patientId, time: $appointmentTime, status: $status)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Appointment &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          patientId == other.patientId &&
          appointmentTime == other.appointmentTime &&
          status == other.status &&
          notes == other.notes &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        patientId,
        appointmentTime,
        status,
        notes,
        accountId,
        deviceId,
        localId,
        updatedAt,
      );
}
