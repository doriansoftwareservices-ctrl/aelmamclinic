// lib/utils/logger.dart
//
// Logger بسيط وموحّد للمشروع.
// - kChatDebugLogs: فلاغ تفعيل عبر dart-define (يعمل افتراضيًا في Debug).
// - استخدام: log.d('msg'), log.w('warn'), log.e('oops', error: e, st: s).
// - يدعم tag، وتجزئة الأسطر الطويلة، و dev.log بمستويات الشدّة.
// - Span لمقاييس زمنية سريعة: final s = log.span('load'); ...; s.end('note');

import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

/// فلاغ تشغيل السجل:
/// افتراضيًا: يعمل في Debug، مطفأ في Release إلا للتحذيرات والأخطاء.
/// يمكن فرضه: --dart-define=CHAT_DEBUG_LOGS=true
const bool kChatDebugLogs = bool.fromEnvironment(
  'CHAT_DEBUG_LOGS',
  defaultValue: !kReleaseMode,
);

/// النواة الثابتة للمسجّل.
class _AppLoggerCore {
  static bool enabled = kChatDebugLogs;

  static void d(
    Object? msg, {
    String tag = 'CHAT',
    Object? data,
  }) =>
      _log(LogLevel.debug, msg, tag: tag, data: data);

  static void i(
    Object? msg, {
    String tag = 'CHAT',
    Object? data,
  }) =>
      _log(LogLevel.info, msg, tag: tag, data: data);

  static void w(
    Object? msg, {
    String tag = 'CHAT',
    Object? data,
    StackTrace? st,
  }) =>
      _log(LogLevel.warn, msg, tag: tag, data: data, st: st);

  static void e(
    Object? msg, {
    String tag = 'CHAT',
    Object? error,
    StackTrace? st,
  }) =>
      _log(LogLevel.error, msg, tag: tag, error: error, st: st);

  static _LogSpan span(String name, {String tag = 'CHAT'}) =>
      _LogSpan._(name, tag);

  static void _log(
    LogLevel level,
    Object? msg, {
    required String tag,
    Object? data,
    Object? error,
    StackTrace? st,
  }) {
    final now = DateTime.now().toIso8601String();
    final lvl = switch (level) {
      LogLevel.debug => 'D',
      LogLevel.info => 'I',
      LogLevel.warn => 'W',
      LogLevel.error => 'E',
    };
    final head = '[$now][$tag][$lvl]';
    final body = _stringify(msg, data: data, error: error, st: st);
    final text = '$head $body';

    // عندما يكون معطلاً: نُبقي التحذيرات والأخطاء فقط.
    final shouldPrint =
        enabled || level == LogLevel.warn || level == LogLevel.error;
    if (!shouldPrint) return;

    // sev للتوافق مع dev.log
    final severity = switch (level) {
      LogLevel.debug => 500,
      LogLevel.info => 800,
      LogLevel.warn => 900,
      LogLevel.error => 1000,
    };

    // dev.log يُرسل للـ Observatory/IDE
    dev.log(text, name: tag, level: severity, error: error, stackTrace: st);

    // وفي Debug نضمن ظهوره في وحدة تحكم Flutter أيضًا مع تقطيع الأسطر.
    if (kDebugMode) {
      _printChunked(text);
      if (error != null) _printChunked('error: $error');
      if (st != null) _printChunked(st.toString());
    }
  }

  static String _stringify(
    Object? msg, {
    Object? data,
    Object? error,
    StackTrace? st,
  }) {
    final b = StringBuffer()..write(msg ?? '');
    if (data != null) b.write(' | data=$data');
    if (error != null) b.write(' | error=$error');
    if (st != null && kDebugMode) b.write('\n$st');
    return b.toString();
  }

  static void _printChunked(String text, {int chunk = 900}) {
    // لتفادي حدود logcat/الكونسول
    for (var i = 0; i < text.length; i += chunk) {
      final end = (i + chunk < text.length) ? i + chunk : text.length;
      debugPrint(text.substring(i, end));
    }
  }
}

/// واجهة ودّية: log.d / log.i / log.w / log.e + span()
final log = _LogFacade();

class _LogFacade {
  void d(Object? msg, {String tag = 'CHAT', Object? data}) =>
      _AppLoggerCore.d(msg, tag: tag, data: data);

  void i(Object? msg, {String tag = 'CHAT', Object? data}) =>
      _AppLoggerCore.i(msg, tag: tag, data: data);

  void w(Object? msg, {String tag = 'CHAT', Object? data, StackTrace? st}) =>
      _AppLoggerCore.w(msg, tag: tag, data: data, st: st);

  void e(Object? msg, {String tag = 'CHAT', Object? error, StackTrace? st}) =>
      _AppLoggerCore.e(msg, tag: tag, error: error, st: st);

  /// Span بسيط لقياس مدة تنفيذ مهمة
  _LogSpan span(String name, {String tag = 'CHAT'}) =>
      _AppLoggerCore.span(name, tag: tag);

  /// تمكين/تعطيل أثناء التشغيل (إن لزم)
  void setEnabled(bool v) => _AppLoggerCore.enabled = v;
}

/// أداة قياس زمن مهمة محددة.
class _LogSpan {
  final String name;
  final String tag;
  final Stopwatch _sw = Stopwatch()..start();

  _LogSpan._(this.name, this.tag) {
    _AppLoggerCore.d('⏱️ $name…', tag: tag);
  }

  void end([Object? note]) {
    _sw.stop();
    final ms = _sw.elapsedMilliseconds;
    _AppLoggerCore.i(
      '⏱️ $name done in ${ms}ms${note != null ? " — $note" : ""}',
      tag: tag,
    );
  }
}

/// إضافة صغيرة لاستخدام الوسم تلقائيًا باسم الصنف/الويدجت.
extension LogTagX on Object {
  void logD(Object? msg, {String? tag}) =>
      log.d(msg, tag: tag ?? runtimeType.toString());
  void logI(Object? msg, {String? tag}) =>
      log.i(msg, tag: tag ?? runtimeType.toString());
  void logW(Object? msg, {String? tag, StackTrace? st}) =>
      log.w(msg, tag: tag ?? runtimeType.toString(), st: st);
  void logE(Object? msg, {String? tag, Object? error, StackTrace? st}) =>
      log.e(msg, tag: tag ?? runtimeType.toString(), error: error, st: st);
}
