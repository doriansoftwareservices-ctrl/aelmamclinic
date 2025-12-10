// lib/models/drug.dart
/*───────────────────────────────────────────────────────────────────────────
  نموذج البيانات: الدواء (Drug)

  محليًا (SQLite - camelCase):
    id, name, notes, createdAt

  سحابيًا (Supabase - snake_case عبر SyncService):
    account_id, device_id, local_id, name, notes, created_at, updated_at
    - local_id يُرسل كبصمة تربط سجل السحابة بالسجل المحلي (id إن لم يُمرّر localId)
───────────────────────────────────────────────────────────────────────────*/

class Drug {
  static const String table = 'drugs';

  /// (اختياري) أمر إنشاء الجدول محليًا لو أردت استخدامه مركزيًا
  static const String createTable = '''
    CREATE TABLE IF NOT EXISTS $table (
      id        INTEGER PRIMARY KEY AUTOINCREMENT,
      name      TEXT UNIQUE NOT NULL,
      notes     TEXT,
      createdAt TEXT NOT NULL DEFAULT (datetime('now'))
    );
  ''';

  /// (اختياري) فهرس فريد case-insensitive — DBService ينشئه أيضًا.
  static const String createIndexes = '''
    CREATE UNIQUE INDEX IF NOT EXISTS uix_drugs_lower_name
    ON $table(lower(name));
  ''';

  /*────────────────────────── الحقول (محلي) ─────────────────────────*/
  final int? id; // محلي فقط (AutoIncrement)
  final String name;
  final String? notes;
  final DateTime createdAt;

  /*──────────────────────── حقول المزامنة (سحابة) ───────────────────*/
  /// معرّف الحساب (Supabase → accounts.id)
  final String? accountId;

  /// معرّف الجهاز (لتتبع المصدر أثناء المزامنة)
  final String? deviceId;

  /// مرجع السجل المحلي عند الرفع (إن لم يُرسل نضع id المحلي)
  final int? localId;

  /// آخر تعديل في السحابة
  final DateTime? updatedAt;

  Drug({
    this.id,
    required this.name,
    this.notes,
    DateTime? createdAt,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /*──────────── Helpers آمنة ────────────*/
  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static String? _toStrN(dynamic v) => v == null ? null : v.toString();

  static String _toStr(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  static DateTime _toDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    return _toDate(v);
  }

  /*──────────────────────── SQLite Map (محلي) ───────────────────────*/
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'notes': notes,
        'createdAt': createdAt.toIso8601String(),
      };

  /*──────────────────────── Cloud Map (سحابة) ───────────────────────*/
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'name': name,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  /// JSON (snake_case) — مرادف لـ toCloudMap
  Map<String, dynamic> toJson() => toCloudMap();

  /// يدعم مفاتيح camelCase و snake_case (قادمة من Supabase أو محلية)
  factory Drug.fromMap(Map<String, dynamic> row) => Drug(
        id: _toIntN(row['id']),
        name: _toStr(row['name']),
        notes: _toStrN(row['notes']),
        createdAt: _toDate(row['createdAt'] ?? row['created_at']),
        accountId: _toStrN(row['accountId'] ?? row['account_id']),
        deviceId: _toStrN(row['deviceId'] ?? row['device_id']),
        localId: _toIntN(row['localId'] ?? row['local_id'] ?? row['id']),
        updatedAt: _toDateN(row['updatedAt'] ?? row['updated_at']),
      );

  factory Drug.fromJson(Map<String, dynamic> json) => Drug.fromMap(json);

  Drug copyWith({
    int? id,
    String? name,
    String? notes,
    DateTime? createdAt,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) {
    return Drug(
      id: id ?? this.id,
      name: name ?? this.name,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      localId: localId ?? this.localId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'Drug(id: $id, name: $name, notes: $notes, createdAt: $createdAt, '
      'accountId: $accountId, deviceId: $deviceId, localId: $localId, updatedAt: $updatedAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Drug &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          notes == other.notes &&
          createdAt == other.createdAt &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
      id, name, notes, createdAt, accountId, deviceId, localId, updatedAt);
}
