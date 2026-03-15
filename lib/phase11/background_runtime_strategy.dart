enum BackgroundRuntimeMode {
  managedPush,
  unsupportedPlatform,
}

class BackgroundRuntimeDecision {
  const BackgroundRuntimeDecision({
    required this.mode,
    required this.supportsTerminatedPush,
    required this.requiresBatteryOptimizationPrompt,
  });

  final BackgroundRuntimeMode mode;
  final bool supportsTerminatedPush;
  final bool requiresBatteryOptimizationPrompt;
}

BackgroundRuntimeDecision resolveBackgroundRuntimeDecision({
  required bool pushSupported,
  required bool isAndroid,
  required bool isIos,
}) {
  if (!pushSupported || (!isAndroid && !isIos)) {
    return const BackgroundRuntimeDecision(
      mode: BackgroundRuntimeMode.unsupportedPlatform,
      supportsTerminatedPush: false,
      requiresBatteryOptimizationPrompt: false,
    );
  }

  return BackgroundRuntimeDecision(
    mode: BackgroundRuntimeMode.managedPush,
    supportsTerminatedPush: true,
    requiresBatteryOptimizationPrompt: isAndroid,
  );
}
