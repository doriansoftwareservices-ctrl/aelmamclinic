import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/patient_complaint_template.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/patient_questions_service.dart';
import 'package:aelmamclinic/screens/patient_questions/complaint_questions_screen.dart';

class ComplaintTemplatesScreen extends StatefulWidget {
  const ComplaintTemplatesScreen({super.key});

  @override
  State<ComplaintTemplatesScreen> createState() => _ComplaintTemplatesScreenState();
}

class _ComplaintTemplatesScreenState extends State<ComplaintTemplatesScreen> {
  final _svc = PatientQuestionsService();
  List<PatientComplaintTemplate> _templates = [];
  bool _loading = true;
  bool _saving = false;
  bool _showInactive = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (accountId == null || accountId.isEmpty) {
      setState(() {
        _templates = [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final list = await _svc.fetchTemplates(
        accountId: accountId,
        includeInactive: _showInactive,
      );
      setState(() => _templates = list);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر تحميل الشكاوى: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _canManage(AuthProvider auth) {
    if (auth.isSuperAdmin) return true;
    return auth.isOwnerOrAdmin;
  }

  Future<void> _openCreateDialog() async {
    final auth = context.read<AuthProvider>();
    final canManage = _canManage(auth);
    if (!canManage) return;

    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('إضافة شكوى'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NeuField(
                  controller: titleCtrl,
                  labelText: 'اسم الشكوى',
                  prefix: const Icon(Icons.medical_information_outlined),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'أدخل اسم الشكوى'
                      : null,
                ),
                const SizedBox(height: 10),
                NeuField(
                  controller: descCtrl,
                  labelText: 'وصف (اختياري)',
                  maxLines: 2,
                  prefix: const Icon(Icons.description_outlined),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;
    if (!mounted) return;

    final accountId = auth.accountId ?? '';
    final uid = auth.uid ?? '';
    if (accountId.isEmpty || uid.isEmpty) return;

    setState(() => _saving = true);
    try {
      final id = await _svc.createTemplate(
        accountId: accountId,
        title: titleCtrl.text.trim(),
        description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
        createdBy: uid,
      );
      await _load();
      if (!mounted) return;
      final created = _templates.firstWhere(
        (t) => t.id == id,
        orElse: () => PatientComplaintTemplate(
          id: id,
          accountId: accountId,
          title: titleCtrl.text.trim(),
          description: descCtrl.text.trim(),
          isActive: true,
          sortOrder: 0,
        ),
      );
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ComplaintQuestionsScreen(template: created),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل الحفظ: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleActive(PatientComplaintTemplate t, bool value) async {
    final auth = context.read<AuthProvider>();
    if (!_canManage(auth)) return;
    setState(() => _saving = true);
    try {
      await _svc.updateTemplate(
        id: t.id,
        isActive: value,
        updatedBy: auth.uid,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر التحديث: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editTemplate(PatientComplaintTemplate t) async {
    final auth = context.read<AuthProvider>();
    if (!_canManage(auth)) return;
    final titleCtrl = TextEditingController(text: t.title);
    final descCtrl = TextEditingController(text: t.description ?? '');
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('تعديل الشكوى'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NeuField(
                  controller: titleCtrl,
                  labelText: 'اسم الشكوى',
                  prefix: const Icon(Icons.medical_information_outlined),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'أدخل اسم الشكوى'
                      : null,
                ),
                const SizedBox(height: 10),
                NeuField(
                  controller: descCtrl,
                  labelText: 'وصف (اختياري)',
                  maxLines: 2,
                  prefix: const Icon(Icons.description_outlined),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await _svc.updateTemplate(
        id: t.id,
        title: titleCtrl.text.trim(),
        description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
        updatedBy: auth.uid,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر التحديث: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final item = _templates.removeAt(oldIndex);
    _templates.insert(newIndex, item);
    setState(() {});

    final auth = context.read<AuthProvider>();
    if (!_canManage(auth)) return;
    setState(() => _saving = true);
    try {
      final sortMap = <String, int>{};
      for (var i = 0; i < _templates.length; i++) {
        sortMap[_templates[i].id] = i;
      }
      await _svc.reorderTemplates(sortById: sortMap, updatedBy: auth.uid ?? '');
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر إعادة الترتيب: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final canManage = _canManage(auth);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('نماذج الشكاوى'),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'إدارة الشكاوى وأسئلتها',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    Switch.adaptive(
                      value: _showInactive,
                      onChanged: (v) {
                        setState(() => _showInactive = v);
                        _load();
                      },
                    ),
                    const Text('إظهار المعطّل'),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _templates.isEmpty
                          ? const Center(child: Text('لا توجد شكاوى بعد'))
                          : ReorderableListView.builder(
                              itemCount: _templates.length,
                              onReorder: _reorder,
                              buildDefaultDragHandles: false,
                              itemBuilder: (ctx, i) {
                                final t = _templates[i];
                                return Padding(
                                  key: ValueKey(t.id),
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: NeuCard(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            ReorderableDragStartListener(
                                              index: i,
                                              enabled: canManage,
                                              child: Icon(
                                                Icons.drag_handle,
                                                color: canManage
                                                    ? scheme.onSurface
                                                    : scheme.onSurface
                                                        .withValues(alpha: .3),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                t.title,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 15.5,
                                                ),
                                              ),
                                            ),
                                            Switch.adaptive(
                                              value: t.isActive,
                                              onChanged: canManage
                                                  ? (v) => _toggleActive(t, v)
                                                  : null,
                                            ),
                                          ],
                                        ),
                                        if ((t.description ?? '')
                                            .trim()
                                            .isNotEmpty)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 6),
                                            child: Text(
                                              t.description!.trim(),
                                              style: TextStyle(
                                                color: scheme.onSurface
                                                    .withValues(alpha: .7),
                                              ),
                                            ),
                                          ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            OutlinedButton.icon(
                                              onPressed: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        ComplaintQuestionsScreen(
                                                            template: t),
                                                  ),
                                                );
                                              },
                                              icon: const Icon(
                                                  Icons.quiz_outlined),
                                              label: const Text('إدارة الأسئلة'),
                                            ),
                                            if (canManage)
                                              OutlinedButton.icon(
                                                onPressed: () => _editTemplate(t),
                                                icon: const Icon(Icons.edit),
                                                label: const Text('تعديل'),
                                              ),
                                            if (canManage)
                                              OutlinedButton.icon(
                                                onPressed: () =>
                                                    _toggleActive(t, false),
                                                icon: const Icon(Icons.block),
                                                label: const Text('تعطيل'),
                                              ),
                                          ],
                                        )
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _openCreateDialog,
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة شكوى'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
