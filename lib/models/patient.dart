// lib/models/patient.dart

/// نموذج المريض (محلي + سحابي عبر SyncService).
/// محليًا في SQLite نستخدم camelCase؛
/// وعند الرفع إلى Remote يُستخدم snake_case عبر `toCloudMap()`.
class Patient {
  static const String table = 'patients';

  /// (اختياري) مخطط الجدول محليًا — موجود أصلًا في DBService، مرفق هنا للمرجعية.
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    age INTEGER,
    diagnosis TEXT,
    paidAmount REAL,
    remaining REAL,
    registerDate TEXT,
    phoneNumber TEXT,
    healthStatus TEXT,
    preferences TEXT,
    doctorId INTEGER,
    doctorName TEXT,
    doctorSpecialization TEXT,
    notes TEXT,
    serviceType TEXT,
    serviceId INTEGER,
    serviceName TEXT,
    serviceCost REAL,
    doctorShare REAL DEFAULT 0,
    doctorInput REAL DEFAULT 0,
    towerShare REAL DEFAULT 0,
    departmentShare REAL DEFAULT 0,
    doctorReviewPending INTEGER NOT NULL DEFAULT 0,
    doctorReviewedAt TEXT
  );
  ''';

  /*────────────────────────── الحقول (محلي) ─────────────────────────*/
  final int? id;
  final String name;
  final int age;
  final String diagnosis;
  final double paidAmount;
  final double remaining;
  final DateTime registerDate;
  final String phoneNumber;
  final String? healthStatus;
  final String? preferences;
  final int? doctorId;
  final String? doctorName;
  final String? doctorSpecialization;
  final String? notes;

  /// مثال: 'radiology' | 'lab' | 'doctor' أو بالعربية 'الأشعة' | 'المختبر' | 'طبيب'
  final String? serviceType;
  final int? serviceId;
  final String? serviceName;
  final double? serviceCost;

  /// حقول التوزيع
  final double doctorShare; // نسبة الطبيب
  final double doctorInput; // مدخلات الطبيب المباشرة
  final double towerShare; // حصة المركز/البرج
  final double departmentShare; // حصة القسم الفني
  final bool doctorReviewPending; // يحتاج الطبيب إلى معاينة المريض
  final DateTime? doctorReviewedAt; // آخر وقت أكّد فيه الطبيب المقابلة

  /*────────────────────── حقول مزامنة اختيارية (سحابة) ─────────────────────*/
  final String? accountId; // Remote → accounts.id
  final String? deviceId; // معرّف الجهاز
  final int? localId; // مرجع السجل المحلي عند الرفع (إن لم يُمرر نضع id المحلي)
  final DateTime? updatedAt;

  Patient({
    this.id,
    required this.name,
    required this.age,
    required this.diagnosis,
    required this.paidAmount,
    required this.remaining,
    required this.registerDate,
    required this.phoneNumber,
    this.healthStatus,
    this.preferences,
    this.doctorId,
    this.doctorName,
    this.doctorSpecialization,
    this.notes,
    this.serviceType,
    this.serviceId,
    this.serviceName,
    this.serviceCost,
    this.doctorShare = 0.0,
    this.doctorInput = 0.0,
    this.towerShare = 0.0,
    this.departmentShare = 0.0,
    this.doctorReviewPending = false,
    this.doctorReviewedAt,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  });

  /*──────────── Helpers آمنة للأنواع ────────────*/
  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _toInt0(dynamic v) => _toIntN(v) ?? 0;

  static double? _toDoubleN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static double _toDouble0(dynamic v) => _toDoubleN(v) ?? 0.0;

  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s.isEmpty) return false;
      return s == '1' || s == 'true' || s == 't' || s == 'yes';
    }
    return false;
  }

  static String? _toStrN(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  static String _toStr0(dynamic v) => v?.toString() ?? '';

  static DateTime _toDateSafe(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    return _toDateSafe(v);
  }

  /*──────────── fromMap (يدعم camel/snake) ────────────*/
  factory Patient.fromMap(Map<String, dynamic> map) => Patient(
        id: _toIntN(map['id']),
        name: _toStr0(map['name']),
        age: _toInt0(map['age']),
        diagnosis: _toStr0(map['diagnosis']),
        paidAmount: _toDouble0(map['paidAmount'] ?? map['paid_amount']),
        remaining: _toDouble0(map['remaining']),
        registerDate: _toDateSafe(map['registerDate'] ?? map['register_date']),
        phoneNumber: _toStr0(map['phoneNumber'] ?? map['phone_number']),
        healthStatus: _toStrN(map['healthStatus'] ?? map['health_status']),
        preferences: _toStrN(map['preferences']),
        doctorId: _toIntN(map['doctorId'] ?? map['doctor_id']),
        doctorName: _toStrN(map['doctorName'] ?? map['doctor_name']),
        doctorSpecialization: _toStrN(
            map['doctorSpecialization'] ?? map['doctor_specialization']),
        notes: _toStrN(map['notes']),
        serviceType: _toStrN(map['serviceType'] ?? map['service_type']),
        serviceId: _toIntN(map['serviceId'] ?? map['service_id']),
        serviceName: _toStrN(map['serviceName'] ?? map['service_name']),
        serviceCost: _toDoubleN(map['serviceCost'] ?? map['service_cost']),
        doctorShare: _toDouble0(map['doctorShare'] ?? map['doctor_share']),
        doctorInput: _toDouble0(map['doctorInput'] ?? map['doctor_input']),
        towerShare: _toDouble0(map['towerShare'] ?? map['tower_share']),
        departmentShare:
            _toDouble0(map['departmentShare'] ?? map['department_share']),
        doctorReviewPending: _toBool(
          map['doctorReviewPending'] ?? map['doctor_review_pending'],
        ),
        doctorReviewedAt:
            _toDateN(map['doctorReviewedAt'] ?? map['doctor_reviewed_at']),
        // حقول المزامنة (camel + snake)
        accountId: _toStrN(map['accountId'] ?? map['account_id']),
        deviceId: _toStrN(map['deviceId'] ?? map['device_id']),
        localId: _toIntN(map['localId'] ?? map['local_id'] ?? map['id']),
        updatedAt: _toDateN(map['updatedAt'] ?? map['updated_at']),
      );

  factory Patient.fromJson(Map<String, dynamic> json) => Patient.fromMap(json);

  factory Patient.fromRemote(Map<String, dynamic> map) => Patient.fromMap(map);

  /*──────────── إلى Map (لـ SQLite؛ SyncService سيحوّل للسحابة) ────────────*/
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'age': age,
        'diagnosis': diagnosis,
        'paidAmount': paidAmount,
        'remaining': remaining,
        'registerDate': registerDate.toIso8601String(),
        'phoneNumber': phoneNumber,
        'healthStatus': healthStatus,
        'preferences': preferences,
        'doctorId': doctorId,
        'doctorName': doctorName,
        'doctorSpecialization': doctorSpecialization,
        'notes': notes,
        'serviceType': serviceType,
        'serviceId': serviceId,
        'serviceName': serviceName,
        'serviceCost': serviceCost,
        'doctorShare': doctorShare,
        'doctorInput': doctorInput,
        'towerShare': towerShare,
        'departmentShare': departmentShare,
        'doctorReviewPending': doctorReviewPending ? 1 : 0,
        'doctorReviewedAt': doctorReviewedAt?.toIso8601String(),
      };

  /*──────────── خريطة سحابية (snake_case) للمزامنة ────────────*/
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        // تعقيم السلاسل الفارغة/المسافات
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'name': name,
        'age': age,
        'diagnosis': diagnosis,
        'paid_amount': paidAmount,
        'remaining': remaining,
        'register_date': registerDate.toIso8601String(),
        'phone_number': phoneNumber,
        'health_status': healthStatus,
        'preferences': preferences,
        'doctor_id': doctorId,
        'doctor_name': doctorName,
        'doctor_specialization': doctorSpecialization,
        'notes': notes,
        'service_type': serviceType,
        'service_id': serviceId,
        'service_name': serviceName,
        'service_cost': serviceCost,
        'doctor_share': doctorShare,
        'doctor_input': doctorInput,
        'tower_share': towerShare,
        'department_share': departmentShare,
        'doctor_review_pending': doctorReviewPending,
        'doctor_reviewed_at': doctorReviewedAt?.toIso8601String(),
        // ملاحظة: `created_at` غير موجود في allow-list لكن لا يضر وجوده (سيُحذف)،
        // تركناه متاحًا إن رغبت الاعتماد عليه لاحقًا.
        'created_at': registerDate.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  /*──────────── JSON عام — نُعيد خريطة السحابة افتراضيًا ────────────*/
  Map<String, dynamic> toRemote() => toCloudMap();

  Map<String, dynamic> toJson() => toCloudMap();

  Patient copyWith({
    int? id,
    String? name,
    int? age,
    String? diagnosis,
    double? paidAmount,
    double? remaining,
    DateTime? registerDate,
    String? phoneNumber,
    String? healthStatus,
    String? preferences,
    int? doctorId,
    String? doctorName,
    String? doctorSpecialization,
    String? notes,
    String? serviceType,
    int? serviceId,
    String? serviceName,
    double? serviceCost,
    double? doctorShare,
    double? doctorInput,
    double? towerShare,
    double? departmentShare,
    bool? doctorReviewPending,
    DateTime? doctorReviewedAt,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      Patient(
        id: id ?? this.id,
        name: name ?? this.name,
        age: age ?? this.age,
        diagnosis: diagnosis ?? this.diagnosis,
        paidAmount: paidAmount ?? this.paidAmount,
        remaining: remaining ?? this.remaining,
        registerDate: registerDate ?? this.registerDate,
        phoneNumber: phoneNumber ?? this.phoneNumber,
        healthStatus: healthStatus ?? this.healthStatus,
        preferences: preferences ?? this.preferences,
        doctorId: doctorId ?? this.doctorId,
        doctorName: doctorName ?? this.doctorName,
        doctorSpecialization: doctorSpecialization ?? this.doctorSpecialization,
        notes: notes ?? this.notes,
        serviceType: serviceType ?? this.serviceType,
        serviceId: serviceId ?? this.serviceId,
        serviceName: serviceName ?? this.serviceName,
        serviceCost: serviceCost ?? this.serviceCost,
        doctorShare: doctorShare ?? this.doctorShare,
        doctorInput: doctorInput ?? this.doctorInput,
        towerShare: towerShare ?? this.towerShare,
        departmentShare: departmentShare ?? this.departmentShare,
        doctorReviewPending: doctorReviewPending ?? this.doctorReviewPending,
        doctorReviewedAt: doctorReviewedAt ?? this.doctorReviewedAt,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'Patient(id:$id, name:$name, age:$age, diagnosis:$diagnosis, paid:$paidAmount, '
      'remaining:$remaining, registerDate:$registerDate, accountId:$accountId, '
      'deviceId:$deviceId, localId:$localId, updatedAt:$updatedAt, '
      'doctorReviewPending:$doctorReviewPending, doctorReviewedAt:$doctorReviewedAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Patient &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          age == other.age &&
          diagnosis == other.diagnosis &&
          paidAmount == other.paidAmount &&
          remaining == other.remaining &&
          registerDate == other.registerDate &&
          phoneNumber == other.phoneNumber &&
          healthStatus == other.healthStatus &&
          preferences == other.preferences &&
          doctorId == other.doctorId &&
          doctorName == other.doctorName &&
          doctorSpecialization == other.doctorSpecialization &&
          notes == other.notes &&
          serviceType == other.serviceType &&
          serviceId == other.serviceId &&
          serviceName == other.serviceName &&
          serviceCost == other.serviceCost &&
          doctorShare == other.doctorShare &&
          doctorInput == other.doctorInput &&
          towerShare == other.towerShare &&
          departmentShare == other.departmentShare &&
          doctorReviewPending == other.doctorReviewPending &&
          doctorReviewedAt == other.doctorReviewedAt &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hashAll([
        id,
        name,
        age,
        diagnosis,
        paidAmount,
        remaining,
        registerDate,
        phoneNumber,
        healthStatus,
        preferences,
        doctorId,
        doctorName,
        doctorSpecialization,
        notes,
        serviceType,
        serviceId,
        serviceName,
        serviceCost,
        doctorShare,
        doctorInput,
        towerShare,
        departmentShare,
        doctorReviewPending,
        doctorReviewedAt,
        accountId,
        deviceId,
        localId,
        updatedAt,
      ]);
}
