// lib/screens/audit/permissions_screen.dart
//
// شاشة إدارة صلاحيات الميزات للعاملين ضمن العيادة.
// - للمالك: عرض جميع الموظفين وتعيين/تعديل/حذف سجل الصلاحيات لكل موظف.
// - لغير المالك (الموظّف): عرض صلاحياته المؤثرة (من دالة my_feature_permissions)
//   بشكل قراءة فقط.
//
// ملاحظات:
// - نعرض البريد الإلكتروني بدل UID في القائمة، ونسمح بالبحث بالبريد أو UID.
// - لجلب البريد نستخدم RPC: list_employees_with_email (SECURITY DEFINER).
// - نعتمد filter(...) بدل eq/gte/... لتوافق نسخ postgrest.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/core/features.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final _client = Supabase.instance.client;

  bool _loading = false;
  bool _initialLoaded = false;

  // لائحة الموظفين في الحساب (مالك فقط)
  final List<_Employee> _employees = [];

  // خريطة صلاحيات مخصصة لكل موظف (إن وُجد سجل)
  final Map<String, _FeaturePerm> _byUser = {};

  // فلتر بحث في القائمة
  final _searchCtrl = TextEditingController();

  // صلاحياتي (للموظّف غير المالك) تُجلب عبر RPC my_feature_permissions
  _FeaturePerm? _myPerms;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    if (_loading) return;
    setState(() => _loading = true);

    final auth = context.read<AuthProvider>();
    final accId = auth.accountId ?? '';
    final isOwner = (auth.role ?? '') == 'owner';
    final isOwnerOrSuper = isOwner || auth.isSuperAdmin;
    final canView =
        isOwnerOrSuper || auth.featureAllowed(FeatureKeys.auditPermissions);

    if (!canView) {
      setState(() {
        _loading = false;
        _initialLoaded = true;
      });
      return;
    }

    try {
      if (!isOwnerOrSuper) {
        // موظّف: نقرأ الصلاحيات المؤثرة فقط عبر RPC
        final res = await _client.rpc('my_feature_permissions', params: {
          'p_account': accId,
        });
        if (res is List && res.isNotEmpty) {
          _myPerms = _FeaturePerm.fromMap(Map<String, dynamic>.from(res.first));
        } else if (res is Map) {
          _myPerms = _FeaturePerm.fromMap(Map<String, dynamic>.from(res));
        } else {
          _myPerms = _FeaturePerm.defaults();
        }
      } else {
        // --- مالك: نقرأ الموظفين + بريد كل موظف عبر RPC ثم ندمج ---
        // 1) خريطة البريد لكل UID من RPC list_employees_with_email
        final Map<String, String> emailByUid = {};
        try {
          final rpc = await _client
              .rpc('list_employees_with_email', params: {'p_account': accId});
          if (rpc is List) {
            for (final r in rpc) {
              final m = Map<String, dynamic>.from(r as Map);
              final uid =
                  (m['user_uid'] as String?) ?? (m['uid'] as String?) ?? '';
              final email = (m['email'] as String?)?.trim();
              if (uid.isNotEmpty && email != null && email.isNotEmpty) {
                emailByUid[uid] = email;
              }
            }
          }
        } catch (_) {
          // تجاهل أي خطأ في الـ RPC — سنعرض UID عند عدم توفر البريد
        }

        // 2) جدول account_users للحصول على الدور/الحالة
        final rows = await _client
            .from('account_users')
            .select('user_uid, role, disabled, created_at')
            .filter('account_id', 'eq', accId)
            .order('created_at', ascending: true);

        _employees
          ..clear()
          ..addAll((rows as List).map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            final uid = m['user_uid']?.toString() ?? '';
            return _Employee.fromAccountUserRow(
              m,
              email: emailByUid[uid],
            );
          }));

        // 3) جدول الصلاحيات لكل مستخدم
        final perms = await _client
            .from('account_feature_permissions')
            .select(
                'user_uid, allowed_features, can_create, can_update, can_delete')
            .filter('account_id', 'eq', accId);

        _byUser.clear();
        for (final r in (perms as List)) {
          final p = _FeaturePerm.fromAfpRow(Map<String, dynamic>.from(r));
          _byUser[p.userUid!] = p;
        }
      }

      setState(() {
        _initialLoaded = true;
      });
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'تعذّر التحميل (${e.code ?? e.message}). تحقق من الصلاحيات.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('خطأ غير متوقع: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // فتح محرّر صلاحيات موظف (لـ owner فقط)
  void _openEditor(_Employee emp) async {
    final current =
        _byUser[emp.userUid] ?? _FeaturePerm.defaults(userUid: emp.userUid);

    final edited = await showModalBottomSheet<_FeaturePerm>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => _PermissionEditor(
        employee: emp,
        initial: current,
      ),
    );

    if (edited == null) return;

    await _savePermission(emp.userUid, edited);
  }

  Future<void> _savePermission(String userUid, _FeaturePerm perm) async {
    final auth = context.read<AuthProvider>();
    final accId = auth.accountId ?? '';

    setState(() => _loading = true);
    try {
      if (perm.isDefaultAll) {
        // حذف السجل لاستعادة الافتراضي
        await _client
            .from('account_feature_permissions')
            .delete()
            .filter('account_id', 'eq', accId)
            .filter('user_uid', 'eq', userUid);
        _byUser.remove(userUid);
      } else {
        // upsert
        await _client.from('account_feature_permissions').upsert({
          'account_id': accId,
          'user_uid': userUid,
          'allowed_features': perm.allowedFeatures,
          'can_create': perm.canCreate,
          'can_update': perm.canUpdate,
          'can_delete': perm.canDelete,
        }, onConflict: 'account_id,user_uid');
        _byUser[userUid] = perm.copyWith(userUid: userUid);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ الصلاحيات.')),
        );
      }
      setState(() {});
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('تعذّر الحفظ (${e.code ?? e.message}). تحقق من RLS.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('خطأ غير متوقع: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isOwner = (auth.role ?? '') == 'owner';
    final isOwnerOrSuper = isOwner || auth.isSuperAdmin;
    final canView =
        isOwnerOrSuper || auth.featureAllowed(FeatureKeys.auditPermissions);

    // تحميل أولي عند أول بناء
    if (!_initialLoaded && !_loading && canView) {
      Future.microtask(_loadAll);
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('صلاحيات الميزات'),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: (!canView || _loading) ? null : _loadAll,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            child: !canView
                ? _buildAccessDenied()
                : _loading && !_initialLoaded
                    ? const Center(child: CircularProgressIndicator())
                    : isOwnerOrSuper
                        ? _buildOwnerBody()
                        : _buildEmployeeReadonly(),
          ),
        ),
      ),
    );
  }

  Widget _buildAccessDenied() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: NeuCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded, color: scheme.error, size: 32),
            const SizedBox(height: 12),
            const Text(
              'لا تملك صلاحية عرض أو تعديل صلاحيات الميزات.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'اطلب من المالك أو السوبر أدمن منحك صلاحية "audit.permissions".',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // واجهة المالك: قائمة الموظفين + مُحرر لكل موظّف
  Widget _buildOwnerBody() {
    final scheme = Theme.of(context).colorScheme;

    final query = _searchCtrl.text.trim().toLowerCase();
    final filtered = _employees.where((e) {
      if (query.isEmpty) return true;
      final email = (e.email ?? '').toLowerCase();
      return email.contains(query) || e.userUid.toLowerCase().contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // شريط بحث
        NeuCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'ابحث بالبريد أو UID…',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: 12),

        Expanded(
          child: RefreshIndicator(
            color: scheme.primary,
            onRefresh: _loadAll,
            child: _employees.isEmpty
                ? const Center(
                    child: Text(
                      'لا يوجد موظفون مسجلون لهذا الحساب.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final emp = filtered[i];
                      final p = _byUser[emp.userUid]; // قد تكون null → افتراضي
                      return _EmployeeTile(
                        employee: emp,
                        perm: p ?? _FeaturePerm.defaults(),
                        isCustom: p != null,
                        onEdit: () => _openEditor(emp),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  // واجهة الموظّف: عرض صلاحياته فقط (قراءة)
  Widget _buildEmployeeReadonly() {
    final scheme = Theme.of(context).colorScheme;
    final p = _myPerms ?? _FeaturePerm.defaults();

    return RefreshIndicator(
      color: scheme.primary,
      onRefresh: _loadAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          NeuCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'صلاحياتي الحالية',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 10),
                _CrudRow(
                  canCreate: p.canCreate,
                  canUpdate: p.canUpdate,
                  canDelete: p.canDelete,
                  readOnly: true,
                ),
                const SizedBox(height: 12),
                _FeatureChips(
                  selected: p.allowedFeatures,
                  readOnly: true,
                ),
                const SizedBox(height: 8),
                if (p.isDefaultAll)
                  Text(
                    'ملاحظة: لا يوجد سجل مخصص لك، لذلك تُطبَّق الصلاحيات الافتراضية (كل الميزات + كامل CRUD).',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: .7),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/*────────────────────────── نماذج البيانات ─────────────────────────*/

class _Employee {
  final String userUid;
  final String role;
  final bool disabled;
  final String? email;

  _Employee({
    required this.userUid,
    required this.role,
    required this.disabled,
    this.email,
  });

  // نبني من صف account_users مع تمرير البريد إن وُجد
  factory _Employee.fromAccountUserRow(Map<String, dynamic> j,
          {String? email}) =>
      _Employee(
        userUid: j['user_uid']?.toString() ?? '',
        role: j['role']?.toString() ?? 'employee',
        disabled: (j['disabled'] as bool?) ?? false,
        email: email,
      );
}

class _FeaturePerm {
  final String? userUid; // اختياري (يملأ عند الحفظ)
  final List<String> allowedFeatures;
  final bool canCreate;
  final bool canUpdate;
  final bool canDelete;

  const _FeaturePerm({
    this.userUid,
    required this.allowedFeatures,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
  });

  bool get isDefaultAll =>
      allowedFeatures.isEmpty && canCreate && canUpdate && canDelete;

  _FeaturePerm copyWith({
    String? userUid,
    List<String>? allowedFeatures,
    bool? canCreate,
    bool? canUpdate,
    bool? canDelete,
  }) {
    return _FeaturePerm(
      userUid: userUid ?? this.userUid,
      allowedFeatures: allowedFeatures ?? this.allowedFeatures,
      canCreate: canCreate ?? this.canCreate,
      canUpdate: canUpdate ?? this.canUpdate,
      canDelete: canDelete ?? this.canDelete,
    );
  }

  factory _FeaturePerm.defaults({String? userUid}) {
    return _FeaturePerm(
      userUid: userUid,
      allowedFeatures: <String>[], // فارغة = كل الميزات (افتراضي SQL)
      canCreate: true,
      canUpdate: true,
      canDelete: true,
    );
  }

  factory _FeaturePerm.fromAfpRow(Map<String, dynamic> j) {
    final feats = <String>[];
    final raw = j['allowed_features'];
    if (raw is List) {
      feats.addAll(raw.map((e) => e.toString()));
    } else if (raw is String) {
      try {
        final d = jsonDecode(raw);
        if (d is List) feats.addAll(d.map((e) => e.toString()));
      } catch (_) {}
    }
    return _FeaturePerm(
      userUid: j['user_uid']?.toString(),
      allowedFeatures: feats,
      canCreate: (j['can_create'] as bool?) ?? true,
      canUpdate: (j['can_update'] as bool?) ?? true,
      canDelete: (j['can_delete'] as bool?) ?? true,
    );
  }

  // من ناتج RPC my_feature_permissions
  factory _FeaturePerm.fromMap(Map<String, dynamic> j) {
    final feats = <String>[];
    final raw = j['allowed_features'];
    if (raw is List) {
      feats.addAll(raw.map((e) => e.toString()));
    } else if (raw is String) {
      try {
        final d = jsonDecode(raw);
        if (d is List) feats.addAll(d.map((e) => e.toString()));
      } catch (_) {}
    }

    return _FeaturePerm(
      allowedFeatures: feats,
      canCreate: (j['can_create'] as bool?) ?? true,
      canUpdate: (j['can_update'] as bool?) ?? true,
      canDelete: (j['can_delete'] as bool?) ?? true,
    );
  }
}

/*────────────────────── تعريف محلّي لقائمة الميزات ──────────────────────*/
// مفاتيح الميزات المستخدمة في الواجهة/التخزين
class _FeatureKeys {
  static const dashboard = 'dashboard';
  static const patientNew = 'patients.new';
  static const patientsList = 'patients.list';
  static const returns = 'returns';
  static const employees = 'employees';
  static const payments = 'payments';
  static const labRadiology = 'lab_radiology';
  static const charts = 'charts';
  static const repository = 'repository';
  static const prescriptions = 'prescriptions';
  static const backup = 'backup';
  static const accounts = 'accounts';
  static const auditLogs = 'audit.logs';
  static const auditPermissions = 'audit.permissions';
}

// توصيف مبسّط (key + label + icon)
class _FeatureDef {
  final String key;
  final String label;
  final IconData icon;
  const _FeatureDef(this.key, this.label, this.icon);
}

// اللائحة المعروضة في واجهة التحديد
const List<_FeatureDef> _kFeatureDefs = [
  _FeatureDef(_FeatureKeys.dashboard, 'لوحة الإحصاءات', Icons.insights_rounded),
  _FeatureDef(_FeatureKeys.patientNew, 'تسجيل مريض جديد',
      Icons.person_add_alt_1_rounded),
  _FeatureDef(
      _FeatureKeys.patientsList, 'قائمة المرضى', Icons.people_outline_rounded),
  _FeatureDef(
      _FeatureKeys.returns, 'العودات', Icons.assignment_return_outlined),
  _FeatureDef(_FeatureKeys.employees, 'شؤون الموظفين', Icons.groups_rounded),
  _FeatureDef(_FeatureKeys.payments, 'الشؤون المالية', Icons.payments_rounded),
  _FeatureDef(
      _FeatureKeys.labRadiology, 'الأشعة والمختبرات', Icons.biotech_rounded),
  _FeatureDef(_FeatureKeys.charts, 'الرسوم البيانية', Icons.bar_chart_rounded),
  _FeatureDef(
      _FeatureKeys.repository, 'قسم المستودع', Icons.inventory_2_rounded),
  _FeatureDef(
      _FeatureKeys.prescriptions, 'الوصفات الطبية', Icons.menu_book_rounded),
  _FeatureDef(_FeatureKeys.backup, 'النسخ الاحتياطي', Icons.backup_rounded),
  _FeatureDef(
      _FeatureKeys.accounts, 'الحسابات', Icons.supervisor_account_rounded),
  _FeatureDef(
      _FeatureKeys.auditLogs, 'سجلات التدقيق', Icons.receipt_long_rounded),
  _FeatureDef(
      _FeatureKeys.auditPermissions, 'صلاحيات الميزات', Icons.tune_rounded),
];

// أدوات مساعدة محليّة
String _labelOf(String key) => _kFeatureDefs
    .firstWhere((d) => d.key == key,
        orElse: () => _FeatureDef(key, key, Icons.help_outline))
    .label;

IconData _iconOf(String key) => _kFeatureDefs
    .firstWhere((d) => d.key == key,
        orElse: () => _FeatureDef(key, key, Icons.help_outline))
    .icon;

/*────────────────────────── عناصر الواجهة ─────────────────────────*/

class _EmployeeTile extends StatelessWidget {
  final _Employee employee;
  final _FeaturePerm perm;
  final bool isCustom;
  final VoidCallback onEdit;

  const _EmployeeTile({
    required this.employee,
    required this.perm,
    required this.isCustom,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleText = (employee.email?.isNotEmpty ?? false)
        ? employee.email!
        : employee.userUid;

    String summary() {
      final feats = perm.allowedFeatures;
      final featsText = feats.isEmpty
          ? 'كل الميزات'
          : feats.map(_labelOf).take(4).join('، ') +
              (feats.length > 4 ? '…' : '');
      final crud = [
        if (perm.canCreate) 'إضافة',
        if (perm.canUpdate) 'تعديل',
        if (perm.canDelete) 'حذف',
      ];
      final crudText = crud.isEmpty ? 'لا CRUD' : crud.join(' + ');
      return '$featsText • $crudText';
    }

    return NeuCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      onTap: onEdit,
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(10),
            child: const Icon(
              Icons.person_outline_rounded,
              color: kPrimaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  children: [
                    if (!isCustom)
                      Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Text(
                          'افتراضي',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .7),
                            fontWeight: FontWeight.w900,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    const Spacer(),
                    Text(
                      titleText, // البريد أو UID
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w900,
                        fontSize: 15.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  employee.disabled
                      ? 'الحالة: مُعطّل'
                      : 'الدور: ${employee.role}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .7),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  summary(),
                  maxLines: 2,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .75),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const Icon(Icons.chevron_left_rounded),
        ],
      ),
    );
  }
}

class _PermissionEditor extends StatefulWidget {
  final _Employee employee;
  final _FeaturePerm initial;

  const _PermissionEditor({
    required this.employee,
    required this.initial,
  });

  @override
  State<_PermissionEditor> createState() => _PermissionEditorState();
}

class _PermissionEditorState extends State<_PermissionEditor> {
  late List<String> _selected;
  late bool _canCreate;
  late bool _canUpdate;
  late bool _canDelete;

  @override
  void initState() {
    super.initState();
    _selected = [...widget.initial.allowedFeatures];
    _canCreate = widget.initial.canCreate;
    _canUpdate = widget.initial.canUpdate;
    _canDelete = widget.initial.canDelete;
  }

  bool get _isDefaultAll =>
      _selected.isEmpty && _canCreate && _canUpdate && _canDelete;

  void _toggleAll(bool sel) {
    setState(() {
      if (sel) {
        _selected = _kFeatureDefs.map((f) => f.key).toList();
      } else {
        _selected = [];
      }
    });
  }

  void _save() {
    final p = _FeaturePerm(
      userUid: widget.employee.userUid,
      allowedFeatures: _selected,
      canCreate: _canCreate,
      canUpdate: _canUpdate,
      canDelete: _canDelete,
    );
    Navigator.pop(context, p);
  }

  void _resetToDefault() {
    setState(() {
      _selected = [];
      _canCreate = true;
      _canUpdate = true;
      _canDelete = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleText = (widget.employee.email?.isNotEmpty ?? false)
        ? widget.employee.email!
        : widget.employee.userUid;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        top: false,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.92,
          minChildSize: 0.6,
          builder: (_, controller) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
              child: Column(
                children: [
                  // عنوان وبريد/UID
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.tune_rounded,
                            color: kPrimaryColor),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'تعديل صلاحيات: $titleText',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Expanded(
                    child: ListView(
                      controller: controller,
                      children: [
                        // CRUD
                        NeuCard(
                          padding: const EdgeInsets.all(12),
                          child: _CrudRow(
                            canCreate: _canCreate,
                            canUpdate: _canUpdate,
                            canDelete: _canDelete,
                            onChanged: (c, u, d) => setState(() {
                              _canCreate = c;
                              _canUpdate = u;
                              _canDelete = d;
                            }),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // ميزات
                        NeuCard(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'الوصول إلى التبويبات / الميزات',
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => _toggleAll(true),
                                    icon: const Icon(Icons.done_all_rounded),
                                    label: const Text('تحديد الكل'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _toggleAll(false),
                                    icon: const Icon(Icons.clear_all_rounded),
                                    label: const Text('إلغاء الكل'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _FeatureChips(
                                selected: _selected,
                                onToggle: (key, sel) {
                                  setState(() {
                                    if (sel) {
                                      if (!_selected.contains(key)) {
                                        _selected.add(key);
                                      }
                                    } else {
                                      _selected.remove(key);
                                    }
                                  });
                                },
                              ),
                              const SizedBox(height: 8),
                              if (_isDefaultAll)
                                Text(
                                  'إذا بقيت القائمة فارغة مع تفعيل CRUD الكامل، فسيتم استخدام الصلاحيات الافتراضية (كل الميزات).',
                                  style: TextStyle(
                                    color:
                                        scheme.onSurface.withValues(alpha: .7),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // أزرار أسفل
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _resetToDefault,
                        icon: const Icon(Icons.restore_rounded),
                        label: const Text('إرجاع الافتراضي'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.save_rounded),
                          label: const Text('حفظ'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CrudRow extends StatelessWidget {
  final bool canCreate;
  final bool canUpdate;
  final bool canDelete;
  final bool readOnly;
  final void Function(bool c, bool u, bool d)? onChanged;

  const _CrudRow({
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
    this.readOnly = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget sw(bool v, String t, void Function(bool)? onChange) {
      return Expanded(
        child: Row(
          children: [
            Switch.adaptive(
              value: v,
              onChanged: readOnly ? null : onChange,
            ),
            const SizedBox(width: 6),
            Text(
              t,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .9),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        sw(canCreate, 'إضافة', (v) => onChanged?.call(v, canUpdate, canDelete)),
        sw(canUpdate, 'تعديل', (v) => onChanged?.call(canCreate, v, canDelete)),
        sw(canDelete, 'حذف', (v) => onChanged?.call(canCreate, canUpdate, v)),
      ],
    );
  }
}

class _FeatureChips extends StatelessWidget {
  final List<String> selected;
  final bool readOnly;
  final void Function(String key, bool selected)? onToggle;

  const _FeatureChips({
    required this.selected,
    this.readOnly = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _kFeatureDefs.map((f) {
        final sel = selected.contains(f.key);
        return FilterChip(
          selected: sel,
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconOf(f.key), size: 18),
              const SizedBox(width: 6),
              Text(_labelOf(f.key)),
            ],
          ),
          onSelected: readOnly ? null : (v) => onToggle?.call(f.key, v),
        );
      }).toList(),
    );
  }
}
