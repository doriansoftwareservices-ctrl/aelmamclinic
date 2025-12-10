// lib/models/item.dart
import 'item_type.dart';

class Item {
  static const String table = 'items';

  /// إنشاء الجدول محليًا (SQLite) — أعمدة snake_case
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    type_id    INTEGER NOT NULL,
    name       TEXT    NOT NULL,
    price      REAL    NOT NULL,
    stock      INTEGER NOT NULL DEFAULT 0,
    created_at TEXT    NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(type_id) REFERENCES ${ItemType.table}(id) ON DELETE CASCADE,
    UNIQUE(type_id, name)
  );
  ''';

  /// (اختياري) فهارس إضافية — DBService ينشئ idx_items_name كذلك
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_type_id ON $table(type_id);
    CREATE INDEX IF NOT EXISTS idx_${table}_name    ON $table(name);
  ''';

  /* ─── الحقول الأساسية (محلي) ─── */
  final int? id;
  final int typeId;
  final String name;
  final double price;
  final int stock; // المتوفر في المخزون
  final DateTime createdAt;

  /* ─── حقول مزامنة اختيارية (لا تُحفَظ محليًا) ─── */
  final String? accountId;
  final String? deviceId;
  final int? localId;
  final DateTime? updatedAt;

  Item({
    this.id,
    required this.typeId,
    required this.name,
    required this.price,
    this.stock = 0,
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

  static int _toInt(dynamic v, [int fallback = 0]) => _toIntN(v) ?? fallback;

  static double _toDouble(dynamic v, [double fallback = 0.0]) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  static DateTime _toDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
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

  /*──────────── إلى/من Map ────────────*/

  /// محليًا نستخدم snake_case (متوافق مع DBService).
  Map<String, dynamic> toMap() => {
        'id': id,
        'type_id': typeId,
        'name': name,
        'price': price,
        'stock': stock,
        'created_at': createdAt.toIso8601String(),
      };

  /// تمثيل مخصص للسحابة (snake_case) مع حقول المزامنة الاختيارية.
  /// ملاحظة: لا نرسل isDeleted/deletedAt هنا—تُدار من DBService عند الحاجة.
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        // تعقيم الحقول الفارغة حتى لا تُرسل كسلاسل فارغة
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'type_id': typeId,
        'name': name,
        'price': price,
        'stock': stock,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  Map<String, dynamic> toJson() => toCloudMap();

  /// يدعم camelCase و snake_case (قادمة من Supabase أو من جداول محلية قديمة)
  factory Item.fromMap(Map<String, dynamic> map) => Item(
        id: _toIntN(map['id']),
        typeId: _toInt(map['type_id'] ?? map['typeId']),
        name: _toStr(map['name']),
        price: _toDouble(map['price']),
        stock: _toInt(map['stock']),
        createdAt: _toDate(map['created_at'] ?? map['createdAt']),
        accountId: _toStrN(map['accountId'] ?? map['account_id']),
        deviceId: _toStrN(map['deviceId'] ?? map['device_id']),
        localId: map['localId'] is int
            ? map['localId'] as int
            : (map['local_id'] is int
                ? map['local_id'] as int
                : map['id'] as int?),
        // updatedAt تصبح null إذا لم تُرسل من المصدر (لا نُسقِط عليها now)
        updatedAt: _toDateN(map['updatedAt'] ?? map['updated_at']),
      );

  /*──────────── JSON (snake_case) إن احتجته مباشرة للسحابة ────────────*/
  Map<String, dynamic> toJsonSnake() => toCloudMap();

  Item copyWith({
    int? id,
    int? typeId,
    String? name,
    double? price,
    int? stock,
    DateTime? createdAt,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      Item(
        id: id ?? this.id,
        typeId: typeId ?? this.typeId,
        name: name ?? this.name,
        price: price ?? this.price,
        stock: stock ?? this.stock,
        createdAt: createdAt ?? this.createdAt,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'Item(id: $id, typeId: $typeId, name: $name, price: $price, stock: $stock, createdAt: $createdAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Item &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          typeId == other.typeId &&
          name == other.name &&
          price == other.price &&
          stock == other.stock &&
          createdAt == other.createdAt &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        typeId,
        name,
        price,
        stock,
        createdAt,
        accountId,
        deviceId,
        localId,
        updatedAt,
      );
}
