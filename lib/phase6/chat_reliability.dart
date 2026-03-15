import 'dart:math';

bool hasBoundChatAccount(String? accountId) {
  return (accountId ?? '').trim().isNotEmpty;
}

String buildChatStorageScopeKey({
  required String uid,
  required String accountId,
}) {
  return '${uid.trim()}|${accountId.trim()}';
}

class ChatRetryPolicy {
  final Duration baseDelay;
  final double multiplier;
  final Duration maxDelay;

  const ChatRetryPolicy({
    required this.baseDelay,
    this.multiplier = 2,
    required this.maxDelay,
  });

  Duration delayForAttempt(int attempt) {
    final normalizedAttempt = attempt < 1 ? 1 : attempt;
    final factor = pow(multiplier, normalizedAttempt - 1).toDouble();
    final delayMs = min(
      maxDelay.inMilliseconds,
      max(1, (baseDelay.inMilliseconds * factor).round()),
    );
    return Duration(milliseconds: delayMs);
  }
}
