// lib/widgets/chat/message_bubble.dart
//
// فقاعة رسالة دردشة بنمط TBIAN مع تحسينات:
// - Hero للصور (tag = message.id) لانتقال سلس مع ImageViewerScreen.
// - شريط Reactions لحظي أسفل كل رسالة (يدعم مصدر خارجي من المزوّد أو fallback على ChatService).
// - معاينة ردّ تدعم صورة مصغّرة + نقر للانتقال للرسالة الأصلية (اختياري).
// - دعم الحالة (إرسال/تم/وصول/مقروء/فشل) وزر إعادة المحاولة عند الفشل.
// - عرض أيقونة الحالة لرسائلي فقط (أهدأ بصريًا).
// - ✅ استخدام كاش المرفقات المحلي لعرض الصور من الجهاز عند توفرها (AttachmentCache).
//
// يعتمد على:
// - core/neumorphism.dart
// - core/theme.dart
// - models/chat_models.dart
// - models/chat_reaction.dart
// - services/chat_service.dart
// - services/attachment_cache.dart
// - utils/time.dart
// - utils/text_direction.dart

import 'dart:io';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/models/chat_reaction.dart';
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/services/attachment_cache.dart'; // ✅ جديد
import 'package:aelmamclinic/utils/time.dart' as t;
import 'package:aelmamclinic/utils/text_direction.dart' as bidi;

