// lib/models/item_type.dart

/// فئة عنصر (تصنيف مخزّنات).
/// متوافقة مع:
/// - SQLite محليًا: الجدول `item_types` بالأعمدة (id, name)
/// - Remote: نفس أسماء الأعمدة؛ يتم تحويل camel↔snake عبر طبقة المزامنة عند الحاجة.
class ItemType {
  static const String table = 'item_types';

  /// إنشاء الجدول محليًا (SQLite)
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE
  );
  ''';

  /// (اختياري) فهرس أداء على الاسم
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_name ON $table(name);
  ''';

  /* ─── الحقول الأساسية (محلي) ─── */
  final int? id; // المعرف الذاتي
  final String name; // اسم الفئة (Unique)

  /* ─── حقول مزامنة اختيارية (لا تُحفَظ محليًا) ─── */
  final String? accountId;
  final String? deviceId;
  final int? localId;
  final DateTime? updatedAt;

  const ItemType({
    this.id,
    required this.name,
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

  static DateTime _toDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  /*──────────── إلى/من Map (SQLite) ────────────*/

  /// محليًا نخزن snake_case فقط.
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
      };

  /// تمثيل مناسب للسحابة (snake_case) مع حقول المزامنة الاختيارية.
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        // تعقيم السلاسل الفارغة/المسافات
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'name': name,
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  Map<String, dynamic> toJson() => toCloudMap();

  /// يدعم القراءة المرنة من أي مصدر (SQLite/Remote) مع camel/snake.
  factory ItemType.fromMap(Map<String, dynamic> map) => ItemType(
        id: _toIntN(map['id']),
        name: _toStr(map['name']),
        accountId: _toStrN(map['accountId'] ?? map['account_id']),
        deviceId: _toStrN(map['deviceId'] ?? map['device_id']),
        localId: map['localId'] is int
            ? map['localId'] as int
            : (map['local_id'] is int
                ? map['local_id'] as int
                : map['id'] as int?),
        updatedAt: map.containsKey('updatedAt') || map.containsKey('updated_at')
            ? _toDate(map['updatedAt'] ?? map['updated_at'])
            : null,
      );

  ItemType copyWith({
    int? id,
    String? name,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      ItemType(
        id: id ?? this.id,
        name: name ?? this.name,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() => 'ItemType(id: $id, name: $name)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ItemType &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode =>
      Object.hash(id, name, accountId, deviceId, localId, updatedAt);
}
