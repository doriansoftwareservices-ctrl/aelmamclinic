// lib/widgets/responsive_frame.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

class ResponsiveFrame extends StatelessWidget {
  const ResponsiveFrame({
    super.key,
    required this.child,
    this.maxWidth = double.infinity,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    final clampedWidth = math.min(width, maxWidth);

    if (width == clampedWidth) {
      return child;
    }

    // Constrain wide layouts so all screens stay readable on large displays.
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: clampedWidth,
          child: MediaQuery(
            data: mq.copyWith(size: Size(clampedWidth, mq.size.height)),
            child: child,
          ),
        ),
      ),
    );
  }
}
