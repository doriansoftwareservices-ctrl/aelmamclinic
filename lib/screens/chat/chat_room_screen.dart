// lib/screens/chat/chat_room_screen.dart
//
// شاشة غرفة الدردشة — نسخة محسّنة + تحسينات تجربة المستخدم:
// - Local-first boot من ChatLocalStore ثم استبدال بمزوّد ChatProvider.
// - ترقيم عكسي + ترحيل للأقدم مع الحفاظ على موضع التمرير.
// - إرسال نص/صور، معاينة مرفقات قبل الإرسال + التقاط كاميرا (ضغط مطوّل).
// - "يكتب…" من ChatProvider فقط.
// - تعليم كمقروء تلقائي عندما تصل رسالة واردة أو عند فتح الغرفة (مع منع القفز غير المرغوب).
// - بحث داخل الدردشة والتمرير إلى رسالة معيّنة.
// - قائمة إجراءات (نسخ/رد/تعديل/حذف/تفاعل/إعادة توجيه) مع احترام نوافذ الصلاحيات.
// - ✅ إصلاح الإيحاء الخاطئ للتسليم: نعرض delivered ↦ sent بصريًا للرسائل الصادرة حتى chat_reads ⇒ read.
// - ✅ فاصل "رسائل جديدة" عند وجود غير مقروء + فواصل أيام (اليوم/أمس/تاريخ).
// - زر عائم للعودة للأسفل عند الابتعاد، مع عدّاد رسائل جديدة.
// - تحسينات الأداء: Selectors لتقليل إعادة البناء، وحراسة فتح الغرفة نفسها.
//
// ملاحظة: يعتمد على التحديثات الأخيرة في ChatProvider/ChatService.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/providers/chat_provider.dart';
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/utils/text_direction.dart' as td;
import 'package:aelmamclinic/widgets/chat/attachment_chip.dart';
import 'package:aelmamclinic/widgets/chat/message_actions_sheet.dart';
import 'package:aelmamclinic/widgets/chat/message_bubble.dart';
import 'package:aelmamclinic/widgets/chat/typing_indicator.dart';
import 'chat_search_screen.dart';
import 'image_viewer_screen.dart';

class ChatRoomScreen extends StatefulWidget {
  final ChatConversation conversation;
  const ChatRoomScreen({super.key, required this.conversation});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  static const bool _chatAttachmentsEnabled = true;
  final _textCtrl = TextEditingController();
  final _focusNode = FocusNode();
  final _listCtrl = ScrollController();
  final _picker = ImagePicker();

  final List<XFile> _pickedImages = [];
  final List<PlatformFile> _pickedFiles = [];
  bool _sending = false;
  bool _loadingMore = false;
  Timer? _scrollDebounce;

  // Composer suggestions for doctors (patients/services).
  int? _doctorIdForSuggestions;
  _ComposerSuggestionKind? _suggestionKind;
  String _suggestionQuery = '';
  bool _loadingSuggestions = false;
  Timer? _suggestionDebounce;
  final List<_ComposerSuggestion> _suggestions = [];

  // typing محلي لإطفاء الحالة إذا لم يطفئها المزوّد سريعًا.
  Timer? _typingOffTimer;

  // لتفادي تعليم القراءة مرارًا لنفس الرسالة
  String? _lastSeenNewestId;

  // تمهيد محلي سريع (قبل أن يجهّز المزوّد دفعة البداية/الستريم)
  List<ChatMessage> _bootLocal = const [];

  ChatProvider? _chat;
  bool _roomOpened = false;

  // Reply (واجهة فقط – نرفق القصاصة ضمن النص عند الإرسال)
  String? _replySnippet;
  void _clearReply() => setState(() => _replySnippet = null);

