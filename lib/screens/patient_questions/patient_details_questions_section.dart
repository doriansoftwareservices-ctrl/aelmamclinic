import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/features.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_complaint.dart';
import 'package:aelmamclinic/models/patient_complaint_answer.dart';
import 'package:aelmamclinic/models/patient_complaint_question.dart';
import 'package:aelmamclinic/models/patient_complaint_template.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/patient_questions_service.dart';
import 'package:aelmamclinic/screens/patient_questions/complaint_questions_screen.dart';
import 'package:aelmamclinic/screens/patient_questions/complaint_templates_screen.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class PatientDetailsQuestionsSection extends StatefulWidget {
  final Patient patient;

  const PatientDetailsQuestionsSection({super.key, required this.patient});

  @override
  State<PatientDetailsQuestionsSection> createState() =>
      _PatientDetailsQuestionsSectionState();
}

class _AnswerDraft {
  bool? answer;
  final TextEditingController noteController;

  _AnswerDraft({required this.answer, String? note})
      : noteController = TextEditingController(text: note ?? '');

  void dispose() => noteController.dispose();
}

class _ComplaintBlock {
  final PatientComplaint complaint;
  final PatientComplaintTemplate? template;
  final List<PatientComplaintQuestion> questions;
  final Map<String, _AnswerDraft> drafts;
  DateTime? lastSaved;

  _ComplaintBlock({
    required this.complaint,
    required this.template,
    required this.questions,
    required this.drafts,
    this.lastSaved,
  });
}

