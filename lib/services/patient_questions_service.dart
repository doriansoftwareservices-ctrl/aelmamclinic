import 'dart:async';

import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_complaint.dart';
import 'package:aelmamclinic/models/patient_complaint_answer.dart';
import 'package:aelmamclinic/models/patient_complaint_question.dart';
import 'package:aelmamclinic/models/patient_complaint_template.dart';
import 'package:aelmamclinic/models/patient_report.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/sync_mapping_service.dart';
import 'package:aelmamclinic/utils/device_id.dart';

class PatientQuestionsService {
  PatientQuestionsService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client,
        _mapping = SyncMappingService(client: client);

  final GraphQLClient _gql;
  final SyncMappingService _mapping;
  static const int _maxQueryAttempts = 4;

  bool _isTransientException(OperationException ex) {
    final msg = ex.toString().toLowerCase();
    return msg.contains('responseformatexception') ||
        msg.contains('formatexception') ||
        msg.contains('unexpected character') ||
        msg.contains('503') ||
        msg.contains('502') ||
        msg.contains('bad gateway') ||
        msg.contains('service temporarily unavailable') ||
        msg.contains('eof') ||
        msg.contains('context deadline exceeded');
  }

  Future<QueryResult> _queryWithRetry(
    QueryOptions options, {
    int maxAttempts = _maxQueryAttempts,
  }) async {
    var attempt = 0;
    while (true) {
      attempt += 1;
      final res = await _gql.query(options);
      if (!res.hasException) return res;
      final ex = res.exception!;
      if (attempt >= maxAttempts || !_isTransientException(ex)) {
        throw ex;
      }
      await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
    }
  }

  Future<String?> resolveRemotePatientId({
    required Patient patient,
    required String accountId,
  }) async {
    final localId = patient.localId ?? patient.id ?? 0;
    if (localId <= 0) return null;
    final deviceId =
        (patient.deviceId != null && patient.deviceId!.trim().isNotEmpty)
            ? patient.deviceId!.trim()
            : await DeviceId.get();
    return _mapping.resolveRemoteId(
      table: 'patients',
      accountId: accountId,
      deviceId: deviceId,
      localId: localId,
    );
  }

  Future<Map<int, String>> mapLocalPatientsToRemote({
    required List<Patient> patients,
    required String accountId,
  }) async {
    final refs = <LocalSyncRef>[];
    for (final p in patients) {
      final localId = p.localId ?? p.id;
      if (localId != null && localId > 0) {
        final deviceId =
            (p.deviceId != null && p.deviceId!.trim().isNotEmpty)
                ? p.deviceId!.trim()
                : await DeviceId.get();
        refs.add(LocalSyncRef(localId: localId, deviceId: deviceId));
      }
    }
    if (refs.isEmpty) return {};
    return _mapping.mapLocalToRemote(
      table: 'patients',
      accountId: accountId,
      refs: refs,
    );
  }