  // مفاتيح لعناصر الرسائل للتمرير إلى رسالة معيّنة
  final Map<String, GlobalKey> _msgKeys = {};
  GlobalKey _keyForMessage(String id) =>
      _msgKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'msg:$id'));

  // Anchor غير مقروء عند أوّل فتح (إن وُجد)
  String? _unreadAnchorMessageId;
  int _initialUnread = 0;

  // زر “إلى الأسفل” يظهر عند الابتعاد + عدّاد وصول جديد
  bool _showJumpToBottom = false;
  int _pendingNewWhileAway = 0;

  String get _convId => widget.conversation.id;
  String get _currentUid => NhostManager.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _initialUnread = (widget.conversation.unreadCount ?? 0);
    _listCtrl.addListener(_onScroll);
    _bootFromLocal(); // عرض فوري من SQLite
    _loadDoctorContext();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chat ??= context.read<ChatProvider>();
    if (!_roomOpened && _chat != null) {
      _roomOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          // يبدأ الستريم/المزامنة والاشتراك على chat_reads
          await _chat!.openConversation(_convId);

          // جهّز Anchor للغير مقروء حسب الدفعة الأولى من المزوّد لاحقًا
          _maybePrepareUnreadAnchorOnce();

          // علّم كمقروء فور الدخول (بدون تحريك إن لم تكن بأسفل)
          await _chat!.markConversationRead(_convId);
        } catch (_) {}
        _scrollToBottom(immediate: true);
      });
    }
  }

  @override
  void dispose() {
    _typingOffTimer?.cancel();
    _scrollDebounce?.cancel();
    _suggestionDebounce?.cancel();
    _listCtrl.removeListener(_onScroll);
    _listCtrl.dispose();
    _textCtrl.dispose();
    _focusNode.dispose();
    _chat?.closeConversation(); // يلغي الاشتراكات (messages/typing/reads)
    super.dispose();
  }

  /*──────────────────── Local-first boot ────────────────────*/

  Future<void> _bootFromLocal() async {
    try {
      final local =
          await ChatLocalStore.instance.getMessages(_convId, limit: 30);
      if (!mounted) return;
      setState(() {
        _bootLocal = local;
      });
    } catch (_) {
      // تجاهل؛ العرض سيأتي من المزوّد لاحقًا.
    }
  }

  /*──────────────────── Scroll & pagination ────────────────────*/

  void _onScroll() {
    if (!_listCtrl.hasClients) return;
    final pos = _listCtrl.position;

    // إظهار/إخفاء زر "إلى الأسفل"
    final away = pos.pixels > 120; // reverse:true => أسفل عند min=0
    if (away != _showJumpToBottom) {
      setState(() => _showJumpToBottom = away);
      if (!away) _pendingNewWhileAway = 0;
    }

    // مع reverse:true يصبح الوصول للأقدم عند الاقتراب من maxScrollExtent.
    final nearTop = pos.pixels > (pos.maxScrollExtent - 120);
    if (pos.maxScrollExtent > 0 && nearTop && !_loadingMore) {
      _scrollDebounce?.cancel();
      _scrollDebounce = Timer(const Duration(milliseconds: 120), () async {
        if (!mounted) return;
        setState(() => _loadingMore = true);

        // احفظ الموضع قبل التحميل للحفاظ على الإزاحة بعد الإدراج.
        final beforePixels = _listCtrl.position.pixels;
        final beforeMax = _listCtrl.position.maxScrollExtent;

        try {
          await _chat?.loadMoreMessages(_convId);
        } finally {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_listCtrl.hasClients) return;
            final afterMax = _listCtrl.position.maxScrollExtent;
            final delta = afterMax - beforeMax;
            final target = beforePixels + delta;
            _listCtrl.jumpTo(target.clamp(
              _listCtrl.position.minScrollExtent,
              _listCtrl.position.maxScrollExtent,
            ));
            if (mounted) setState(() => _loadingMore = false);
          });
        }
      });
    }
  }

  bool _isNearBottom() {
    if (!_listCtrl.hasClients) return true;
    return _listCtrl.position.pixels <= 120;
  }

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listCtrl.hasClients) return;
      final target = _listCtrl.position.minScrollExtent; // reverse:true
      if (immediate) {
        _listCtrl.jumpTo(target);
      } else {
        _listCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _scrollToMessageId(String messageId) async {
    // إذا كانت الرسالة معروضة حاليًا: مرّر إليها
    Future<bool> tryScrollVisible() async {
      final key = _msgKeys[messageId];
      final ctx = key?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: .3,
        );
        return true;
      }
      return false;
    }

    if (await tryScrollVisible()) return;
    for (var i = 0; i < 6; i++) {
      await _chat?.loadMoreMessages(_convId);
      if (await tryScrollVisible()) return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('الرسالة خارج النطاق الحالي. مرّر للأعلى لتحميل المزيد.'),
      ));
    }
  }

  /*──────────────────── Send / Attachments / Actions ────────────────────*/

  Future<void> _pickImages({bool fromCamera = false}) async {
    if (!_chatAttachmentsEnabled) return;
    try {
      if (fromCamera) {
        final shot = await _picker.pickImage(
            source: ImageSource.camera, imageQuality: 90);
        if (shot != null) setState(() => _pickedImages.add(shot));
      } else {
        final files = await _picker.pickMultiImage(imageQuality: 90);
        if (files.isEmpty) return;
        setState(() => _pickedImages.addAll(files));
      }
    } catch (e) {
      _snack('تعذّر اختيار الصور: $e');
    }
  }

  Future<void> _pickFiles() async {
    if (!_chatAttachmentsEnabled) return;
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      final valid = result.files.where((f) => f.path != null).toList();
      if (valid.isEmpty) return;
      setState(() => _pickedFiles.addAll(valid));
    } catch (e) {
      _snack('تعذّر اختيار الملفات: $e');
    }
  }

  Future<void> _send() async {
    if (_sending) return;

    final text = _textCtrl.text.trim();
    final hasText = text.isNotEmpty;
    if (!_chatAttachmentsEnabled && _pickedImages.isNotEmpty) {
      _pickedImages.clear();
    }
    if (!_chatAttachmentsEnabled && _pickedFiles.isNotEmpty) {
      _pickedFiles.clear();
    }
    final hasImages = _chatAttachmentsEnabled && _pickedImages.isNotEmpty;
    final hasFiles = _chatAttachmentsEnabled && _pickedFiles.isNotEmpty;

    if (!hasText && !hasImages && !hasFiles) {
      _snack(_chatAttachmentsEnabled
          ? 'اكتب رسالة أو أرفق صورة/ملف.'
          : 'اكتب رسالة.');
      return;
    }

    final provider = context.read<ChatProvider>();
    final conv = provider.conversationById(_convId) ?? widget.conversation;
    final myRole = provider.myRoleForConversation(_convId);
    if ((conv.isFrozen || conv.adminsOnly) && !_isAdminRole(myRole)) {
      _snack('الدردشة مقفلة للمشرفين فقط.');
      return;
    }

    setState(() => _sending = true);
    try {
      if (hasText) {
        // لو لدينا ردّ، أضِف قصاصة بسيط أعلى النص (حل واجهة مؤقت)
        final finalText = _replySnippet == null
            ? text
            : '↩︎ ${_replySnippet!.length > 90 ? '${_replySnippet!.substring(0, 90)}…' : _replySnippet!}\n—\n$text';

        await _chat?.sendText(conversationId: _convId, text: finalText);
        _textCtrl.clear();
        _replySnippet = null;

        // Haptic بسيط للإرسال
        try {
          HapticFeedback.lightImpact();
        } catch (_) {}
      }
      if (hasImages) {
        final files = _pickedImages.map((x) => File(x.path)).toList();
        await _chat?.sendImages(conversationId: _convId, files: files);
        _pickedImages.clear();
        try {
          HapticFeedback.lightImpact();
        } catch (_) {}
      }
      if (hasFiles) {
        final files = _pickedFiles
            .map((x) => x.path == null ? null : File(x.path!))
            .whereType<File>()
            .toList();
        if (files.isNotEmpty) {
          await _chat?.sendFiles(conversationId: _convId, files: files);
        }
        _pickedFiles.clear();
        try {
          HapticFeedback.lightImpact();
        } catch (_) {}
      }

      // أطفئ حالة الكتابة محليًا
      _typingOffTimer?.cancel();
      context.read<ChatProvider>().setTyping(_convId, false);

      _chat?.markConversationRead(_convId);
      _scrollToBottom();
    } catch (e) {
      _snack('تعذّر الإرسال: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openMessageActions(ChatMessage m) async {
    final isMine = m.senderUid == _currentUid;
    final isText = m.kind == ChatMessageKind.text;
    final canEdit = isMine && isText && !m.deleted;

    await showMessageActionsSheet(
      context,
      message: m,
      myUid: _currentUid,
      onReply: (msg) {
        final raw = (msg.body ?? '').trim();
        setState(() => _replySnippet = raw.isEmpty
            ? (msg.kind == ChatMessageKind.image ? '📷 صورة' : '')
            : raw);
        FocusScope.of(context).requestFocus(_focusNode);
      },
      onMention: (msg) {
        // هنا نستخدم email الحقيقي من الرسالة، وليس اللابل المعروض في الفقاعة
        final email = (msg.senderEmail ?? '').trim();
        if (email.isEmpty) return;
        final cur = _textCtrl.text;
        _textCtrl.text = '$cur @$email ';
        _textCtrl.selection = TextSelection.fromPosition(
            TextPosition(offset: _textCtrl.text.length));
        FocusScope.of(context).requestFocus(_focusNode);
      },
      // تعديل/حذف عبر المزوّد
      onEdit: canEdit
          ? (msg) async {
              final newText = await _promptEditText(context, msg.body ?? '');
              if (newText == null) return;
              try {
                await context.read<ChatProvider>().editMessage(
                      messageId: msg.id,
                      newBody: newText,
                    );
              } catch (e) {
                _snack('تعذّر التعديل: $e');
              }
            }
          : null,
      onDelete: isMine
          ? (msg) async {
              final ok = await _confirmDelete(context);
              if (!ok) return;
              try {
                await context.read<ChatProvider>().deleteMessage(msg.id);
              } catch (e) {
                _snack('تعذّر الحذف: $e');
              }
            }
          : null,
      onReact: (msg, emoji) async {
        try {
          await ChatService.instance.toggleReaction(
            messageId: msg.id,
            emoji: emoji,
          );
        } catch (_) {
          // تجاهل
        }
      },
      onForward: (msg) => _forwardMessageFlow(msg),
      canEdit: canEdit,
      canDelete: isMine,
    );
  }

  Future<String?> _promptEditText(BuildContext context, String initial) async {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('تعديل الرسالة'),
          content: TextField(
            controller: c,
            maxLines: 5,
            minLines: 1,
            textDirection: td.textDirectionFor(c.text),
            onChanged: (_) => (ctx as Element).markNeedsBuild(),
            decoration: const InputDecoration(hintText: 'اكتب النص الجديد…'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, c.text.trim()),
                child: const Text('حفظ')),
          ],
        );
      },
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الرسالة'),
        content: const Text('هل تريد حذف هذه الرسالة للجميع؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    return res == true;
  }

  // ————— إعادة التوجيه (نصي/صور) دون كشف المصدر —————
  Future<void> _forwardMessageFlow(ChatMessage msg) async {
    final targets = await _pickForwardTargets();
    if (targets == null || targets.isEmpty) return;

    _showProgress();
    try {
      // نص تم تحويله (إن وجد)
      final rawTxt = _extractForwardText(msg);
      final hasText = rawTxt.isNotEmpty;

      // مرفقات (إن وُجدت)
      final atts = msg.attachments;
      if (!_chatAttachmentsEnabled && atts.isNotEmpty && !hasText) {
        if (mounted) {
          Navigator.of(context).maybePop();
          _snack('تم تعطيل إرسال المرفقات.');
        }
        return;
      }

      for (final conv in targets) {
        // أرسل نصًا (بعنوان صغير) إن وُجد
        if (hasText) {
          final body = '— تم تحويلها —\n$rawTxt';
          await context.read<ChatProvider>().sendText(
                conversationId: conv.id,
                text: body,
              );
        }

        // إن كانت هناك صور: نزّلها مؤقتًا ثم أعد رفعها كرسالة صور
        if (_chatAttachmentsEnabled && atts.isNotEmpty) {
          final files = <File>[];
          for (final a in atts) {
            var url = a.url.trim();
            if (url.isEmpty) {
              url = (a.signedUrl ?? '').trim();
            }
            if (url.isEmpty) continue;
            try {
              final tmp = await _downloadTempFile(url);
              files.add(tmp);
            } catch (_) {
              // ????? ???? ????? ?????
            }
          }
          if (files.isNotEmpty) {
            await context.read<ChatProvider>().sendImages(
                  conversationId: conv.id,
                  files: files,
                  optionalText: hasText ? null : '— تم تحويلها —',
                );
          }
        }
      }

      if (!mounted) return;
      Navigator.of(context).maybePop(); // إغلاق progress
      _snack('تمت إعادة التوجيه.');
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).maybePop();
      _snack('تعذّر إعادة التوجيه: $e');
    }
  }

  String _extractForwardText(ChatMessage msg) {
    final body = msg.body;
    if (body != null) {
      final trimmed = body.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return msg.text.trim();
  }

  Future<File> _downloadTempFile(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode}';
      }
      final bytes = await res.fold<List<int>>([], (p, e) {
        p.addAll(e);
        return p;
      });
      final dir = await Directory.systemTemp.createTemp('forward_');
      final name = Uri.parse(url).pathSegments.isNotEmpty
          ? Uri.parse(url).pathSegments.last.split('?').first
          : 'image.jpg';
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes, flush: true);
      return f;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<ChatConversation>?> _pickForwardTargets() async {
    final provider = context.read<ChatProvider>();
    final all = provider.conversations.where((c) => c.id != _convId).toList();

    final selected = <String>{};
    return showDialog<List<ChatConversation>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: const Text('إعادة توجيه إلى…'),
              content: SizedBox(
                width: 420,
                height: 420,
                child: ListView.builder(
                  itemCount: all.length,
                  itemBuilder: (_, i) {
                    final c = all[i];
                    final title = provider.displayTitleOf(c.id);
                    final checked = selected.contains(c.id);
                    return CheckboxListTile(
                      value: checked,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            selected.add(c.id);
                          } else {
                            selected.remove(c.id);
                          }
                        });
                      },
                      title: Text(title, overflow: TextOverflow.ellipsis),
                      secondary: Icon(
                        c.isGroup ? Icons.groups_rounded : Icons.person_rounded,
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          final chosen = all
                              .where((c) => selected.contains(c.id))
                              .toList();
                          Navigator.pop(ctx, chosen);
                        },
                  child: const Text('إرسال'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /*──────────────────── Helpers ────────────────────*/

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _isAdminRole(String? role) =>
      role != null && (role == 'owner' || role == 'admin');

  Future<void> _openGroupActions(ChatConversation conv) async {
    final provider = context.read<ChatProvider>();
    final myRole = provider.myRoleForConversation(_convId);
    final isAdmin = _isAdminRole(myRole);
    if (!isAdmin) {
      _snack('ليست لديك صلاحية إدارة المجموعة.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('تغيير اسم المجموعة'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _renameGroup(conv);
                },
              ),
              ListTile(
                leading: Icon(
                  conv.isFrozen
                      ? Icons.lock_open_rounded
                      : Icons.lock_rounded,
                ),
                title: Text(conv.isFrozen ? 'فتح الدردشة' : 'قفل الدردشة'),
                subtitle: const Text('عند القفل: الإرسال للمشرفين فقط'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _toggleGroupLock(conv);
                },
              ),
              ListTile(
                leading: const Icon(Icons.group_rounded),
                title: const Text('إدارة الأعضاء والمشرفين'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _manageGroupMembers(conv);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('حذف المجموعة'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _deleteGroup(conv);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameGroup(ChatConversation conv) async {
    final controller = TextEditingController(text: conv.title ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تغيير اسم المجموعة'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'اسم المجموعة'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return;
    try {
      await context.read<ChatProvider>().groupSetTitle(
            conversationId: _convId,
            title: result.trim(),
          );
    } catch (e) {
      _snack('تعذّر تغيير الاسم: $e');
    }
  }

  Future<void> _toggleGroupLock(ChatConversation conv) async {
    final isFrozen = !conv.isFrozen;
    try {
      await context.read<ChatProvider>().groupSetFrozen(
            conversationId: _convId,
            isFrozen: isFrozen,
            adminsOnly: isFrozen ? true : false,
          );
    } catch (e) {
      _snack('تعذّر تحديث القفل: $e');
    }
  }

  Future<void> _manageGroupMembers(ChatConversation conv) async {
    final provider = context.read<ChatProvider>();
    final myRole = provider.myRoleForConversation(_convId);
    final isOwner = myRole == 'owner';
    final isAdmin = _isAdminRole(myRole);
    final parts = provider.participantsOf(_convId);

    if (!isAdmin) {
      _snack('ليست لديك صلاحية إدارة الأعضاء.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: parts.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final p = parts[i];
                final name = (p.nickname?.trim().isNotEmpty == true)
                    ? p.nickname!
                    : (p.email?.trim().isNotEmpty == true
                        ? p.email!
                        : p.userUid);
                final roleLabel = p.role == 'owner'
                    ? 'المنشئ'
                    : (p.role == 'admin' ? 'مشرف' : 'عضو');
                final canManageRole = isOwner && p.role != 'owner';
                final canRemove =
                    isAdmin && p.role != 'owner' && p.userUid != _currentUid;

                return ListTile(
                  leading: const Icon(Icons.person_rounded),
                  title: Text(name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(roleLabel),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      if (canManageRole)
                        TextButton(
                          onPressed: () async {
                            final nextRole =
                                (p.role == 'admin') ? 'member' : 'admin';
                            try {
                              await provider.groupSetMemberRole(
                                conversationId: _convId,
                                targetUid: p.userUid,
                                role: nextRole,
                              );
                              _snack('تم تحديث الدور');
                            } catch (e) {
                              _snack('تعذّر تحديث الدور: $e');
                            }
                          },
                          child: Text(
                            p.role == 'admin' ? 'إلغاء مشرف' : 'ترقية مشرف',
                          ),
                        ),
                      if (canRemove)
                        TextButton(
                          onPressed: () async {
                            try {
                              await provider.groupRemoveMember(
                                conversationId: _convId,
                                targetUid: p.userUid,
                              );
                              _snack('تم حذف العضو');
                            } catch (e) {
                              _snack('تعذّر حذف العضو: $e');
                            }
                          },
                          child: const Text('حذف'),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteGroup(ChatConversation conv) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف المجموعة'),
          content: const Text('هل تريد حذف هذه المجموعة نهائيًا؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (confirm != true) return;
    try {
      await context.read<ChatProvider>().groupDelete(_convId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _snack('تعذّر حذف المجموعة: $e');
    }
  }

  void _showProgress() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }

  String _titleFor(ChatConversation c) {
    final t = (c.title ?? '').trim();
    if (t.isNotEmpty) return t;
    return c.isGroup ? 'مجموعة' : 'محادثة مباشرة';
  }

  // ✅ اسم المرسل في المجموعات: إن كان للمستخدم اسم محفوظ في المزوّد نستعمله، وإلا نعرض الإيميل (fallback).
  String _senderLabelFor(ChatMessage m) {
    final email = (m.senderEmail ?? '').trim();
    if (!widget.conversation.isGroup) return email;
    try {
      final names = context
          .read<ChatProvider>()
          .displayNamesForTyping(_convId, [m.senderUid]);
      final name = (names.isNotEmpty ? names.first : '').trim();
      return name.isNotEmpty ? name : email;
    } catch (_) {
      return email;
    }
  }

  Future<void> _loadDoctorContext() async {
    final uid = _currentUid;
    if (uid.isEmpty) return;
    try {
      final doctor = await DBService.instance.getDoctorByUserUid(uid);
      if (!mounted) return;
      setState(() => _doctorIdForSuggestions = doctor?.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _doctorIdForSuggestions = null);
    }
  }

  int _findTokenStart(String text, int cursor) {
    var i = cursor - 1;
    while (i >= 0) {
      final ch = text[i];
      if (ch.trim().isEmpty) break;
      i--;
    }
    return i + 1;
  }

  void _clearComposerSuggestions() {
    if (_suggestionKind == null && _suggestions.isEmpty) return;
    setState(() {
      _suggestionKind = null;
      _suggestionQuery = '';
      _loadingSuggestions = false;
      _suggestions.clear();
    });
  }

  Future<List<_ComposerSuggestion>> _loadPatientSuggestions(
    String query,
  ) async {
    final doctorId = _doctorIdForSuggestions;
    if (doctorId == null) return const [];
    final q = query.toLowerCase();
    final list = await DBService.instance.getAllPatients(doctorId: doctorId);
    list.sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
    final results = <_ComposerSuggestion>[];
    for (final p in list) {
      final name = p.name.trim();
      final phone = p.phoneNumber.trim();
      if (name.isEmpty && phone.isEmpty) continue;
      if (q.isNotEmpty) {
        final hay = '$name $phone'.toLowerCase();
        if (!hay.contains(q)) continue;
      }
      final insertText =
          phone.isNotEmpty ? '$name - $phone' : name;
      results.add(_ComposerSuggestion(
        label: name.isEmpty ? phone : name,
        subtitle: name.isNotEmpty && phone.isNotEmpty ? phone : null,
        insertText: insertText,
        icon: Icons.person,
      ));
      if (results.length >= 12) break;
    }
    return results;
  }

  Future<List<_ComposerSuggestion>> _loadServiceSuggestions(
    String query,
  ) async {
    final doctorId = _doctorIdForSuggestions;
    if (doctorId == null) return const [];
    final q = query.toLowerCase();
    final rows =
        await DBService.instance.getDoctorServiceCatalogWithPercents(doctorId);
    final results = <_ComposerSuggestion>[];
    for (final row in rows) {
      final name = (row['serviceName'] ?? row['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      if (q.isNotEmpty && !name.toLowerCase().contains(q)) continue;
      results.add(_ComposerSuggestion(
        label: name,
        insertText: '@$name',
        icon: Icons.medical_services_outlined,
      ));
      if (results.length >= 12) break;
    }
    return results;
  }

  void _updateComposerSuggestions() {
    if (!_focusNode.hasFocus) {
      _clearComposerSuggestions();
      return;
    }
    final cursor = _textCtrl.selection.baseOffset;
    if (cursor <= 0) {
      _clearComposerSuggestions();
      return;
    }
    final text = _textCtrl.text;
    final start = _findTokenStart(text, cursor);
    if (start >= cursor) {
      _clearComposerSuggestions();
      return;
    }
    final token = text.substring(start, cursor);
    if (token.isEmpty) {
      _clearComposerSuggestions();
      return;
    }

    _ComposerSuggestionKind? kind;
    String query = '';
    if (token.startsWith('/')) {
      kind = _ComposerSuggestionKind.patient;
      query = token.substring(1);
    } else if (token.startsWith('@')) {
      kind = _ComposerSuggestionKind.service;
      query = token.substring(1);
    } else {
      _clearComposerSuggestions();
      return;
    }

    if (_doctorIdForSuggestions == null) {
      _clearComposerSuggestions();
      return;
    }

    if (kind == _suggestionKind && query == _suggestionQuery) {
      return;
    }

    _suggestionDebounce?.cancel();
    setState(() {
      _suggestionKind = kind;
      _suggestionQuery = query;
      _loadingSuggestions = true;
    });
    _suggestionDebounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final results = kind == _ComposerSuggestionKind.patient
            ? await _loadPatientSuggestions(query)
            : await _loadServiceSuggestions(query);
        if (!mounted) return;
        setState(() {
          _suggestions
            ..clear()
            ..addAll(results);
          _loadingSuggestions = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _suggestions.clear();
          _loadingSuggestions = false;
        });
      }
    });
  }

  void _applySuggestion(_ComposerSuggestion s) {
    final cursor = _textCtrl.selection.baseOffset;
    if (cursor < 0) return;
    final text = _textCtrl.text;
    final start = _findTokenStart(text, cursor);
    final insert = '${s.insertText} ';
    final updated = text.replaceRange(start, cursor, insert);
    final newOffset = start + insert.length;
    _textCtrl.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    _clearComposerSuggestions();
  }

  Widget _buildSuggestionsPanel() {
    final scheme = Theme.of(context).colorScheme;
    final title = _suggestionKind == _ComposerSuggestionKind.patient
        ? 'مرضى الطبيب'
        : 'خدمات الطبيب';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outline.withValues(alpha: .3)),
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: .06),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 6),
          if (_loadingSuggestions)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else if (_suggestions.isEmpty)
            Text(
              'لا توجد نتائج مطابقة.',
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .6),
                fontSize: 12,
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 210),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _suggestions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final s = _suggestions[i];
                  return InkWell(
                    onTap: () => _applySuggestion(s),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 6),
                      child: Row(
                        children: [
                          Icon(s.icon, size: 18, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if ((s.subtitle ?? '').trim().isNotEmpty)
                                  Text(
                                    s.subtitle!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          scheme.onSurface.withValues(alpha: .6),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // ✅ تشغيل/إطفاء "يكتب..." + تمرير للأسفل عند الحاجة
  void _onTextChanged(String _) {
    if (mounted) setState(() {});
    context.read<ChatProvider>().setTyping(_convId, true);
    _typingOffTimer?.cancel();
    _typingOffTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      context.read<ChatProvider>().setTyping(_convId, false);
    });
    if (_isNearBottom()) {
      _scrollToBottom();
    }
    _updateComposerSuggestions();
  }

  // تهيئة Anchor للغير مقروء مرّة واحدة بعد وصول أول دفعة من المزوّد
  void _maybePrepareUnreadAnchorOnce() {
    if (_unreadAnchorMessageId != null) return;
    final providerMsgs = context.read<ChatProvider>().messagesOf(_convId);
    if (_initialUnread > 0 && providerMsgs.length >= _initialUnread) {
      // الرسائل مرتبة الأحدث أولًا — الـ anchor هو الرسالة رقم initialUnread-1
      final idx = _initialUnread - 1;
      _unreadAnchorMessageId = providerMsgs[idx].id;
    }
  }

  // تعليم كمقروء عند وصول رسالة جديدة من الآخر + عدّاد لو بعيد عن الأسفل
  Future<void> _autoReadNewestIfNeeded(List<ChatMessage> msgs) async {
    if (msgs.isEmpty) return;
    final newest = msgs.first;
    if (newest.id == _lastSeenNewestId) return;
    _lastSeenNewestId = newest.id;

    final fromMe = newest.senderUid == _currentUid;
    if (!fromMe) {
      if (_isNearBottom()) {
        _chat?.markConversationRead(_convId);
        _scrollToBottom();
      } else {
        setState(() =>
            _pendingNewWhileAway = (_pendingNewWhileAway + 1).clamp(0, 99));
      }
    }
  }

  // تنسيق عنوان فاصل اليوم
  String _dayLabel(DateTime utc) {
    final now = DateTime.now();
    final d = utc.toLocal();
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    final yesterday = DateTime(now.year, now.month, now.day - 1);
    if (sameDay(d, now)) return 'اليوم';
    if (sameDay(d, yesterday)) return 'أمس';
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}/$mm/$dd';
  }

  /*──────────────────── UI ────────────────────*/

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = context.watch<ChatProvider>();
    final conv = provider.conversationById(_convId) ?? widget.conversation;

    // أسماء الذين "يكتبون الآن" من المزوّد فقط
    final typingUids = provider.typingUids(_convId);
    final typingNames = provider.displayNamesForTyping(_convId, typingUids);

    final bgGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        scheme.surfaceContainerHighest.withValues(alpha: .40),
        scheme.surface.withValues(alpha: .95),
      ],
    );

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        extendBody: true,
        appBar: AppBar(
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          backgroundColor: Colors.transparent,
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.primary.withValues(alpha: .20),
                  scheme.surface.withValues(alpha: .00),
                ],
              ),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(18)),
            ),
          ),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.chat_bubble_outline_rounded, size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _titleFor(conv),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              if (typingNames.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  typingNames.length == 1
                      ? '${typingNames.first} يكتب…'
                      : '${typingNames.join('، ')} يكتبون…',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: .65),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (conv.isGroup)
              IconButton(
                icon: const Icon(Icons.settings_rounded),
                onPressed: () => _openGroupActions(conv),
                tooltip: 'إدارة المجموعة',
              ),
            IconButton(
              tooltip: 'بحث',
              icon: const Icon(Icons.search_rounded),
              onPressed: () async {
                final selId = await Navigator.of(context).push<String?>(
                  MaterialPageRoute(
                    builder: (_) => ChatSearchScreen(
                      conversationId: _convId,
                      title: _titleFor(conv),
                    ),
                  ),
                );
                if (selId != null && selId.isNotEmpty) {
                  await _scrollToMessageId(selId);
                }
              },
            ),
            if (_chatAttachmentsEnabled)
              IconButton(
                tooltip: 'المرفقات',
                onPressed: () async => _pickImages(),
                icon: const Icon(Icons.image_rounded),
              ),
            if (_chatAttachmentsEnabled)
              IconButton(
                tooltip: 'إرفاق ملف',
                onPressed: () async => _pickFiles(),
                icon: const Icon(Icons.attach_file_rounded),
              ),
          ],
        ),
        body: Container(
          decoration: BoxDecoration(gradient: bgGradient),
          child: SafeArea(
            child: Column(
              children: [
                // ---------- قائمة الرسائل ----------
                Expanded(
                  child: Selector<ChatProvider, List<ChatMessage>>(
                    selector: (_, p) => p.messagesOf(_convId),
                    shouldRebuild: (prev, next) => !identical(prev, next),
                    builder: (_, providerMsgs, __) {
                      // استخدم رسائل المزوّد إن توفّرت، وإلاّ اعرض التمهيد المحلي
                      final List<ChatMessage> msgs =
                          providerMsgs.isNotEmpty ? providerMsgs : _bootLocal;

                      // حضّر Anchor unread مرّة واحدة
                      _maybePrepareUnreadAnchorOnce();

                      // بعد البناء: افحص الأحدث لتعليم القراءة إن لزم
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _autoReadNewestIfNeeded(msgs);
                      });

                      return Stack(
                        children: [
                          if (msgs.isEmpty)
                            Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.chat_bubble_outline_rounded,
                                      size: 36, color: scheme.outline),
                                  const SizedBox(height: 10),
                                  Text(
                                    'لا توجد رسائل بعد',
                                    style: TextStyle(
                                      color: scheme.onSurface
                                          .withValues(alpha: .7),
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'ابدأ بكتابة رسالتك في الأسفل',
                                    style: TextStyle(
                                      color: scheme.onSurface
                                          .withValues(alpha: .55),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: scheme.surface.withValues(alpha: .55),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: ListView.builder(
                                  key: PageStorageKey<String>(
                                      'chat-room-list:${_convId}'),
                                  controller: _listCtrl,
                                  reverse: true,
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 12, 12, 12),
                                  itemCount: msgs.length + 1,
                                  itemBuilder: (_, index) {
                                    if (index == msgs.length) {
                                      return AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 150),
                                        child: _loadingMore
                                            ? Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 10),
                                                child: Center(
                                                  child: SizedBox(
                                                    width: 22,
                                                    height: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2.4,
                                                      color: scheme.primary,
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : const SizedBox.shrink(),
                                      );
                                    }

                                    final ChatMessage raw = msgs[index];
                                    final mine = raw.senderUid == _currentUid;

                                    final effectiveStatus = mine
                                        ? context
                                            .read<ChatProvider>()
                                            .computeStatusFor(_convId, raw)
                                        : raw.status;
                                    final m =
                                        raw.copyWith(status: effectiveStatus);

                                    // هل نضيف فاصل يوم قبل هذه الرسالة؟
                                    bool showDayDivider = false;
                                    String? dayLabel;
                                    if (index == msgs.length - 1) {
                                      showDayDivider = true;
                                      dayLabel = _dayLabel(m.createdAt);
                                    } else {
                                      final ChatMessage prevNewer =
                                          msgs[index + 1];
                                      if (prevNewer.createdAt.toLocal().day !=
                                              m.createdAt.toLocal().day ||
                                          prevNewer.createdAt.toLocal().month !=
                                              m.createdAt.toLocal().month ||
                                          prevNewer.createdAt.toLocal().year !=
                                              m.createdAt.toLocal().year) {
                                        showDayDivider = true;
                                        dayLabel = _dayLabel(m.createdAt);
                                      }
                                    }

                                    // فاصل "رسائل جديدة" عند Anchor (مرة واحدة)
                                    final isUnreadAnchor =
                                        (_unreadAnchorMessageId != null &&
                                            m.id == _unreadAnchorMessageId);

                                    // حدّ أقصى ~70–78% لعرض الفقاعة
                                    final screenW =
                                        MediaQuery.of(context).size.width;
                                    final maxBubbleW = screenW * 0.70;

                                    return Column(
                                      key: _keyForMessage(m.id),
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (showDayDivider &&
                                            (dayLabel?.isNotEmpty ?? false))
                                          _DayDivider(label: dayLabel!),
                                        if (isUnreadAnchor)
                                          const _NewMessagesDivider(),
                                        Container(
                                          margin: const EdgeInsets.symmetric(
                                              vertical: 2),
                                          child: Row(
                                            mainAxisAlignment: mine
                                                ? MainAxisAlignment
                                                    .start // RTL: start = يمين
                                                : MainAxisAlignment
                                                    .end, // RTL: end = يسار
                                            children: [
                                              ConstrainedBox(
                                                constraints: BoxConstraints(
                                                    maxWidth: maxBubbleW),
                                                child: MessageBubble(
                                                  message: m,
                                                  isMine: mine,
                                                  showSenderHeader: !mine &&
                                                      widget
                                                          .conversation.isGroup,
                                                  senderEmail:
                                                      _senderLabelFor(m),
                                                  onOpenImage: (url) {
                                                    if (url.isEmpty) return;
                                                    ImageViewerScreen
                                                        .pushSingle(
                                                      context,
                                                      imageUrl: url,
                                                      heroTag: m.id,
                                                    );
                                                  },
                                                  onLongPress: () =>
                                                      _openMessageActions(m),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),

                          // مؤشر "يكتب..." سفلي
                          if (typingNames.isNotEmpty)
                            Positioned(
                              left: 12,
                              right: 12,
                              bottom: 6,
                              child: Align(
                                alignment: Alignment.center,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color:
                                        scheme.surface.withValues(alpha: .55),
                                    borderRadius: BorderRadius.circular(14),
                                    boxShadow: [
                                      BoxShadow(
                                        blurRadius: 10,
                                        color:
                                            Colors.black.withValues(alpha: .06),
                                      )
                                    ],
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    child: TypingIndicator(
                                        participants: typingNames),
                                  ),
                                ),
                              ),
                            ),

                          // زر عائم “إلى الأسفل” مع عدّاد
                          if (_showJumpToBottom)
                            Positioned(
                              right: 16,
                              bottom: 100,
                              child: _JumpToBottomFab(
                                count: _pendingNewWhileAway,
                                onTap: () => _scrollToBottom(),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),

                // ---------- معاينة المرفقات المختارة ----------
                if (_chatAttachmentsEnabled && _pickedImages.isNotEmpty)
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      scrollDirection: Axis.horizontal,
                      itemCount: _pickedImages.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final double w =
                            (MediaQuery.of(context).size.width * 0.8)
                                .clamp(240.0, 360.0)
                                .toDouble();
                        final x = _pickedImages[i];
                        final f = File(x.path);
                        return SizedBox(
                          width: w,
                          child: AttachmentChip(
                            status: AttachmentUploadStatus.queued,
                            file: f,
                            name: x.name,
                            onRemove: () =>
                                setState(() => _pickedImages.removeAt(i)),
                            compact: true,
                          ),
                        );
                      },
                    ),
                  ),
                if (_chatAttachmentsEnabled && _pickedFiles.isNotEmpty)
                  SizedBox(
                    height: 80,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      scrollDirection: Axis.horizontal,
                      itemCount: _pickedFiles.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final f = _pickedFiles[i];
                        return _FileAttachmentChip(
                          name: f.name,
                          sizeBytes: f.size,
                          onRemove: () =>
                              setState(() => _pickedFiles.removeAt(i)),
                        );
                      },
                    ),
                  ),

                // ---------- شريط الكتابة + Reply Preview ----------
                if (_suggestionKind != null)
                  _buildSuggestionsPanel(),

                if ((_replySnippet ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: .06),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Theme.of(context).dividerColor),
                            ),
                            child: Text(
                              _replySnippet!.length > 140
                                  ? '${_replySnippet!.substring(0, 140)}…'
                                  : _replySnippet!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'إلغاء الرد',
                          onPressed: _clearReply,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),

                _ComposerBar(
                  textCtrl: _textCtrl,
                  focusNode: _focusNode,
                  sending: _sending,
                  onChanged: _onTextChanged,
                  attachmentsEnabled: _chatAttachmentsEnabled,
                  onAttachImages: () async {
                    // ضغطة قصيرة: الاستديو، ضغطة مطوّلة: الكاميرا
                    await _pickImages();
                  },
                  onAttachImagesLong: () async {
                    await _pickImages(fromCamera: true);
                  },
                  onAttachFiles: () async {
                    await _pickFiles();
                  },
                  onSend: _send,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/*──────────────────── عناصر تصميم إضافية ───────────────────*/

enum _ComposerSuggestionKind { patient, service }

class _ComposerSuggestion {
  final String label;
  final String insertText;
  final String? subtitle;
  final IconData icon;

  const _ComposerSuggestion({
    required this.label,
    required this.insertText,
    required this.icon,
    this.subtitle,
  });
}

class _FileAttachmentChip extends StatelessWidget {
  final String name;
  final int sizeBytes;
  final VoidCallback onRemove;

  const _FileAttachmentChip({
    required this.name,
    required this.sizeBytes,
    required this.onRemove,
  });

  String _fmtBytes(int b) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double s = b.toDouble();
    int i = 0;
    while (s >= 1024 && i < units.length - 1) {
      s /= 1024;
      i++;
    }
    return '${s.toStringAsFixed(s >= 100 || i == 0 ? 0 : (s >= 10 ? 1 : 2))} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file_rounded,
              color: scheme.primary, size: 28),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  _fmtBytes(sizeBytes),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurface.withValues(alpha: .6),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'إزالة',
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

class _DayDivider extends StatelessWidget {
  final String label;
  const _DayDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider(height: 1)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.surface.withValues(alpha: .75),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  blurRadius: 10,
                  color: Colors.black.withValues(alpha: .05),
                ),
              ],
            ),
            child: Text(
              label,
              style: TextStyle(
                color: c.onSurface.withValues(alpha: .75),
                fontWeight: FontWeight.w800,
                fontSize: 11.5,
              ),
            ),
          ),
          const Expanded(child: Divider(height: 1)),
        ],
      ),
    );
  }
}

class _NewMessagesDivider extends StatelessWidget {
  const _NewMessagesDivider();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.primary.withValues(alpha: .35)),
          ),
          child: Text(
            'رسائل جديدة',
            style: TextStyle(
              color: c.primary,
              fontWeight: FontWeight.w900,
              fontSize: 11.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _JumpToBottomFab extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _JumpToBottomFab({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Material(
      color: c.primary,
      borderRadius: BorderRadius.circular(28),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.keyboard_double_arrow_down_rounded,
                  color: Colors.white),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .20),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/*──────────────────── Composer Bar (Glass) ───────────────────*/
class _ComposerBar extends StatelessWidget {
  final TextEditingController textCtrl;
  final FocusNode focusNode;
  final bool sending;
  final ValueChanged<String> onChanged;
  final bool attachmentsEnabled;
  final VoidCallback onAttachImages;
  final VoidCallback? onAttachImagesLong;
  final VoidCallback onAttachFiles;
  final VoidCallback onSend;

  const _ComposerBar({
    required this.textCtrl,
    required this.focusNode,
    required this.sending,
    required this.onChanged,
    required this.attachmentsEnabled,
    required this.onAttachImages,
    this.onAttachImagesLong,
    required this.onAttachFiles,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            if (attachmentsEnabled) ...[
              // زر إرفاق داخل بطاقة زجاجية (ضغط مطوّل = كاميرا)
              Container(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: GestureDetector(
                  onLongPress: sending ? null : onAttachImagesLong,
                  child: IconButton(
                    icon: const Icon(Icons.image_rounded),
                    tooltip: 'إرفاق صورة (اضغط مطولًا للكاميرا)',
                    onPressed: sending ? null : onAttachImages,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: IconButton(
                  icon: const Icon(Icons.attach_file_rounded),
                  tooltip: 'إرفاق ملف',
                  onPressed: sending ? null : onAttachFiles,
                ),
              ),
              const SizedBox(width: 8),
            ],

            // حقل الإدخال (زجاجي)
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: .65),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                      color: Colors.black.withValues(alpha: .07),
                    ),
                  ],
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: TextField(
                  controller: textCtrl,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 6,
                  onChanged: onChanged,
                  textDirection: td.textDirectionFor(textCtrl.text),
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'اكتب رسالة...',
                  ),
                  onSubmitted: (_) => FocusScope.of(context).unfocus(),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // زر إرسال (نيومورفك)
            NeuButton.primary(
              icon: Icons.send_rounded,
              label: '',
              onPressed: sending ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}