class _PatientDetailsQuestionsSectionState
    extends State<PatientDetailsQuestionsSection> {
  final _svc = PatientQuestionsService();
  String? _remotePatientId;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  bool _isDoctor = false;
  String? _doctorUid;

  List<PatientComplaintTemplate> _templates = [];
  List<_ComplaintBlock> _blocks = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDoctorFlag();
    });
    _load();
  }

  @override
  void dispose() {
    for (final block in _blocks) {
      for (final d in block.drafts.values) {
        d.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _loadDoctorFlag() async {
    final auth = context.read<AuthProvider>();
    final uid = auth.uid ?? '';
    if (uid.isEmpty || uid == _doctorUid) return;
    _doctorUid = uid;
    try {
      final emp = await DBService.instance.getEmployeeByUserUid(uid);
      if (!mounted) return;
      setState(() => _isDoctor = emp?.isDoctor ?? false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isDoctor = false);
    }
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (accountId == null || accountId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _error = 'لا يوجد حساب مرتبط.';
        _loading = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final remoteId = await _svc.resolveRemotePatientId(
        patient: widget.patient,
        accountId: accountId,
      );
      if (!mounted) return;
      if (remoteId == null || remoteId.isEmpty) {
        setState(() {
          _remotePatientId = null;
          _loading = false;
          _error = 'المريض غير مزامن على الخادم بعد.';
        });
        return;
      }
      _remotePatientId = remoteId;

      final templates = await _svc.fetchTemplates(
        accountId: accountId,
        includeInactive: true,
      );
      if (!mounted) return;
      final templateById = {
        for (final t in templates) t.id: t,
      };

      final complaints = await _svc.fetchPatientComplaints(patientId: remoteId);
      if (!mounted) return;

      for (final block in _blocks) {
        for (final draft in block.drafts.values) {
          draft.dispose();
        }
      }

      final blocks = <_ComplaintBlock>[];
      for (final c in complaints) {
        final template = c.complaintId != null
            ? templateById[c.complaintId!]
            : null;
        final questions = c.complaintId != null
            ? await _svc.fetchQuestions(complaintId: c.complaintId!)
            : <PatientComplaintQuestion>[];
        final answers = await _svc.fetchAnswers(patientComplaintId: c.id);
        final draftMap = <String, _AnswerDraft>{};
        for (final q in questions) {
          PatientComplaintAnswer? ans;
          for (final a in answers) {
            if (a.questionId == q.id) {
              ans = a;
              break;
            }
          }
          if (ans != null) {
            draftMap[q.id] =
                _AnswerDraft(answer: ans.answerBool, note: ans.noteText);
          } else {
            draftMap[q.id] = _AnswerDraft(answer: null, note: null);
          }
        }
        blocks.add(_ComplaintBlock(
          complaint: c,
          template: template,
          questions: questions,
          drafts: draftMap,
          lastSaved: null,
        ));
      }

      if (!mounted) return;
      setState(() {
        _templates = templates;
        _blocks = blocks;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر تحميل أسئلة المريض: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _canManageTemplates(AuthProvider auth) {
    if (auth.isSuperAdmin) return true;
    return _isDoctor && auth.featureAllowed(FeatureKeys.patientQuestions);
  }

  Future<void> _addComplaint() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId ?? '';
    final uid = auth.uid ?? '';
    if (accountId.isEmpty || uid.isEmpty) return;
    final remoteId = _remotePatientId;
    if (remoteId == null || remoteId.isEmpty) return;

    PatientComplaintTemplate? selected;
    final canManageTemplates = _canManageTemplates(auth);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const LocalizedText('اختر الشكوى'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius)),
          content: DropdownButtonFormField<PatientComplaintTemplate>(
            initialValue: selected,
            items: _templates
                .where((t) => t.isActive)
                .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(t.title),
                    ))
                .toList(),
            onChanged: (v) => selected = v,
            decoration: InputDecoration(labelText: context.trRaw('الشكوى')),
          ),
          actions: [
            if (canManageTemplates)
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx, false);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ComplaintTemplatesScreen(),
                    ),
                  ).then((_) => _load());
                },
                icon: const Icon(Icons.add),
                label: const LocalizedText('إضافة شكوى جديدة'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const LocalizedText('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const LocalizedText('إضافة'),
            ),
          ],
        );
      },
    );

    if (ok != true || selected == null) return;

    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await _svc.ensurePatientComplaint(
        accountId: accountId,
        patientId: remoteId,
        complaintId: selected!.id,
        createdBy: uid,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LocalizedText('تعذر الإضافة: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveBlock(_ComplaintBlock block) async {
    final auth = context.read<AuthProvider>();
    final uid = auth.uid ?? '';
    final accountId = auth.accountId ?? '';
    if (uid.isEmpty || accountId.isEmpty) return;

    final objects = <Map<String, dynamic>>[];
    final now = DateTime.now().toIso8601String();
    for (final q in block.questions) {
      final draft = block.drafts[q.id];
      if (draft == null) continue;
      objects.add({
        'account_id': accountId,
        'patient_complaint_id': block.complaint.id,
        'question_id': q.id,
        'answer_bool': draft.answer,
        'note_text': draft.noteController.text.trim().isEmpty
            ? null
            : draft.noteController.text.trim(),
        'answered_by': uid,
        'answered_at': now,
        'updated_at': now,
      });
    }

    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await _svc.upsertAnswers(objects: objects);
      if (mounted) {
        setState(() => block.lastSaved = DateTime.now());
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LocalizedText('تعذر الحفظ: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deactivateComplaint(_ComplaintBlock block) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const LocalizedText('إزالة الشكوى؟'),
          backgroundColor: scheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius)),
          content: const LocalizedText('سيتم إخفاؤها من هذا المريض دون حذف البيانات.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const LocalizedText('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const LocalizedText('إزالة'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;

    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await _svc.updatePatientComplaintStatus(
        id: block.complaint.id,
        status: 'inactive',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LocalizedText('تعذر الإزالة: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildQuestionRow(PatientComplaintQuestion q, _AnswerDraft draft) {
    final scheme = Theme.of(context).colorScheme;
    int? currentIndex;
    if (draft.answer == true) currentIndex = 0;
    if (draft.answer == false) currentIndex = 1;
    if (draft.answer == null) currentIndex = 2;

    List<bool> selected = [false, false, false];
    if (currentIndex != null) selected[currentIndex] = true;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(q.questionText,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ToggleButtons(
            borderRadius: BorderRadius.circular(8),
            selectedColor: Colors.white,
            fillColor: kPrimaryColor,
            color: scheme.onSurface.withValues(alpha: .7),
            isSelected: selected,
            onPressed: (index) {
              setState(() {
                if (index == 0) draft.answer = true;
                if (index == 1) draft.answer = false;
                if (index == 2) draft.answer = null;
              });
            },
            children: const [
              Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: LocalizedText('نعم')),
              Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: LocalizedText('لا')),
              Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: LocalizedText('غير مجاب')),
            ],
          ),
          const SizedBox(height: 6),
          NeuField(
            controller: draft.noteController,
            labelText: context.trRaw('ملاحظة (اختياري)'),
            maxLines: 2,
            prefix: const Icon(Icons.note_alt_outlined),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final canManageTemplates = _canManageTemplates(auth);
    final canUseFeature = auth.isSuperAdmin ||
        (_isDoctor && auth.featureAllowed(FeatureKeys.patientQuestions));

    if (!canUseFeature) {
      return const SizedBox.shrink();
    }

    if (_loading) {
      return const NeuCard(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return NeuCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_error!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const LocalizedText('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(title: 'أسئلة المريض', color: kPrimaryColor),
        const SizedBox(height: 10),
        if (_blocks.isEmpty)
          NeuCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LocalizedText('لا توجد شكاوى مرتبطة بهذا المريض بعد.'),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _saving ? null : _addComplaint,
                  icon: const Icon(Icons.add),
                  label: const LocalizedText('إضافة شكوى'),
                ),
              ],
            ),
          )
        else
          ..._blocks.map((block) {
            final title = block.template?.title ??
                block.complaint.complaintTitleCustom ??
                'شكوى غير معنونة';
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NeuCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: context.trRaw('إزالة الشكوى'),
                          onPressed: _saving
                              ? null
                              : () => _deactivateComplaint(block),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ],
                    ),
                    if (block.template == null || block.questions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: LocalizedText('لا توجد أسئلة مرتبطة بهذه الشكوى بعد.',
                          style: TextStyle(
                              color:
                                  scheme.onSurface.withValues(alpha: .7)),
                        ),
                      ),
                    if (block.template != null && canManageTemplates)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ComplaintQuestionsScreen(
                                  template: block.template!,
                                ),
                              ),
                            ).then((_) => _load());
                          },
                          icon: const Icon(Icons.quiz_outlined),
                          label: const LocalizedText('إدارة الأسئلة'),
                        ),
                      ),
                    const Divider(height: 18),
                    ...block.questions.map((q) {
                      final draft = block.drafts[q.id];
                      if (draft == null) return const SizedBox.shrink();
                      return _buildQuestionRow(q, draft);
                    }),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed:
                                _saving ? null : () => _saveBlock(block),
                            icon: const Icon(Icons.save),
                            label: const LocalizedText('حفظ الإجابات'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (block.lastSaved != null)
                          LocalizedText('آخر حفظ: ${block.lastSaved!.toLocal().toString().substring(0, 16)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurface.withValues(alpha: .6),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _saving ? null : _addComplaint,
          icon: const Icon(Icons.add),
          label: const LocalizedText('إضافة شكوى'),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Color color;

  const _SectionHeader({required this.title, required this.color});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 6,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 15.5,
            ),
          ),
        ],
      );
}
