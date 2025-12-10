// lib/models/chat_attachment.dart
//
// محوِّلات بين:
//   - ChatAttachmentRecord (سجل DB) ←→ ChatAttachment (نموذج واجهة داخل chat_models.dart)
//
// ملاحظة هامة:
// هذا الملف لا يعرّف فئة باسم ChatAttachment لتفادي التعارض مع
// ChatAttachment الموجودة في lib/models/chat_models.dart.

import 'chat_attachment_record.dart';
import 'chat_models.dart' show ChatAttachment, ChatAttachmentType;

/// تحويل سجل DB إلى نموذج واجهة.
/// - إن لم يتوفر url مباشر، نضع Placeholder "storage://bucket/path"
///   ويمكن لاحقًا استبداله برابط موقّع.
extension ChatAttachmentRecordX on ChatAttachmentRecord {
  ChatAttachment toUiAttachment(
      {String? signedUrl, Map<String, dynamic>? extra}) {
    // تحديد النوع من المايم تايب
    final type = mimeType.toLowerCase().startsWith('image/')
        ? ChatAttachmentType.image
        : ChatAttachmentType.file;

    final placeholderUrl = 'storage://$bucket/$path';

    return ChatAttachment(
      id: id,
      type: type,
      url: signedUrl ?? placeholderUrl,
      bucket: bucket,
      path: path,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      width: width,
      height: height,
      createdAt: createdAt,
      signedUrl: signedUrl,
      extra: extra,
    );
  }
}

/// تحويل نموذج واجهة إلى سجل DB.
/// - يتطلب messageId لأنه عمود أساسي في جدول المرفقات.
extension ChatAttachmentUiX on ChatAttachment {
  ChatAttachmentRecord toRecord({required String messageId}) {
    // إن لم توجد قيم، نضع افتراضيات مناسبة
    final String bucketVal = (bucket ?? 'chat-attachments');
    final String pathVal = (path ?? '');

    final String mime =
        (mimeType ?? (isImage ? 'image/jpeg' : 'application/octet-stream'));

    final int size = (sizeBytes ?? 0);

    return ChatAttachmentRecord(
      id: id,
      messageId: messageId,
      bucket: bucketVal,
      path: pathVal,
      mimeType: mime,
      sizeBytes: size,
      width: width,
      height: height,
      createdAt: createdAt,
    );
  }
}
