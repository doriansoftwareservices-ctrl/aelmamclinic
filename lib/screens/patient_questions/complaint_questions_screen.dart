import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/patient_complaint_question.dart';
import 'package:aelmamclinic/models/patient_complaint_template.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/patient_questions_service.dart';

class ComplaintQuestionsScreen extends StatefulWidget {
  final PatientComplaintTemplate template;

  const ComplaintQuestionsScreen({super.key, required this.template});

  @override
  State<ComplaintQuestionsScreen> createState() => _ComplaintQuestionsScreenState();
}

class _ComplaintQuestionsScreenState extends State<ComplaintQuestionsScreen> {
  final _svc = PatientQuestionsService();
  List<PatientComplaintQuestion> _questions = [];
  bool _loading = true;
  bool _saving = false;
  bool _showInactive = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _svc.fetchQuestions(
        complaintId: widget.template.id,
        includeInactive: _showInactive,
      );
      setState(() => _questions = list);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر تحميل الأسئلة: $e')));
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
    if (!_canManage(auth)) return;
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('إضافة سؤال'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
          ),
          content: Form(
            key: formKey,
            child: NeuField(
              controller: ctrl,
              labelText: 'نص السؤال',
              maxLines: 3,
              prefix: const Icon(Icons.help_outline),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'أدخل نص السؤال'
                  : null,
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
      await _svc.createQuestion(
        accountId: accountId,
        complaintId: widget.template.id,
        questionText: ctrl.text.trim(),
        createdBy: uid,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل الحفظ: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editQuestion(PatientComplaintQuestion q) async {
    final auth = context.read<AuthProvider>();
    if (!_canManage(auth)) return;
    final ctrl = TextEditingController(text: q.questionText);
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('تعديل السؤال'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius),
          ),
          content: Form(
            key: formKey,
            child: NeuField(
              controller: ctrl,
              labelText: 'نص السؤال',
              maxLines: 3,
              prefix: const Icon(Icons.help_outline),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'أدخل نص السؤال'
                  : null,
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
      await _svc.updateQuestion(
        id: q.id,
        questionText: ctrl.text.trim(),
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

  Future<void> _toggleActive(PatientComplaintQuestion q, bool v) async {
    final auth = context.read<AuthProvider>();
    if (!_canManage(auth)) return;
    setState(() => _saving = true);
    try {
      await _svc.updateQuestion(
        id: q.id,
        isActive: v,
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
    final item = _questions.removeAt(oldIndex);
    _questions.insert(newIndex, item);
    setState(() {});

    final auth = context.read<AuthProvider>();
    if (!_canManage(auth)) return;
    setState(() => _saving = true);
    try {
      final sortMap = <String, int>{};
      for (var i = 0; i < _questions.length; i++) {
        sortMap[_questions[i].id] = i;
      }
      await _svc.reorderQuestions(sortById: sortMap, updatedBy: auth.uid ?? '');
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
          title: Text('أسئلة: ${widget.template.title}'),
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
                        'إدارة الأسئلة الخاصة بالشكوى',
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
                      : _questions.isEmpty
                          ? const Center(child: Text('لا توجد أسئلة بعد'))
                          : ReorderableListView.builder(
                              itemCount: _questions.length,
                              onReorder: _reorder,
                              buildDefaultDragHandles: false,
                              itemBuilder: (ctx, i) {
                                final q = _questions[i];
                                return Padding(
                                  key: ValueKey(q.id),
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
                                                q.questionText,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 15,
                                                ),
                                              ),
                                            ),
                                            Switch.adaptive(
                                              value: q.isActive,
                                              onChanged: canManage
                                                  ? (v) => _toggleActive(q, v)
                                                  : null,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            if (canManage)
                                              OutlinedButton.icon(
                                                onPressed: () => _editQuestion(q),
                                                icon: const Icon(Icons.edit),
                                                label: const Text('تعديل'),
                                              ),
                                            if (canManage)
                                              OutlinedButton.icon(
                                                onPressed: () => _toggleActive(q, false),
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
                    label: const Text('إضافة سؤال'),
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
