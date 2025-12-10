// lib/models/chat_attachment_record.dart
//
// نموذج "سجل مرفق" مطابق لجدول Supabase: public.chat_attachments
// لا يحتوي حقول واجهة مثل حالة الرفع/التقدّم... إلخ.
// يدعم camelCase وsnake_case في fromMap.
//
// يعتمد على utils/time.dart للدوال:
//  - t.parseDateFlexibleUtc(dynamic)
//  - t.toIsoUtc(DateTime?)

import 'package:aelmamclinic/utils/time.dart' as t;

class ChatAttachmentRecord {
  // حقول قاعدة البيانات
  final String? id; // uuid (قد تكون null قبل الإدراج)
  final String messageId; // uuid
  final String bucket; // افتراضيًا 'chat-attachments'
  final String path; // مسار داخل البكت
  final String mimeType; // مثل image/png
  final int sizeBytes; // الحجم بالبايت
  final int? width; // أبعاد اختيارية للصورة/الفيديو
  final int? height;
  final DateTime? createdAt; // UTC

  const ChatAttachmentRecord({
    this.id,
    required this.messageId,
    this.bucket = 'chat-attachments',
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    this.width,
    this.height,
    this.createdAt,
  });

  // ----------------- Utilities -----------------

  static String _trimOr(dynamic v, String fallback) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? fallback : s;
  }

  static String? _trimOrNull(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  static int _toInt(dynamic v, {int fallback = 0}) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  static int? _toIntOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  // ----------------- Factories -----------------

  /// يدعم مفاتيح camelCase و snake_case
  factory ChatAttachmentRecord.fromMap(Map<String, dynamic> map) {
    dynamic pick(List<String> keys) {
      for (final k in keys) {
        if (map.containsKey(k)) return map[k];
      }
      return null;
    }

    return ChatAttachmentRecord(
      id: _trimOrNull(pick(const ['id'])),
      messageId: _trimOr(pick(const ['message_id', 'messageId']), ''),
      bucket: _trimOr(pick(const ['bucket']), 'chat-attachments'),
      path: _trimOr(pick(const ['path']), ''),
      mimeType: _trimOr(pick(const ['mime_type', 'mimeType']), ''),
      sizeBytes: _toInt(pick(const ['size_bytes', 'sizeBytes']), fallback: 0),
      width: _toIntOrNull(pick(const ['width'])),
      height: _toIntOrNull(pick(const ['height'])),
      createdAt:
          t.parseDateFlexibleUtc(pick(const ['created_at', 'createdAt'])),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'messageId': messageId,
        'bucket': bucket,
        'path': path,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'width': width,
        'height': height,
        'createdAt': t.toIsoUtc(createdAt),
      };

  /// خريطة إدراج لسيرفر (snake_case)
  Map<String, dynamic> toRemoteInsertMap() => {
        if (id != null) 'id': id,
        'message_id': messageId,
        'bucket': bucket,
        'path': path,
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (createdAt != null) 'created_at': t.toIsoUtc(createdAt),
      };

  /// خريطة تحديث لسيرفر (snake_case)
  Map<String, dynamic> toRemoteUpdateMap() => {
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };

  ChatAttachmentRecord copyWith({
    String? id,
    String? messageId,
    String? bucket,
    String? path,
    String? mimeType,
    int? sizeBytes,
    int? width,
    int? height,
    DateTime? createdAt,
  }) {
    return ChatAttachmentRecord(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      bucket: bucket ?? this.bucket,
      path: path ?? this.path,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      width: width ?? this.width,
      height: height ?? this.height,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  // ملائمة لعرض اسم/امتداد الملف
  String get fileName {
    final norm = path.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return (i >= 0 && i < norm.length - 1) ? norm.substring(i + 1) : norm;
  }

  String get fileExt {
    final f = fileName;
    final i = f.lastIndexOf('.');
    return (i >= 0 && i < f.length - 1) ? f.substring(i + 1) : '';
  }

  bool get isImage => mimeType.toLowerCase().startsWith('image/');
  bool get isVideo => mimeType.toLowerCase().startsWith('video/');
  bool get isAudio => mimeType.toLowerCase().startsWith('audio/');
  bool get isPdf => mimeType.toLowerCase() == 'application/pdf';

  double? get aspectRatio {
    if ((width ?? 0) <= 0 || (height ?? 0) <= 0) return null;
    return width! / height!;
  }

  @override
  String toString() =>
      'ChatAttachmentRecord(id=$id, msg=$messageId, path=$path, mime=$mimeType, size=$sizeBytes, w=$width, h=$height)';
}
