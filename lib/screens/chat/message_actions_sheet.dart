// lib/screens/chat/message_actions_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

/// دالة مساعدة لفتح الـ BottomSheet بسهولة — متوافقة مع ChatRoomScreen.
Future<void> showMessageActionsSheet(
  BuildContext context, {
  required ChatMessage message,
  required String myUid,

  /// رد على الرسالة المختارة
  void Function(ChatMessage msg)? onReply,

  /// ذكر المرسل (@email) — يعتمد على senderEmail داخل الرسالة
  void Function(ChatMessage msg)? onMention,

  /// نسخ النص
  void Function(ChatMessage msg)? onCopy,

  /// تعديل الرسالة (يجب احترام صلاحيات الوقت من الخارج)
  Future<void> Function(ChatMessage msg)? onEdit,

  /// حذف للجميع (يجب احترام صلاحيات الوقت من الخارج)
  Future<void> Function(ChatMessage msg)? onDelete,

  /// تفاعل (إيموجي)
  void Function(ChatMessage msg, String emoji)? onReact,

  /// تمرير صلاحيات جاهزة (تتجاوز الحساب التلقائي)
  bool? canEdit,
  bool? canDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => MessageActionsSheet(
      message: message,
      myUid: myUid,
      onReply: onReply,
      onMention: onMention,
      onCopy: onCopy,
      onEdit: onEdit,
      onDelete: onDelete,
      onReact: onReact,
      canEditOverride: canEdit,
      canDeleteOverride: canDelete,
    ),
  );
}

/// ويدجت ورقة إجراءات رسالة (BottomSheet)
class MessageActionsSheet extends StatelessWidget {
  const MessageActionsSheet({
    super.key,
    required this.message,
    required this.myUid,
    this.onReply,
    this.onMention,
    this.onCopy,
    this.onEdit,
    this.onDelete,
    this.onReact,
    this.canEditOverride,
    this.canDeleteOverride,
  });

  final ChatMessage message;
  final String myUid;

  final void Function(ChatMessage msg)? onReply;
  final void Function(ChatMessage msg)? onMention;
  final void Function(ChatMessage msg)? onCopy;
  final Future<void> Function(ChatMessage msg)? onEdit;
  final Future<void> Function(ChatMessage msg)? onDelete;
  final void Function(ChatMessage msg, String emoji)? onReact;

  final bool? canEditOverride;
  final bool? canDeleteOverride;

  bool get _computedCanEdit =>
      message.senderUid == myUid &&
      message.kind == ChatMessageKind.text &&
      !message.deleted;

  bool get _computedCanDelete => message.senderUid == myUid && !message.deleted;

  bool get _canEdit => canEditOverride ?? _computedCanEdit;
  bool get _canDelete => canDeleteOverride ?? _computedCanDelete;

  bool get _hasCopyableText =>
      !message.deleted && ((message.body ?? '').trim().isNotEmpty);

  bool get _canMention =>
      !message.deleted && ((message.senderEmail ?? '').trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Directionality(
      textDirection: Directionality.of(context),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // شريط تفاعلات سريع
              _ReactionsBar(
                enabled: !message.deleted,
                onPick: (emoji) {
                  if (onReact != null) onReact!(message, emoji);
                  Navigator.of(context).maybePop();
                },
              ),

              const Divider(height: 8),

              // ردّ
              if (!message.deleted)
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: const LocalizedText('الردّ على الرسالة'),
                  onTap: () {
                    Navigator.of(context).maybePop();
                    onReply?.call(message);
                  },
                ),

              // ذكر المرسل
              if (_canMention)
                ListTile(
                  leading: const Icon(Icons.alternate_email_rounded),
                  title: const LocalizedText('ذكر المرسل'),
                  onTap: () {
                    Navigator.of(context).maybePop();
                    onMention?.call(message);
                  },
                ),

              // نسخ
              if (_hasCopyableText)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const LocalizedText('نسخ النص'),
                  onTap: () async {
                    Navigator.of(context).maybePop();
                    if (onCopy != null) {
                      onCopy!(message);
                    } else {
                      await Clipboard.setData(
                        ClipboardData(text: message.body!.trim()),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: LocalizedText('تم نسخ النص')),
                        );
                      }
                    }
                  },
                ),

              // تعديل (لنصي للمرسل فقط)
              if (_canEdit)
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const LocalizedText('تعديل الرسالة'),
                  onTap: () async {
                    Navigator.of(context).maybePop();
                    await onEdit?.call(message);
                  },
                ),

              // حذف للجميع (للمُرسل فقط)
              if (_canDelete)
                ListTile(
                  leading: Icon(Icons.delete, color: theme.colorScheme.error),
                  title: LocalizedText('حذف للجميع',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: () async {
                    Navigator.of(context).maybePop();
                    await onDelete?.call(message);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactionsBar extends StatelessWidget {
  const _ReactionsBar({
    required this.onPick,
    this.enabled = true,
  });

  final ValueChanged<String> onPick;
  final bool enabled;

  static const _emojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  @override
  Widget build(BuildContext context) {
    final disabledColor = Theme.of(context).disabledColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        children: _emojis.map((e) {
          return InkWell(
            onTap: enabled ? () => onPick(e) : null,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: enabled ? Colors.grey.shade300 : disabledColor,
                ),
              ),
              child: Text(
                e,
                style: const TextStyle(fontSize: 18),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
