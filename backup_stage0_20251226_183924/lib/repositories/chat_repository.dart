// lib/repositories/chat_repository.dart
//
// ChatRepository
// طبقة وسيطة (Repository) تبسّط استهلاك ChatService من الشاشات/المزوّدات.
// - توفّر دوال high-level للعمل اليومي (قائمة المحادثات، الرسائل، الإرسال، البحث..).
// - ستريم لقائمة المحادثات (polling خفيف افتراضيًا).
// - تمهيد لميزات واتساب (تعديل/حذف/منشن/رد/مرفقات/تفاعلات/يكتب...).

import 'dart:async';
import 'dart:io';

import 'package:aelmamclinic/models/chat_models.dart'
    show ChatConversation, ChatMessage, ConversationListItem;
import 'package:aelmamclinic/models/chat_reaction.dart'; // نوع التفاعلات
import 'package:aelmamclinic/services/chat_service.dart' as chat_svc;

class ChatRepository {
  ChatRepository._();
  static final ChatRepository instance = ChatRepository._();

  final chat_svc.ChatService _svc = chat_svc.ChatService.instance;

  // -----------------------------------------------------------------------------
  // محادثاتي (قائمة)
  // -----------------------------------------------------------------------------
  Future<List<ConversationListItem>> getConversationsOverview() {
    return _svc.fetchMyConversationsOverview();
  }

  Stream<List<ConversationListItem>> watchConversationsOverview({
    Duration interval = const Duration(seconds: 2),
    bool emitCacheOnListen = true,
  }) {
    late final StreamController<List<ConversationListItem>> controller;
    Timer? timer;
    bool disposed = false;

    bool inFlight = false;
    bool pending = false;

    List<ConversationListItem>? lastEmitted;

    Future<void> _tick() async {
      if (disposed) return;
      if (inFlight) {
        pending = true;
        return;
      }
      inFlight = true;
      try {
        final list = await _svc.fetchMyConversationsOverview();
        lastEmitted = list;
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        inFlight = false;
        if (pending && !disposed) {
          pending = false;
          _tick();
        }
      }
    }

    void _start() {
      if (disposed) return;
      if (emitCacheOnListen && lastEmitted != null && !controller.isClosed) {
        scheduleMicrotask(() {
          if (!controller.isClosed && lastEmitted != null) {
            controller.add(List<ConversationListItem>.from(lastEmitted!));
          }
        });
      }
      _tick();
      if (interval.inMilliseconds > 0) {
        timer = Timer.periodic(interval, (_) => _tick());
      }
    }

    Future<void> _stop() async {
      disposed = true;
      timer?.cancel();
      timer = null;
      if (!controller.isClosed) {
        await controller.close();
      }
    }

    controller = StreamController<List<ConversationListItem>>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );

    return controller.stream;
  }

  // -----------------------------------------------------------------------------
  // إنشاء محادثات
  // -----------------------------------------------------------------------------
  Future<ChatConversation> startDM(String email) =>
      _svc.startDMWithEmail(email);

  Future<ChatConversation> createGroup({
    required String title,
    required List<String> memberEmails,
  }) =>
      _svc.createGroup(title: title, memberEmails: memberEmails);

  // -----------------------------------------------------------------------------
  // الرسائل
  // -----------------------------------------------------------------------------
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 40,
  }) =>
      _svc.fetchMessages(conversationId: conversationId, limit: limit);

  Future<List<ChatMessage>> getOlderMessages({
    required String conversationId,
    required DateTime beforeCreatedAt,
    int limit = 40,
  }) =>
      _svc.fetchOlderMessages(
        conversationId: conversationId,
        beforeCreatedAt: beforeCreatedAt,
        limit: limit,
      );

  Stream<List<ChatMessage>> watchMessages(String conversationId) =>
      _svc.watchMessages(conversationId);

  Future<ChatMessage> sendText({
    required String conversationId,
    required String body,
    int? localSeq,
    String? replyToMessageId,
    List<String>? mentionsEmails,
  }) =>
      _svc.sendText(
        conversationId: conversationId,
        body: body,
        localSeq: localSeq,
        replyToMessageId: replyToMessageId,
        mentionsEmails: mentionsEmails,
      );

  Future<List<ChatMessage>> sendImages({
    required String conversationId,
    required List<File> files,
    String? optionalText,
    int? localSeq,
    String? replyToMessageId,
    List<String>? mentionsEmails,
  }) =>
      _svc.sendImages(
        conversationId: conversationId,
        files: files,
        optionalText: optionalText,
        localSeq: localSeq,
        replyToMessageId: replyToMessageId,
        mentionsEmails: mentionsEmails,
      );

  Future<void> editMessage({
    required String messageId,
    required String newBody,
  }) =>
      _svc.editMessage(messageId: messageId, newBody: newBody);

  Future<void> deleteMessage(String messageId) => _svc.deleteMessage(messageId);

  Future<void> deleteMessageAttachments(String messageId) =>
      _svc.deleteMessageAttachments(messageId);

  Future<DateTime?> markReadUpToLatest(String conversationId) =>
      _svc.markReadUpToLatest(conversationId);

  Future<DateTime?> markConversationRead(String conversationId) =>
      _svc.markReadUpToLatest(conversationId);

  Future<List<ChatMessage>> searchMessages({
    required String conversationId,
    required String query,
    int limit = 100,
  }) =>
      _svc.searchMessages(
        conversationId: conversationId,
        query: query,
        limit: limit,
      );

  // -----------------------------------------------------------------------------
  // Typing (يكتب...)
  // -----------------------------------------------------------------------------
  Stream<Map<String, dynamic>> typingStream(String conversationId) =>
      _svc.typingStream(conversationId);

  Future<void> pingTyping(String conversationId, {required bool typing}) =>
      _svc.pingTyping(conversationId, typing: typing);

  // -----------------------------------------------------------------------------
  // Reactions
  // -----------------------------------------------------------------------------
  Future<List<ChatReaction>> getReactions(String messageId) =>
      _svc.getReactions(messageId);

  Future<void> addReaction({
    required String messageId,
    required String emoji,
  }) =>
      _svc.addReaction(messageId: messageId, emoji: emoji);

  Future<void> removeReaction({
    required String messageId,
    required String emoji,
  }) =>
      _svc.removeReaction(messageId: messageId, emoji: emoji);

  Future<void> toggleReaction({
    required String messageId,
    required String emoji,
  }) =>
      _svc.toggleReaction(messageId: messageId, emoji: emoji);

  Stream<List<ChatReaction>> watchReactions(String messageId) =>
      _svc.watchReactions(messageId);
}