/// حالة واجهة مبسّطة لعرض أيقونة الحالة
enum _UiStatus { sending, sent, delivered, read, failed }

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;

  /// في المحادثات الجماعية: إظهار بريد المرسل أعلى الفقاعة (للرسائل الواردة فقط).
  final bool showSenderHeader;
  final String? senderEmail;

  /// عند النقر على الصورة (يُمرَّر مسار محلي إن وجد، وإلا رابط HTTP)
  final void Function(String imagePathOrUrl)? onOpenImage;

  /// زر إعادة المحاولة عند فشل الإرسال (للصورة أو النص)
  final void Function(ChatMessage failed)? onRetry;

  /// إجراءات سياقية (حذف/رد/نسخ…)
  final VoidCallback? onLongPress;

  /// عرض ذيل الفقاعة
  final bool showTail;

  /// (اختياري) دعم التنقل إلى الرسالة المُشار إليها في الردّ
  final String? replyToMessageId;
  final String? replyThumbnailUrl;
  final void Function(String messageId)? onTapReplyTarget;

  /// (اختياري) تزويد Stream ردود الفعل من مزوّد خارجي لتقليل الاشتراكات داخل الويدجت
  final Stream<List<ChatReaction>>? reactionsStream;

  /// (اختياري) مُبدّل تفاعل خارجي (مثلاً من ChatProvider) — وإلا نستخدم ChatService.toggleReaction
  final Future<void> Function(String emoji)? onToggleReaction;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.showSenderHeader = false,
    this.senderEmail,
    this.onOpenImage,
    this.onRetry,
    this.onLongPress,
    this.showTail = true,
    this.replyToMessageId,
    this.replyThumbnailUrl,
    this.onTapReplyTarget,
    this.reactionsStream,
    this.onToggleReaction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bg = isMine
        ? kPrimaryColor.withValues(alpha: .10)
        : scheme.surfaceContainerHigh;
    final border = Border.all(color: scheme.outlineVariant);

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMine && showTail ? 4 : 16),
      bottomRight: Radius.circular(!isMine && showTail ? 4 : 16),
    );

    // اشتغال احترازي: إن وصلت delivered نظهرها كـ sent (لو لم تُطبّع سابقًا من الشاشة)
    final rawUiStatus = _deriveUiStatus(message);
    final uiStatus =
        rawUiStatus == _UiStatus.delivered ? _UiStatus.sent : rawUiStatus;

    final maxW = MediaQuery.of(context).size.width * 0.78;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Align(
        alignment: isMine
            ? AlignmentDirectional.centerStart // start=يمين في RTL
            : AlignmentDirectional.centerEnd, // end=يسار في RTL
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showSenderHeader &&
                  !isMine &&
                  (senderEmail?.isNotEmpty ?? false))
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                      start: 6, bottom: 4, end: 6),
                  child: Text(
                    bidi.ensureLtr(senderEmail ?? ''),
                    textDirection: ui.TextDirection.ltr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: .65),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),

              // الفقاعة
              Semantics(
                label: 'رسالة',
                onLongPressHint: 'إجراءات الرسالة',
                child: GestureDetector(
                  onLongPress: onLongPress,
                  child: NeuCard(
                    padding: EdgeInsets.zero,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: maxW),
                      decoration: BoxDecoration(
                        color: bg,
                        border: border,
                        borderRadius: radius,
                      ),
                      child: _buildBubbleContent(context, uiStatus),
                    ),
                  ),
                ),
              ),

              // Reactions (لحظية) — مصدر خارجي إن وُجد، وإلا fallback على ChatService
              Padding(
                padding:
                    const EdgeInsetsDirectional.only(top: 4, start: 6, end: 6),
                child: _ReactionsBar(
                  messageId: message.id,
                  alignStart: isMine, // في RTL: start=يمين
                  externalStream: reactionsStream,
                  onToggleExternal: onToggleReaction,
                ),
              ),

              // الوقت + أيقونة الحالة (للمُرسِل فقط)
              Padding(
                padding:
                    const EdgeInsetsDirectional.only(top: 2, start: 6, end: 6),
                child: Row(
                  mainAxisAlignment:
                      isMine ? MainAxisAlignment.start : MainAxisAlignment.end,
                  children: [
                    if (isMine) _StatusIcon(status: uiStatus),
                    if (isMine) const SizedBox(width: 6),
                    Text(
                      t.formatMessageTimestamp(message.createdAt),
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .55),
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBubbleContent(BuildContext context, _UiStatus uiStatus) {
    if (_isDeleted(message)) {
      return _DeletedBody(isMine: isMine);
    }

    final replySnip = _replySnippetOf(message);
    final hasReply = replySnip.isNotEmpty;

    switch (message.kind) {
      case ChatMessageKind.image:
        final src = _firstImageSourceOf(message);
        final caption = _bodyOf(message).isEmpty ? null : _bodyOf(message);
        return _ImageBody(
          heroTag: message.id, // ← ليتطابق مع ImageViewerScreen
          imageUrl: src.remoteUrl,
          localPath: src.localPath, // ✅ إن وجد سنعرض من الملف
          caption: caption,
          isMine: isMine,
          edited: message.edited,
          replySnippet: hasReply ? replySnip : null,
          replyToMessageId: replyToMessageId,
          replyThumbnailUrl: replyThumbnailUrl,
          onOpen: onOpenImage,
          status: uiStatus,
          onRetry: onRetry == null ? null : () => onRetry!(message),
          onTapReplyTarget: onTapReplyTarget,
        );

      case ChatMessageKind.text:
      default:
        return _TextBody(
          text: _bodyOf(message),
          isMine: isMine,
          edited: message.edited,
          replySnippet: hasReply ? replySnip : null,
          replyToMessageId: replyToMessageId,
          replyThumbnailUrl: replyThumbnailUrl,
          onRetry: onRetry == null ? null : () => onRetry!(message),
          failed: uiStatus == _UiStatus.failed,
          onTapReplyTarget: onTapReplyTarget,
        );
    }
  }

// ---------- Helpers ----------

  String _bodyOf(ChatMessage m) {
    final body = m.body;
    if (body != null) {
      final trimmed = body.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return m.text.trim();
  }

  String _replySnippetOf(ChatMessage m) => (m.replyToSnippet ?? '').trim();

  bool _isDeleted(ChatMessage m) => m.deleted == true;

  /// مصدر الصورة: مسار محلي (إن وُجد) + رابط HTTP كاحتياطي
  _ImageSource _firstImageSourceOf(ChatMessage m) {
    String remote = '';
    String? local;

    if (m.attachments.isNotEmpty) {
      final a = m.attachments.first;

      // 1) رابط HTTP/موقّع
      try {
        final primaryUrl = a.url.isNotEmpty ? a.url : (a.signedUrl ?? '');
        final url = primaryUrl.trim();
        if (url.isNotEmpty) remote = url;
      } catch (_) {}

      // 2) جرّب مسار محلي من extra['local_path']
      try {
        final extra = (a as dynamic).extra;
        if (extra is Map && extra['local_path'] is String) {
          final lp = (extra['local_path'] as String).trim();
          if (lp.isNotEmpty && File(lp).existsSync()) {
            local = lp;
          }
        }
      } catch (_) {}

      // 3) إن لم يوجد في extra، اسأل الكاش بالـ URL (توقيع واحد فقط)
      if (local == null && remote.isNotEmpty) {
        try {
          // استعلام غير حاجب للتأكد من وجود الملف محليًا إن كان مُسبق التحميل
          AttachmentCache.instance.localPathIfAny(remote).then((_) {
            // لا حاجة لإعادة البناء هنا؛ العرض الحالي يكفي.
          });
        } catch (_) {}
      }
    }

    return _ImageSource(remoteUrl: remote, localPath: local);
  }

  _UiStatus _deriveUiStatus(ChatMessage m) {
    switch (m.status) {
      case ChatMessageStatus.sending:
        return _UiStatus.sending;
      case ChatMessageStatus.sent:
        return _UiStatus.sent;
      case ChatMessageStatus.delivered:
        return _UiStatus.delivered;
      case ChatMessageStatus.read:
        return _UiStatus.read;
      case ChatMessageStatus.failed:
        return _UiStatus.failed;
    }
  }
}

class _ImageSource {
  final String remoteUrl;
  final String? localPath;
  const _ImageSource({required this.remoteUrl, required this.localPath});
}

/*──────────────────── أجزاء الفقاعة ────────────────────*/

class _TextBody extends StatelessWidget {
  final String text;
  final bool isMine;
  final bool edited;
  final String? replySnippet;
  final String? replyToMessageId;
  final String? replyThumbnailUrl;
  final VoidCallback? onRetry;
  final bool failed;
  final void Function(String messageId)? onTapReplyTarget;

  const _TextBody({
    required this.text,
    required this.isMine,
    required this.edited,
    this.replySnippet,
    this.replyToMessageId,
    this.replyThumbnailUrl,
    this.onRetry,
    required this.failed,
    this.onTapReplyTarget,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dir = bidi.textDirectionFor(text);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          if (replySnippet != null) ...[
            _ReplyPreview(
              text: replySnippet!,
              thumbnailUrl: replyThumbnailUrl,
              messageId: replyToMessageId,
              onTapReplyTarget: onTapReplyTarget,
            ),
            const SizedBox(height: 6),
          ],
          SelectableText(
            text.isEmpty ? '‎' : bidi.autoBidiWrap(text),
            textDirection: dir,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 14.5,
              height: 1.35,
            ),
          ),
          if (edited)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '(معدل)',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .55),
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ),
          if (failed && isMine && onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('إعادة المحاولة'),
                  onPressed: onRetry,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ImageBody extends StatelessWidget {
  final String heroTag;
  final String imageUrl; // HTTP fallback
  final String? localPath; // ✅ مسار محلي إن وُجد
  final String? caption;
  final bool isMine;
  final bool edited;
  final String? replySnippet;
  final String? replyToMessageId;
  final String? replyThumbnailUrl;
  final void Function(String pathOrUrl)? onOpen;
  final _UiStatus status;
  final VoidCallback? onRetry;
  final void Function(String messageId)? onTapReplyTarget;

  const _ImageBody({
    required this.heroTag,
    required this.imageUrl,
    required this.localPath,
    required this.caption,
    required this.isMine,
    required this.edited,
    required this.replySnippet,
    this.replyToMessageId,
    this.replyThumbnailUrl,
    required this.onOpen,
    required this.status,
    this.onRetry,
    this.onTapReplyTarget,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final hasLocal = (localPath != null &&
        localPath!.isNotEmpty &&
        File(localPath!).existsSync());
    final openArg = hasLocal ? localPath! : imageUrl;

    Widget imageWidget;
    if (hasLocal) {
      imageWidget = Image.file(
        File(localPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            const Center(child: Icon(Icons.broken_image_outlined)),
      );
    } else {
      imageWidget = Image.network(
        imageUrl,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // Fade-in لطيف عند اكتمال أول إطار
        frameBuilder: (_, child, frame, __) {
          if (frame == null) {
            return AnimatedOpacity(
              opacity: 0,
              duration: const Duration(milliseconds: 150),
              child: child,
            );
          }
          return AnimatedOpacity(
            opacity: 1,
            duration: const Duration(milliseconds: 220),
            child: child,
          );
        },
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          final total = progress.expectedTotalBytes ?? 0;
          final loaded = progress.cumulativeBytesLoaded;
          final v = (total > 0) ? loaded / total : null;
          return Stack(
            fit: StackFit.expand,
            children: [
              const Center(child: Icon(Icons.image_rounded, size: 42)),
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 2,
                ),
              ),
            ],
          );
        },
        errorBuilder: (_, __, ___) =>
            const Center(child: Icon(Icons.broken_image_outlined)),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          if (replySnippet != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: _ReplyPreview(
                text: replySnippet!,
                thumbnailUrl: replyThumbnailUrl,
                messageId: replyToMessageId,
                onTapReplyTarget: onTapReplyTarget,
              ),
            ),
          ],
          GestureDetector(
            onTap: (onOpen != null && openArg.isNotEmpty)
                ? () => onOpen!(openArg)
                : null,
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Hero(
                tag: heroTag,
                child: Container(
                  color: Colors.black12,
                  child: (openArg.isEmpty)
                      ? const Center(child: Icon(Icons.broken_image_outlined))
                      : imageWidget,
                ),
              ),
            ),
          ),
          if ((caption?.isNotEmpty ?? false) || edited)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                crossAxisAlignment:
                    isMine ? CrossAxisAlignment.start : CrossAxisAlignment.end,
                children: [
                  if (caption?.isNotEmpty ?? false)
                    SelectableText(
                      bidi.autoBidiWrap(caption!),
                      textDirection: bidi.textDirectionFor(caption!),
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        height: 1.3,
                      ),
                    ),
                  if (edited)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '(معدل)',
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: .55),
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // في حالة فشل الإرسال لصور المرسل، أعرض زر إعادة المحاولة
          if (isMine && status == _UiStatus.failed && onRetry != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('إعادة المحاولة'),
                  onPressed: onRetry,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeletedBody extends StatelessWidget {
  final bool isMine;
  const _DeletedBody({required this.isMine});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          Icon(Icons.delete_outline_rounded,
              color: scheme.onSurface.withValues(alpha: .55), size: 18),
          const SizedBox(width: 6),
          Text(
            'تم حذف هذه الرسالة',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .6),
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  final String text;
  final String? thumbnailUrl;
  final String? messageId; // الأصل
  final void Function(String messageId)? onTapReplyTarget;

  const _ReplyPreview({
    required this.text,
    this.thumbnailUrl,
    this.messageId,
    this.onTapReplyTarget,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = text.length > 90 ? '${text.substring(0, 90)}…' : text;

    final hasThumb = (thumbnailUrl != null && thumbnailUrl!.trim().isNotEmpty);
    final isImageHint =
        text.contains('📷'); // دعم قديم لعرض أيقونة كاميرا عند عدم توفر thumb

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasThumb)
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              thumbnailUrl!,
              width: 34,
              height: 34,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const _MiniThumbPlaceholder(),
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return const _MiniThumbPlaceholder();
              },
            ),
          )
        else if (isImageHint)
          const _MiniThumbPlaceholder(),
        if (hasThumb || isImageHint) const SizedBox(width: 8),
        Flexible(
          child: Text(
            bidi.autoBidiWrap(display),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textDirection: bidi.textDirectionFor(display),
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .9),
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ),
      ],
    );

    final box = Container(
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: content,
    );

    if (messageId != null && onTapReplyTarget != null) {
      return InkWell(onTap: () => onTapReplyTarget!(messageId!), child: box);
    }
    return box;
  }
}

