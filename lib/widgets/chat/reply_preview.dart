// lib/widgets/chat/reply_preview.dart
//
// معاينة الرسالة المُشار إليها (Reply Preview) أعلى حقل الإدخال – بأسلوب واتساب.
// - تُظهر اسم المرسل (أو "أنت") + مقتطف من الرسالة.
// - صورة مصغّرة إن كانت الرسالة صورة، وأيقونة 📎 إن كانت ملفًا.
// - يدعم RTL ويضمن عرض البريد الإلكتروني LTR.
// - زر إغلاق لمسح حالة الرد.
// - نقرة على الصندوق كله (اختياري) للانتقال للرسالة الأصلية.
//
// الاستخدام:
// ReplyPreview(
//   message: replyingToMessage,         // أو مرّر text فقط
//   // أو:
//   // text: 'مقتطف نصي للرد',
//   onCancel: () => setState(() => replyingToMessage = null),
//   onTapOriginal: () => scrollToMessage(replyingToMessage!.id),
// )
//
// يتطلب:
// - models/chat_models.dart (ChatMessage / ChatAttachment / ChatMessageKind)
// - utils/text_direction.dart (ensureLtr / textDirectionFor)

import 'package:flutter/material.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';

import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/utils/text_direction.dart' as bidi;
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class ReplyPreview extends StatelessWidget {
  const ReplyPreview({
    super.key,
    this.message,
    this.text, // ← دعم مقتطف نصّي مباشر (للتوافق مع ChatComposer)
    this.onCancel,
    this.onTapOriginal,
    this.meUid,
    this.margin,
    this.compact = false,
  });

  /// الرسالة المُشار إليها. إن كانت null سنعتمد على [text] إن وُجد.
  final ChatMessage? message;

  /// بديل متوافق: مقتطف نصّي فقط عند عدم توفر [message].
  final String? text;

  /// إلغاء الرد.
  final VoidCallback? onCancel;

  /// الانتقال للرسالة الأصلية عند النقر على المعاينة (اختياري).
  final VoidCallback? onTapOriginal;

  /// uid الخاص بي (اختياري). إن لم يُمرَّر نأخذ من Nhost.currentUser.
  final String? meUid;

  /// هامش خارجي اختياري.
  final EdgeInsetsGeometry? margin;

  /// نمط مضغوط قليلًا (ارتفاع أخفض).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // لو لا رسالة ولا نص → لا شيء
    if (message == null && (text == null || text!.trim().isEmpty)) {
      return const SizedBox.shrink();
    }

    final m = message;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final myUid = meUid ?? NhostManager.client.auth.currentUser?.id;

    // المرسل
    String senderLabel;
    if (m != null) {
      final isMine =
          (myUid != null && myUid.isNotEmpty && m.senderUid == myUid);
      senderLabel = isMine
          ? 'أنت'
          : ((m.senderEmail ?? '').trim().isNotEmpty
              ? bidi.ensureLtr(m.senderEmail!.trim())
              : 'مستخدم');
    } else {
      // عندما لا توجد رسالة (نص فقط)
      senderLabel = 'مقتطف';
    }

    // المقتطف + النوع + الصورة المصغّرة (إن وجدت)
    final snippetInfo = _buildSnippetAndMeta(m, text);
    final snippet = snippetInfo.snippet;
    final kind = snippetInfo.kind;
    final thumbUrl = snippetInfo.thumbUrl;

    // ألوان خفيفة متوافقة مع الثيم
    final cs = Theme.of(context).colorScheme;
    final surface = cs.surfaceContainerHighest.withValues(alpha: 0.45);
    final borderColor = cs.outlineVariant;
    final barColor = cs.primary;

    final titleStyle = TextStyle(
      color: cs.primary,
      fontWeight: FontWeight.w800,
      fontSize: compact ? 12.0 : 13.0,
    );

    final snippetDir = bidi.textDirectionFor(snippet);

    final content = Expanded(
      child: InkWell(
        onTap: onTapOriginal,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: compact ? 6 : 8,
          ),
          child: Column(
            crossAxisAlignment:
                isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                senderLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              const SizedBox(height: 2),
              Text(
                snippet,
                maxLines: compact ? 1 : 2,
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                overflow: TextOverflow.ellipsis,
                textDirection: snippetDir,
                style: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.95),
                  fontSize: compact ? 12.0 : 13.0,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final bar = Container(
      width: 4,
      height: compact ? 40 : 44,
      decoration: BoxDecoration(
        color: barColor,
        borderRadius: BorderRadius.circular(4),
      ),
    );

    final cancelBtn = IconButton(
      icon: const Icon(Icons.close_rounded),
      tooltip: context.trRaw('إغلاق'),
      onPressed: onCancel,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      splashRadius: 18,
    );

    final thumb = _Thumb(url: thumbUrl, kind: kind, compact: compact);

    // ترتيب العناصر حسب الاتجاه
    final children = <Widget>[
      if (isRtl) cancelBtn,
      if (!isRtl) bar,
      const SizedBox(width: 8),
      thumb,
      const SizedBox(width: 10),
      content,
      if (isRtl) bar,
      if (!isRtl) cancelBtn,
    ];

    return Semantics(
      label: context.trRaw('معاينة الرد'),
      onTapHint: onTapOriginal != null
          ? context.trRaw('الانتقال للرسالة الأصلية')
          : null,
      child: Container(
        margin: margin ??
            const EdgeInsets.symmetric(horizontal: 8).copyWith(top: 6),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: children,
        ),
      ),
    );
  }

  /// يبني المقتطف والنوع والصورة المصغرة اعتمادًا على الرسالة أو النص البديل.
  _SnippetMeta _buildSnippetAndMeta(ChatMessage? m, String? altText) {
    if (m == null) {
      final t = (altText ?? '').trim();
      return _SnippetMeta(
        snippet: t.isEmpty ? 'رسالة' : t,
        kind: ChatMessageKind.text,
        thumbUrl: null,
      );
    }

    if (m.deleted) {
      return _SnippetMeta(
        snippet: 'تم حذف هذه الرسالة',
        kind: ChatMessageKind.text,
        thumbUrl: null,
      );
    }

    if (!AppConstants.chatAllowAttachments &&
        (m.kind == ChatMessageKind.image || m.kind == ChatMessageKind.file)) {
      final t = _primaryText(m);
      return _SnippetMeta(
        snippet: t.isNotEmpty ? t : 'مرفق غير متاح',
        kind: ChatMessageKind.text,
        thumbUrl: null,
      );
    }

    if (m.kind == ChatMessageKind.image) {
      final t = _primaryText(m);
      final label = t.isNotEmpty ? '📷 $t' : '📷 صورة';
      String? url;
      if (m.attachments.isNotEmpty) {
        final a = m.attachments.first;
        final b = (a.bucket ?? '').trim();
        final p = (a.path ?? '').trim();
        if (b.isNotEmpty && p.isNotEmpty) {
          url = 'storage://$b/$p';
        } else if (a.url.isNotEmpty) {
          url = a.url;
        } else if ((a.signedUrl ?? '').trim().isNotEmpty) {
          url = a.signedUrl;
        }
      }
      return _SnippetMeta(
        snippet: label,
        kind: ChatMessageKind.image,
        thumbUrl: url,
      );
    }

    if (m.kind == ChatMessageKind.file) {
      final t = _primaryText(m);
      final label = t.isNotEmpty ? '📎 $t' : '📎 ملف';
      // يمكن لاحقًا دعم صورة مصغّرة للملفات إن وُجدت
      return _SnippetMeta(
        snippet: label,
        kind: ChatMessageKind.file,
        thumbUrl: null,
      );
    }

    // الافتراضي (نص / أي نوع آخر غير معرّف لدينا)
    final t = _primaryText(m);
    return _SnippetMeta(
      snippet: t.isNotEmpty ? t : 'رسالة',
      kind: ChatMessageKind.text,
      thumbUrl: null,
    );
  }

  String _primaryText(ChatMessage message) {
    final body = message.body;
    if (body != null) {
      final trimmed = body.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return message.text.trim();
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({this.url, required this.kind, required this.compact});

  final String? url;
  final ChatMessageKind kind;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = compact ? 30.0 : 34.0;

    Widget child;
    switch (kind) {
      case ChatMessageKind.image:
        if ((url ?? '').isEmpty) {
          child = Icon(
            Icons.image_outlined,
            size: size * .55,
            color: cs.onSurfaceVariant.withValues(alpha: 0.8),
          );
        } else {
          child = ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _ResolvedThumbImage(
              url: url!,
              size: size,
            ),
          );
        }
        break;

      case ChatMessageKind.file:
        child = Icon(
          Icons.attach_file_rounded,
          size: size * .55,
          color: cs.onSurfaceVariant.withValues(alpha: 0.85),
        );
        break;

      default:
        child = Icon(
          Icons.text_snippet_rounded,
          size: size * .55,
          color: cs.onSurfaceVariant.withValues(alpha: 0.8),
        );
        break;
    }

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: child,
    );
  }
}

