// lib/models/doctor.dart
//
// نموذج الطبيب: يدعم تخزين SQLite (camelCase) ومزامنة Remote (snake_case).

class Doctor {
  static const String table = 'doctors';

  /// مخطط SQLite المحلي (مستخدم من DBService).
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    employeeId     INTEGER,
    userUid        TEXT,
    name           TEXT,
    specialization TEXT,
    phoneNumber    TEXT,
    startTime      TEXT,
    endTime        TEXT,
    printCounter   INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (employeeId) REFERENCES employees(id) ON DELETE SET NULL
  );
  ''';

  final int? id;
  final int? employeeId;
  final String? userUid; // Remote auth.users.id
  final String name;
  final String specialization;
  final String phoneNumber;
  final String startTime;
  final String endTime;
  final int printCounter;

  const Doctor({
    this.id,
    this.employeeId,
    this.userUid,
    required this.name,
    required this.specialization,
    required this.phoneNumber,
    required this.startTime,
    required this.endTime,
    this.printCounter = 0,
  });

  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _toInt0(dynamic v) => _toIntN(v) ?? 0;

  static String _toStr(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  static String? _toStrN(dynamic v) {
    final s = _toStr(v, '');
    return s.isEmpty ? null : s;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'employeeId': employeeId,
        'userUid': userUid,
        'name': name,
        'specialization': specialization,
        'phoneNumber': phoneNumber,
        'startTime': startTime,
        'endTime': endTime,
        'printCounter': printCounter,
      };

  Map<String, dynamic> toJson() => toMap();

  factory Doctor.fromMap(Map<String, dynamic> map) => Doctor(
        id: _toIntN(map['id']),
        employeeId: _toIntN(map['employeeId'] ?? map['employee_id']),
        userUid: _toStrN(map['userUid'] ?? map['user_uid']),
        name: _toStr(map['name']),
        specialization: _toStr(map['specialization']),
        phoneNumber: _toStr(map['phoneNumber'] ?? map['phone_number']),
        startTime: _toStr(map['startTime'] ?? map['start_time']),
        endTime: _toStr(map['endTime'] ?? map['end_time']),
        printCounter: _toInt0(map['printCounter'] ?? map['print_counter']),
      );

  factory Doctor.fromJson(Map<String, dynamic> json) => Doctor.fromMap(json);

  Doctor copyWith({
    int? id,
    int? employeeId,
    String? userUid,
    String? name,
    String? specialization,
    String? phoneNumber,
    String? startTime,
    String? endTime,
    int? printCounter,
  }) =>
      Doctor(
        id: id ?? this.id,
        employeeId: employeeId ?? this.employeeId,
        userUid: userUid ?? this.userUid,
        name: name ?? this.name,
        specialization: specialization ?? this.specialization,
        phoneNumber: phoneNumber ?? this.phoneNumber,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
        printCounter: printCounter ?? this.printCounter,
      );

  @override
  String toString() =>
      'Doctor(id:$id, employeeId:$employeeId, userUid:$userUid, name:$name, specialization:$specialization, printCounter:$printCounter)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Doctor &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          employeeId == other.employeeId &&
          userUid == other.userUid &&
          name == other.name &&
          specialization == other.specialization &&
          phoneNumber == other.phoneNumber &&
          startTime == other.startTime &&
          endTime == other.endTime &&
          printCounter == other.printCounter;

  @override
  int get hashCode => Object.hash(
        id,
        employeeId,
        userUid,
        name,
        specialization,
        phoneNumber,
        startTime,
        endTime,
        printCounter,
      );
}
