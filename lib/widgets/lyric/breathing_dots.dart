import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 计算一帧圆点动画的参数（对齐 AMLL `interlude-dots.ts`）。
///
/// 动画锚定到 [anchorTimeMs]（进入间奏/seek 时以当前时间重新锚定），
/// 各阶段按「锚点 → [endTimeMs] 的剩余时长」分配：
/// - 前 2s `easeOutExpo` 入场放大，前 500ms 完全隐藏、500–1000ms 渐入；
/// - 之后按整周期（~4.5s）自适应正弦呼吸（±5%）；
/// - 最后 750ms `easeInOutBack` 收缩回弹，最后 375ms 渐隐，直接「汇入」
///   下一句，避免结束时整组瞬间消失；
/// - 三个圆点随进度按 1/3 间隔依次点亮（0.25 → 1）；
/// - 基准缩放 0.7。
///
/// 返回每帧的 [scale] 与每个圆点的透明度（已含全局透明度）。
({double scale, List<double> dotAlphas}) computeBreathingDotsFrame({
  required int anchorTimeMs,
  required int endTimeMs,
  required int currentTimeMs,
  int dotCount = 3,
}) {
  const targetBreatheDurationMs = 4500;
  const enterDurationMs = 2000;
  const enterFadeInStartMs = 500;
  const enterFadeInEndMs = 1000;
  const exitDurationMs = 750;
  const exitFadeDurationMs = 375;
  const baseScale = 0.7;

  final empty = (scale: 0.0, dotAlphas: List<double>.filled(dotCount, 0));
  final total = endTimeMs - anchorTimeMs;
  if (total <= 0) return empty;
  final elapsed = (currentTimeMs - anchorTimeMs).clamp(0, total);
  if (elapsed >= total) return empty;
  final remaining = total - elapsed;

  // 呼吸周期：把整段切分为整数个 ~4.5s 周期，速度随间奏长度自适应。
  final breatheDuration =
      total / (total / targetBreatheDurationMs).ceil().toDouble();

  var scale = 1.0;
  var globalOpacity = 1.0;

  // 正弦呼吸，围绕基准 ±5%。
  scale *=
      math.sin(1.5 * math.pi - (elapsed / breatheDuration) * 2 * math.pi) /
              20 +
          1;

  // 入场放大（前 2s easeOutExpo）。
  if (elapsed < enterDurationMs) {
    scale *= _easeOutExpo(elapsed / enterDurationMs);
  }

  // 入场透明度：前 500ms 隐藏，500–1000ms 渐入。
  if (elapsed < enterFadeInStartMs) {
    globalOpacity = 0;
  } else if (elapsed < enterFadeInEndMs) {
    globalOpacity *=
        (elapsed - enterFadeInStartMs) / (enterFadeInEndMs - enterFadeInStartMs);
  }

  // 退场收缩（最后 750ms easeInOutBack 回弹）。
  if (remaining < exitDurationMs) {
    scale *= 1 - _easeInOutBack((exitDurationMs - remaining) / exitDurationMs / 2);
  }

  // 退场渐隐（最后 375ms）。
  if (remaining < exitFadeDurationMs) {
    globalOpacity *= (remaining / exitFadeDurationMs).clamp(0.0, 1.0);
  }

  scale = (scale > 0 ? scale : 0) * baseScale;

  // 逐点点亮：三圆点随进度按 1/3 间隔，0.25 → 1。
  final dotsDuration = total - exitDurationMs;
  double dotOpacity(int i) {
    if (dotsDuration <= 0) return 0.25;
    final phase = elapsed - dotsDuration * i / dotCount;
    return ((phase * dotCount / dotsDuration) * 0.75).clamp(0.25, 1.0);
  }

  return (
    scale: scale,
    dotAlphas: [
      for (var i = 0; i < dotCount; i++)
        (globalOpacity * dotOpacity(i)).clamp(0.0, 1.0),
    ],
  );
}

double _easeOutExpo(double x) =>
    x >= 1 ? 1 : 1 - math.pow(2, -10 * x).toDouble();

double _easeInOutBack(double x) {
  const c1 = 1.70158;
  const c2 = c1 * 1.525;
  if (x < 0.5) {
    return (math.pow(2 * x, 2) * ((c2 + 1) * 2 * x - c2)).toDouble() / 2;
  }
  return ((math.pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2)
              .toDouble()) /
      2;
}

/// 前奏/间奏呼吸圆点。
///
/// 无状态、纯时间驱动（跟随 [currentTimeMs]），暂停/停止时时间不再前进，
/// 动画自然冻结。详见 [computeBreathingDotsFrame]。
class BreathingDots extends StatelessWidget {
  /// 动画锚定时间（进入间奏或 seek 时以当前时间重新锚定）。
  final int anchorTimeMs;

  /// 圆点动画结束时间（下一句歌词开始时间）。
  final int endTimeMs;

  final int currentTimeMs;
  final Color color;
  final int dotCount;
  final double dotSize;
  final double dotMargin;

  const BreathingDots({
    super.key,
    required this.anchorTimeMs,
    required this.endTimeMs,
    required this.currentTimeMs,
    required this.color,
    this.dotCount = 3,
    this.dotSize = 16,
    this.dotMargin = 12,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BreathingDotsPainter(
        anchorTimeMs: anchorTimeMs,
        endTimeMs: endTimeMs,
        currentTimeMs: currentTimeMs,
        color: color,
        dotCount: dotCount,
        dotSize: dotSize,
        dotMargin: dotMargin,
      ),
      size: Size(dotSize * dotCount + dotMargin * (dotCount - 1), dotSize),
    );
  }
}

class _BreathingDotsPainter extends CustomPainter {
  final int anchorTimeMs;
  final int endTimeMs;
  final int currentTimeMs;
  final Color color;
  final int dotCount;
  final double dotSize;
  final double dotMargin;

  _BreathingDotsPainter({
    required this.anchorTimeMs,
    required this.endTimeMs,
    required this.currentTimeMs,
    required this.color,
    required this.dotCount,
    required this.dotSize,
    required this.dotMargin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final frame = computeBreathingDotsFrame(
      anchorTimeMs: anchorTimeMs,
      endTimeMs: endTimeMs,
      currentTimeMs: currentTimeMs,
      dotCount: dotCount,
    );
    if (frame.scale <= 0 || frame.dotAlphas.every((a) => a <= 0)) return;

    final center = Offset(size.width / 2, size.height / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(frame.scale);
    canvas.translate(-center.dx, -center.dy);

    for (var i = 0; i < dotCount; i++) {
      final cx = dotSize / 2 + (dotSize + dotMargin) * i;
      final cy = size.height / 2;
      canvas.drawCircle(
        Offset(cx, cy),
        dotSize / 2,
        Paint()..color = color.withValues(alpha: frame.dotAlphas[i]),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BreathingDotsPainter oldDelegate) {
    return oldDelegate.anchorTimeMs != anchorTimeMs ||
        oldDelegate.endTimeMs != endTimeMs ||
        oldDelegate.currentTimeMs != currentTimeMs ||
        oldDelegate.color != color;
  }
}
