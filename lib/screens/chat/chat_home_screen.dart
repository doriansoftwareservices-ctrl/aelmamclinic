// lib/screens/chat/chat_home_screen.dart
//
// الشاشة الرئيسية للمحادثات للمستخدم النهائي. تعتمد على ChatProvider
// لجلب المحادثات وعرضها مع دعم البحث وتصفية الرسائل غير المقروءة.

import 'dart:async';
import 'dart:ui' as ui show TextDirection;

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/chat_provider.dart';
import 'package:aelmamclinic/widgets/chat/conversation_tile.dart';
import 'package:aelmamclinic/utils/chat_code_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'chat_room_screen.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class ChatHomeScreen extends StatefulWidget {
  const ChatHomeScreen({super.key});

  static const String routeName = '/chat/home';

  @override
  State<ChatHomeScreen> createState() => _ChatHomeScreenState();
}

class _ChatHomeScreenState extends State<ChatHomeScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  bool _unreadOnly = false;
  bool _archivedOnly = false;
  String? _openingConversationId;
  String? _selectedConversationId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureBootstrap());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _ensureBootstrap() async {
    final chat = context.read<ChatProvider>();
    if (chat.busy) return;
    final auth = context.read<AuthProvider>();
    await chat.ensureBootstrapped(
      accountId: auth.accountId,
      role: auth.role,
      isSuperAdmin: auth.isSuperAdmin,
    );
    if (!mounted) return;
    final isOwner = auth.role?.toLowerCase() == 'owner';
    if (isOwner) {
      await chat.ensureSupportConversation();
      if (!mounted) return;
      await chat.refreshConversations();
    } else if (chat.conversations.isEmpty) {
      await chat.refreshConversations();
    }
  }

  Future<void> _refresh() async {
    FocusScope.of(context).unfocus();
    await context.read<ChatProvider>().refreshConversations();
  }

  Future<void> _openSupportChat() async {
    final auth = context.read<AuthProvider>();
    final isOwner = auth.role?.toLowerCase() == 'owner';
    if (!isOwner) return;
    final chat = context.read<ChatProvider>();
    await chat.ensureSupportConversation(force: true);
    final convId = chat.supportConversationId;
    if (convId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('خدمة العملاء غير مفعّلة بعد.')),
      );
      return;
    }
    if (!mounted) return;
    final conv = chat.conversationById(convId);
    if (conv == null) {
      await chat.refreshConversations();
    }
    final resolved = chat.conversationById(convId);
    if (resolved == null || !mounted) return;
    final isWide = MediaQuery.of(context).size.width >= 1000;
    if (isWide) {
      setState(() => _selectedConversationId = resolved.id);
      await chat.openConversation(resolved.id);
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(conversation: resolved),
        ),
      );
      if (!mounted) return;
      await chat.refreshConversations();
    }
  }

  ChatMessage? _latestMessageFor(ChatProvider chat, String conversationId) {
    if (chat.openedConversationId != conversationId) return null;
    final list = chat.messagesOf(conversationId);
    if (list.isEmpty) return null;
    return list.first;
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final auth = context.watch<AuthProvider>();
    final convs = chat.conversations;
    final query = _query.trim().toLowerCase();
    final qDigits = ChatCodeUtils.normalize(query);

    final filtered = convs.where((conv) {
      if (_unreadOnly && (conv.unreadCount ?? 0) == 0) {
        return false;
      }
      if (_archivedOnly && !chat.isConversationArchived(conv.id)) {
        return false;
      }
      if (!_archivedOnly && chat.isConversationArchived(conv.id)) {
        return false;
      }
      if (query.isEmpty) return true;
      final titleRaw = chat.displayTitleOf(conv.id);
      final title = titleRaw.toLowerCase();
      final titleDigits = ChatCodeUtils.normalize(titleRaw);
      final parts = chat.participantsOf(conv.id);
      final partsHay = parts
          .map((p) => chat.displayForParticipant(conv.id, p.userUid))
          .join(' ')
          .toLowerCase();
      return title.contains(query) ||
          partsHay.contains(query) ||
          (qDigits.isNotEmpty && titleDigits.contains(qDigits));
    }).toList()
      ..sort((a, b) {
        final aTime = a.lastMsgAt ?? a.updatedAt ?? a.createdAt;
        final bTime = b.lastMsgAt ?? b.updatedAt ?? b.createdAt;
        return bTime.compareTo(aTime);
      });
    final supportId = chat.supportConversationId;
    if (supportId != null) {
      final idx = filtered.indexWhere((c) => c.id == supportId);
      if (idx > 0) {
        final item = filtered.removeAt(idx);
        filtered.insert(0, item);
      }
    }

    final isBusy = chat.busy && !chat.ready;
    final isRefreshing = chat.busy && chat.ready;
    final isWide = MediaQuery.of(context).size.width >= 1000;
    final selectedConvId = _selectedConversationId;

    final listBody = RefreshIndicator(
      color: kPrimaryColor,
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (value) {
                        _searchDebounce?.cancel();
                        _searchDebounce = Timer(
                          const Duration(milliseconds: 220),
                          () {
                            if (!mounted) return;
                            setState(() => _query = value);
                          },
                        );
                      },
                      decoration: InputDecoration(
                        hintText: context.trRaw('ابحث بالرقم أو البريد'),
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _query = '');
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                        border: const OutlineInputBorder(),
                      ),
                      textDirection: Directionality.of(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const LocalizedText('غير المقروءة'),
                    avatar: const Icon(
                      Icons.mark_chat_unread_rounded,
                      size: 18,
                    ),
                    selected: _unreadOnly,
                    onSelected: (value) => setState(() => _unreadOnly = value),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const LocalizedText('المؤرشفة'),
                    avatar: const Icon(Icons.archive_rounded, size: 18),
                    selected: _archivedOnly,
                    onSelected: (value) async {
                      setState(() => _archivedOnly = value);
                      await chat.refreshConversations();
                    },
                  ),
                ],
              ),
            ),
          ),
          if (isRefreshing)
            const SliverToBoxAdapter(
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (isBusy)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (filtered.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: LocalizedText('لا توجد محادثات متاحة.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final conversation = filtered[index];
                    final displayTitleRaw =
                        chat.displayTitleOf(conversation.id);
                    final displayTitle =
                        ChatCodeUtils.isChatCode(displayTitleRaw)
                            ? ChatCodeUtils.format(displayTitleRaw)
                            : displayTitleRaw;
                    final isSupport =
                        chat.isSupportConversation(conversation.id);
                    final typing = chat.typingUids(conversation.id);
                    final lastMessage =
                        _latestMessageFor(chat, conversation.id);
                    final subtitleOverride =
                        typing.isNotEmpty ? 'جارٍ الكتابة...' : null;
                    final isOpen = chat.openedConversationId == conversation.id;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ConversationTile(
                        conversation: conversation,
                        titleOverride:
                            isSupport ? chat.supportDisplayName : displayTitle,
                        leadingImageAsset:
                            isSupport ? 'assets/images/support icon.png' : null,
                        leadingIcon: isSupport ? null : null,
                        subtitleOverride: subtitleOverride,
                        subtitleIsTyping: typing.isNotEmpty,
                        lastMessage: lastMessage,
                        unreadCount: conversation.unreadCount ?? 0,
                        clinicLabel: null,
                        isMuted: false,
                        isOnline: null,
                        showChevron: !isOpen,
                        onTap: () {
                          if (isWide) {
                            setState(() =>
                                _selectedConversationId = conversation.id);
                            chat.openConversation(conversation.id);
                          } else {
                            _openConversation(conversation.id);
                          }
                        },
                        onLongPress: () => _showConversationActions(
                          context,
                          conversation,
                        ),
                      ),
                    );
                  },
                  childCount: filtered.length,
                ),
              ),
            ),
        ],
      ),
    );

    Widget buildHeader() {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            bottom:
                BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: context.trRaw('رجوع'),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const Icon(Icons.chat_rounded),
            const SizedBox(width: 8),
            const Expanded(
              child: LocalizedText('المحادثات',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (auth.role?.toLowerCase() == 'owner')
              IconButton(
                tooltip: context.trRaw('خدمة العملاء'),
                onPressed: _openSupportChat,
                icon: const Icon(Icons.support_agent_rounded),
              ),
            IconButton(
              tooltip: context.trRaw('تحديث'),
              onPressed: chat.busy ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      );
    }

    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        appBar: isWide
            ? null
            : AppBar(
                title: const LocalizedText('المحادثات'),
                actions: [
                  if (auth.role?.toLowerCase() == 'owner')
                    IconButton(
                      tooltip: context.trRaw('خدمة العملاء'),
                      onPressed: _openSupportChat,
                      icon: const Icon(Icons.support_agent_rounded),
                    ),
                  IconButton(
                    tooltip: context.trRaw('تحديث'),
                    onPressed: chat.busy ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
        floatingActionButton: isWide
            ? null
            : FloatingActionButton(
                onPressed: () => _showNewConversationDialog(context),
                tooltip: context.trRaw('بدء محادثة جديدة'),
                child: const Icon(Icons.chat_rounded),
              ),
        body: SafeArea(
          child: isWide
              ? Row(
                  children: [
                    SizedBox(
                      width: MediaQuery.of(context).size.width * 0.40,
                      child: Column(
                        children: [
                          buildHeader(),
                          Expanded(
                            child: Stack(
                              children: [
                                listBody,
                                Positioned(
                                  left: 16,
                                  bottom: 16,
                                  child: FloatingActionButton(
                                    onPressed: () =>
                                        _showNewConversationDialog(context),
                                    tooltip: context.trRaw('بدء محادثة جديدة'),
                                    child: const Icon(Icons.chat_rounded),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: () {
                        if (selectedConvId == null) {
                          final scheme = Theme.of(context).colorScheme;
                          return Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  const Color(0xFFF2F6F9),
                                  scheme.surface.withValues(alpha: .98),
                                ],
                              ),
                              image: const DecorationImage(
                                image: AssetImage('assets/images/buck.png'),
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                              ),
                            ),
                            child: Center(
                              child: LocalizedText('اختر محادثة لعرضها هنا.',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface.withValues(alpha: .6),
                                ),
                              ),
                            ),
                          );
                        }
                        final conv = chat.conversationById(selectedConvId);
                        if (conv == null) {
                          return Center(
                            child: LocalizedText('اختر محادثة لعرضها هنا.',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: .6),
                              ),
                            ),
                          );
                        }
                        return ChatRoomScreen(
                          conversation: conv,
                          embedded: true,
                        );
                      }(),
                    ),
                  ],
                )
              : listBody,
        ),
      ),
    );
  }

  Future<void> _showAliasDialog(ChatConversation conversation) async {
    final chat = context.read<ChatProvider>();
    final initial = chat.aliasForConversation(conversation.id) ?? '';
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          title: const LocalizedText('تحديد اسم بديل'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: context.trRaw('اكتب الاسم الذي تريد إظهاره'),
            ),
            textDirection: Directionality.of(context),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const LocalizedText('إلغاء'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const LocalizedText('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final trimmed = result.trim();
    if (trimmed == initial.trim()) return;
    await chat.updateConversationAlias(
      conversationId: conversation.id,
      alias: trimmed,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: LocalizedText(
          trimmed.isEmpty ? 'تم إزالة الاسم البديل' : 'تم تحديث الاسم البديل',
        ),
      ),
    );
  }

  Future<void> _openConversation(String conversationId) async {
    if (_openingConversationId != null) return;
    _openingConversationId = conversationId;
    final chat = context.read<ChatProvider>();
    try {
      await chat.openConversation(conversationId);
      await chat.markConversationRead(conversationId);
      if (!mounted) return;
      final conversation = chat.conversations.firstWhere(
        (c) => c.id == conversationId,
        orElse: () => chat.conversations.first,
      );
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(conversation: conversation),
        ),
      );
      if (!mounted) return;
      await chat.refreshConversations();
    } finally {
      if (mounted && _openingConversationId == conversationId) {
        setState(() => _openingConversationId = null);
      } else {
        _openingConversationId = null;
      }
    }
  }

  Future<void> _showConversationActions(
    BuildContext context,
    ChatConversation conversation,
  ) async {
    final chat = context.read<ChatProvider>();
    final isDirect = !conversation.isGroup;
    final alias = isDirect ? chat.aliasForConversation(conversation.id) : null;
    final archived = chat.isConversationArchived(conversation.id);

    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => Directionality(
        textDirection: Directionality.of(context),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.visibility_rounded),
                title: const LocalizedText('عرض المحادثة'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openConversation(conversation.id);
                },
              ),
              if (isDirect)
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const LocalizedText('تعديل الاسم البديل'),
                  subtitle: (alias != null && alias.isNotEmpty)
                      ? LocalizedText('الاسم الحالي: $alias')
                      : const LocalizedText('سيظهر البريد الأصلي إذا تُرك الحقل فارغاً'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _showAliasDialog(conversation);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.mark_email_read_rounded),
                title: const LocalizedText('تعيين كمقروء'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await chat.markConversationRead(conversation.id);
                },
              ),
              ListTile(
                leading: Icon(
                  archived ? Icons.unarchive_rounded : Icons.archive_rounded,
                ),
                title: Text(archived ? 'إلغاء الأرشفة' : 'أرشفة المحادثة'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await chat.setConversationArchived(
                    conversation.id,
                    archived: !archived,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const LocalizedText('حذف المحادثة من جهازي'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await chat.deleteConversationForMe(conversation.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showNewConversationDialog(BuildContext context) async {
    final inputCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          title: const LocalizedText('بدء محادثة جديدة'),
          content: TextField(
            controller: inputCtrl,
            keyboardType: TextInputType.emailAddress,
            inputFormatters: [
              TextInputFormatter.withFunction((oldValue, newValue) {
                final text = newValue.text;
                if (text.contains('@')) return newValue;
                final digits = ChatCodeUtils.normalize(text);
                return newValue.copyWith(
                  text: digits,
                  selection: TextSelection.collapsed(offset: digits.length),
                );
              }),
            ],
            decoration: InputDecoration(
              hintText: context.trRaw('أدخل رقم الحساب لبدء دردشة معه'),
            ),
            textDirection: ui.TextDirection.ltr,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const LocalizedText('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).pop(inputCtrl.text.trim().toLowerCase()),
              child: const LocalizedText('بدء'),
            ),
          ],
        ),
      ),
    );

    if (result == null || result.isEmpty) {
      return;
    }

    try {
      final chat = context.read<ChatProvider>();
      final normalized =
          result.contains('@') ? result : ChatCodeUtils.normalize(result);
      final conversation = await chat.startDirectByEmail(normalized);
      await chat.openConversation(conversation.id);
      await chat.markConversationRead(conversation.id);
      if (!mounted) return;
      final isWide = MediaQuery.of(context).size.width >= 1000;
      if (isWide) {
        setState(() => _selectedConversationId = conversation.id);
      } else {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatRoomScreen(conversation: conversation),
          ),
        );
        await chat.refreshConversations();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: LocalizedText('تعذر إنشاء المحادثة: $e')));
    } finally {
      inputCtrl.dispose();
    }
  }
}