  // ---------------------------------------------------------------------------
  // Templates
  // ---------------------------------------------------------------------------
  Future<List<PatientComplaintTemplate>> fetchTemplates({
    required String accountId,
    bool includeInactive = false,
  }) async {
    final query = includeInactive
        ? r'''
      query Templates($acc: uuid!) {
        complaint_templates(
          where: { account_id: { _eq: $acc } }
          order_by: [{ sort_order: asc }, { created_at: asc }]
        ) {
          id
          account_id
          title
          description
          is_active
          sort_order
          created_by
          updated_by
          created_at
          updated_at
        }
      }
    '''
        : r'''
      query Templates($acc: uuid!) {
        complaint_templates(
          where: { account_id: { _eq: $acc }, is_active: { _eq: true } }
          order_by: [{ sort_order: asc }, { created_at: asc }]
        ) {
          id
          account_id
          title
          description
          is_active
          sort_order
          created_by
          updated_by
          created_at
          updated_at
        }
      }
    ''';
    final res = await _queryWithRetry(
      QueryOptions(
        document: gql(query),
        variables: {
          'acc': accountId,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    final rows = (res.data?['complaint_templates'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => PatientComplaintTemplate.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<String> createTemplate({
    required String accountId,
    required String title,
    String? description,
    required String createdBy,
  }) async {
    const mutation = r'''
      mutation CreateTemplate($obj: complaint_templates_insert_input!) {
        insert_complaint_templates_one(object: $obj) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'obj': {
            'account_id': accountId,
            'title': title,
            'description': description,
            'created_by': createdBy,
            'updated_by': createdBy,
          }
        },
      ),
    );
    if (res.hasException) throw res.exception!;
    return (res.data?['insert_complaint_templates_one'] as Map?)?['id']
            ?.toString() ??
        '';
  }

  Future<void> updateTemplate({
    required String id,
    String? title,
    String? description,
    bool? isActive,
    int? sortOrder,
    String? updatedBy,
  }) async {
    const mutation = r'''
      mutation UpdateTemplate($id: uuid!, $set: complaint_templates_set_input!) {
        update_complaint_templates_by_pk(pk_columns: {id: $id}, _set: $set) {
          id
        }
      }
    ''';
    final set = <String, dynamic>{
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (isActive != null) 'is_active': isActive,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (updatedBy != null) 'updated_by': updatedBy,
      'updated_at': DateTime.now().toIso8601String(),
    };
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'id': id, 'set': set},
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<void> reorderTemplates({
    required Map<String, int> sortById,
    required String updatedBy,
  }) async {
    for (final entry in sortById.entries) {
      await updateTemplate(
        id: entry.key,
        sortOrder: entry.value,
        updatedBy: updatedBy,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Questions
  // ---------------------------------------------------------------------------
  Future<List<PatientComplaintQuestion>> fetchQuestions({
    required String complaintId,
    bool includeInactive = false,
  }) async {
    final query = includeInactive
        ? r'''
      query Questions($cid: uuid!) {
        complaint_questions(
          where: { complaint_id: { _eq: $cid } }
          order_by: [{ sort_order: asc }, { created_at: asc }]
        ) {
          id
          account_id
          complaint_id
          question_text
          is_active
          sort_order
          created_by
          updated_by
          created_at
          updated_at
        }
      }
    '''
        : r'''
      query Questions($cid: uuid!) {
        complaint_questions(
          where: { complaint_id: { _eq: $cid }, is_active: { _eq: true } }
          order_by: [{ sort_order: asc }, { created_at: asc }]
        ) {
          id
          account_id
          complaint_id
          question_text
          is_active
          sort_order
          created_by
          updated_by
          created_at
          updated_at
        }
      }
    ''';
    final res = await _queryWithRetry(
      QueryOptions(
        document: gql(query),
        variables: {
          'cid': complaintId,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    final rows = (res.data?['complaint_questions'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => PatientComplaintQuestion.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<String> createQuestion({
    required String accountId,
    required String complaintId,
    required String questionText,
    required String createdBy,
  }) async {
    const mutation = r'''
      mutation CreateQuestion($obj: complaint_questions_insert_input!) {
        insert_complaint_questions_one(object: $obj) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'obj': {
            'account_id': accountId,
            'complaint_id': complaintId,
            'question_text': questionText,
            'created_by': createdBy,
            'updated_by': createdBy,
          }
        },
      ),
    );
    if (res.hasException) throw res.exception!;
    return (res.data?['insert_complaint_questions_one'] as Map?)?['id']
            ?.toString() ??
        '';
  }

  Future<void> updateQuestion({
    required String id,
    String? questionText,
    bool? isActive,
    int? sortOrder,
    String? updatedBy,
  }) async {
    const mutation = r'''
      mutation UpdateQuestion($id: uuid!, $set: complaint_questions_set_input!) {
        update_complaint_questions_by_pk(pk_columns: {id: $id}, _set: $set) {
          id
        }
      }
    ''';
    final set = <String, dynamic>{
      if (questionText != null) 'question_text': questionText,
      if (isActive != null) 'is_active': isActive,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (updatedBy != null) 'updated_by': updatedBy,
      'updated_at': DateTime.now().toIso8601String(),
    };
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'id': id, 'set': set},
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<void> reorderQuestions({
    required Map<String, int> sortById,
    required String updatedBy,
  }) async {
    for (final entry in sortById.entries) {
      await updateQuestion(
        id: entry.key,
        sortOrder: entry.value,
        updatedBy: updatedBy,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Patient complaints + answers
  // ---------------------------------------------------------------------------
  Future<List<PatientComplaint>> fetchPatientComplaints({
    required String patientId,
    bool includeInactive = false,
  }) async {
    final query = includeInactive
        ? r'''
      query PatientComplaints($pid: uuid!) {
        patient_complaints(
          where: { patient_id: { _eq: $pid } }
          order_by: [{ created_at: desc }]
        ) {
          id
          account_id
          patient_id
          complaint_id
          complaint_title_custom
          status
          created_by
          created_at
          updated_at
        }
      }
    '''
        : r'''
      query PatientComplaints($pid: uuid!) {
        patient_complaints(
          where: { patient_id: { _eq: $pid }, status: { _eq: \"active\" } }
          order_by: [{ created_at: desc }]
        ) {
          id
          account_id
          patient_id
          complaint_id
          complaint_title_custom
          status
          created_by
          created_at
          updated_at
        }
      }
    ''';
    final res = await _queryWithRetry(
      QueryOptions(
        document: gql(query),
        variables: {
          'pid': patientId,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    final rows = (res.data?['patient_complaints'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => PatientComplaint.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<String> ensurePatientComplaint({
    required String accountId,
    required String patientId,
    required String complaintId,
    required String createdBy,
  }) async {
    const mutation = r'''
      mutation EnsurePatientComplaint($obj: patient_complaints_insert_input!) {
        insert_patient_complaints_one(
          object: $obj
          on_conflict: {
            constraint: patient_complaints_patient_complaint_uq
            update_columns: [updated_at, status]
          }
        ) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'obj': {
            'account_id': accountId,
            'patient_id': patientId,
            'complaint_id': complaintId,
            'status': 'active',
            'created_by': createdBy,
          }
        },
      ),
    );
    if (res.hasException) throw res.exception!;
    return (res.data?['insert_patient_complaints_one'] as Map?)?['id']
            ?.toString() ??
        '';
  }

  Future<void> updatePatientComplaintStatus({
    required String id,
    required String status,
  }) async {
    const mutation = r'''
      mutation UpdatePatientComplaint($id: uuid!, $set: patient_complaints_set_input!) {
        update_patient_complaints_by_pk(pk_columns: {id: $id}, _set: $set) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'id': id,
          'set': {
            'status': status,
            'updated_at': DateTime.now().toIso8601String(),
          }
        },
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<List<PatientComplaintAnswer>> fetchAnswers({
    required String patientComplaintId,
  }) async {
    const query = r'''
      query Answers($pcid: uuid!) {
        patient_complaint_answers(
          where: { patient_complaint_id: { _eq: $pcid } }
        ) {
          id
          account_id
          patient_complaint_id
          question_id
          answer_bool
          note_text
          answered_by
          answered_at
          updated_at
        }
      }
    ''';
    final res = await _queryWithRetry(
      QueryOptions(
        document: gql(query),
        variables: {'pcid': patientComplaintId},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    final rows = (res.data?['patient_complaint_answers'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => PatientComplaintAnswer.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> upsertAnswers({
    required List<Map<String, dynamic>> objects,
  }) async {
    if (objects.isEmpty) return;
    const mutation = r'''
      mutation UpsertAnswers($objects: [patient_complaint_answers_insert_input!]!) {
        insert_patient_complaint_answers(
          objects: $objects
          on_conflict: {
            constraint: patient_complaint_answers_uq
            update_columns: [answer_bool, note_text, answered_by, answered_at, updated_at]
          }
        ) { affected_rows }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'objects': objects},
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  // ---------------------------------------------------------------------------
  // Reports
  // ---------------------------------------------------------------------------
  Future<List<PatientReport>> fetchReports({
    required String patientId,
  }) async {
    const query = r'''
      query Reports($pid: uuid!) {
        patient_reports(where: { patient_id: { _eq: $pid } }, order_by: { created_at: desc }) {
          id
          account_id
          patient_id
          patient_complaint_id
          report_text
          status
          snapshot
          created_by
          created_at
          updated_at
        }
      }
    ''';
    final res = await _queryWithRetry(
      QueryOptions(
        document: gql(query),
        variables: {'pid': patientId},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    final rows = (res.data?['patient_reports'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => PatientReport.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<PatientReport?> fetchReportById(String id) async {
    const query = r'''
      query ReportById($id: uuid!) {
        patient_reports_by_pk(id: $id) {
          id
          account_id
          patient_id
          patient_complaint_id
          report_text
          status
          snapshot
          created_by
          created_at
          updated_at
        }
      }
    ''';
    final res = await _queryWithRetry(
      QueryOptions(
        document: gql(query),
        variables: {'id': id},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    final row = res.data?['patient_reports_by_pk'] as Map?;
    if (row == null) return null;
    return PatientReport.fromMap(Map<String, dynamic>.from(row));
  }

  Future<String> createReport({
    required String accountId,
    required String patientId,
    String? patientComplaintId,
    required String reportText,
    required String status,
    required Map<String, dynamic> snapshot,
    required String createdBy,
  }) async {
    const mutation = r'''
      mutation CreateReport($obj: patient_reports_insert_input!) {
        insert_patient_reports_one(object: $obj) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'obj': {
            'account_id': accountId,
            'patient_id': patientId,
            'patient_complaint_id': patientComplaintId,
            'report_text': reportText,
            'status': status,
            'snapshot': snapshot,
            'created_by': createdBy,
          }
        },
      ),
    );
    if (res.hasException) throw res.exception!;
    return (res.data?['insert_patient_reports_one'] as Map?)?['id']
            ?.toString() ??
        '';
  }

  Future<Map<String, int>> countReportsByPatientIds(
    List<String> patientIds,
  ) async {
    if (patientIds.isEmpty) return {};
    const query = r'''
      query ReportCounts($ids: [uuid!]!) {
        patient_reports(where: { patient_id: { _in: $ids } }) {
          id
          patient_id
        }
      }
    ''';
    final res = await _queryWithRetry(
      QueryOptions(
        document: gql(query),
        variables: {'ids': patientIds},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    final rows = (res.data?['patient_reports'] as List?) ?? const [];
    final counts = <String, int>{};
    for (final row in rows.whereType<Map>()) {
      final pid = row['patient_id']?.toString() ?? '';
      if (pid.isEmpty) continue;
      counts[pid] = (counts[pid] ?? 0) + 1;
    }
    return counts;
  }
}
