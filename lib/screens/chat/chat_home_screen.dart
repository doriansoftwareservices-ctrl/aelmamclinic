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
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'chat_room_screen.dart';

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
  String? _openingConversationId;

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
    if (chat.ready || chat.busy) return;
    final auth = context.read<AuthProvider>();
    await chat.bootstrap(
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
    if (convId == null || !mounted) return;
    final conv = chat.conversationById(convId);
    if (conv == null) {
      await chat.refreshConversations();
    }
    final resolved = chat.conversationById(convId);
    if (resolved == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(conversation: resolved),
      ),
    );
    if (!mounted) return;
    await chat.refreshConversations();
  }

  ChatMessage? _latestMessageFor(ChatProvider chat, String conversationId) {
    final list = chat.messagesOf(conversationId);
    if (list.isEmpty) return null;
    var latest = list.first;
    for (final m in list) {
      if (m.createdAt.isAfter(latest.createdAt)) {
        latest = m;
      }
    }
    return latest;
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final auth = context.watch<AuthProvider>();
    final convs = chat.conversations;
    final query = _query.trim().toLowerCase();

    final filtered = convs.where((conv) {
      if (_unreadOnly && (conv.unreadCount ?? 0) == 0) {
        return false;
      }
      if (query.isEmpty) return true;
      final title = chat.displayTitleOf(conv.id).toLowerCase();
      final snippet = (conv.lastMsgSnippet ?? '').toLowerCase();
      return title.contains(query) || snippet.contains(query);
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

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المحادثات'),
          actions: [
            if (auth.role?.toLowerCase() == 'owner')
              IconButton(
                tooltip: 'خدمة العملاء',
                onPressed: _openSupportChat,
                icon: const Icon(Icons.support_agent_rounded),
              ),
            IconButton(
              tooltip: 'تحديث',
              onPressed: chat.busy ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _showNewConversationDialog(context),
          tooltip: 'بدء محادثة جديدة',
          child: const Icon(Icons.chat_rounded),
        ),
        body: SafeArea(
          child: RefreshIndicator(
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
                              hintText: 'ابحث باسم الشخص أو محتوى الرسائل',
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
                            textDirection: ui.TextDirection.rtl,
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('غير المقروءة'),
                          avatar: const Icon(
                            Icons.mark_chat_unread_rounded,
                            size: 18,
                          ),
                          selected: _unreadOnly,
                          onSelected: (value) =>
                              setState(() => _unreadOnly = value),
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
                      child: Text(
                        'لا توجد محادثات متاحة.',
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
                          final displayTitle = chat.displayTitleOf(
                            conversation.id,
                          );
                          final isSupport =
                              chat.isSupportConversation(conversation.id);
                          final typing = chat.typingUids(conversation.id);
                          final lastMessage =
                              _latestMessageFor(chat, conversation.id);
                          final subtitleOverride =
                              typing.isNotEmpty ? 'جارٍ الكتابة...' : null;
                          final isOpen =
                              chat.openedConversationId == conversation.id;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ConversationTile(
                              conversation: conversation,
                              titleOverride: isSupport
                                  ? chat.supportDisplayName
                                  : displayTitle,
                              leadingIcon: isSupport
                                  ? Icons.support_agent_rounded
                                  : null,
                              subtitleOverride: subtitleOverride,
                              subtitleIsTyping: typing.isNotEmpty,
                              lastMessage: lastMessage,
                              unreadCount: conversation.unreadCount ?? 0,
                              clinicLabel: null,
                              isMuted: false,
                              isOnline: null,
                              showChevron: !isOpen,
                              onTap: () => _openConversation(conversation.id),
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
          ),
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
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تحديد اسم بديل'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'اكتب الاسم الذي تريد إظهاره',
            ),
            textDirection: ui.TextDirection.rtl,
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
        content: Text(
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
        textDirection: ui.TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.visibility_rounded),
                title: const Text('عرض المحادثة'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openConversation(conversation.id);
                },
              ),
              if (isDirect)
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('تعديل الاسم البديل'),
                  subtitle: (alias != null && alias.isNotEmpty)
                      ? Text('الاسم الحالي: $alias')
                      : const Text('سيظهر البريد الأصلي إذا تُرك الحقل فارغاً'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _showAliasDialog(conversation);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.mark_email_read_rounded),
                title: const Text('تعيين كمقروء'),
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
                title: const Text('حذف المحادثة من جهازي'),
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
    final emailCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('بدء محادثة جديدة'),
          content: TextField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              hintText: 'أدخل البريد الإلكتروني',
            ),
            textDirection: ui.TextDirection.ltr,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).pop(emailCtrl.text.trim().toLowerCase()),
              child: const Text('بدء'),
            ),
          ],
        ),
      ),
    );

    if (result == null || result.isEmpty) {
      emailCtrl.dispose();
      return;
    }

    try {
      final chat = context.read<ChatProvider>();
      final conversation = await chat.startDirectByEmail(result);
      await chat.openConversation(conversation.id);
      await chat.markConversationRead(conversation.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(conversation: conversation),
        ),
      );
      await chat.refreshConversations();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر إنشاء المحادثة: $e')));
    } finally {
      emailCtrl.dispose();
    }
  }
}
