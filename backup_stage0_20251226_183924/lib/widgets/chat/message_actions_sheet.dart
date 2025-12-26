// lib/widgets/chat/message_actions_sheet.dart
//
// BottomSheet لإجراءات الرسالة – بأسلوب واتساب.
// - تفاعل سريع (ردود فعل/إيموجي) في الأعلى.
// - إجراءات سياقية: رد، منشن، نسخ، تعديل/حذف (للرسائل الخاصة بي)، إعادة توجيه، حفظ صورة…
// - إخفاء ما لا يلزم حسب نوع الرسالة وملكيّتها وحالتها (deleted).
// - يدعم RTL ويضمن عرض بريد المرسل LTR.
// - واجهة مرنة عبر تمكين/تعطيل الإجراءات وتمرير callbacks.
//
// ملاحظات:
// - إن مررت onCopy سنستخدمه؛ وإن لم تمرّره سننفّذ النسخ محليًا تلقائيًا (body ثم text، أو رابط أول مرفق للصور).
// - تمرير الـ callbacks اختياري؛ لن تُعرض الأزرار التي بلا callback.
// - نافذة التعديل: ساعتان، نافذة الحذف: 12 ساعة.
// - onReact تُستدعى مع (message, emoji) ليتوافق مع ChatService.toggleReaction.
//
// يتطلب:
//   - models/chat_models.dart
//   - utils/text_direction.dart
//   - utils/time.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/utils/text_direction.dart' as bidi;
import 'package:aelmamclinic/utils/time.dart' as time;

const List<String> _kCommonReactions = <String>[
  '👍',
  '❤️',
  '😂',
  '😮',
  '😢',
  '👎'
];

// نوافذ الصلاحيات
const Duration _kEditWindow = Duration(hours: 2);
const Duration _kDeleteWindow = Duration(hours: 12);

Future<void> showMessageActionsSheet(
  BuildContext context, {
  required ChatMessage message,
  String? myUid,

  // Callbacks (اختيارية – حسب ما تدعمه شاشتك/مزودك)
  void Function(ChatMessage m)? onReply,
  void Function(ChatMessage m)? onMention,
  void Function(ChatMessage m)? onEdit,
  void Function(ChatMessage m)? onDelete,
  void Function(ChatMessage m)? onForward,
  void Function(ChatMessage m)? onSelect,
  void Function(ChatMessage m, String emoji)? onReact,
  void Function(ChatMessage m)? onSaveImage,
  void Function(ChatMessage m)? onInfo,
  void Function(ChatMessage m)? onPin,
  void Function(ChatMessage m)? onCopy, // إن لم يُمرر سننسخ محليًا

  // تحكم عرض/إخفاء (إن أردت إجبار حالة معيّنة)
  bool? canReply,
  bool? canMention,
  bool? canCopy,
  bool? canEdit,
  bool? canDelete,
  bool? canForward,
  bool? canReact,
  bool? canSelect,
  bool? canSaveImage,
  bool? canInfo,
  bool? canPin,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _MessageActionsSheet(
      message: message,
      myUid: myUid,
      onReply: onReply,
      onMention: onMention,
      onEdit: onEdit,
      onDelete: onDelete,
      onForward: onForward,
      onSelect: onSelect,
      onReact: onReact,
      onSaveImage: onSaveImage,
      onInfo: onInfo,
      onPin: onPin,
      onCopy: onCopy,
      canReply: canReply,
      canMention: canMention,
      canCopy: canCopy,
      canEdit: canEdit,
      canDelete: canDelete,
      canForward: canForward,
      canReact: canReact,
      canSelect: canSelect,
      canSaveImage: canSaveImage,
      canInfo: canInfo,
      canPin: canPin,
    ),
  );
}

class _MessageActionsSheet extends StatelessWidget {
  const _MessageActionsSheet({
    required this.message,
    this.myUid,
    this.onReply,
    this.onMention,
    this.onEdit,
    this.onDelete,
    this.onForward,
    this.onSelect,
    this.onReact,
    this.onSaveImage,
    this.onInfo,
    this.onPin,
    this.onCopy,
    this.canReply,
    this.canMention,
    this.canCopy,
    this.canEdit,
    this.canDelete,
    this.canForward,
    this.canReact,
    this.canSelect,
    this.canSaveImage,
    this.canInfo,
    this.canPin,
  });

