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
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';

import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/models/chat_reaction.dart';
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/services/attachment_cache.dart'; // ✅ جديد
import 'package:aelmamclinic/services/nhost_storage_service.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/text_direction.dart' as bidi;

/// حالة واجهة مبسّطة لعرض أيقونة الحالة
enum _UiStatus { sending, sent, delivered, read, failed }

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  final bool isOnline;
  final bool allowRemoteAttachmentDownload;

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
    this.isOnline = true,
    this.allowRemoteAttachmentDownload = true,
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

    final bg = isMine ? const Color(0xFF0185F6) : Colors.white;
    final border = Border.all(color: Colors.black.withValues(alpha: .06));

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMine && showTail ? 4 : 16),
      bottomRight: Radius.circular(!isMine && showTail ? 4 : 16),
    );

    final uiStatus = _deriveUiStatus(message);

    final screenW = MediaQuery.of(context).size.width;
    final maxW = screenW >= 900 ? screenW * 0.55 : screenW * 0.70;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Align(
        alignment:
            isMine ? Alignment.centerLeft : Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
                  child: IntrinsicWidth(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxW),
                      child: Container(
                        decoration: BoxDecoration(
                          color: bg,
                          border: border,
                          borderRadius: radius,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .06),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildBubbleContent(context, uiStatus),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                          child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Directionality(
                                  textDirection: ui.TextDirection.ltr,
                                  child: Text(
                                    DateFormat('HH:mm')
                                        .format(message.createdAt.toLocal()),
                                    style: TextStyle(
                                      color: (isMine
                                              ? Colors.white
                                              : scheme.onSurface)
                                          .withValues(alpha: .65),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 10.5,
                                    ),
                                  ),
                                ),
                                if (isMine) ...[
                                  const SizedBox(width: 6),
                                  _StatusIcon(
                                    status: uiStatus,
                                    isOnline: isOnline,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                          ],
                        ),
                      ),
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
                  alignStart: !isMine, // في RTL: start=يمين
                  externalStream: reactionsStream,
                  onToggleExternal: onToggleReaction,
                ),
              ),

              // الوقت + أيقونة الحالة (للمُرسِل فقط)
              const SizedBox.shrink(),
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

    if (!AppConstants.chatAllowAttachments &&
        (message.kind == ChatMessageKind.image ||
            message.kind == ChatMessageKind.file)) {
      return _TextBody(
        text: 'المرفقات معطّلة في هذا الإصدار.',
        isMine: isMine,
        edited: message.edited,
        replySnippet: hasReply ? replySnip : null,
        replyToMessageId: replyToMessageId,
        replyThumbnailUrl: replyThumbnailUrl,
        allowRemoteDownload: allowRemoteAttachmentDownload,
        onRetry: onRetry == null ? null : () => onRetry!(message),
        failed: uiStatus == _UiStatus.failed,
        onTapReplyTarget: onTapReplyTarget,
      );
    }

    switch (message.kind) {
      case ChatMessageKind.image:
        final src = _firstImageSourceOf(message);
        final caption = _bodyOf(message).isEmpty ? null : _bodyOf(message);
        final firstAtt =
            message.attachments.isNotEmpty ? message.attachments.first : null;
        return _ImageBody(
          heroTag: message.id, // ← ليتطابق مع ImageViewerScreen
          imageUrl: src.remoteUrl,
          localPath: src.localPath, // ✅ إن وجد سنعرض من الملف
          bucket: firstAtt?.bucket,
          path: firstAtt?.path,
          fileId: _attachmentFileId(firstAtt),
          caption: caption,
          isMine: isMine,
          edited: message.edited,
          allowRemoteDownload: allowRemoteAttachmentDownload,
          replySnippet: hasReply ? replySnip : null,
          replyToMessageId: replyToMessageId,
          replyThumbnailUrl: replyThumbnailUrl,
          onOpen: onOpenImage,
          status: uiStatus,
          onRetry: onRetry == null ? null : () => onRetry!(message),
          onTapReplyTarget: onTapReplyTarget,
        );

      case ChatMessageKind.file:
        final caption = _bodyOf(message);
        final firstAtt =
            message.attachments.isNotEmpty ? message.attachments.first : null;
        return _FileBody(
          attachment: firstAtt,
          caption: caption,
          isMine: isMine,
          edited: message.edited,
          allowRemoteDownload: allowRemoteAttachmentDownload,
          replySnippet: hasReply ? replySnip : null,
          replyToMessageId: replyToMessageId,
          replyThumbnailUrl: replyThumbnailUrl,
          onTapReplyTarget: onTapReplyTarget,
          onRetry: onRetry == null ? null : () => onRetry!(message),
          status: uiStatus,
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
          allowRemoteDownload: allowRemoteAttachmentDownload,
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

      // 1) رابط HTTP/موقّع إن وُجد (نفضّله لتجنّب مشاكل صلاحيات الملفات)
      try {
        final primaryUrl = a.url.isNotEmpty ? a.url : (a.signedUrl ?? '');
        final url = primaryUrl.trim();
        if (url.isNotEmpty && url.startsWith('http')) {
          remote = url;
        }
      } catch (_) {}

      // 2) إن لم نجد رابطًا صالحًا، جرّب bucket/path
      if (remote.isEmpty) {
        final b = (a.bucket ?? '').trim();
        final p = (a.path ?? '').trim();
        if (b.isNotEmpty && p.isNotEmpty) {
          remote = 'storage://$b/$p';
        } else {
          // 3) fallback: أي رابط غير فارغ حتى لو لم يبدأ بـ http
          try {
            final primaryUrl = a.url.isNotEmpty ? a.url : (a.signedUrl ?? '');
            final url = primaryUrl.trim();
            if (url.isNotEmpty) remote = url;
          } catch (_) {}
        }
      }

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

      // 2.5) إن كان path يشير لملف محلي صالح
      if (local == null) {
        try {
          final p = (a.path ?? '').trim();
          if (p.isNotEmpty && File(p).existsSync()) {
            local = p;
          }
        } catch (_) {}
      }

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

  String? _attachmentFileId(ChatAttachment? att) {
    if (att == null) return null;
    final extra = att.extra;
    final map = extra is Map
        ? Map<String, dynamic>.from(extra as Map)
        : const <String, dynamic>{};
    final v1 = map['file_id']?.toString();
    if (v1 != null && v1.trim().isNotEmpty) return v1.trim();
    final v2 = map['fileId']?.toString();
    if (v2 != null && v2.trim().isNotEmpty) return v2.trim();
    return null;
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
  final bool allowRemoteDownload;
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
    required this.allowRemoteDownload,
    this.onRetry,
    required this.failed,
    this.onTapReplyTarget,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dir = bidi.textDirectionFor(text);

    final textColor = isMine ? Colors.white : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: dir == ui.TextDirection.rtl
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (replySnippet != null) ...[
            _ReplyPreview(
              text: replySnippet!,
              thumbnailUrl: replyThumbnailUrl,
              allowRemoteDownload: allowRemoteDownload,
              messageId: replyToMessageId,
              onTapReplyTarget: onTapReplyTarget,
            ),
            const SizedBox(height: 6),
          ],
          SelectableText(
            text.isEmpty ? '‎' : bidi.autoBidiWrap(text),
            textDirection: dir,
            textAlign: dir == ui.TextDirection.rtl
                ? TextAlign.right
                : TextAlign.left,
            style: TextStyle(
              color: textColor,
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
                  color: (isMine ? Colors.white : scheme.onSurface)
                      .withValues(alpha: .65),
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
  final String? bucket;
  final String? path;
  final String? fileId;
  final String? caption;
  final bool isMine;
  final bool edited;
  final bool allowRemoteDownload;
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
    required this.bucket,
    required this.path,
    required this.fileId,
    required this.caption,
    required this.isMine,
    required this.edited,
    required this.allowRemoteDownload,
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
    final tapArg = hasLocal ? localPath! : imageUrl;

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
      imageWidget = _ResolvedNetworkImage(
        url: imageUrl,
        bucket: bucket,
        path: path,
        fileId: fileId,
        allowRemoteDownload: allowRemoteDownload,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (replySnippet != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: _ReplyPreview(
                text: replySnippet!,
                thumbnailUrl: replyThumbnailUrl,
                allowRemoteDownload: allowRemoteDownload,
                messageId: replyToMessageId,
                onTapReplyTarget: onTapReplyTarget,
              ),
            ),
          ],
          Builder(
            builder: (context) {
              final screenW = MediaQuery.of(context).size.width;
              final maxWidth = screenW * 0.70;
              const maxHeight = 280.0;
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: maxHeight,
                ),
                child: GestureDetector(
                  onTap: (onOpen != null && tapArg.trim().isNotEmpty)
                      ? () => onOpen!(tapArg)
                      : null,
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Hero(
                      tag: heroTag,
                      child: Container(
                        color: Colors.black12,
                        child: imageWidget,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if ((caption?.isNotEmpty ?? false) || edited)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                crossAxisAlignment:
                    isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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

class _FileBody extends StatefulWidget {
  final ChatAttachment? attachment;
  final String caption;
  final bool isMine;
  final bool edited;
  final bool allowRemoteDownload;
  final String? replySnippet;
  final String? replyToMessageId;
  final String? replyThumbnailUrl;
  final void Function(String messageId)? onTapReplyTarget;
  final VoidCallback? onRetry;
  final _UiStatus status;

  const _FileBody({
    required this.attachment,
    required this.caption,
    required this.isMine,
    required this.edited,
    required this.allowRemoteDownload,
    required this.replySnippet,
    this.replyToMessageId,
    this.replyThumbnailUrl,
    this.onTapReplyTarget,
    this.onRetry,
    required this.status,
  });

  @override
  State<_FileBody> createState() => _FileBodyState();
}

class _FileBodyState extends State<_FileBody> {
  bool _opening = false;
  bool _saving = false;

  String _fileName() {
    final a = widget.attachment;
    final path = (a?.path ?? '').trim();
    if (path.isNotEmpty) return p.basename(path);
    final url = (a?.url ?? '').trim();
    if (url.isNotEmpty) {
      try {
        return p.basename(Uri.parse(url).path);
      } catch (_) {}
    }
    return 'ملف';
  }

  String _prettySize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  IconData _iconForMime(String? mime, String name) {
    final lower = (mime ?? '').toLowerCase();
    final ext = p.extension(name).toLowerCase();
    if (lower.contains('pdf') || ext == '.pdf') return Icons.picture_as_pdf_rounded;
    if (lower.contains('word') || ext == '.doc' || ext == '.docx') {
      return Icons.article_rounded;
    }
    if (lower.contains('excel') || ext == '.xls' || ext == '.xlsx' || ext == '.csv') {
      return Icons.grid_on_rounded;
    }
    if (lower.contains('powerpoint') || ext == '.ppt' || ext == '.pptx') {
      return Icons.slideshow_rounded;
    }
    if (lower.startsWith('image/') || ['.png','.jpg','.jpeg','.gif','.webp'].contains(ext)) {
      return Icons.image_rounded;
    }
    if (lower.startsWith('video/') || ['.mp4','.mov','.avi','.mkv'].contains(ext)) {
      return Icons.movie_rounded;
    }
    if (lower.startsWith('audio/') || ['.mp3','.wav','.m4a'].contains(ext)) {
      return Icons.audiotrack_rounded;
    }
    if (['.zip','.rar','.7z','.tar','.gz'].contains(ext)) {
      return Icons.archive_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  Future<void> _openFile(BuildContext context) async {
    if (_opening) return;
    final a = widget.attachment;
    if (a == null) return;
    final bucket = (a.bucket ?? '').trim();
    final path = (a.path ?? '').trim();
    var url = (a.signedUrl ?? a.url).trim();
    if (bucket.isEmpty || path.isEmpty) {
      final rawUrl = (a.signedUrl ?? a.url).trim();
      if (rawUrl.isEmpty) return;
      if (!widget.allowRemoteDownload) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('الملف لم يكتمل تنزيله بعد')),
          );
        }
        return;
      }
      final local = await AttachmentCache.instance.ensureFileFor(rawUrl);
      if (local == null || local.isEmpty) return;
      await OpenFile.open(local);
      return;
    }

    setState(() => _opening = true);
    try {
      String? local =
          AttachmentCache.instance.localPathSyncIfAny(bucket, path);
      if (local == null || local.isEmpty) {
        if (!widget.allowRemoteDownload) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('الملف لم يكتمل تنزيله بعد')),
            );
          }
          return;
        }
        if (url.isEmpty || url.startsWith('storage://')) {
          url = await NhostStorageService()
                  .resolveSignedUrlForPath(bucket: bucket, path: path) ??
              url;
        }
        local = await AttachmentCache.instance.ensureFileForStorage(
          bucket,
          path,
          url: url,
        );
      }
      if (local == null || local.isEmpty) return;

      // Ensure file has extension for OS open
      final name = _fileName();
      final ext = p.extension(name);
      var openPath = local;
      if (ext.isNotEmpty && !local.toLowerCase().endsWith(ext.toLowerCase())) {
        final tmp = File(p.join(Directory.systemTemp.path, name));
        await tmp.writeAsBytes(await File(local).readAsBytes(), flush: true);
        openPath = tmp.path;
      }
      await OpenFile.open(openPath);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _saveFile(BuildContext context) async {
    if (_saving) return;
    final a = widget.attachment;
    if (a == null) return;
    final bucket = (a.bucket ?? '').trim();
    final path = (a.path ?? '').trim();
    var url = (a.signedUrl ?? a.url).trim();

    setState(() => _saving = true);
    try {
      String? local;
      if (bucket.isNotEmpty && path.isNotEmpty) {
        local = AttachmentCache.instance.localPathSyncIfAny(bucket, path);
        if (local == null || local.isEmpty) {
          if (!widget.allowRemoteDownload) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('الملف لم يكتمل تنزيله بعد')),
              );
            }
            return;
          }
          if (url.isEmpty || url.startsWith('storage://')) {
            url = await NhostStorageService()
                    .resolveSignedUrlForPath(bucket: bucket, path: path) ??
                url;
          }
          local = await AttachmentCache.instance.ensureFileForStorage(
            bucket,
            path,
            url: url,
          );
        }
      } else {
        if (url.isEmpty || !widget.allowRemoteDownload) return;
        local = await AttachmentCache.instance.ensureFileFor(url);
      }
      if (local == null || local.isEmpty) return;
      await saveFileToDownloads(File(local), fileName: _fileName());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = _fileName();
    final size = _prettySize(widget.attachment?.sizeBytes);
    final icon = _iconForMime(widget.attachment?.mimeType, name);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment:
            widget.isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (widget.replySnippet != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: _ReplyPreview(
                text: widget.replySnippet!,
                thumbnailUrl: widget.replyThumbnailUrl,
                allowRemoteDownload: widget.allowRemoteDownload,
                messageId: widget.replyToMessageId,
                onTapReplyTarget: widget.onTapReplyTarget,
              ),
            ),
          ],
          InkWell(
            onTap: () => _openFile(context),
            onLongPress: () => _saveFile(context),
            child: Container(
              color: Colors.black12,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        if (size.isNotEmpty)
                          Text(
                            size,
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: .6),
                              fontSize: 11.5,
                            ),
                          ),
                        if (widget.caption.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              widget.caption,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_opening)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  if (_saving)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (widget.isMine &&
              widget.status == _UiStatus.failed &&
              widget.onRetry != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('إعادة المحاولة'),
                  onPressed: widget.onRetry,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResolvedNetworkImage extends StatefulWidget {
  final String url;
  final String? bucket;
  final String? path;
  final String? fileId;
  final bool allowRemoteDownload;

  const _ResolvedNetworkImage({
    required this.url,
    required this.bucket,
    required this.path,
    required this.fileId,
    required this.allowRemoteDownload,
  });

  @override
  State<_ResolvedNetworkImage> createState() => _ResolvedNetworkImageState();
}

class _ResolvedNetworkImageState extends State<_ResolvedNetworkImage> {
  final NhostStorageService _storage = NhostStorageService();
  Future<String?>? _future;

  @override
  void initState() {
    super.initState();
    _future = _resolve();
  }

  @override
  void didUpdateWidget(covariant _ResolvedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.bucket != widget.bucket ||
        oldWidget.path != widget.path ||
        oldWidget.fileId != widget.fileId ||
        oldWidget.allowRemoteDownload != widget.allowRemoteDownload) {
      _future = _resolve();
    }
  }

  Future<String?> _resolve() async {
    final raw = widget.url.trim();
    final explicitBucket = (widget.bucket ?? '').trim();
    final explicitPath = (widget.path ?? '').trim();
    final explicitFileId = (widget.fileId ?? '').trim();

    if (explicitFileId.isNotEmpty) {
      if (!widget.allowRemoteDownload) {
        return _storage.publicFileUrl(explicitFileId);
      }
      final signed = await _storage.createSignedUrl(
        explicitFileId,
        expiresInSeconds: AppConstants.storageSignedUrlTTLSeconds,
      );
      if (signed != null && signed.isNotEmpty) return signed;
      return _storage.publicFileUrl(explicitFileId);
    }

    // لو لدينا bucket/path من المرفق، نفضّل إعادة توقيعها دائمًا.
    if (explicitBucket.isNotEmpty && explicitPath.isNotEmpty) {
      if (!widget.allowRemoteDownload) return null;
      return _storage.resolveSignedUrlForPath(
        bucket: explicitBucket,
        path: explicitPath,
      );
    }

    if (raw.startsWith('http')) {
      if (!widget.allowRemoteDownload) return raw;
      return await _storage.resolveSignedUrlFromUrl(raw) ?? raw;
    }
    final storage = _parseStorageUrl(raw);
    final bucket = storage?.bucket ?? '';
    final path = storage?.path ?? '';
    if (bucket.isEmpty || path.isEmpty) return null;
    if (!widget.allowRemoteDownload) return null;
    return _storage.resolveSignedUrlForPath(bucket: bucket, path: path);
  }

  _StorageRef? _parseStorageUrl(String raw) {
    if (!raw.startsWith('storage://')) return null;
    final rest = raw.substring('storage://'.length);
    final idx = rest.indexOf('/');
    if (idx <= 0 || idx >= rest.length - 1) return null;
    final bucket = rest.substring(0, idx);
    final path = rest.substring(idx + 1);
    if (bucket.isEmpty || path.isEmpty) return null;
    return _StorageRef(bucket: bucket, path: path);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snap) {
        final resolved = snap.data ?? '';
        if (resolved.isEmpty) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: Icon(Icons.image_rounded, size: 42));
          }
          return const Center(child: Icon(Icons.image_rounded, size: 42));
        }
        return AttachmentCacheImage(
          url: resolved,
          fit: BoxFit.cover,
          placeholder: const Center(child: Icon(Icons.image_rounded, size: 42)),
          errorWidget: const Center(child: Icon(Icons.broken_image_outlined)),
          allowDownload: widget.allowRemoteDownload,
        );
      },
    );
  }
}

