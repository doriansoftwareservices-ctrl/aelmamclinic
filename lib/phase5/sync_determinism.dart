import 'dart:math';

enum SyncLifecyclePhase {
  idle,
  bootstrapping,
  realtimeStarting,
  realtimeActive,
  paused,
  blocked,
  pushing,
  pulling,
  disposed,
}

class SyncRetryPolicy {
  final Duration baseDelay;
  final double multiplier;
  final Duration maxDelay;

  const SyncRetryPolicy({
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

class SyncPullScheduleDecision {
  final bool shouldPullNow;
  final Duration? nextCheckDelay;
  final String reason;
  final Duration activityAge;

  const SyncPullScheduleDecision({
    required this.shouldPullNow,
    required this.nextCheckDelay,
    required this.reason,
    required this.activityAge,
  });
}

SyncPullScheduleDecision computeSyncPullSchedule({
  required DateTime now,
  required Duration stalenessThreshold,
  DateTime? lastPullAt,
  DateTime? lastRealtimeEventAt,
  bool force = false,
}) {
  if (force) {
    return const SyncPullScheduleDecision(
      shouldPullNow: true,
      nextCheckDelay: null,
      reason: 'force',
      activityAge: Duration.zero,
    );
  }

  final latestActivityAt = () {
    if (lastPullAt == null) return lastRealtimeEventAt;
    if (lastRealtimeEventAt == null) return lastPullAt;
    return lastPullAt.isAfter(lastRealtimeEventAt)
        ? lastPullAt
        : lastRealtimeEventAt;
  }();

  if (latestActivityAt == null) {
    return const SyncPullScheduleDecision(
      shouldPullNow: true,
      nextCheckDelay: null,
      reason: 'no_activity',
      activityAge: Duration.zero,
    );
  }

  final age = now.difference(latestActivityAt);
  if (age >= stalenessThreshold) {
    return SyncPullScheduleDecision(
      shouldPullNow: true,
      nextCheckDelay: null,
      reason: 'stale_activity',
      activityAge: age,
    );
  }

  final remaining = stalenessThreshold - age;
  return SyncPullScheduleDecision(
    shouldPullNow: false,
    nextCheckDelay:
        remaining <= Duration.zero ? const Duration(seconds: 1) : remaining,
    reason: 'await_staleness_window',
    activityAge: age,
  );
}