  final ChatMessage message;
  final String? myUid;

  final void Function(ChatMessage m)? onReply;
  final void Function(ChatMessage m)? onMention;
  final void Function(ChatMessage m)? onEdit;
  final void Function(ChatMessage m)? onDelete;
  final void Function(ChatMessage m)? onForward;
  final void Function(ChatMessage m)? onSelect;
  final void Function(ChatMessage m, String emoji)? onReact;
  final void Function(ChatMessage m)? onSaveImage;
  final void Function(ChatMessage m)? onInfo;
  final void Function(ChatMessage m)? onPin;
  final void Function(ChatMessage m)? onCopy;

  final bool? canReply;
  final bool? canMention;
  final bool? canCopy;
  final bool? canEdit;
  final bool? canDelete;
  final bool? canForward;
  final bool? canReact;
  final bool? canSelect;
  final bool? canSaveImage;
  final bool? canInfo;
  final bool? canPin;

  bool get _isMine {
    final uid = myUid;
    return uid != null && uid.isNotEmpty && message.senderUid == uid;
  }

  bool get _isText => message.kind == ChatMessageKind.text;
  bool get _isImage => message.kind == ChatMessageKind.image;
  bool get _isDeleted => message.deleted;

  bool get _withinEditWindow =>
      DateTime.now().toUtc().difference(message.createdAt) <= _kEditWindow;

  bool get _withinDeleteWindow =>
      DateTime.now().toUtc().difference(message.createdAt) <= _kDeleteWindow;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    // عنوان صغير أعلى اللستة: المرسل + الوقت
    final senderLabel = _isMine
        ? 'أنت'
        : (message.senderEmail == null || message.senderEmail!.trim().isEmpty
            ? 'مستخدم'
            : bidi.ensureLtr(message.senderEmail!.trim()));
    final timeLabel = time.formatMessageTimestamp(message.createdAt);

    // نص فعلي قابل للنسخ (للنسخ المحلي fallback)
    final bodyText = message.body;
    final rawCopyText =
        bodyText != null ? bodyText.trim() : message.text.trim();

    // رابط أول مرفق (للرسائل الصورية) — يُستخدم كنسخ fallback عند عدم وجود نص
    String? firstAttachmentUrl;
    bool hasAttachmentUrl = false;
    try {
      final atts = message.attachments;
      if (atts.isNotEmpty) {
        final u = atts.first.url.trim();
        if (u.isNotEmpty) {
          firstAttachmentUrl = u;
          hasAttachmentUrl = true;
        }
      }
    } catch (_) {
      // تجاهل
    }

    // قدرات افتراضية إن لم تُمرّر:
    final allowReply = canReply ?? (onReply != null && !_isDeleted);
    final allowMention = canMention ?? (onMention != null && !_isDeleted);

    // نسخ: مسموح إن كان هناك onCopy أو نص فعلي أو رابط مرفق للصور
    final allowCopy = canCopy ??
        (((onCopy != null) ||
                (_isText && rawCopyText.isNotEmpty) ||
                (_isImage && hasAttachmentUrl)) &&
            !_isDeleted);

    // تعديل: نصي + ملكي + داخل المهلة + لديك onEdit
    final allowEdit = canEdit ??
        (_isText &&
            _isMine &&
            !_isDeleted &&
            _withinEditWindow &&
            onEdit != null);

    // حذف: ملكي + داخل المهلة + لديك onDelete
    final allowDelete = canDelete ??
        (_isMine && !_isDeleted && _withinDeleteWindow && onDelete != null);

    final allowForward = canForward ?? (onForward != null && !_isDeleted);
    final allowReact = this.canReact ?? (onReact != null && !_isDeleted);
    final allowSelect = canSelect ?? (onSelect != null && !_isDeleted);
    final allowSaveImage =
        canSaveImage ?? (_isImage && !_isDeleted && onSaveImage != null);
    final allowInfo = canInfo ?? (onInfo != null);
    final allowPin = canPin ?? (onPin != null && !_isDeleted);

