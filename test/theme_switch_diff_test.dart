import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/widgets/theme_switch_diff.dart';

void main() {
  testWidgets('CircleRevealClipper：startRadius 起步、progress 1 覆盖全屏', (
    tester,
  ) async {
    const origin = Offset(50, 50);
    const screenSize = Size(400, 800);
    const startRadius = 30.0;

    final clipperAt0 = CircleRevealClipper(
      origin: origin,
      progress: 0,
      startRadius: startRadius,
      screenSize: screenSize,
    );
    final clipperAt1 = CircleRevealClipper(
      origin: origin,
      progress: 1,
      startRadius: startRadius,
      screenSize: screenSize,
    );
    final midProgress = 0.5;

    final pathAt0 = clipperAt0.getClip(screenSize);
    final pathAt1 = clipperAt1.getClip(screenSize);

    // progress 0：从 startRadius（组件一半）起步，非 0 半径点。
    expect(pathAt0.getBounds().width, closeTo(startRadius * 2, 0.001));

    // progress 1：以组件中心为圆心、覆盖全屏（半径 >= 到最远角距离）。
    final maxRadius = [
      (origin - Offset.zero).distance,
      (origin - Offset(screenSize.width, 0)).distance,
      (origin - Offset(0, screenSize.height)).distance,
      (origin - screenSize.bottomRight(Offset.zero)).distance,
    ].reduce(math.max);
    expect(pathAt1.getBounds().width, closeTo(maxRadius * 2, 0.001));
    expect(pathAt1.getBounds().height, closeTo(maxRadius * 2, 0.001));

    // progress 0.5：半径在 startRadius 与 maxRadius 之间线性插值。
    final mid =
        CircleRevealClipper(
          origin: origin,
          progress: midProgress,
          startRadius: startRadius,
          screenSize: screenSize,
        ).getClip(screenSize).getBounds().width /
        2;
    expect(
      mid,
      closeTo(startRadius + (maxRadius - startRadius) * midProgress, 0.001),
    );
  });
}