class _StorageRef {
  final String bucket;
  final String path;
  const _StorageRef({required this.bucket, required this.path});
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
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
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
  final bool allowRemoteDownload;
  final String? messageId; // الأصل
  final void Function(String messageId)? onTapReplyTarget;

  const _ReplyPreview({
    required this.text,
    this.thumbnailUrl,
    required this.allowRemoteDownload,
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
            child: AttachmentCacheImage(
              url: thumbnailUrl!,
              width: 34,
              height: 34,
              fit: BoxFit.cover,
              allowDownload: allowRemoteDownload,
              placeholder: const _MiniThumbPlaceholder(),
              errorWidget: const _MiniThumbPlaceholder(),
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
  final bool isOnline;
  const _StatusIcon({required this.status, required this.isOnline});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    IconData icon = Icons.schedule_rounded;
    Color color = scheme.onSurface.withValues(alpha: .45);

    switch (status) {
      case _UiStatus.sending:
        icon = isOnline ? Icons.schedule_rounded : Icons.cloud_off_rounded;
        color = isOnline
            ? scheme.onSurface.withValues(alpha: .45)
            : Colors.orange.shade400;
        break;
      case _UiStatus.sent:
        icon = Icons.done_rounded; // ✓
        color = scheme.onSurface.withValues(alpha: .55);
        break;
      case _UiStatus.delivered:
        icon = Icons.done_all_rounded; // ✓✓
        color = Colors.white.withValues(alpha: .85);
        break;
      case _UiStatus.read:
        icon = Icons.done_all_rounded; // ✓✓ أزرق
        color = const Color(0xFF9FE3FF);
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
    final myUid = NhostManager.client.auth.currentUser?.id ?? '';
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