class _ResolvedThumbImage extends StatefulWidget {
  final String url;
  final double size;

  const _ResolvedThumbImage({
    required this.url,
    required this.size,
  });

  @override
  State<_ResolvedThumbImage> createState() => _ResolvedThumbImageState();
}

class _ResolvedThumbImageState extends State<_ResolvedThumbImage> {
  final NhostStorageService _storage = NhostStorageService();
  late Future<String?> _future;

  @override
  void initState() {
    super.initState();
    _future = _resolve();
  }

  @override
  void didUpdateWidget(covariant _ResolvedThumbImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = _resolve();
    }
  }

  Future<String?> _resolve() async {
    final raw = widget.url.trim();
    if (raw.startsWith('http')) {
      return await _storage.resolveSignedUrlFromUrl(raw) ?? raw;
    }
    if (!raw.startsWith('storage://')) return null;
    final rest = raw.substring('storage://'.length);
    final idx = rest.indexOf('/');
    if (idx <= 0 || idx >= rest.length - 1) return null;
    final bucket = rest.substring(0, idx);
    final path = rest.substring(idx + 1);
    if (bucket.isEmpty || path.isEmpty) return null;
    return _storage.resolveSignedUrlForPath(bucket: bucket, path: path);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snap) {
        final resolved = snap.data ?? '';
        if (resolved.isEmpty) {
          return Container(
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            color: Colors.black12,
            child: Icon(
              snap.connectionState == ConnectionState.waiting
                  ? Icons.image_rounded
                  : Icons.broken_image_outlined,
              size: widget.size * .55,
              color: cs.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          );
        }
        return Image.network(
          resolved,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Icon(
            Icons.broken_image_outlined,
            size: widget.size * .55,
            color: cs.onSurfaceVariant.withValues(alpha: 0.8),
          ),
          loadingBuilder: (_, child, progress) {
            if (progress == null) return child;
            return Container(
              width: widget.size,
              height: widget.size,
              alignment: Alignment.center,
              color: Colors.black12,
              child: Icon(
                Icons.image_rounded,
                size: widget.size * .55,
                color: cs.onSurfaceVariant.withValues(alpha: .6),
              ),
            );
          },
        );
      },
    );
  }
}

class _SnippetMeta {
  final String snippet;
  final ChatMessageKind kind;
  final String? thumbUrl;

  _SnippetMeta({
    required this.snippet,
    required this.kind,
    required this.thumbUrl,
  });
}