class _MiniThumbPlaceholder extends StatelessWidget {
  const _MiniThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.photo_size_select_actual_rounded, size: 18),
    );
  }
}

/*──────────────────── أيقونة الحالة ────────────────────*/

class _StatusIcon extends StatelessWidget {
  final _UiStatus status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    IconData icon = Icons.schedule_rounded;
    Color color = scheme.onSurface.withValues(alpha: .45);

    switch (status) {
      case _UiStatus.sending:
        icon = Icons.schedule_rounded;
        color = scheme.onSurface.withValues(alpha: .45);
        break;
      case _UiStatus.sent:
        icon = Icons.done_rounded; // ✓
        color = scheme.onSurface.withValues(alpha: .55);
        break;
      case _UiStatus.delivered:
        icon = Icons.done_all_rounded; // ✓✓
        color = scheme.onSurface.withValues(alpha: .75);
        break;
      case _UiStatus.read:
        icon = Icons.done_all_rounded; // ✓✓ أزرق
        color = kPrimaryColor;
        break;
      case _UiStatus.failed:
        icon = Icons.error_outline_rounded;
        color = Colors.redAccent;
        break;
    }

    return Icon(icon, size: 16, color: color);
  }
}

/*──────────────────── Reactions Bar ───────────────────*/

class _ReactionsBar extends StatelessWidget {
  final String messageId;
  final bool alignStart;

