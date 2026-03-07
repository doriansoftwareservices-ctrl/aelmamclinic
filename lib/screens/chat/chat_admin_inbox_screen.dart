// lib/screens/chat/chat_admin_inbox_screen.dart
//
// صندوق وارد السوبر أدمن — يعتمد على ChatProvider لقائمة المحادثات.
// بحث + فلتر غير المقروء.
// بدء محادثة مع مالك عبر بريد — عبر RPC (SECURITY DEFINER) لتجاوز RLS بأمان.

import 'dart:async';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/chat_provider.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/widgets/chat/conversation_tile.dart';
import 'package:aelmamclinic/main.dart' show ChatRoomLoader;
import 'chat_room_screen.dart';

class ChatAdminInboxScreen extends StatefulWidget {
  const ChatAdminInboxScreen({super.key});

  @override
  State<ChatAdminInboxScreen> createState() => _ChatAdminInboxScreenState();
}

class _ChatAdminInboxScreenState extends State<ChatAdminInboxScreen> {
  final GraphQLClient _gql = NhostGraphqlService.buildClient();

  final _searchCtrl = TextEditingController();
  final _supportNameCtrl = TextEditingController(text: 'خدمة العملاء');
  bool _loading = true;
  bool _refreshing = false;
  bool _unreadOnly = false;

  List<_AdminItem> _items = [];
  List<_SupportCandidate> _supportCandidates = [];
  String? _supportAgentUid;
  bool _supportLoading = false;

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
    _supportNameCtrl.dispose();
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

    final chat = context.read<ChatProvider>();
    if (!chat.ready && !chat.busy) {
      await chat.bootstrap(
        accountId: null,
        role: 'superadmin',
        isSuperAdmin: true,
      );
    }
    await chat.refreshConversations();
    await _fetchInbox();
    await _loadSupportAgents();
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

