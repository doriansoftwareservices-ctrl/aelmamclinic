// lib/models/chat_message.dart
//
// غلاف توافق (shim) لتوحيد نماذج الدردشة.
// يصدّر الأنواع من chat_models.dart ويضيف امتدادات توافقية
// لتجنّب التعارض بين تعريفين مختلفين لـ ChatMessage في المشروع.
//
// الهدف: إزالة ازدواجية النماذج وإيقاف أخطاء النوع (type mismatch).
// كل المنطق الحقيقي موجود في lib/models/chat_models.dart.

library chat_message_model;

// مهم: نجلب الأنواع إلى المجال المحلي للاستخدام داخل الامتدادات.
import 'chat_models.dart';

export 'chat_models.dart'
    show
        // الرسائل والمرفقات
        ChatMessage,
        ChatMessageKind,
        ChatMessageKindX,
        ChatMessageStatus,
        ChatMessageStatusX,
        ChatAttachment,
        ChatAttachmentType,
        ChatAttachmentTypeX,
        // المحادثات ونوعها + عنصر القائمة
        ChatConversation,
        ChatConversationType,
        ChatConversationTypeX,
        ConversationListItem,
        // كيانات إضافية شائعة
        ChatParticipant,
        ChatReadState;

// توافق قديم: اسم الحالة القديم كان ChatDeliveryStatus.
// نخليه alias لـ ChatMessageStatus حتى يشتغل أي كود قديم بدون تعديل.
typedef ChatDeliveryStatus = ChatMessageStatus;

/// امتدادات توافقية تضيف خصائص كانت متوقعة في الكود القديم.
extension ChatMessageCompatX on ChatMessage {
  bool get isText => kind == ChatMessageKind.text;
  bool get isImage => kind == ChatMessageKind.image;

  // دعم واجهة قديمة:
  bool get isFile =>
      kind == ChatMessageKind.file; // كان false دائمًا، صححناه حسب النوع
  bool get isSystem => false; // لا يوجد نوع system لدينا

  /// أول مرفق صورة (إن وُجد) وإلا نرجع عنصرًا افتراضيًا.
  ChatAttachment get firstImageAttachment => attachments.firstWhere(
        (a) => a.isImage,
        orElse: () => const ChatAttachment.empty(),
      );

  /// هل توجد صورة قابلة للعرض داخل الفقاعة؟
  bool get hasDisplayableImage => attachments.any((a) => a.isImage) || isImage;

// ملاحظة: لا نعرّف imageUrl هنا لأن ChatMessage يوفّرها أصلًا.
}
