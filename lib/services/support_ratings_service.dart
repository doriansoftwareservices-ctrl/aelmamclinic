// lib/services/support_ratings_service.dart

import 'dart:convert';

import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/models/support_rating_entry.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class SupportRatingsService {
  SupportRatingsService._();
  static final SupportRatingsService instance = SupportRatingsService._();

  GraphQLClient get _gql => NhostGraphqlService.client;

  static const String _kTypeResponse = 'support_rating_response';

  bool _isMissingChatMessages(OperationException ex) {
    final msg = ex.toString().toLowerCase();
    if (msg.contains("field 'chat_messages' not found")) return true;
    for (final err in ex.graphqlErrors) {
      final em = err.message.toLowerCase();
      if (em.contains("field 'chat_messages' not found")) return true;
      final path = err.extensions?['path']?.toString().toLowerCase();
      if (path != null && path.contains("selectionset.chat_messages")) {
        return true;
      }
    }
    return false;
  }

  SupportRatingEntry? parseFromBody({
    required String body,
    required String conversationId,
    String? accountId,
    String? ownerUid,
  }) {
    final raw = body.trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = decoded.map((k, v) => MapEntry(k.toString(), v));
      final type = map['type']?.toString();
      if (type != _kTypeResponse) return null;
      final sessionId = map['session_id']?.toString() ?? '';
      if (sessionId.isEmpty) return null;
      final r = map['rating'];
      final rating = (r is num) ? r.toInt() : int.tryParse('$r') ?? 0;
      if (rating < 1 || rating > 5) return null;
      final note = map['note']?.toString();
      final submittedAtRaw = map['submitted_at']?.toString();
      final submittedAt = submittedAtRaw == null || submittedAtRaw.isEmpty
          ? DateTime.now().toUtc()
          : DateTime.tryParse(submittedAtRaw)?.toUtc() ??
              DateTime.now().toUtc();
      return SupportRatingEntry(
        conversationId: conversationId,
        accountId: accountId,
        ownerUid: ownerUid,
        sessionId: sessionId,
        rating: rating,
        note: (note == null || note.trim().isEmpty) ? null : note.trim(),
        submittedAt: submittedAt,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<SupportRatingEntry>> fetchRatings({
    DateTime? from,
    DateTime? to,
    String? accountId,
  }) async {
    final variables = <String, dynamic>{};
    final filters = <String>[];

    filters.add('kind: {_eq: "system"}');
    filters.add('body: {_ilike: "%$_kTypeResponse%"}');

    if (accountId != null && accountId.trim().isNotEmpty) {
      variables['accountId'] = accountId.trim();
      filters.add('account_id: {_eq: \$accountId}');
    }
    final createdAtParts = <String>[];
    if (from != null) {
      variables['from'] = from.toUtc().toIso8601String();
      createdAtParts.add('_gte: \$from');
    }
    if (to != null) {
      variables['to'] = to.toUtc().toIso8601String();
      createdAtParts.add('_lte: \$to');
    }
    if (createdAtParts.isNotEmpty) {
      filters.add('created_at: {${createdAtParts.join(', ')}}');
    }

    final whereClause = filters.isEmpty ? '' : 'where: {${filters.join(', ')}}';

    final query = '''
      query SupportRatings(\$accountId: uuid, \$from: timestamptz, \$to: timestamptz) {
        chat_messages($whereClause) {
          id
          conversation_id
          account_id
          sender_uid
          body
          created_at
        }
      }
    ''';

    final result = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );

    if (result.hasException) {
      final ex = result.exception!;
      if (_isMissingChatMessages(ex)) {
        return [];
      }
      throw ex;
    }

    final rows = (result.data?['chat_messages'] as List?) ?? const [];
    final out = <SupportRatingEntry>[];
    for (final raw in rows.whereType<Map>()) {
      final map = Map<String, dynamic>.from(raw);
      final body = map['body']?.toString() ?? '';
      final entry = parseFromBody(
        body: body,
        conversationId: map['conversation_id']?.toString() ?? '',
        accountId: map['account_id']?.toString(),
        ownerUid: map['sender_uid']?.toString(),
      );
      if (entry != null) {
        out.add(entry);
      }
    }

    out.sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
    return out;
  }
}
