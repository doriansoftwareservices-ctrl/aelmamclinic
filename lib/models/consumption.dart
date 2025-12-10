// lib/models/consumption.dart
//
// نموذج استهلاك (مصروف / خصم من المخزون).
// محليًا نخزّن camelCase كما في SQLite، ومع المزامنة نوفر toCloudMap()
// الذي يحوّل إلى snake_case ويضيف حقول مزامنة اختيارية.

class Consumption {
  static const String table = 'consumptions';

  /*────────────────────────── إنشاء الجدول محليًا ─────────────────────────*/
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    patientId TEXT,
    itemId    TEXT,
    quantity  INTEGER NOT NULL DEFAULT 0,
    date      TEXT    NOT NULL,
    amount    REAL    NOT NULL DEFAULT 0,
    note      TEXT
  );
  ''';

  /*────────────────────────── الحقول الأساسية (محلي) ─────────────────────────*/
  int? id;

  /// نخزّنه نصاً محلياً (قد يكون رقم في الأصل)
  String? patientId;

  /// نخزّنه نصاً محلياً (قد يكون رقم في الأصل)
  String? itemId;

  int quantity;
  double amount;
  String? note;

  DateTime _storedDate;

  /*────────────────────────── حقول مزامنة اختيارية ─────────────────────────*/
  /// معرّف الحساب في السحابة (Supabase → accounts.id)
  String? accountId;

  /// معرّف الجهاز (لتتبّع المصدر أثناء المزامنة)
  String? deviceId;

  /// مرجع السجلّ المحلي عند الرفع (إن لم يُمرّر نستخدم id المحلي)
  int? localId;

  /// آخر تحديث (اختياري) — يُفيد في فضّ التعارضات
  DateTime? updatedAt;

  Consumption({
    this.id,
    this.patientId,
    this.itemId,
    this.quantity = 0,
    this.amount = 0.0,
    this.note,
    DateTime? date,
    DateTime? consumedAt, // احتياطًا لقبول اسم بديل
    this.accountId,
    this.deviceId,
    this.localId,
    this.updatedAt,
  }) : _storedDate = date ?? consumedAt ?? DateTime.now();

  DateTime get date => _storedDate;
  DateTime get consumedAt => _storedDate;

  /// خريطة للحفظ في SQLite (camelCase) — التحويل إلى snake_case يتم في SyncService عند الرفع.
  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'itemId': itemId,
        'quantity': quantity,
        'amount': amount,
        'note': note,
        'date': _storedDate.toIso8601String(),
      };

  /// خريطة لاستخدامها في السحابة (snake_case)
  /// ✅ تم اعتماد 'date' بدل 'consumed_at' لتتوافق مع allow-list في SyncService.
  Map<String, dynamic> toCloudMap() => {
        'local_id': localId ?? id,
        'account_id': (accountId?.isEmpty ?? true) ? null : accountId,
        'device_id': (deviceId?.isEmpty ?? true) ? null : deviceId,
        'patient_id': patientId,
        'item_id': itemId,
        'quantity': quantity,
        'amount': amount,
        'note': note,
        'date': _storedDate.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      }..removeWhere((k, v) => v == null);

  /// مرادف عندما يلزم JSON (نستخدم تمثيل السحابة افتراضيًا)
  Map<String, dynamic> toJson() => toCloudMap();

  /* ─── محوّلات آمنة ─── */
  static int _toInt(dynamic v, [int fallback = 0]) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? fallback;
  }

  static double _toDouble(dynamic v, [double fallback = 0.0]) {
    if (v == null) return fallback;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  static String? _toStrOrNull(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  static DateTime _epochToDate(num n) {
    // ثوانٍ/ميلي/مايكرو — دعم أزمنة رقمية إن وجدت
    if (n < 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt() * 1000);
    } else if (n < 10000000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n.toInt());
    } else {
      return DateTime.fromMicrosecondsSinceEpoch(n.toInt());
    }
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    if (v is num) return _epochToDate(v);
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  static DateTime _pickDate(Map<String, dynamic> m) {
    // أولوية: 'date' ثم 'consumedAt' ثم 'consumed_at' ثم 'created_at'
    for (final k in ['date', 'consumedAt', 'consumed_at', 'created_at']) {
      final v = m[k];
      if (v != null) return _parseDate(v);
    }
    return DateTime.now();
  }

  /// قراءة مرنة تتحمل null وأنواع مختلفة وأسماء مفاتيح بديلة (snake/camel)
  factory Consumption.fromMap(Map<String, dynamic> m) {
    return Consumption(
      id: m['id'] as int?,
      patientId: _toStrOrNull(m['patientId'] ?? m['patient_id']),
      itemId: _toStrOrNull(m['itemId'] ?? m['item_id']),
      quantity: _toInt(m['quantity']),
      amount: _toDouble(m['amount']),
      note: m['note'] as String?,
      date: _pickDate(m),
      // حقول مزامنة (camel + snake)
      accountId: _toStrOrNull(m['accountId'] ?? m['account_id']),
      deviceId: _toStrOrNull(m['deviceId'] ?? m['device_id']),
      localId: m['localId'] is int
          ? m['localId'] as int
          : (m['local_id'] is int ? m['local_id'] as int : m['id'] as int?),
      updatedAt: (() {
        final v = m['updatedAt'] ?? m['updated_at'];
        if (v == null) return null;
        return DateTime.tryParse(v.toString());
      })(),
    );
  }

  /// مرادف عندما يلزم من JSON
  factory Consumption.fromJson(Map<String, dynamic> m) =>
      Consumption.fromMap(m);

  Consumption copyWith({
    int? id,
    String? patientId,
    String? itemId,
    int? quantity,
    double? amount,
    String? note,
    DateTime? date,
    String? accountId,
    String? deviceId,
    int? localId,
    DateTime? updatedAt,
  }) {
    return Consumption(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      itemId: itemId ?? this.itemId,
      quantity: quantity ?? this.quantity,
      amount: amount ?? this.amount,
      note: note ?? this.note,
      date: date ?? _storedDate,
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      localId: localId ?? this.localId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'Consumption(id: $id, patientId: $patientId, itemId: $itemId, qty: $quantity, amount: $amount, date: $_storedDate)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Consumption &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          patientId == other.patientId &&
          itemId == other.itemId &&
          quantity == other.quantity &&
          amount == other.amount &&
          note == other.note &&
          _storedDate == other._storedDate &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          localId == other.localId &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        patientId,
        itemId,
        quantity,
        amount,
        note,
        _storedDate,
        accountId,
        deviceId,
        localId,
        updatedAt,
      );
}
