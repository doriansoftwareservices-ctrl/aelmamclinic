import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_complaint.dart';
import 'package:aelmamclinic/models/patient_complaint_answer.dart';
import 'package:aelmamclinic/models/patient_complaint_question.dart';
import 'package:aelmamclinic/models/patient_complaint_template.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/patient_questions_service.dart';

class ReportEditorScreen extends StatefulWidget {
  final Patient patient;
  final String remotePatientId;
  final PatientComplaint complaint;

  const ReportEditorScreen({
    super.key,
    required this.patient,
    required this.remotePatientId,
    required this.complaint,
  });

  @override
  State<ReportEditorScreen> createState() => _ReportEditorScreenState();
}

class _ReportEditorScreenState extends State<ReportEditorScreen> {
  final _svc = PatientQuestionsService();
  final _reportCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  List<PatientComplaintQuestion> _questions = [];
  List<PatientComplaintAnswer> _answers = [];
  PatientComplaintTemplate? _template;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reportCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId ?? '';
    setState(() => _loading = true);
    try {
      if (widget.complaint.complaintId != null) {
        final templates = await _svc.fetchTemplates(
          accountId: accountId,
          includeInactive: true,
        );
        _template = templates.firstWhere(
          (t) => t.id == widget.complaint.complaintId,
          orElse: () => PatientComplaintTemplate(
            id: widget.complaint.complaintId!,
            accountId: accountId,
            title: widget.complaint.complaintTitleCustom ?? 'شكوى',
            description: '',
            isActive: true,
            sortOrder: 0,
          ),
        );
        _questions = await _svc.fetchQuestions(
          complaintId: widget.complaint.complaintId!,
          includeInactive: true,
        );
      }
      _answers =
          await _svc.fetchAnswers(patientComplaintId: widget.complaint.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر تحميل البيانات: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _answerLabel(bool? v) {
    if (v == true) return 'نعم';
    if (v == false) return 'لا';
    return 'غير مجاب';
  }

  Future<void> _save(String status) async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId ?? '';
    final uid = auth.uid ?? '';
    if (accountId.isEmpty || uid.isEmpty) return;

    if (_reportCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل نص التقرير أولاً')),
      );
      return;
    }

    final complaintTitle =
        _template?.title ?? widget.complaint.complaintTitleCustom ?? '';
    final complaintDesc = _template?.description ?? '';

    final questionsSnapshot = _questions.map((q) {
      PatientComplaintAnswer? ans;
      for (final a in _answers) {
        if (a.questionId == q.id) {
          ans = a;
          break;
        }
      }
      return {
        'question_id': q.id,
        'question_text': q.questionText,
        'answer': ans?.answerBool,
        'note': ans?.noteText,
      };
    }).toList();

    final snapshot = {
      'complaint': {
        'title': complaintTitle,
        'description': complaintDesc,
        'source': 'template',
      },
      'questions': questionsSnapshot,
    };

    setState(() => _saving = true);
    try {
      await _svc.createReport(
        accountId: accountId,
        patientId: widget.remotePatientId,
        patientComplaintId: widget.complaint.id,
        reportText: _reportCtrl.text.trim(),
        status: status,
        snapshot: snapshot,
        createdBy: uid,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('تم حفظ التقرير')));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر الحفظ: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final complaintTitle =
        _template?.title ?? widget.complaint.complaintTitleCustom ?? '—';

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إنشاء تقرير'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NeuCard(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('المريض: ${widget.patient.name}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text('ما يعاني منه: $complaintTitle'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      NeuCard(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('نص التقرير',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15)),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 220,
                              child: NeuField(
                                controller: _reportCtrl,
                                labelText: 'اكتب التقرير هنا',
                                maxLines: null,
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.newline,
                                prefix: const Icon(Icons.description_outlined),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: NeuCard(
                          padding: const EdgeInsets.all(12),
                          child: ListView.builder(
                            itemCount: _questions.length,
                            itemBuilder: (ctx, i) {
                              final q = _questions[i];
                              PatientComplaintAnswer? ans;
                              for (final a in _answers) {
                                if (a.questionId == q.id) {
                                  ans = a;
                                  break;
                                }
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(q.questionText,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 4),
                                    Text('الإجابة: ${_answerLabel(ans?.answerBool)}'),
                                    if ((ans?.noteText ?? '').trim().isNotEmpty)
                                      Text('ملاحظة: ${ans!.noteText}'),
                                    const Divider(height: 16),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _saving ? null : () => _save('final'),
                              icon: const Icon(Icons.save),
                              label: const Text('حفظ'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _saving ? null : () => _save('draft'),
                              icon: const Icon(Icons.save_as_outlined),
                              label: const Text('حفظ كمسودة'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