  Future<Map<String, dynamic>> _runQuery(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _gql.query(
      QueryOptions(
        document: gql(doc),
        variables: variables,
        context: Context.fromList(const [
          HttpLinkHeaders(headers: {'x-hasura-role': 'superadmin'}),
        ]),
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _runMutation(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _gql.mutate(
      MutationOptions(
        document: gql(doc),
        variables: variables,
        context: Context.fromList(const [
          HttpLinkHeaders(headers: {'x-hasura-role': 'superadmin'}),
        ]),
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  List<Map<String, dynamic>> _rowsFromData(
    Map<String, dynamic> data,
    String key,
  ) {
    final raw = data[key];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  Future<void> _fetchInbox() async {
    final me = NhostManager.client.auth.currentUser;
    if (me == null) return;

    final cp = context.read<ChatProvider>();
    if (!cp.ready && !cp.busy) {
      await cp.bootstrap(
        accountId: null,
        role: 'superadmin',
        isSuperAdmin: true,
      );
      await cp.refreshConversations();
    }
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

      final partsQuery = '''
        query Participants(\$ids: [uuid!]!) {
          chat_participants(where: {conversation_id: {_in: \$ids}}) {
            conversation_id
            user_uid
            email
          }
        }
      ''';
      final partsData = await _runQuery(partsQuery, {'ids': convIds});
      final parts = _rowsFromData(partsData, 'chat_participants');

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
      final auQuery = '''
        query AccountUsers(\$uids: [uuid!]!) {
          account_users(
            where: {user_uid: {_in: \$uids}},
            order_by: {created_at: desc}
          ) {
            user_uid
            role
            account_id
            email
            chat_code
            created_at
          }
        }
      ''';
      final auData = await _runQuery(auQuery, {'uids': otherUids.toList()});
      final auRows = _rowsFromData(auData, 'account_users');

      final latestByUid = <String, Map<String, dynamic>>{};
      for (final r in (auRows as List).whereType<Map<String, dynamic>>()) {
        final uid = r['user_uid']?.toString() ?? '';
        if (uid.isEmpty) continue;
        latestByUid.putIfAbsent(uid, () => r);
      }

      final readsQuery = '''
        query Reads(\$uid: uuid!, \$ids: [uuid!]!) {
          chat_reads(
            where: {user_uid: {_eq: \$uid}, conversation_id: {_in: \$ids}}
          ) {
            conversation_id
            last_read_at
          }
        }
      ''';
      final readsData =
          await _runQuery(readsQuery, {'uid': meId, 'ids': convIds});
      final readsRows = _rowsFromData(readsData, 'chat_reads');

      final readAtByConv = <String, DateTime?>{};
      for (final r in (readsRows as List).whereType<Map<String, dynamic>>()) {
        final cid = r['conversation_id']?.toString() ?? '';
        final ts = r['last_read_at'];
        readAtByConv[cid] =
            ts == null ? null : DateTime.tryParse(ts.toString())?.toUtc();
      }
      for (final cid in convIds) {
        readAtByConv.putIfAbsent(cid, () => cp.lastReadAtOf(cid));
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
          final clinicsQuery = '''
            query Clinics(\$ids: [uuid!]!) {
              clinics(where: {id: {_in: \$ids}}) {
                id
                name
              }
            }
          ''';
          final clinicsData =
              await _runQuery(clinicsQuery, {'ids': accountIds});
          final clinicRows = _rowsFromData(clinicsData, 'clinics');
          for (final r in clinicRows) {
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
        final ownerCode = (latest['chat_code']?.toString() ?? '').trim();

        final lastAt = c.lastMsgAt;
        final lastReadAt = readAtByConv[c.id];
        final hasUnread = (lastAt != null) &&
            (lastReadAt == null || lastAt.isAfter(lastReadAt));

        final clinicName =
            c.accountId != null ? (clinicsById[c.accountId!] ?? '') : '';

        items.add(_AdminItem(
          conversation: c,
          ownerEmail: ownerEmail,
          ownerCode: ownerCode,
          clinicName: (clinicName.trim().isEmpty ? null : clinicName.trim()),
          lastSnippet: c.lastMsgSnippet,
          hasUnread: hasUnread,
          supportStatus: c.supportStatus,
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

  Future<void> _loadSupportAgents() async {
    setState(() => _supportLoading = true);
    try {
      const agentQuery = r'''
        query SupportAgent {
          chat_support_agent {
            user_uid
            display_name
          }
        }
      ''';
      const superQuery = r'''
        query SuperAdmins {
          super_admins(order_by: {created_at: desc}) {
            user_uid
            email
          }
        }
      ''';
      final agentData = await _runQuery(agentQuery, const {});
      final agentRows = _rowsFromData(agentData, 'chat_support_agent');
      if (agentRows.isNotEmpty) {
        final row = agentRows.first;
        _supportAgentUid = row['user_uid']?.toString();
        final display = row['display_name']?.toString().trim() ?? '';
        if (display.isNotEmpty) {
          _supportNameCtrl.text = display;
        }
      }

      final superData = await _runQuery(superQuery, const {});
      _supportCandidates = _rowsFromData(superData, 'super_admins')
          .map((r) => _SupportCandidate(
                uid: r['user_uid']?.toString() ?? '',
                email: r['email']?.toString() ?? '',
              ))
          .where((c) => c.uid.isNotEmpty)
          .toList();
      if (_supportAgentUid == null && _supportCandidates.isNotEmpty) {
        _supportAgentUid = _supportCandidates.first.uid;
      }
    } catch (e) {
      _snack('تعذّر تحميل قائمة الدعم: $e');
    } finally {
      if (mounted) setState(() => _supportLoading = false);
    }
  }

  Future<void> _setSupportAgent() async {
    final uid = _supportAgentUid ?? '';
    if (uid.isEmpty) {
      _snack('يرجى اختيار سوبر أدمن.');
      return;
    }
    setState(() => _supportLoading = true);
    try {
      const mutation = r'''
        mutation SetSupportAgent($uid: uuid!, $name: String!) {
          chat_set_support_agent(args: {p_user_uid: $uid, p_display_name: $name}) {
            user_uid
            display_name
          }
        }
      ''';
      final data = await _runMutation(mutation, {
        'uid': uid,
        'name': _supportNameCtrl.text.trim().isEmpty
            ? 'خدمة العملاء'
            : _supportNameCtrl.text.trim(),
      });
      final rows = _rowsFromData(data, 'chat_set_support_agent');
      if (rows.isNotEmpty) {
        _supportAgentUid = rows.first['user_uid']?.toString();
        final display = rows.first['display_name']?.toString() ?? '';
        if (display.trim().isNotEmpty) {
          _supportNameCtrl.text = display.trim();
        }
      }
      _snack('تم تفعيل خدمة العملاء.');
    } catch (e) {
      _snack('تعذّر تعيين خدمة العملاء: $e');
    } finally {
      if (mounted) setState(() => _supportLoading = false);
    }
  }

  // ✅ بدء DM عبر RPC تتجاوز RLS بأمان
  Future<void> _startOwnerDM() async {
    final me = NhostManager.client.auth.currentUser;
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
            hintText: 'البريد الإلكتروني أو الرقم',
            prefixIcon: Icon(Icons.person_search_rounded),
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
      final resolvedEmail = await _resolveEmailForIdentifier(targetEmail);
      if (resolvedEmail == null || resolvedEmail.isEmpty) return;
      // تستدعي دالة chat_admin_start_dm(target_email text) وترجع conv_id (uuid)
      final mutation = '''
        mutation StartAdminDM(\$email: String!) {
          chat_admin_start_dm(args: {target_email: \$email}) {
            id
          }
        }
      ''';
      final data = await _runMutation(mutation, {'email': resolvedEmail});
      final rows = _rowsFromData(data, 'chat_admin_start_dm');
      final convId = rows.isEmpty ? null : rows.first['id']?.toString();

      if (convId == null || convId.isEmpty) {
        _snack('تعذّر إنشاء/استرجاع المحادثة.');
        return;
      }

      // اجلب صف المحادثة لنبني ChatConversation محليًا
      final convQuery = '''
        query Conversation(\$id: uuid!) {
          chat_conversations_by_pk(id: \$id) {
            id
            account_id
            is_group
            title
            created_by
            created_at
            updated_at
            last_msg_at
            last_msg_snippet
          }
        }
      ''';
      final convData = await _runQuery(convQuery, {'id': convId});
      final row = convData['chat_conversations_by_pk'];
      if (row == null) {
        _snack('تم إنشاء المحادثة لكن لم أستطع قراءتها.');
        return;
      }

      final conv = ChatConversation.fromMap(
        Map<String, dynamic>.from(row as Map),
      );

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
        e.ownerCode ?? '',
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
              if (_supportCandidates.isNotEmpty || _supportLoading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                  child: NeuCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.support_agent_rounded),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'تعيين خدمة العملاء',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                            IconButton(
                              tooltip: 'تحديث القائمة',
                              onPressed:
                                  _supportLoading ? null : _loadSupportAgents,
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _supportAgentUid,
                          decoration: const InputDecoration(
                            labelText: 'حساب خدمة العملاء',
                            border: OutlineInputBorder(),
                          ),
                          items: _supportCandidates
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c.uid,
                                  child: Text(c.email),
                                ),
                              )
                              .toList(),
                          onChanged: _supportLoading
                              ? null
                              : (value) =>
                                  setState(() => _supportAgentUid = value),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _supportNameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'الاسم الظاهر للملاك',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: SizedBox(
                            width: 180,
                            child: NeuButton.primary(
                              label: _supportLoading
                                  ? 'جارٍ الحفظ...'
                                  : 'حفظ خدمة العملاء',
                              icon: Icons.check_rounded,
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.max,
                              onPressed:
                                  _supportLoading ? null : _setSupportAgent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                                'ابحث بالبريد أو الرقم أو اسم العيادة…',
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
                        final statusLabel =
                            _statusLabel(it.supportStatus);
                        final snippet =
                            _formatSubtitleFromSnippet(it.lastSnippet);

                        return ConversationTile(
                          conversation: it.conversation,
                          titleOverride: (it.ownerCode?.isNotEmpty ?? false)
                              ? it.ownerCode
                              : it.ownerEmail,
                          subtitleOverride: snippet,
                          lastMessage: null,
                          clinicLabel:
                              (it.clinicName?.trim().isNotEmpty ?? false)
                                  ? it.clinicName!.trim()
                                  : null,
                          statusBadgeText: statusLabel,
                          statusBadgeColor:
                              _statusColor(context, it.supportStatus),
                          unreadCount: it.hasUnread ? 1 : 0,
                          showChevron: true,
                          onTap: () async {
                            try {
                              if (!mounted) return;
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ChatRoomLoader(
                                    conversationId: it.conversation.id,
                                  ),
                                ),
                              );
                              if (mounted) await _fetchInbox();
                            } catch (e) {
                              _snack(_friendlyMessage(e));
                            }
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
    return s.isEmpty ? 'لا رسائل بعد' : s;
  }

  String? _statusLabel(ChatSupportStatus? status) {
    return status?.labelAr ?? 'قيد انتظار الرد عليه';
  }

  Color? _statusColor(BuildContext context, ChatSupportStatus? status) {
    if (status == null) return Colors.orange.shade700;
    switch (status) {
      case ChatSupportStatus.pendingReply:
        return Colors.orange.shade700;
      case ChatSupportStatus.underReview:
        return Colors.blue.shade700;
      case ChatSupportStatus.responded:
        return Colors.green.shade700;
      case ChatSupportStatus.closed:
        return Theme.of(context).colorScheme.outline;
    }
  }

  String _friendlyMessage(Object msg) {
    final raw = msg.toString();
    final s = raw.toLowerCase();
    final isNetwork = s.contains('network') ||
        s.contains('socket') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('connection') ||
        s.contains('semaphore timeout') ||
        s.contains('semaphore') ||
        s.contains('bad gateway') ||
        s.contains('service temporarily unavailable') ||
        s.contains('responseformatexception') ||
        s.contains('unexpected character') ||
        s.contains('document is empty') ||
        s.contains('eof');
    if (isNetwork) return 'يبدو ان الشبكة غير مستقرة لديك';
    return raw;
  }

  void _snack(Object msg) {
    if (!mounted) return;
    final text = _friendlyMessage(msg);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String?> _resolveEmailForIdentifier(String input) async {
    final lookup = input.trim().toLowerCase();
    if (lookup.isEmpty) return null;
    if (lookup.contains('@')) return lookup;
    try {
      const query = r'''
        query ResolveChatUser($ident: String!) {
          chat_resolve_user_for_dm(args: {p_identifier: $ident}) {
            email
            chat_code
          }
        }
      ''';
      final data = await _runQuery(query, {'ident': lookup});
      final rows = _rowsFromData(data, 'chat_resolve_user_for_dm');
      if (rows.isEmpty) {
        _snack('لا يوجد مستخدم بالرقم: $lookup');
        return null;
      }
      final email = (rows.first['email']?.toString() ?? '').trim();
      if (email.isEmpty) {
        _snack('تعذّر العثور على بريد المستخدم.');
        return null;
      }
      return email.toLowerCase();
    } catch (e) {
      _snack('تعذّر البحث عن المستخدم: $e');
      return null;
    }
  }
}

/*�������� ????? ?????? ��������*/
class _AdminItem {
  final ChatConversation conversation;
  final String ownerEmail;
  final String? ownerCode;
  final String? clinicName;
  final String? lastSnippet;
  final bool hasUnread;
  final ChatSupportStatus? supportStatus;

  const _AdminItem({
    required this.conversation,
    required this.ownerEmail,
    required this.ownerCode,
    required this.clinicName,
    required this.lastSnippet,
    required this.hasUnread,
    required this.supportStatus,
  });
}

class _SupportCandidate {
  final String uid;
  final String email;
  const _SupportCandidate({required this.uid, required this.email});
}

class _UserRef {
  final String uid;
  final String email;
  const _UserRef({required this.uid, required this.email});
}
