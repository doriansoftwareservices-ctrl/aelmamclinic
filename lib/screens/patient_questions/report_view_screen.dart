import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_report.dart';
import 'package:aelmamclinic/services/patient_report_pdf_service.dart';

class ReportViewScreen extends StatelessWidget {
  final Patient patient;
  final PatientReport report;

  const ReportViewScreen({
    super.key,
    required this.patient,
    required this.report,
  });

  @override
  Widget build(BuildContext context) {
    final snap = report.snapshot;
    final complaint = (snap['complaint'] as Map?) ?? {};
    final title = (complaint['title'] ?? '').toString().trim();
    final questions = (snap['questions'] as List?) ?? const [];

    String answerLabel(dynamic v) {
      if (v == true) return 'نعم';
      if (v == false) return 'لا';
      return 'غير مجاب';
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('استعراض التقرير'),
          actions: [
            IconButton(
              tooltip: 'طباعة PDF',
              icon: const Icon(Icons.picture_as_pdf),
              onPressed: () async {
                await PatientReportPdfService.sharePdf(
                  patient: patient,
                  report: report,
                );
              },
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title.isNotEmpty)
                  NeuCard(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'ما يعاني منه المريض: $title',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ),
                const SizedBox(height: 10),
                NeuCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'نص التقرير',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(report.reportText.isEmpty ? '—' : report.reportText),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: NeuCard(
                    padding: const EdgeInsets.all(12),
                    child: ListView.builder(
                      itemCount: questions.length,
                      itemBuilder: (ctx, i) {
                        final q = questions[i];
                        if (q is! Map) return const SizedBox.shrink();
                        final text = (q['question_text'] ?? '').toString();
                        final note = (q['note'] ?? '').toString();
                        final ans = answerLabel(q['answer']);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(text,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 4),
                              Text('الإجابة: $ans'),
                              if (note.trim().isNotEmpty)
                                Text('ملاحظة: $note'),
                              const Divider(height: 16),
                            ],
                          ),
                        );
                      },
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
}
