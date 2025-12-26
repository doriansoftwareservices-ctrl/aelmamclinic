// lib/models/storage_type.dart

/// تمثيل نوع التخزين للنسخ الاحتياطي/المزامنة.
/// - `local`        : تخزين محلي على الجهاز.
/// - `googleDrive`  : تخزين على Google Drive.
///
/// يدعم هذا الملف محوّلات مرنة (String/int/enum) مع توافق خلفي لقبول:
///  googleDrive / google_drive / google-drive / google drive / gdrive / drive
/// وأيضًا تسميات عربية مثل: "محلي" ، "قوقل درايف".
enum StorageType { local, googleDrive }

extension StorageTypeX on StorageType {
  /// قيمة نصية ثابتة للحفظ في قواعد البيانات/JSON.
  /// ملاحظة: أبقينا "googleDrive" للتوافق مع القيم القديمة المخزّنة.
  String get dbValue {
    switch (this) {
      case StorageType.local:
        return 'local';
      case StorageType.googleDrive:
        return 'googleDrive';
    }
  }

  /// عنوان ودّي للعرض في الواجهات.
  String get label {
    switch (this) {
      case StorageType.local:
        return 'محلي';
      case StorageType.googleDrive:
        return 'Google Drive';
    }
  }

  /// هل يتطلب هذا النوع تسجيل دخول خارجي (OAuth)؟
  bool get requiresOAuth => this == StorageType.googleDrive;

  /// هل هو تخزين سحابي؟
  bool get isCloud => this == StorageType.googleDrive;

  /// تحويل للقيمة النصّية للاستخدام في JSON/DB.
  String toJson() => dbValue;

  /// بديل آمن عن toString() عند الحاجة لقيمة ثابتة.
  String asString() => dbValue;
}

/// محوّلات عامة مرنة للاستخدام مع DB/Prefs/JSON.
class StorageTypeParser {
  static const StorageType _fallback = StorageType.local;

  /// يعيد قيمة enum من أي تمثيل شائع:
  /// - enum نفسه
  /// - index (int)
  /// - String: local / googleDrive / google_drive / google-drive / google drive / gdrive / drive
  /// - عربي: "محلي" ، "قوقل درايف" ، "جوجل درايف"
  static StorageType parse(dynamic v) {
    if (v is StorageType) return v;

    if (v is int) {
      return (v >= 0 && v < StorageType.values.length)
          ? StorageType.values[v]
          : _fallback;
    }

    final s = v?.toString().trim().toLowerCase();
    switch (s) {
      // Local
      case 'local':
      case 'محلي':
        return StorageType.local;

      // Google Drive (أشكال متعددة)
      case 'googledrive':
      case 'google_drive':
      case 'google-drive':
      case 'google drive':
      case 'gdrive':
      case 'drive':
      case 'قوقل درايف':
      case 'جوجل درايف':
        return StorageType.googleDrive;

      default:
        return _fallback;
    }
  }

  /// للاحتفاظ كنص في DB/Prefs.
  static String toDbValue(StorageType t) => t.dbValue;

  /// للقراءة من DB/Prefs (نص).
  static StorageType fromDbValue(String? s) => parse(s);

  /// للحفظ كـ رقم (SQLite INT أو SharedPrefs).
  static int toIndex(StorageType t) => t.index;

  /// للقراءة من رقم.
  static StorageType fromIndex(int? i) =>
      (i != null && i >= 0 && i < StorageType.values.length)
          ? StorageType.values[i]
          : _fallback;

  /// من JSON (يدعم أي من الأشكال المذكورة أعلاه).
  static StorageType fromJson(dynamic json) => parse(json);

  /// يحاول التحويل من الملصق المعروض للمستخدم.
  /// أمثلة: "محلي" → local، "Google Drive" → googleDrive.
  static StorageType fromLabel(String? label) {
    final s = label?.trim().toLowerCase();
    if (s == 'محلي' || s == 'local') return StorageType.local;
    if (s == 'google drive' || s == 'جوجل درايف' || s == 'قوقل درايف') {
      return StorageType.googleDrive;
    }
    return _fallback;
  }
}
