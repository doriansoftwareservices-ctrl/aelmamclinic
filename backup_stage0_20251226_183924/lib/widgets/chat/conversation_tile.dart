// lib/widgets/chat/conversation_tile.dart
//
// عنصر عرض لمحادثة (DM أو مجموعة) بنمط TBIAN/Neumorphism.
// الميزات:
// - عنوان المحادثة (أو بريد الطرف الآخر في الـ DM).
// - وسم اسم العيادة (اختياري).
// - شارة "غير مقروء" + توقيت آخر رسالة.
// - حالة "يكتب..." (إن وُجدت).
// - حالة اتصال للطرف الآخر في DM (نقطة خضراء).
// - يدعم RTL ويقصّ النصوص الطويلة.
// - يتعامل مع رسالة صورة: يعرض "📷 صورة"؛ وملف: "📎 ملف".
// - يتعامل مع عدم وجود رسائل.
// - يتعامل مع نوع المحادثة announcement بأيقونة مناسبة.
// تحسينات:
// - إصلاح منطق تلوين السطر الثاني: لم نعد نلوّنه لمجرد تمرير subtitleOverride؛ فقط عند subtitleIsTyping.
// - إضافة أيقونة كتم صغيرة بجوار الوقت عند isMuted.
// - تحسين دلالات الوصول (Semantics) لقرّاء الشاشة.
// - تقليم أفضل للملخّص (إزالة الأسطر الجديدة الطويلة).
//
// الاعتمادات:
// - core/neumorphism.dart
// - core/theme.dart
// - models/chat_models.dart
// - utils/time.dart
// - utils/text_direction.dart

import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/utils/time.dart' as tutils;
import 'package:aelmamclinic/utils/text_direction.dart' as bidi;

class ConversationTile extends StatelessWidget {
  final ChatConversation conversation;

  /// لتجاوز العنوان الافتراضي (مثلاً بريد الموظف في محادثة 1:1)
  final String? titleOverride;

  /// لتجاوز السطر الثاني (مثلاً "يكتب...")
  final String? subtitleOverride;

  /// إن كان النص الممرَّر في [subtitleOverride] يمثل حالة "يكتب..."
  /// لاستعمال لون مميّز.
  final bool subtitleIsTyping;

  /// آخر رسالة (إن وُجدت) لتحسين العرض بدلاً من الاعتماد على snippet فقط
  final ChatMessage? lastMessage;

  /// وسم اختياري (اسم العيادة)
  final String? clinicLabel;

  /// عدد الرسائل غير المقروءة (0 = سيُستخدم conversation.unreadCount إن وُجد)
  final int unreadCount;

  /// كتم الإشعارات (يؤثر على لون شارة غير المقروء + إظهار أيقونة بجانب الوقت)
  final bool isMuted;

  /// حالة الاتصال للطرف الآخر في DM (نقطة خضراء).
  final bool? isOnline;

  /// إظهار سهم تنقل
  final bool showChevron;

