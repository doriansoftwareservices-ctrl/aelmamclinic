// lib/models/employee.dart

/// نموذج الموظّف (محلي + متزامن مع السحابة).
/// محليًا في SQLite نستخدم camelCase؛ وعند الرفع للسحابة
/// نقدّم snake_case عبر toCloudMap().
///
/// توافق خلفي:
/// - بعض الإصدارات القديمة كانت تحتوي عمود doctorId بدل isDoctor.
///   عند القراءة: إذا وُجد doctorId > 0 سنعتبر isDoctor=true.
class Employee {
  static const String table = 'employees';

  /// إنشاء جدول SQLite (مطابق لتعريفه الأحدث في DBService).
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT,
    identityNumber TEXT,
    phoneNumber    TEXT,
    jobTitle       TEXT,
    address        TEXT,
    maritalStatus  TEXT,
    basicSalary    REAL,
    finalSalary    REAL,
    isDoctor       INTEGER DEFAULT 0,
    userUid        TEXT
  );
  ''';

  /// (اختياري) فهارس مفيدة للأداء.
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_name     ON $table(name);
    CREATE INDEX IF NOT EXISTS idx_${table}_isDoctor ON $table(isDoctor);
  ''';

  /*────────────────────────── الحقول (محلي) ─────────────────────────*/
  final int? id;
  final String name;
  final String identityNumber;
  final String phoneNumber;
  final String jobTitle;
  final String address;
  final String maritalStatus;
  final double basicSalary;
  final double finalSalary;
  final bool isDoctor;
  final String? userUid;

  /*────────────────────────── حقول مزامنة اختيارية (سحابة) ─────────────────────────*/
  /// معرّف الحساب (Supabase → accounts.id)
  final String? accountId;

  /// معرّف الجهاز (لتتبّع المصدر أثناء المزامنة)
  final String? deviceId;

  /// مرجع السجل المحلي عند الرفع (إن لم يُمرّر نستخدم id المحلي)
  final int? localId;

  /// آخر تحديث في السحابة (اختياري)
  final DateTime? updatedAt;

  const Employee({
    this.id,
    this.name = '',
    this.identityNumber = '',
    this.phoneNumber = '',
    this.jobTitle = '',
    this.address = '',
    this.maritalStatus = '',
    this.basicSalary = 0.0,
    this.finalSalary = 0.0,
    this.isDoctor = false,
    this.userUid,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  });

  /* ─────────── Helpers آمنة ─────────── */
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

  static String? _toStrN(dynamic v) => v?.toString();
  static String _toStr0(dynamic v) => v?.toString() ?? '';

  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v?.toString().trim().toLowerCase();
    return s == 'true' || s == 't' || s == '1' || s == 'yes';
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  /* ─────────── التحويلات ─────────── */

  /// نخزّن محليًا بصيغة camelCase.
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'identityNumber': identityNumber,
        'phoneNumber': phoneNumber,
        'jobTitle': jobTitle,
        'address': address,
        'maritalStatus': maritalStatus,
        'basicSalary': basicSalary,
        'finalSalary': finalSalary,
        'isDoctor': isDoctor ? 1 : 0,
        'userUid': userUid,
      };

  /// تمثيل سحابي (snake_case) للاستخدام عند الدفع إلى Supabase.
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        'account_id': accountId,
        'device_id': deviceId,
        'name': name,
        'identity_number': identityNumber,
        'phone_number': phoneNumber,
        'job_title': jobTitle,
        'address': address,
        'marital_status': maritalStatus,
        'basic_salary': basicSalary,
        'final_salary': finalSalary,
        'is_doctor': isDoctor,
        'user_uid': userUid,
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  /// JSON عام — نُعيد خريطة السحابة افتراضيًا
  Map<String, dynamic> toJson() => toCloudMap();

  /// يدعم القراءة من camelCase و/أو snake_case،
  /// مع توافق خلفي لعمود doctorId القديم.
  factory Employee.fromMap(Map<String, dynamic> m) {
    final id = _toIntN(m['id']);
    final name = _toStr0(m['name']);
    final identityNumber = _toStr0(m['identityNumber'] ?? m['identity_number']);
    final phoneNumber = _toStr0(m['phoneNumber'] ?? m['phone_number']);
    final jobTitle = _toStr0(m['jobTitle'] ?? m['job_title']);
    final address = _toStr0(m['address']);
    final maritalStatus = _toStr0(m['maritalStatus'] ?? m['marital_status']);
    final basicSalary = _toDouble0(m['basicSalary'] ?? m['basic_salary']);
    final finalSalary = _toDouble0(m['finalSalary'] ?? m['final_salary']);
    final userUid = _toStrN(m['userUid'] ?? m['user_uid']);

    // isDoctor: اقرأ من isDoctor / is_doctor، وإن لم يوجد فافحص doctorId>0 (قديم)
    bool isDoctor = _toBool(m['isDoctor'] ?? m['is_doctor'] ?? 0);
    if (!isDoctor) {
      final legacyDoctorId = _toInt0(m['doctorId'] ?? m['doctor_id']);
      if (legacyDoctorId > 0) isDoctor = true;
    }

    // حقول المزامنة (camel + snake)
    final accountId = _toStrN(m['accountId'] ?? m['account_id']);
    final deviceId = _toStrN(m['deviceId'] ?? m['device_id']);
    final localId = m['localId'] is int
        ? m['localId'] as int
        : (m['local_id'] is int ? m['local_id'] as int : m['id'] as int?);
    final updatedAt = _toDateN(m['updatedAt'] ?? m['updated_at']);
    return Employee(
      id: id,
      name: name,
      identityNumber: identityNumber,
      phoneNumber: phoneNumber,
      jobTitle: jobTitle,
      address: address,
      maritalStatus: maritalStatus,
      basicSalary: basicSalary,
      finalSalary: finalSalary,
      isDoctor: isDoctor,
      userUid: (userUid == null || userUid.isEmpty) ? null : userUid,
      accountId: accountId,
      deviceId: deviceId,
      localId: localId,
      updatedAt: updatedAt,
    );
  }

  factory Employee.fromJson(Map<String, dynamic> json) =>
      Employee.fromMap(json);

  Employee copyWith({
    int? id,
    String? name,
    String? identityNumber,
    String? phoneNumber,
    String? jobTitle,
    String? address,
    String? maritalStatus,
    double? basicSalary,
    double? finalSalary,
    bool? isDoctor,
    String? userUid,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      Employee(
        id: id ?? this.id,
        name: name ?? this.name,
        identityNumber: identityNumber ?? this.identityNumber,
        phoneNumber: phoneNumber ?? this.phoneNumber,
        jobTitle: jobTitle ?? this.jobTitle,
        address: address ?? this.address,
        maritalStatus: maritalStatus ?? this.maritalStatus,
        basicSalary: basicSalary ?? this.basicSalary,
        finalSalary: finalSalary ?? this.finalSalary,
        isDoctor: isDoctor ?? this.isDoctor,
        userUid: userUid ?? this.userUid,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'Employee(id:$id, name:$name, phone:$phoneNumber, job:$jobTitle, isDoctor:$isDoctor, userUid:$userUid)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Employee &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          identityNumber == other.identityNumber &&
          phoneNumber == other.phoneNumber &&
          jobTitle == other.jobTitle &&
          address == other.address &&
          maritalStatus == other.maritalStatus &&
          basicSalary == other.basicSalary &&
          finalSalary == other.finalSalary &&
          isDoctor == other.isDoctor &&
          userUid == other.userUid &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        identityNumber,
        phoneNumber,
        jobTitle,
        address,
        maritalStatus,
        basicSalary,
        finalSalary,
        isDoctor,
        userUid,
        accountId,
        deviceId,
        localId,
        updatedAt,
      );
}