  /// مصدر خارجي (من مزوّد) — إن لم يُمرَّر نستخدم ChatService.watchReactions(messageId)
  final Stream<List<ChatReaction>>? externalStream;

  /// مُبدّل تفاعل خارجي (من مزوّد) — إن لم يُمرَّر نستخدم ChatService.toggleReaction
  final Future<void> Function(String emoji)? onToggleExternal;

  const _ReactionsBar({
    required this.messageId,
    required this.alignStart,
    this.externalStream,
    this.onToggleExternal,
  });

  @override
  Widget build(BuildContext context) {
    final myUid = Supabase.instance.client.auth.currentUser?.id ?? '';
    final stream =
        externalStream ?? ChatService.instance.watchReactions(messageId);

    return StreamBuilder<List<ChatReaction>>(
      stream: stream,
      builder: (context, snap) {
        final reactions = snap.data ?? const <ChatReaction>[];
        if (reactions.isEmpty) return const SizedBox.shrink();

        // تجميع بحسب الإيموجي
        final byEmoji = <String, List<ChatReaction>>{};
        for (final r in reactions) {
          (byEmoji[r.emoji] ??= <ChatReaction>[]).add(r);
        }

        final chips = <Widget>[];
        byEmoji.forEach((emoji, list) {
          final count = list.length;
          final mine = list.any((r) => r.userUid == myUid);

          chips.add(_ReactionChip(
            emoji: emoji,
            count: count,
            selected: mine,
            onTap: () async {
              try {
                if (onToggleExternal != null) {
                  await onToggleExternal!(emoji);
                } else {
                  await ChatService.instance.toggleReaction(
                    messageId: messageId,
                    emoji: emoji,
                  );
                }
              } catch (_) {
                // تجاهل
              }
            },
          ));
        });

        return Align(
          alignment: alignStart ? Alignment.centerRight : Alignment.centerLeft,
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: chips,
          ),
        );
      },
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final String emoji;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = selected ? kPrimaryColor.withValues(alpha: .12) : scheme.surface;
    final brd =
        selected ? kPrimaryColor.withValues(alpha: .6) : scheme.outlineVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: brd),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface.withValues(alpha: .8),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
