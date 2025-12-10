// lib/widgets/user_account_picker_dialog.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/auth_supabase_service.dart';

/// نتيجة اختيار حساب مستخدم.
class UserAccountSelection {
  final String uid;
  final String email;
  final bool disabled;

  const UserAccountSelection({
    required this.uid,
    required this.email,
    required this.disabled,
  });
}

class UserAccountPickerDialog extends StatefulWidget {
  final Set<String> excludeUserUids;
  final String? initialUserUid;

  const UserAccountPickerDialog({
    super.key,
    this.excludeUserUids = const <String>{},
    this.initialUserUid,
  });

  @override
  State<UserAccountPickerDialog> createState() =>
      _UserAccountPickerDialogState();
}

class _UserAccountPickerDialogState extends State<UserAccountPickerDialog> {
  final AuthSupabaseService _authService = AuthSupabaseService();
  final TextEditingController _searchCtrl = TextEditingController();

  final List<UserAccountSelection> _all = <UserAccountSelection>[];
  List<UserAccountSelection> _filtered = <UserAccountSelection>[];

  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilter);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_applyFilter);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final accountId = context.read<AuthProvider>().accountId;
      if (accountId == null || accountId.isEmpty) {
        setState(() {
          _all.clear();
          _filtered = const [];
          _loading = false;
        });
        return;
      }

      final exclude = <String>{
        ...widget.excludeUserUids
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty),
      };
      final initial = widget.initialUserUid?.trim();
      if (initial != null && initial.isNotEmpty) {
        exclude.remove(initial);
      }

      final options = await _fetchAccounts(accountId);
      final filtered = options
          .where((opt) => !exclude.contains(opt.uid))
          .toList()
        ..sort(
            (a, b) => a.email.toLowerCase().compareTo(b.email.toLowerCase()));

      setState(() {
        _all
          ..clear()
          ..addAll(filtered);
        _filtered = List<UserAccountSelection>.from(_all);
        _loading = false;
      });
      _applyFilter();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<List<UserAccountSelection>> _fetchAccounts(String accountId) async {
    final List<UserAccountSelection> items = [];

    Future<List<Map<String, dynamic>>> rpc() async {
      final data = await _authService.client
          .rpc('list_employees_with_email', params: {'p_account': accountId});
      if (data is List) {
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      throw Exception('Unexpected RPC payload');
    }

    Future<List<Map<String, dynamic>>> edge() async {
      final resp = await _authService.client.functions.invoke(
        'admin__list_employees',
        body: {'account_id': accountId},
      );
      final data = resp.data;
      if (data is List) {
        return data.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      throw Exception('Unexpected edge payload');
    }

    Future<List<Map<String, dynamic>>> profiles() async {
      final rows = await _authService.client
          .from('profiles')
          .select('id, disabled')
          .eq('account_id', accountId)
          .eq('role', 'employee');
      if (rows is List) {
        return rows.map((r) => Map<String, dynamic>.from(r)).toList();
      }
      throw Exception('Unexpected profiles payload');
    }

    List<Map<String, dynamic>> rows;
    try {
      rows = await rpc();
    } catch (_) {
      try {
        rows = await edge();
      } catch (_) {
        rows = await profiles();
      }
    }

    final seen = <String>{};
    for (final row in rows) {
      final uid = (row['user_uid'] ?? row['uid'] ?? row['id'] ?? '').toString();
      final email = (row['email'] ?? '—').toString();
      final disabled = row['disabled'] == true;
      final trimmed = uid.trim();
      if (trimmed.isEmpty || seen.contains(trimmed)) continue;
      seen.add(trimmed);
      items.add(
          UserAccountSelection(uid: trimmed, email: email, disabled: disabled));
    }

    return items;
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    if (query.isEmpty) {
      setState(() => _filtered = List<UserAccountSelection>.from(_all));
      return;
    }
    setState(() {
      _filtered = _all
          .where((opt) =>
              opt.email.toLowerCase().contains(query) ||
              opt.uid.toLowerCase().contains(query))
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('اختيار حساب الموظف'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'ابحث بالبريد أو المعرّف',
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else if (_filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('لا توجد حسابات متاحة للربط'),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 0),
                  itemBuilder: (context, index) {
                    final item = _filtered[index];
                    return ListTile(
                      title: Text(item.email.isEmpty ? '—' : item.email),
                      subtitle: Text(item.uid),
                      leading: const Icon(Icons.person_outline_rounded),
                      trailing: item.disabled
                          ? const Icon(Icons.pause_circle_filled,
                              color: Colors.orangeAccent)
                          : null,
                      onTap: () => Navigator.of(context).pop(item),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
      ],
    );
  }
}
