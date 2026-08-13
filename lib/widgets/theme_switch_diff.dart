import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 从 [origin] 到屏幕四个角落的最大距离，即扩散到覆盖全屏所需的最大半径。
double maxRevealRadius(Offset origin, Size screenSize) {
  final corners = [
    (origin - Offset.zero).distance,
    (origin - Offset(screenSize.width, 0)).distance,
    (origin - Offset(0, screenSize.height)).distance,
    (origin - screenSize.bottomRight(Offset.zero)).distance,
  ];
  return corners.reduce(math.max);
}

/// 给定起始半径与进度，计算当前扩散圆半径（clipper 与 halo 共用，保证一致）。
double revealRadiusAt({
  required Offset origin,
  required Size screenSize,
  required double startRadius,
  required double progress,
}) {
  final start = math.max(0.0, startRadius);
  final maxR = maxRevealRadius(origin, screenSize);
  return start + (maxR - start) * progress;
}

/// 主题切换「扩散」的圆形裁剪。
///
/// 以 [origin] 为圆心、随 [progress]（0→1）从 [startRadius] 放大到覆盖全屏：
/// 上层是新主题的实时界面，下层是旧主题的静态快照。两幅画面始终同时可见，
/// 圆孔只是把新旧主题的边界从点击组件处向外扫过，不盖住任何内容。
///
/// [startRadius] 通常取被点组件尺寸的一半（`max(w, h) / 2`），使扩散从
/// 「一个与被点组件等大小的圆」开始，而非 0 半径的点，观感更自然
/// （起始即填满组件，不产生「从某点向外刮」的起点）。
class CircleRevealClipper extends CustomClipper<Path> {
  final Offset origin;
  final double progress;
  final double startRadius;
  final Size screenSize;

  const CircleRevealClipper({
    required this.origin,
    required this.progress,
    required this.startRadius,
    required this.screenSize,
  });

  @override
  Path getClip(Size size) {
    final radius = revealRadiusAt(
      origin: origin,
      screenSize: screenSize,
      startRadius: startRadius,
      progress: progress,
    );
    return Path()..addOval(Rect.fromCircle(center: origin, radius: radius));
  }

  @override
  bool shouldReclip(CircleRevealClipper oldClipper) =>
      oldClipper.origin != origin ||
      oldClipper.progress != progress ||
      oldClipper.startRadius != startRadius ||
      oldClipper.screenSize != screenSize;
}

/// 在 App 根部（MultiProvider / MaterialApp 之上）暴露主题切换扩散能力：
/// 截取旧画面快照 + 圆形裁剪揭示新主题。由主题选择卡片调用。
class ThemeRevealScope extends InheritedWidget {
  final Future<void> Function({
    required Offset origin,
    required double startRadius,
    required ThemeMode newMode,
  })
  startReveal;

  const ThemeRevealScope({
    super.key,
    required this.startReveal,
    required super.child,
  });

  static ThemeRevealScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeRevealScope>();

  @override
  bool updateShouldNotify(ThemeRevealScope oldWidget) => true;
}