    final hasReactionBar = allowReact;
    final hasAnyAction = allowReply ||
        allowMention ||
        allowCopy ||
        allowEdit ||
        allowDelete ||
        allowForward ||
        allowSaveImage ||
        allowSelect ||
        allowPin ||
        allowInfo;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // رأس مختصر: المرسل + الوقت
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Icon(_isImage ? Icons.image_rounded : Icons.text_snippet_rounded,
                  color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$senderLabel • $timeLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: isRtl ? TextAlign.right : TextAlign.left,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),

        // شريط التفاعل السريع
        if (hasReactionBar)
          _ReactionBar(
            onPick: (emoji) async {
              // UX: هزة خفيفة + إغلاق الشيت لمنع تعدد الضغطات.
              HapticFeedback.selectionClick();
              Navigator.of(context).maybePop();
              onReact?.call(message, emoji);
            },
          ),

        // Divider يظهر فقط إن كان هناك تفاعلات أو أزرار تليها
        if (hasReactionBar && hasAnyAction)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
          ),

        // عناصر الإجراءات
        _ActionTile(
          visible: allowReply,
          icon: Icons.reply_rounded,
          label: 'رد',
          onTap: () {
            Navigator.of(context).maybePop();
            onReply?.call(message);
          },
        ),
        _ActionTile(
          visible: allowMention,
          icon: Icons.alternate_email_rounded,
          label: 'منشن',
          onTap: () {
            Navigator.of(context).maybePop();
            onMention?.call(message);
          },
        ),
        _ActionTile(
          visible: allowCopy,
          icon: Icons.copy_rounded,
          label: 'نسخ',
          onTap: () async {
            Navigator.of(context).maybePop();
            if (onCopy != null) {
              onCopy!(message);
              return;
            }
            // النسخ المحلي الافتراضي (body ثم text، أو رابط أول مرفق للصور)
            final txt = rawCopyText.isNotEmpty
                ? rawCopyText
                : (firstAttachmentUrl ?? '');
            if (txt.isNotEmpty) {
              await Clipboard.setData(ClipboardData(text: txt));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تم النسخ')),
                );
              }
            }
          },
        ),
        _ActionTile(
          visible: allowEdit,
          icon: Icons.edit_rounded,
          label: 'تعديل',
          onTap: () {
            Navigator.of(context).maybePop();
            onEdit?.call(message);
          },
        ),
        _ActionTile(
          visible: allowDelete,
          icon: Icons.delete_rounded,
          label: 'حذف',
          danger: true,
          onTap: () {
            Navigator.of(context).maybePop();
            onDelete?.call(message);
          },
        ),
        _ActionTile(
          visible: allowForward,
          icon: Icons.forward_rounded,
          label: 'إعادة توجيه',
          onTap: () {
            Navigator.of(context).maybePop();
            onForward?.call(message);
          },
        ),
        _ActionTile(
          visible: allowSaveImage,
          icon: Icons.download_rounded,
          label: 'حفظ الصورة',
          onTap: () {
            Navigator.of(context).maybePop();
            onSaveImage?.call(message);
          },
        ),
        _ActionTile(
          visible: allowSelect,
          icon: Icons.check_circle_rounded,
          label: 'تحديد',
          onTap: () {
            Navigator.of(context).maybePop();
            onSelect?.call(message);
          },
        ),
        _ActionTile(
          visible: allowPin,
          icon: Icons.push_pin_rounded,
          label: 'تثبيت',
          onTap: () {
            Navigator.of(context).maybePop();
            onPin?.call(message);
          },
        ),
        _ActionTile(
          visible: allowInfo,
          icon: Icons.info_outline_rounded,
          label: 'معلومات',
          onTap: () {
            Navigator.of(context).maybePop();
            onInfo?.call(message);
          },
        ),

        const SizedBox(height: 8),
        const SafeArea(top: false, child: SizedBox(height: 4)),
      ],
    );
  }
}

class _ReactionBar extends StatelessWidget {
  const _ReactionBar({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _kCommonReactions.map((emoji) {
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onPick(emoji),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.visible,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final bool visible;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final color = danger ? cs.error : cs.onSurface;
    return ListTile(
      dense: true,
      minLeadingWidth: 24,
      leading: Icon(icon, color: color),
      title: Text(
        label,
        style: TextStyle(
          color: danger ? cs.error : cs.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: onTap,
    );
  }
}