  /// أقصى عدد حروف لسطـر الملخص
  final int maxSubtitleChars;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ConversationTile({
    super.key,
    required this.conversation,
    this.titleOverride,
    this.subtitleOverride,
    this.subtitleIsTyping = false,
    this.lastMessage,
    this.clinicLabel,
    this.unreadCount = 0,
    this.isMuted = false,
    this.isOnline,
    this.showChevron = false,
    this.maxSubtitleChars = 64,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final titleText = (titleOverride?.trim().isNotEmpty ?? false)
        ? titleOverride!.trim()
        : _computeTitle(conversation);

    final subText = (subtitleOverride?.trim().isNotEmpty ?? false)
        ? subtitleOverride!.trim()
        : _computeSubtitle(conversation, lastMessage, maxSubtitleChars);

    // مصدر الوقت: آخر رسالة مُمرّرة > lastMsgAt > createdAt
    final DateTime timeSource = lastMessage?.createdAt ??
        conversation.lastMsgAt ??
        conversation.createdAt;
    final timeText = tutils.formatChatListTimestamp(timeSource);

    // إن لم يمرَّر unreadCount، استخدم قيمة المحادثة إن وُجدت
    final resolvedUnread =
        unreadCount != 0 ? unreadCount : (conversation.unreadCount ?? 0);
    final hasUnread = resolvedUnread > 0;

    // دلالات وصول
    final semanticsLabel = StringBuffer()
      ..write(titleText)
      ..write(', ')
      ..write(hasUnread
          ? 'لديك $resolvedUnread رسائل غير مقروءة'
          : 'لا توجد رسائل غير مقروءة')
      ..write(', آخر تحديث ')
      ..write(timeText);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Semantics(
        label: semanticsLabel.toString(),
        button: true,
        child: NeuCard(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: ListTile(
            onTap: onTap,
            onLongPress: onLongPress,
            contentPadding: EdgeInsets.zero,
            leading: _buildLeadingAvatar(
              type: conversation.type,
              isOnline: isOnline,
            ),
            title: Row(
              children: [
                Expanded(
                  child: _TitleText(
                    text: titleText,
                    bold: hasUnread, // نُبرز العنوان إذا كان هناك غير مقروء
                  ),
                ),
                const SizedBox(width: 6),
                if (clinicLabel != null && clinicLabel!.trim().isNotEmpty)
                  _ClinicChip(text: clinicLabel!.trim()),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _SubtitleText(
                text: subText,
                isTyping:
                    subtitleIsTyping, // ✅ لم نعد نلوّن لمجرد وجود override
                bold: hasUnread, // نُبرز السطر الثاني أيضًا عند وجود غير مقروء
              ),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timeText,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .55),
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                    if (isMuted) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.notifications_off_rounded,
                        size: 14,
                        color: scheme.onSurface.withValues(alpha: .45),
                        semanticLabel: 'مكتومة',
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (hasUnread)
                  _UnreadBadge(
                    count: resolvedUnread,
                    muted: isMuted,
                  )
                else if (showChevron)
                  const Icon(Icons.chevron_left_rounded, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- Helpers UI ----------

  Widget _buildLeadingAvatar({
    required ChatConversationType type,
    bool? isOnline,
  }) {
    final isGroup = type == ChatConversationType.group;
    final isAnnouncement = type == ChatConversationType.announcement;

    IconData icon;
    if (isGroup) {
      icon = Icons.forum_rounded;
    } else if (isAnnouncement) {
      icon = Icons.campaign_rounded;
    } else {
      icon = Icons.person_rounded;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: kPrimaryColor.withValues(alpha: .08),
          child: Icon(icon, color: kPrimaryColor),
        ),
        if (isOnline == true && !isGroup && !isAnnouncement)
          const Positioned(
            right: -2,
            top: -2,
            child: CircleAvatar(
              radius: 6,
              backgroundColor: Colors.green,
            ),
          ),
      ],
    );
  }

  String _computeTitle(ChatConversation c) {
    final t = (c.title ?? '').trim();
    if (t.isNotEmpty) return t;
    // عناوين افتراضية ألطف حسب النوع
    switch (c.type) {
      case ChatConversationType.group:
        return 'مجموعة';
      case ChatConversationType.announcement:
        return 'إعلان';
      case ChatConversationType.direct:
        return 'محادثة';
    }
  }

  String _computeSubtitle(
    ChatConversation c,
    ChatMessage? last,
    int maxLen,
  ) {
    // لو لدينا رسالة أخيرة ممررة، استخدمها أولاً
    if (last != null) {
      if (last.deleted) return 'رسالة محذوفة';
      if (last.kind == ChatMessageKind.image) return '📷 صورة';
      if (last.kind == ChatMessageKind.file) return '📎 ملف';
      if (last.kind == ChatMessageKind.text) {
        final s = (last.body ?? '').trim();
        if (s.isNotEmpty) {
          final oneLine =
              s.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ');
          return oneLine.length > maxLen
              ? '${oneLine.substring(0, maxLen)}…'
              : oneLine;
        }
      }
    }

    // وإلا استعمل الـ snippet من المحادثة (lastMessageText/last_msg_snippet)
    final sn = (c.lastMessageText ?? c.lastMsgSnippet ?? '').trim();
    if (sn.isNotEmpty) {
      final oneLine = sn.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ');
      return oneLine.length > maxLen
          ? '${oneLine.substring(0, maxLen)}…'
          : oneLine;
    }

    return 'لا رسائل بعد';
  }
}

/*──────── Widgets داخلية للمظهر ────────*/

class _TitleText extends StatelessWidget {
  final String text;
  final bool bold;
  const _TitleText({required this.text, this.bold = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dir = bidi.ltrIfEmailOrLatinElseRtl(text);

    return Text(
      text,
      textDirection: dir,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: scheme.onSurface,
        fontWeight: bold ? FontWeight.w900 : FontWeight.w800,
      ),
    );
  }
}

class _SubtitleText extends StatelessWidget {
  final String text;
  final bool isTyping;
  final bool bold;
  const _SubtitleText(
      {required this.text, required this.isTyping, this.bold = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dir = bidi.ltrIfEmailOrLatinElseRtl(text);

    return Text(
      text,
      textDirection: dir,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color:
            isTyping ? kPrimaryColor : scheme.onSurface.withValues(alpha: .75),
        fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
      ),
    );
  }
}

class _ClinicChip extends StatelessWidget {
  final String text;
  const _ClinicChip({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: scheme.onSurface.withValues(alpha: .85),
          fontWeight: FontWeight.w800,
          fontSize: 11.5,
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  final bool muted;
  const _UnreadBadge({required this.count, required this.muted});

  @override
  Widget build(BuildContext context) {
    final bg = muted ? Colors.grey : kPrimaryColor;
    final capped = count > 999 ? '999+' : (count > 99 ? '99+' : '$count');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        capped,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}
