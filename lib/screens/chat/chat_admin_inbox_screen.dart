// lib/screens/chat/chat_admin_inbox_screen.dart
//
// صندوق وارد السوبر أدمن — يعتمد على ChatProvider لقائمة المحادثات.
// بحث + فلتر غير المقروء.
// بدء محادثة مع مالك عبر بريد — عبر RPC (SECURITY DEFINER) لتجاوز RLS بأمان.

import 'dart:async';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/chat_provider.dart';
import 'package:aelmamclinic/widgets/chat/conversation_tile.dart';
import 'chat_room_screen.dart';

class ChatAdminInboxScreen extends StatefulWidget {
  const ChatAdminInboxScreen({super.key});

  @override
  State<ChatAdminInboxScreen> createState() => _ChatAdminInboxScreenState();
}

class _ChatAdminInboxScreenState extends State<ChatAdminInboxScreen> {
  final _sb = Supabase.instance.client;

  final _searchCtrl = TextEditingController();
  bool _loading = true;
  bool _refreshing = false;
  bool _unreadOnly = false;

  List<_AdminItem> _items = [];

  bool _providerListenerAttached = false;
  Timer? _providerDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _guardAndBootstrap());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _providerDebounce?.cancel();
    try {
      if (_providerListenerAttached) {
        context
            .read<ChatProvider>()
            .removeListener(_onProviderConversationsChanged);
      }
    } catch (_) {}
    super.dispose();
  }

  Future<void> _guardAndBootstrap() async {
    final isSuper = context.read<AuthProvider>().isSuperAdmin;
    if (!isSuper) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('الوصول لهذه الشاشة مخصّص للسوبر أدمن فقط.')),
      );
      Navigator.of(context).maybePop();
      return;
    }

    await _fetchInbox();
    if (!mounted) return;
    setState(() => _loading = false);

    context.read<ChatProvider>().addListener(_onProviderConversationsChanged);
    _providerListenerAttached = true;
  }

  void _onProviderConversationsChanged() {
    _providerDebounce?.cancel();
    _providerDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _fetchInbox();
    });
  }

  Future<void> _fetchInbox() async {
    final me = _sb.auth.currentUser;
    if (me == null) return;

    final cp = context.read<ChatProvider>();
    final allConvs = cp.conversations;
    final dmConvs = allConvs.where((c) => !c.isGroup).toList();
    if (!mounted) return;

    setState(() => _refreshing = true);
    try {
      if (dmConvs.isEmpty) {
        _items = [];
        if (mounted) setState(() => _refreshing = false);
        return;
      }

      final convIds = dmConvs.map((e) => e.id).toList();

      final parts = await _sb
          .from('chat_participants')
          .select('conversation_id, user_uid, email')
          .inFilter('conversation_id', convIds);

      final byConvParts = <String, List<_UserRef>>{};
      final otherUids = <String>{};
      for (final p in (parts as List).whereType<Map<String, dynamic>>()) {
        final cid = p['conversation_id'].toString();
        final uid = (p['user_uid']?.toString() ?? '');
        final email = (p['email']?.toString() ?? '').toLowerCase();
        (byConvParts[cid] ??= []).add(_UserRef(uid: uid, email: email));
      }

      final meId = me.id;
      final otherByConv = <String, _UserRef>{};
      for (final c in dmConvs) {
        final list = byConvParts[c.id] ?? const <_UserRef>[];
        if (list.length != 2) continue;
        final other = list.firstWhere(
          (u) => u.uid != meId,
          orElse: () => const _UserRef(uid: '', email: ''),
        );
        if (other.uid.isNotEmpty) {
          otherByConv[c.id] = other;
          otherUids.add(other.uid);
        }
      }

      if (otherUids.isEmpty) {
        _items = [];
        if (mounted) setState(() => _refreshing = false);
        return;
      }

      final ownerRoles = ['owner', 'admin', 'owner_admin'];
      final auRows = await _sb
          .from('account_users')
          .select('user_uid, role, account_id, email, created_at')
          .inFilter('user_uid', otherUids.toList())
          .order('created_at', ascending: false);

      final latestByUid = <String, Map<String, dynamic>>{};
      for (final r in (auRows as List).whereType<Map<String, dynamic>>()) {
        final uid = r['user_uid']?.toString() ?? '';
        if (uid.isEmpty) continue;
        latestByUid.putIfAbsent(uid, () => r);
      }

      final readsRows = await _sb
          .from('chat_reads')
          .select('conversation_id, last_read_at')
          .eq('user_uid', meId)
          .inFilter('conversation_id', convIds);

      final readAtByConv = <String, DateTime?>{};
      for (final r in (readsRows as List).whereType<Map<String, dynamic>>()) {
        final cid = r['conversation_id']?.toString() ?? '';
        final ts = r['last_read_at'];
        readAtByConv[cid] =
            ts == null ? null : DateTime.tryParse(ts.toString())?.toUtc();
      }

      final accountIds = dmConvs
          .map((e) => e.accountId)
          .where((e) => (e ?? '').toString().isNotEmpty)
          .cast<String>()
          .toSet()
          .toList();

      final clinicsById = <String, String>{};
      if (accountIds.isNotEmpty) {
        try {
          final clinicRows = await _sb
              .from('clinics')
              .select('id, name')
              .inFilter('id', accountIds);
          for (final r
              in (clinicRows as List).whereType<Map<String, dynamic>>()) {
            clinicsById[r['id'].toString()] =
                (r['name']?.toString() ?? '').trim();
          }
        } catch (_) {}
      }

      final items = <_AdminItem>[];
      for (final c in dmConvs) {
        final other = otherByConv[c.id];
        if (other == null) continue;

        final latest = latestByUid[other.uid];
        if (latest == null) continue;
        final role = (latest['role']?.toString() ?? '').toLowerCase();
        if (!ownerRoles.contains(role)) continue;

        final ownerEmail = (other.email.isNotEmpty)
            ? other.email
            : ((latest['email']?.toString() ?? '').toLowerCase());

        final lastAt = c.lastMsgAt;
        final lastReadAt = readAtByConv[c.id];
        final hasUnread = (lastAt != null) &&
            (lastReadAt == null || lastAt.isAfter(lastReadAt));

        final clinicName =
            c.accountId != null ? (clinicsById[c.accountId!] ?? '') : '';

        items.add(_AdminItem(
          conversation: c,
          ownerEmail: ownerEmail,
          clinicName: (clinicName.trim().isEmpty ? null : clinicName.trim()),
          lastSnippet: c.lastMsgSnippet,
          hasUnread: hasUnread,
        ));
      }

      items.sort((a, b) {
        if (a.hasUnread != b.hasUnread) return a.hasUnread ? -1 : 1;
        final ta = a.conversation.lastMsgAt ?? a.conversation.createdAt;
        final tb = b.conversation.lastMsgAt ?? b.conversation.createdAt;
        return tb.compareTo(ta);
      });

      _items = items;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تحميل الصندوق: $e')),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // ✅ بدء DM عبر RPC تتجاوز RLS بأمان
  Future<void> _startOwnerDM() async {
    final me = _sb.auth.currentUser;
    if (me == null) return;

    final emailCtrl = TextEditingController();

    final targetEmail = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('بدء محادثة مع مالك'),
        content: TextField(
          controller: emailCtrl,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            hintText: 'البريد الإلكتروني للمالك',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
          textDirection: ui.TextDirection.ltr,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, emailCtrl.text.trim().toLowerCase()),
            child: const Text('بدء'),
          ),
        ],
      ),
    );

    if (targetEmail == null || targetEmail.isEmpty) return;

    try {
      // تستدعي دالة chat_admin_start_dm(target_email text) وترجع conv_id (uuid)
      final String? convId = await _sb.rpc<String>(
        'chat_admin_start_dm',
        params: {'target_email': targetEmail},
      );

      if (convId == null || convId.isEmpty) {
        _snack('تعذّر إنشاء/استرجاع المحادثة.');
        return;
      }

      // اجلب صف المحادثة لنبني ChatConversation محليًا
      final row = await _sb
          .from('chat_conversations')
          .select(
            'id, account_id, is_group, title, created_by, created_at, updated_at, last_msg_at, last_msg_snippet',
          )
          .eq('id', convId)
          .maybeSingle();

      if (row == null) {
        _snack('تم إنشاء المحادثة لكن لم أستطع قراءتها.');
        return;
      }

      final conv = ChatConversation.fromMap(row);

      if (!mounted) return;
      final cp = context.read<ChatProvider>();
      await cp.openConversation(conv.id);
      await cp.markConversationRead(conv.id);

      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatRoomScreen(conversation: conv)),
      );

      if (mounted) await _fetchInbox();
    } catch (e) {
      _snack('تعذّر بدء المحادثة: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = _items.where((e) {
      if (_unreadOnly && !e.hasUnread) return false;
      if (q.isEmpty) return true;
      final hay = [
        e.ownerEmail,
        e.clinicName ?? '',
        e.conversation.title ?? '',
        e.lastSnippet ?? '',
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.support_agent_rounded, size: 22),
              SizedBox(width: 8),
              Text('صندوق السوبر أدمن'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: _refreshing ? null : _fetchInbox,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _startOwnerDM,
          icon: const Icon(Icons.mark_email_unread_rounded),
          label: const Text('بدء محادثة مع مالك'),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            hintText:
                                'ابحث ببريد المالك، اسم العيادة، أو الملخّص…',
                            border: InputBorder.none,
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                          textDirection: ui.TextDirection.rtl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      selected: _unreadOnly,
                      onSelected: (v) => setState(() => _unreadOnly = v),
                      label: const Text('غير المقروء'),
                      avatar:
                          const Icon(Icons.mark_chat_unread_rounded, size: 18),
                    ),
                  ],
                ),
              ),
              if (_loading)
                const Expanded(
                    child: Center(child: CircularProgressIndicator()))
              else if (filtered.isEmpty)
                Expanded(
                  child: RefreshIndicator(
                    color: kPrimaryColor,
                    onRefresh: _fetchInbox,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 60),
                        Center(
                          child: NeuCard(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 14),
                            child: Text(
                              'لا توجد محادثات مطابقة.',
                              style: TextStyle(
                                color: scheme.onSurface.withValues(alpha: .75),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: RefreshIndicator(
                    color: kPrimaryColor,
                    onRefresh: _fetchInbox,
                    child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
                      itemBuilder: (_, i) {
                        final it = filtered[i];
                        final subtitle =
                            _formatSubtitleFromSnippet(it.lastSnippet);

                        return ConversationTile(
                          conversation: it.conversation,
                          titleOverride: it.ownerEmail,
                          subtitleOverride: subtitle,
                          lastMessage: null,
                          clinicLabel:
                              (it.clinicName?.trim().isNotEmpty ?? false)
                                  ? it.clinicName!.trim()
                                  : null,
                          unreadCount: it.hasUnread ? 1 : 0,
                          showChevron: true,
                          onTap: () async {
                            final cp = context.read<ChatProvider>();
                            await cp.openConversation(it.conversation.id);
                            await cp.markConversationRead(it.conversation.id);
                            if (!mounted) return;
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ChatRoomScreen(
                                    conversation: it.conversation),
                              ),
                            );
                            if (mounted) await _fetchInbox();
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

  String _formatSubtitleFromSnippet(String? snippet) {
    final s = (snippet ?? '').trim();
    return s.isEmpty ? '?? ????? ???' : s;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/*�������� ????? ?????? ��������*/
class _AdminItem {
  final ChatConversation conversation;
  final String ownerEmail;
  final String? clinicName;
  final String? lastSnippet;
  final bool hasUnread;

  const _AdminItem({
    required this.conversation,
    required this.ownerEmail,
    required this.clinicName,
    required this.lastSnippet,
    required this.hasUnread,
  });
}

class _UserRef {
  final String uid;
  final String email;
  const _UserRef({required this.uid, required this.email});
}
