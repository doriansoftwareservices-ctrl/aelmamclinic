// lib/models/chat_conversation.dart
//
// Shim لإزالة ازدواجية التعريفات.
// يصدّر ChatConversation و ChatConversationType من المصدر الموحّد chat_models.dart
// إن احتجت سجل قاعدة البيانات فاستعمل: lib/models/chat_conversation_record.dart

library chat_conversation_model;

export 'chat_models.dart' show ChatConversation, ChatConversationType;
