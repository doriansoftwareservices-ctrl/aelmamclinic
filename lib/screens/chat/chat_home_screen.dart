// lib/screens/chat/chat_home_screen.dart
//
// الشاشة الرئيسية للمحادثات للمستخدم النهائي. تعتمد على ChatProvider
// لجلب المحادثات وعرضها مع دعم البحث وتصفية الرسائل غير المقروءة.

import 'dart:ui' as ui show TextDirection;

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_invitation.dart';
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

enum _NewConversationMode {
  direct,
  group,
}

class _ChatHomeScreenState extends State<ChatHomeScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _unreadOnly = false;
  String? _processingInvitationId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureBootstrap());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _ensureBootstrap() {
    final chat = context.read<ChatProvider>();
    if (chat.ready || chat.busy) return;
    final auth = context.read<AuthProvider>();
    chat.bootstrap(
      accountId: auth.accountId,
      role: auth.role,
      isSuperAdmin: auth.isSuperAdmin,
    );
  }

  Future<void> _refresh() async {
    await context.read<ChatProvider>().refreshConversations();
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final convs = chat.conversations;
    final invites = chat.invitations;
    final query = _searchCtrl.text.trim().toLowerCase();

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

    final isBusy = chat.busy && !chat.ready;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المحادثات'),
          actions: [
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
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'ابحث باسم الشخص أو محتوى الرسائل',
                          prefixIcon: Icon(Icons.search_rounded),
                          border: OutlineInputBorder(),
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
              if (invites.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          'دعوات المجموعات',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...invites.map(
                        (inv) => _InvitationCard(
                          invitation: inv,
                          busy: _processingInvitationId == inv.id,
                          onAccept: () => _onAcceptInvitation(inv),
                          onDecline: () => _onDeclineInvitation(inv),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: RefreshIndicator(
                  color: kPrimaryColor,
                  onRefresh: _refresh,
                  child: Builder(
                    builder: (_) {
                      if (isBusy) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (filtered.isEmpty) {
                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            Center(
                              child: Text(
                                'لا توجد محادثات متاحة.',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        );
                      }

                      return ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
                        itemBuilder: (context, index) {
                          final conversation = filtered[index];
                          final displayTitle = chat.displayTitleOf(
                            conversation.id,
                          );
                          final snippet = conversation.lastMsgSnippet ?? '';
                          final typing = chat.typingUids(conversation.id);
                          final subtitleOverride = typing.isNotEmpty
                              ? 'جارٍ الكتابة...'
                              : (snippet.trim().isEmpty
                                  ? 'لا توجد رسائل بعد'
                                  : snippet.trim());

                          return ConversationTile(
                            conversation: conversation,
                            titleOverride: displayTitle,
                            subtitleOverride: subtitleOverride,
                            subtitleIsTyping: typing.isNotEmpty,
                            unreadCount: conversation.unreadCount ?? 0,
                            clinicLabel: null,
                            isMuted: false,
                            isOnline: null,
                            showChevron: true,
                            onTap: () => _openConversation(conversation.id),
                            onLongPress: () =>
                                _showConversationActions(context, conversation),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onAcceptInvitation(ChatGroupInvitation invitation) async {
    if (_processingInvitationId != null) return;
    setState(() => _processingInvitationId = invitation.id);
    final chat = context.read<ChatProvider>();
    try {
      await chat.acceptGroupInvitation(invitation.id);
      if (!mounted) return;
      await _openConversation(invitation.conversationId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر قبول الدعوة: $e')));
      }
    } finally {
      if (mounted) setState(() => _processingInvitationId = null);
    }
  }

  Future<void> _onDeclineInvitation(ChatGroupInvitation invitation) async {
    if (_processingInvitationId != null) return;
    setState(() => _processingInvitationId = invitation.id);
    try {
      await context.read<ChatProvider>().declineGroupInvitation(invitation.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم رفض الدعوة')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر رفض الدعوة: $e')));
      }
    } finally {
      if (mounted) setState(() => _processingInvitationId = null);
    }
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
    final chat = context.read<ChatProvider>();
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
  }

  Future<void> _showConversationActions(
    BuildContext context,
    ChatConversation conversation,
  ) async {
    final chat = context.read<ChatProvider>();
    final isDirect = !conversation.isGroup;
    final alias = isDirect ? chat.aliasForConversation(conversation.id) : null;

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
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showNewConversationDialog(BuildContext context) async {
    final mode = await showDialog<_NewConversationMode>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('بدء محادثة جديدة'),
          content: const Text('اختر نوع المحادثة'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_NewConversationMode.direct),
              child: const Text('محادثة مباشرة'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_NewConversationMode.group),
              child: const Text('مجموعة'),
            ),
          ],
        ),
      ),
    );

    if (mode == null) return;

    if (mode == _NewConversationMode.direct) {
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
        final conversation = await chat.startDirectByEmail(
          result,
        ); // will schedule refresh
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
      return;
    }

    final titleCtrl = TextEditingController();
    final membersCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('إنشاء مجموعة جديدة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  hintText: 'اسم المجموعة',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: membersCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  hintText: 'أدخل الإيميلات (مفصولة بفواصل أو أسطر)',
                ),
                maxLines: 4,
                textDirection: ui.TextDirection.ltr,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('إنشاء'),
            ),
          ],
        ),
      ),
    );

    if (result != true) {
      titleCtrl.dispose();
      membersCtrl.dispose();
      return;
    }

    final title = titleCtrl.text.trim();
    final rawMembers = membersCtrl.text.trim();
    final members = rawMembers
        .split(RegExp(r'[,\n\r;\s]+'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();

    if (title.isEmpty || members.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى إدخال اسم المجموعة والإيميلات.')),
      );
      titleCtrl.dispose();
      membersCtrl.dispose();
      return;
    }

    try {
      final chat = context.read<ChatProvider>();
      final conversation = await chat.createGroup(
        title: title,
        memberEmails: members,
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء المجموعة: $e')),
      );
    } finally {
      titleCtrl.dispose();
      membersCtrl.dispose();
    }
  }
}

class _InvitationCard extends StatelessWidget {
  final ChatGroupInvitation invitation;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _InvitationCard({
    required this.invitation,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (invitation.conversationTitle ?? '').trim().isEmpty
        ? 'مجموعة بدون عنوان'
        : invitation.conversationTitle!.trim();
    final actionable = invitation.isActionable && !busy;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              textDirection: ui.TextDirection.rtl,
            ),
            const SizedBox(height: 6),
            Text(
              'الحالة الحالية: ${invitation.statusLabel}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textDirection: ui.TextDirection.rtl,
            ),
            if (invitation.responseNote != null &&
                invitation.responseNote!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'ملاحظة: ${invitation.responseNote}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.tertiary),
                textDirection: ui.TextDirection.rtl,
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'تمت دعوتك للانضمام إلى هذه المجموعة. يمكنك القبول أو الرفض الآن.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textDirection: ui.TextDirection.rtl,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: actionable ? onAccept : null,
                    child: busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('قبول'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        invitation.isActionable && !busy ? onDecline : null,
                    child: const Text('رفض'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
