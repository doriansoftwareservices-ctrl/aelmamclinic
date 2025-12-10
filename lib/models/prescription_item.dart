// lib/models/prescription_item.dart
/*───────────────────────────────────────────────────────────────────────────
  نموذج: PrescriptionItem (عناصر الوصفة)
  محليًا (SQLite - camelCase): prescriptionId, drugId, days, timesPerDay
  سحابيًا (Supabase - snake_case عبر toCloudMap/SyncService):
    account_id, device_id, local_id, prescription_id, drug_id, days,
    times_per_day, updated_at
  fromMap يدعم camel + snake ويحوّل الأنواع بأمان.
───────────────────────────────────────────────────────────────────────────*/

class PrescriptionItem {
  /*────────── الثوابت ──────────*/
  static const String table = 'prescription_items';

  /*──────── SQL (محلي SQLite) ────────*/
  /// ملاحظة: DBService ينشئ هذا الجدول؛ أبقيناه هنا للتوحيد.
  static const String createTable = '''
    CREATE TABLE IF NOT EXISTS $table (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      prescriptionId INTEGER NOT NULL,
      drugId INTEGER        NOT NULL,
      days INTEGER          NOT NULL,
      timesPerDay INTEGER   NOT NULL,
      FOREIGN KEY (prescriptionId) REFERENCES prescriptions(id) ON DELETE CASCADE,
      FOREIGN KEY (drugId)        REFERENCES drugs(id)
    );
  ''';

  /// فهارس اختيارية لتحسين الاستعلامات
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_prescriptionId ON $table(prescriptionId);
    CREATE INDEX IF NOT EXISTS idx_${table}_drugId         ON $table(drugId);
  ''';

  /*────────── الحقول (محلي) ──────────*/
  final int? id; // PK
  final int prescriptionId; // FK → prescriptions.id
  final int drugId; // FK → drugs.id
  final int days; // مدة الاستعمال بالأيام
  final int timesPerDay; // مرات الاستخدام يوميًا

  /*────────── حقول مزامنة اختيارية (لا تُحفَظ محليًا) ──────────*/
  final String? accountId; // Supabase → accounts.id
  final String? deviceId; // معرّف الجهاز
  final int? localId; // مرجع السجل المحلي عند الرفع (إن لم يُمرّر نستخدم id)
  final DateTime? updatedAt;

  const PrescriptionItem({
    this.id,
    required this.prescriptionId,
    required this.drugId,
    required this.days,
    required this.timesPerDay,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  });

  /*──────── helpers آمنة ────────*/
  static int? _asIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _asInt0(dynamic v) => _asIntN(v) ?? 0;

  static String? _asStrN(dynamic v) => v == null ? null : v.toString();

  static DateTime? _asDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  /*──────── تحويلات↔︎ خريطة ────────*/
  /// SQLite محليًا: نخزّن camelCase.
  Map<String, dynamic> toMap() => {
        'id': id,
        'prescriptionId': prescriptionId,
        'drugId': drugId,
        'days': days,
        'timesPerDay': timesPerDay,
      };

  Map<String, dynamic> toJson() => toMap();

  /// تمثيل سحابي (snake_case) — يستخدمه SyncService عند الرفع.
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'prescription_id': prescriptionId,
        'drug_id': drugId,
        'days': days,
        'times_per_day': timesPerDay,
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  /// يدعم مفاتيح camelCase و snake_case (قادمة من Supabase).
  factory PrescriptionItem.fromMap(Map<String, dynamic> row) =>
      PrescriptionItem(
        id: _asIntN(row['id']),
        prescriptionId:
            _asInt0(row['prescriptionId'] ?? row['prescription_id']),
        drugId: _asInt0(row['drugId'] ?? row['drug_id']),
        days: _asInt0(row['days']),
        timesPerDay: _asInt0(row['timesPerDay'] ?? row['times_per_day']),
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

  /*──────── copyWith ────────*/
  PrescriptionItem copyWith({
    int? id,
    int? prescriptionId,
    int? drugId,
    int? days,
    int? timesPerDay,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      PrescriptionItem(
        id: id ?? this.id,
        prescriptionId: prescriptionId ?? this.prescriptionId,
        drugId: drugId ?? this.drugId,
        days: days ?? this.days,
        timesPerDay: timesPerDay ?? this.timesPerDay,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'PrescriptionItem(id: $id, prescriptionId: $prescriptionId, drugId: $drugId, '
      'days: $days, timesPerDay: $timesPerDay, accountId: $accountId, '
      'deviceId: $deviceId, localId: $localId, updatedAt: $updatedAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrescriptionItem &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          prescriptionId == other.prescriptionId &&
          drugId == other.drugId &&
          days == other.days &&
          timesPerDay == other.timesPerDay &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(id, prescriptionId, drugId, days, timesPerDay,
      accountId, deviceId, localId, updatedAt);
}
