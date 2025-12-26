// lib/widgets/chat/chat_composer.dart
//
// شريط كتابة الرسائل “Composer”
// - إرسال نص + صور (مثل واتساب: لو وُجد نص وصور نرسل النص ثم الصور).
// - اختيار صور عبر callback يوفّره الأب (لا نعتمد حزمات خارجية هنا).
// - معاينة المرفقات قبل الإرسال عبر AttachmentChip.
// - معاينة الرد (Reply) مبسّطة بالاعتماد على replyToSnippet + زر إلغاء.
// - إرسال/إيقاف إشارة الكتابة (typing) عبر ChatService + ChatProvider، مع debounce.
// - اتجاه نص ذكي بالعربية/الإنجليزية باستخدام utils/text_direction.dart.
// - تحسينات سطح مكتب: إرسال بـ Ctrl/Cmd+Enter.
//
// المتطلبات:
//   - provider: لاستخدام ChatProvider من الشجرة.
//   - core/neumorphism.dart (NeuCard)
//   - core/theme.dart (kPrimaryColor)
//   - utils/text_direction.dart
//   - widgets/chat/attachment_chip.dart

import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/providers/chat_provider.dart';
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/utils/text_direction.dart' as bidi;
import 'attachment_chip.dart';

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.conversationId,
    this.controller,
    this.focusNode,
    this.hintText = 'اكتب رسالة…',
    this.replyToSnippet,
    this.onCancelReply,
    this.pickImages, // ← يزوّدها الأب لالتقاط/اختيار الصور
    this.enableImages = true,
  });

  final String conversationId;

  /// يمكنك تمرير Controller/FocusNode من الأب إن رغبت (اختياري).
  final TextEditingController? controller;
  final FocusNode? focusNode;

  final String hintText;

  /// معاينة الرد (واجهة فقط حاليًا).
  final String? replyToSnippet;
  final VoidCallback? onCancelReply;

  /// دالة اختيار الصور: يجب أن تُعيد ملفات الصور المختارة.
  /// مثال في الشاشة: () async => (await ImagePicker.pickMultiImage ...)…
  final Future<List<File>> Function()? pickImages;

  final bool enableImages;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _PendingImage {
  _PendingImage(this.file);
  final File file;
  AttachmentUploadStatus status = AttachmentUploadStatus.queued;
  double progress = 0; // غير مستعمل حاليًا (لا نملك تقدم فعلي من التخزين)
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _ChatComposerState extends State<ChatComposer> {
  late final TextEditingController _ctrl =
      widget.controller ?? TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();

  final List<_PendingImage> _images = [];

  bool _sending = false;

  // typing debounce
  Timer? _typingTimer;
  bool _typingActive = false;

  @override
  void dispose() {
    _typingTimer?.cancel();
    // أرسل إشارة توقف الكتابة
    unawaited(
        ChatService.instance.pingTyping(widget.conversationId, typing: false));
    if (widget.controller == null) _ctrl.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    // لو فرغ الحقل بالكامل أوقف الكتابة فورًا
    if (v.trim().isEmpty && _typingActive) {
      _setTyping(false, immediate: true);
      return;
    }
    _setTyping(true);
    setState(() {}); // لتحديث حالة زر الإرسال
  }

  void _setTyping(bool typing, {bool immediate = false}) {
    _typingTimer?.cancel();

    if (typing && !_typingActive) {
      _typingActive = true;
      context.read<ChatProvider>().setTyping(widget.conversationId, true);
      unawaited(
          ChatService.instance.pingTyping(widget.conversationId, typing: true));
    }

    // سنوقف الكتابة بعد 4 ثوانٍ من عدم النشاط
    if (immediate) {
      _typingActive = false;
      context.read<ChatProvider>().setTyping(widget.conversationId, false);
      unawaited(ChatService.instance
          .pingTyping(widget.conversationId, typing: false));
    } else {
      _typingTimer = Timer(const Duration(seconds: 4), () {
        _typingActive = false;
        context.read<ChatProvider>().setTyping(widget.conversationId, false);
        unawaited(ChatService.instance
            .pingTyping(widget.conversationId, typing: false));
      });
    }
  }

  Future<void> _pickImages() async {
    if (!widget.enableImages || widget.pickImages == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختيار الصور غير مُفعَّل في هذه الشاشة')),
      );
      return;
    }
    try {
      final files = await widget.pickImages!.call();
      if (files.isEmpty) return;
      setState(() {
        _images.addAll(files.map((f) => _PendingImage(f)));
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر اختيار الصور: $e')),
      );
    }
  }

  Future<void> _send() async {
    if (_sending) return;

    final text = _ctrl.text.trim();
    final hasText = text.isNotEmpty;
    final hasImages = _images.isNotEmpty;

    if (!hasText && !hasImages) return;

    setState(() => _sending = true);

    try {
      // أوقف typing فورًا عند الإرسال
      _setTyping(false, immediate: true);

      // 1) نص
      if (hasText) {
        await context
            .read<ChatProvider>()
            .sendText(conversationId: widget.conversationId, text: text);
        _ctrl.clear();
      }

      // 2) صور
      if (hasImages) {
        // علّمها "uploading"
        setState(() {
          for (final p in _images) {
            p.status = AttachmentUploadStatus.uploading;
          }
        });

        try {
          await context.read<ChatProvider>().sendImages(
                conversationId: widget.conversationId,
                files: _images.map((e) => e.file).toList(),
              );

          // نجاح: أفرغ القائمة
          setState(() => _images.clear());
        } catch (e) {
          // فشل: علّمها failed واتركها معروضة
          setState(() {
            for (final p in _images) {
              p.status = AttachmentUploadStatus.failed;
            }
          });
          rethrow;
        }
      }

      // نجاح كامل
      widget.onCancelReply?.call(); // لو كنت في وضع رد، ألغِه بعد الإرسال
      _focus.requestFocus();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر الإرسال: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = _ctrl.text;
    final currentDir = bidi.textDirectionFor(text);

    final canSendNow = _ctrl.text.trim().isNotEmpty || _images.isNotEmpty;
    final showSend = _sending ? true : canSendNow;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: SafeArea(
        top: false,
        child: Shortcuts(
          shortcuts: <LogicalKeySet, Intent>{
            // Ctrl/Cmd + Enter للإرسال على سطح المكتب
            LogicalKeySet(LogicalKeyboardKey.enter, LogicalKeyboardKey.control):
                const _SendIntent(),
            LogicalKeySet(LogicalKeyboardKey.enter, LogicalKeyboardKey.meta):
                const _SendIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _SendIntent: CallbackAction<_SendIntent>(
                onInvoke: (_) {
                  if (!_sending && canSendNow) _send();
                  return null;
                },
              ),
            },
            child: FocusTraversalGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Reply preview (واجهة مبسّطة)
                  if ((widget.replyToSnippet ?? '').trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10)
                          .copyWith(top: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: kPrimaryColor.withValues(alpha: .06),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: Theme.of(context).dividerColor),
                              ),
                              child: Text(
                                (widget.replyToSnippet!.trim().length > 140)
                                    ? '${widget.replyToSnippet!.trim().substring(0, 140)}…'
                                    : widget.replyToSnippet!.trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'إلغاء الرد',
                            onPressed: widget.onCancelReply,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),

                  // Selected attachments preview
                  if (_images.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8)
                          .copyWith(top: 8),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final p in _images)
                              AttachmentChip(
                                name: _fileName(p.file),
                                status: p.status,
                                file: p.file,
                                onRemove: _sending
                                    ? null
                                    : () {
                                        setState(() => _images.remove(p));
                                      },
                                compact: true,
                              ),
                          ],
                        ),
                      ),
                    ),

                  // Composer box
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8)
                        .copyWith(top: 8),
                    child: NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Attach
                          IconButton(
                            tooltip: 'إرفاق صورة',
                            onPressed: (_sending || !widget.enableImages)
                                ? null
                                : _pickImages,
                            icon: const Icon(Icons.photo_library_rounded),
                            color: scheme.onSurface.withValues(alpha: .85),
                          ),

                          // TextField (مرن)
                          Expanded(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 140),
                              child: Scrollbar(
                                child: TextField(
                                  controller: _ctrl,
                                  focusNode: _focus,
                                  maxLines: null,
                                  minLines: 1,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  onChanged: _onChanged,
                                  onTapOutside: (_) =>
                                      _setTyping(false, immediate: true),
                                  textDirection: currentDir,
                                  textInputAction: TextInputAction.newline,
                                  decoration: InputDecoration(
                                    hintText: widget.hintText,
                                    border: InputBorder.none,
                                    isDense: true,
                                    hintStyle: TextStyle(
                                      color: scheme.onSurface
                                          .withValues(alpha: .45),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  style: TextStyle(
                                    color: scheme.onSurface,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(width: 6),

                          // Send button
                          _SendButton(
                            enabled: showSend && !_sending,
                            sending: _sending,
                            onPressed: _send,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _fileName(File f) {
    final s = f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : '';
    return s.isEmpty ? 'صورة' : s;
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.sending,
    required this.onPressed,
  });

  final bool enabled;
  final bool sending;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = enabled ? kPrimaryColor : scheme.surfaceContainerHigh;

    return SizedBox(
      width: 44,
      height: 44,
      child: ElevatedButton(
        onPressed: enabled ? onPressed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: enabled ? Colors.white : scheme.onSurfaceVariant,
          elevation: enabled ? 1.5 : 0,
          padding: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: sending
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(
                      enabled ? Colors.white : scheme.onSurfaceVariant),
                ),
              )
            : const Icon(Icons.send_rounded, size: 20),
      ),
    );
  }
}
