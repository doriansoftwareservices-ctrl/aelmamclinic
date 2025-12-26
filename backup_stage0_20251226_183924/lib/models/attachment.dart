// lib/models/attachment.dart

/// نموذج لتمثيل المرفقات المرتبطة بمريض.
/// ⚠️ محلي فقط: لا يُرفع إلى السرفر ولا يُسحب منه.
class Attachment {
  /// المعرف الأساسي (محلي في SQLite).
  final int? id;

  /// معرّف المريض المرتبط.
  final int patientId;

  /// اسم الملف (مثال: invoice.pdf / photo.jpg).
  final String fileName;

  /// المسار الكامل للملف على الجهاز.
  final String filePath;

  /// نوع الميديا (MIME) مثل: image/jpeg أو application/pdf.
  final String mimeType;

  /// تاريخ الإنشاء (ISO8601).
  final DateTime createdAt;

  Attachment({
    this.id,
    required this.patientId,
    required this.fileName,
    required this.filePath,
    required this.mimeType,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// اسم الجدول في SQLite.
  static const String tableName = 'attachments';

  /// جملة إنشاء الجدول.
  static const String createTable = '''
    CREATE TABLE IF NOT EXISTS $tableName (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      patientId  INTEGER NOT NULL,
      fileName   TEXT    NOT NULL,
      filePath   TEXT    NOT NULL,
      mimeType   TEXT    NOT NULL,
      createdAt  TEXT    NOT NULL,
      FOREIGN KEY(patientId) REFERENCES patients(id) ON DELETE CASCADE
    );
  ''';

  /// (اختياري) فهرس لتحسين الاستعلامات حسب المريض/التاريخ.
  static const String createIndexes = '''
    CREATE INDEX IF NOT EXISTS idx_$tableName\_patient_created
    ON $tableName (patientId, createdAt);
  ''';

  /* ───────── helpers آمنة للتحويل ───────── */

  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _toInt0(dynamic v) => _toIntN(v) ?? 0;

  static String _toStr(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    return v.toString();
  }

  static DateTime _toDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  /// تحويل النموذج إلى Map (للإدراج/التحديث في SQLite).
  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'fileName': fileName,
        'filePath': filePath,
        'mimeType': mimeType,
        'createdAt': createdAt.toIso8601String(),
      };

  /// إنشاء نموذج من Map (يدعم camelCase وsnake_case للتوافق/الهجرة فقط).
  factory Attachment.fromMap(Map<String, dynamic> map) {
    return Attachment(
      id: _toIntN(map['id']),
      patientId: _toInt0(map['patientId'] ?? map['patient_id']),
      fileName: _toStr(map['fileName'] ?? map['file_name']),
      filePath: _toStr(map['filePath'] ?? map['file_path']),
      mimeType: _toStr(map['mimeType'] ?? map['mime_type']),
      createdAt: _toDate(map['createdAt'] ?? map['created_at']),
    );
  }

  Attachment copyWith({
    int? id,
    int? patientId,
    String? fileName,
    String? filePath,
    String? mimeType,
    DateTime? createdAt,
  }) {
    return Attachment(
      id: id ?? this.id,
      patientId: patientId ?? this.patientId,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      mimeType: mimeType ?? this.mimeType,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() =>
      'Attachment(id: $id, patientId: $patientId, fileName: $fileName)';
}
