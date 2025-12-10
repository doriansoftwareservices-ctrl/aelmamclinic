// lib/services/realtime_hub.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef VoidCb = void Function();
typedef MsgCb = void Function(PostgresChangePayload payload);

/// Hub واحد لإدارة الاشتراك في تغييرات جداول الدردشة.
/// يحافظ على قناة واحدة فقط، ويدعم تحديث الفلاتر وإعادة الاشتراك عند تغيّر حالة Auth.
class RealtimeHub {
  RealtimeHub._();
  static final RealtimeHub instance = RealtimeHub._();

  final SupabaseClient _sb = Supabase.instance.client;

  RealtimeChannel? _channel;
  StreamSubscription<AuthState>? _authSub;

  // آخر فلاتر مستخدمة
  String? _accountId;
  String? _myUid;

  // آخر callbacks لتفعيل إعادة الاشتراك بدون تمريرها كل مرة
  VoidCb? _onConversationsChanged;
  VoidCb? _onParticipantsChanged;
  MsgCb? _onMessageChanged;

  bool get isActive => _channel != null;

  /// اشتراك واحد على مستوى التطبيق.
  /// لو تغيّرت الفلاتر يعاد إنشاء القناة تلقائياً.
  void ensureSubscribed({
    required VoidCb onConversationsChanged,
    required VoidCb onParticipantsChanged,
    required MsgCb onMessageChanged,
    String? accountId,
    String? myUid,
  }) {
    final sameFilters =
        _channel != null && _accountId == accountId && _myUid == myUid;

    _onConversationsChanged = onConversationsChanged;
    _onParticipantsChanged = onParticipantsChanged;
    _onMessageChanged = onMessageChanged;
    _accountId = accountId;
    _myUid = myUid;

    if (sameFilters) return;

    // أعِد بناء القناة وفق الفلاتر الجديدة
    close();
    _subscribeInternal();
    _ensureAuthListener();
  }

  /// إغلاق يدوي كامل.
  void close() {
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        ch.unsubscribe();
      } catch (_) {}
      try {
        _sb.removeChannel(ch);
      } catch (_) {}
    }
  }

  /// إلغاء كل شيء عند إنهاء التطبيق.
  void dispose() {
    close();
    try {
      _authSub?.cancel();
    } catch (_) {}
    _authSub = null;
  }

  /// لطباعة معلومات القنوات النشطة.
  void debugChannels() {
    final list = _sb.getChannels();
    debugPrint('Realtime channels = ${list.length}');
    for (final ch in list) {
      debugPrint(' - ${ch.topic}');
    }
  }

  // --------------------------- داخلي ---------------------------

  void _subscribeInternal() {
    if (_onConversationsChanged == null ||
        _onParticipantsChanged == null ||
        _onMessageChanged == null) {
      // لم تُمرّر callbacks
      return;
    }

    final ch = _sb.channel('chat-hub');

    // chat_conversations
    ch.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'chat_conversations',
      filter: (_accountId == null)
          ? null
          : PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'account_id',
              value: _accountId,
            ),
      callback: (_) => _onConversationsChanged!.call(),
    );

    // chat_participants (خاص بالمستخدم الحالي)
    ch.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'chat_participants',
      filter: (_myUid == null)
          ? null
          : PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_uid',
              value: _myUid,
            ),
      callback: (_) => _onParticipantsChanged!.call(),
    );

    // chat_reads → تؤثر على شارات غير المقروء
    ch.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'chat_reads',
      filter: (_myUid == null)
          ? null
          : PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_uid',
              value: _myUid,
            ),
      callback: (_) => _onConversationsChanged!.call(),
    );

    // chat_messages (مفلترة بالحساب إن وُجد)
    ch.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'chat_messages',
      filter: (_accountId == null)
          ? null
          : PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'account_id',
              value: _accountId,
            ),
      callback: (payload) => _onMessageChanged!.call(payload),
    );

    ch.subscribe((status, [err]) {
      if (kDebugMode) {
        debugPrint('RealtimeHub status: $status  err: $err');
      }
    });

    _channel = ch;
  }

  void _ensureAuthListener() {
    if (_authSub != null) return;
    _authSub = _sb.auth.onAuthStateChange.listen((event) {
      final session = event.session;
      // عند تسجيل الخروج أغلق القناة. عند تسجيل الدخول أعد الاشتراك بالفلاتر المخزنة.
      if (session == null) {
        close();
      } else {
        // إن كانت القناة مغلقة أعد إنشاءها بنفس الفلاتر.
        if (_channel == null) {
          _subscribeInternal();
        }
      }
    });
  }
}
