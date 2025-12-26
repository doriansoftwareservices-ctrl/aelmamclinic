// lib/models/purchase.dart
import 'item.dart';

/// نموذج الشراء (Purchase)
/// محليًا: نخزّن snake_case في SQLite.
/// سحابيًا: نستخدم toCloudMap لإرسال snake_case مع حقول المزامنة الاختيارية.
class Purchase {
  static const String table = 'purchases';

  /* ─── إنشاء الجدول (snake_case محليًا) ─── */
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id    INTEGER NOT NULL,
    quantity   INTEGER NOT NULL,
    unit_price REAL    NOT NULL,
    created_at TEXT    NOT NULL,
    FOREIGN KEY(item_id) REFERENCES ${Item.table}(id) ON DELETE CASCADE
  );
  ''';

  /// (اختياري) فهرس على created_at لتسريع الترتيب حسب التاريخ
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_${table}_created_at ON $table(created_at);
  ''';

  /* ─── الحقول الأساسية (محلي) ─── */
  final int? id;
  final int itemId;
  final int quantity;
  final double unitPrice;
  final DateTime createdAt;

  /* ─── حقول مزامنة اختيارية (لا تُحفَظ محليًا) ─── */
  final String? accountId;
  final String? deviceId;
  final int? localId;
  final DateTime? updatedAt;

  Purchase({
    this.id,
    required this.itemId,
    required this.quantity,
    required this.unitPrice,
    DateTime? createdAt,
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /* ─── Helpers آمنة ─── */
  static int? _asIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _asInt(dynamic v, {int fallback = 0}) => _asIntN(v) ?? fallback;

  static double _asDouble(dynamic v, {double fallback = 0.0}) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  static DateTime _asDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  static DateTime? _asDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  static String? _asStrN(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  /* ─── SQLite Map (نخزّن محليًا snake_case) ─── */
  Map<String, dynamic> toMap() => {
        'id': id,
        'item_id': itemId,
        'quantity': quantity,
        'unit_price': unitPrice,
        'created_at': createdAt.toIso8601String(),
      };

  /// تمثيل مخصص للسحابة (snake_case) مع حقول المزامنة الاختيارية.
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        'account_id': (accountId?.trim().isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.trim().isEmpty ?? true) ? null : deviceId,
        'item_id': itemId,
        'quantity': quantity,
        'unit_price': unitPrice,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  Map<String, dynamic> toJson() => toCloudMap();

  /// يدعم مفاتيح camelCase أو snake_case (قادمة من Remote)
  factory Purchase.fromMap(Map<String, dynamic> map) => Purchase(
        id: _asIntN(map['id']),
        itemId: _asInt(map['itemId'] ?? map['item_id']),
        quantity: _asInt(map['quantity']),
        unitPrice: _asDouble(map['unitPrice'] ?? map['unit_price']),
        createdAt: _asDate(
          map['createdAt'] ?? map['created_at'] ?? map['purchased_at'],
        ),
        accountId: _asStrN(map['accountId'] ?? map['account_id']),
        deviceId: _asStrN(map['deviceId'] ?? map['device_id']),
        localId: map['localId'] is int
            ? map['localId'] as int
            : (map['local_id'] is int
                ? map['local_id'] as int
                : _asIntN(map['id'])),
        updatedAt: _asDateN(map['updatedAt'] ?? map['updated_at']),
      );

  Purchase copyWith({
    int? id,
    int? itemId,
    int? quantity,
    double? unitPrice,
    DateTime? createdAt,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) =>
      Purchase(
        id: id ?? this.id,
        itemId: itemId ?? this.itemId,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice ?? this.unitPrice,
        createdAt: createdAt ?? this.createdAt,
        accountId: accountId ?? this.accountId,
        deviceId: deviceId ?? this.deviceId,
        localId: localId ?? this.localId,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  double get totalPrice => unitPrice * quantity;

  @override
  String toString() =>
      'Purchase(id: $id, itemId: $itemId, qty: $quantity, unit: $unitPrice, total: $totalPrice, createdAt: $createdAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Purchase &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          itemId == other.itemId &&
          quantity == other.quantity &&
          unitPrice == other.unitPrice &&
          createdAt == other.createdAt &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        itemId,
        quantity,
        unitPrice,
        createdAt,
        accountId,
        deviceId,
        localId,
        updatedAt,
      );
}
