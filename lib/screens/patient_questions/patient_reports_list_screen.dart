import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_report.dart';
import 'package:aelmamclinic/services/patient_questions_service.dart';
import 'package:aelmamclinic/screens/patient_questions/report_view_screen.dart';

class PatientReportsListScreen extends StatefulWidget {
  final Patient patient;
  final String remotePatientId;

  const PatientReportsListScreen({
    super.key,
    required this.patient,
    required this.remotePatientId,
  });

  @override
  State<PatientReportsListScreen> createState() => _PatientReportsListScreenState();
}

class _PatientReportsListScreenState extends State<PatientReportsListScreen> {
  final _svc = PatientQuestionsService();
  bool _loading = true;
  List<PatientReport> _reports = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _svc.fetchReports(patientId: widget.remotePatientId);
      setState(() => _reports = list);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر تحميل التقارير: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تقارير المريض'),
          actions: [
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _reports.isEmpty
                    ? const Center(child: Text('لا توجد تقارير بعد'))
                    : ListView.separated(
                        itemCount: _reports.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (ctx, i) {
                          final r = _reports[i];
                          final snap = r.snapshot;
                          final complaint = (snap['complaint'] as Map?) ?? {};
                          final title =
                              (complaint['title'] ?? '').toString().trim();
                          final date = r.createdAt != null
                              ? r.createdAt!.toLocal().toString().substring(0, 16)
                              : '';
                          return NeuCard(
                            padding: const EdgeInsets.all(12),
                            child: ListTile(
                              title: Text(
                                title.isEmpty ? 'تقرير طبي' : 'تقرير: $title',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text(date.isEmpty ? '—' : date),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ReportViewScreen(
                                      patient: widget.patient,
                                      report: r,
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
          ),
        ),
      ),
    );
  }
}
