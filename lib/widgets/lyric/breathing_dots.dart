import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 前奏/间奏呼吸圆点。
///
/// 三阶段时间轴：进入淡入放大 → 呼吸（余弦收缩）→ 逐点点亮 → 退场淡出。
/// 圆点直径、间距、时长均可调，[color] 跟随主题。
class BreathingDots extends StatelessWidget {
  final int startTimeMs;
  final int endTimeMs;
  final int currentTimeMs;
  final Color color;
  final int dotCount;
  final double dotSize;
  final double dotMargin;

  const BreathingDots({
    super.key,
    required this.startTimeMs,
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
        startTimeMs: startTimeMs,
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
  static const _minScale = 0.8;
  static const _breatheMidpoint = 0.9;
  static const _breatheAmplitude = 0.1;
  static const _enterDurationMs = 3000;
  static const _breathingCycleDurationMs = 3000;
  static const _preExitStillDuration = 200;
  static const _preExitDipAndRiseDuration = 3000;
  static const _exitDurationMs = 200;

  final int startTimeMs;
  final int endTimeMs;
  final int currentTimeMs;
  final Color color;
  final int dotCount;
  final double dotSize;
  final double dotMargin;

  _BreathingDotsPainter({
    required this.startTimeMs,
    required this.endTimeMs,
    required this.currentTimeMs,
    required this.color,
    required this.dotCount,
    required this.dotSize,
    required this.dotMargin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final totalAvailable = (endTimeMs - startTimeMs).toDouble();
    final defaultTotal =
        (_enterDurationMs +
                _preExitDipAndRiseDuration +
                _preExitStillDuration +
                _exitDurationMs)
            .toDouble();

    // 呼吸阶段至少保留总时长的一部分，避免短间奏（<defaultTotal）时因等比
    // 压缩而退化为 0（dipStart == enterEnd，圆点不呼吸）。
    final breathingBudget = math.max(0.0, totalAvailable * 0.25);
    final fixedTotal = math.max(0.0, totalAvailable - breathingBudget);
    final factor = fixedTotal >= defaultTotal ? 1.0 : fixedTotal / defaultTotal;

    final enter = _enterDurationMs * factor;
    final dip = _preExitDipAndRiseDuration * factor;
    final still = _preExitStillDuration * factor;
    final exit = _exitDurationMs * factor;

    final enterEnd = startTimeMs + enter;
    final dipStart = endTimeMs - exit - still - dip;
    final stillStart = endTimeMs - exit - still;
    final exitStart = endTimeMs - exit;
    final breathingDuration = dipStart - enterEnd;

    final t = currentTimeMs.toDouble();
    var scale = 1.0;
    var alpha = 1.0;
    var revealProgress = 1.0;

    if (t < enterEnd) {
      final progress = ((t - startTimeMs) / (enterEnd - startTimeMs)).clamp(
        0.0,
        1.0,
      );
      alpha = Curves.fastOutSlowIn.transform(progress);
      scale = alpha * _minScale;
      revealProgress = alpha;
    } else if (t < dipStart) {
      revealProgress = 1.0;
      scale = _breatheScale(
        timeInPhaseMs: t - enterEnd,
        phaseDurationMs: breathingDuration,
        preferredCycleDurationMs: _breathingCycleDurationMs,
      );
    } else if (t < stillStart) {
      final progress = ((t - dipStart) / (stillStart - dipStart)).clamp(
        0.0,
        1.0,
      );
      scale = 0.8 + 0.2 * math.cos(progress * 2 * math.pi);
    } else if (t < exitStart) {
      scale = 1.0;
    } else {
      final progress = ((endTimeMs - t) / (endTimeMs - exitStart)).clamp(
        0.0,
        1.0,
      );
      final eased = Curves.fastOutSlowIn.transform(progress);
      alpha = eased;
      scale = eased;
      revealProgress = 1.0;
    }

    if (totalAvailable <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);

    canvas.saveLayer(Offset.zero & size, Paint());

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);

    for (var i = 0; i < dotCount; i++) {
      final dotAlpha = breathingDuration > 0 && t >= enterEnd
          ? ((t - enterEnd - i * (breathingDuration / dotCount)) /
                            (breathingDuration / dotCount))
                        .clamp(0.0, 1.0) *
                    0.6 +
                0.4
          : 0.4;
      final cx = dotSize / 2 + (dotSize + dotMargin) * i;
      final cy = size.height / 2;
      canvas.drawCircle(
        Offset(cx, cy),
        dotSize / 2,
        Paint()..color = color.withValues(alpha: dotAlpha * alpha),
      );
    }
    canvas.restore();

    // 左→右揭示
    final softEdgeWidth = 0.5;
    final revealPos = revealProgress * (1 + softEdgeWidth);
    final shader = LinearGradient(
      colors: [
        Colors.black,
        Colors.black,
        Colors.transparent,
        Colors.transparent,
      ],
      stops: [
        0,
        (revealPos - softEdgeWidth).clamp(0.0, 1.0),
        revealPos.clamp(0.0, 1.0),
        1,
      ],
    ).createShader(Offset.zero & size);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.dstIn,
    );

    canvas.restore();
  }

  double _breatheScale({
    required double timeInPhaseMs,
    required double phaseDurationMs,
    required int preferredCycleDurationMs,
  }) {
    if (phaseDurationMs <= 0) return 1;
    final safePhase = phaseDurationMs.clamp(1.0, double.maxFinite);
    final safeTime = timeInPhaseMs.clamp(0.0, safePhase);
    final desiredHalfCycles =
        safePhase / (preferredCycleDurationMs.clamp(1, 1 << 30) / 2.0);
    final alignedHalfCycles = _nearestOddHalfCycle(desiredHalfCycles);
    final angle = (safeTime / safePhase) * alignedHalfCycles * math.pi;
    return _breatheMidpoint - _breatheAmplitude * math.cos(angle);
  }

  int _nearestOddHalfCycle(double desiredHalfCycles) {
    final rounded = desiredHalfCycles.round().clamp(1, 1 << 30);
    if (rounded % 2 == 1) return rounded;
    final lowerOdd = (rounded - 1).clamp(1, 1 << 30);
    final upperOdd = rounded + 1;
    return (desiredHalfCycles - lowerOdd).abs() <=
            (upperOdd - desiredHalfCycles).abs()
        ? lowerOdd
        : upperOdd;
  }

  @override
  bool shouldRepaint(covariant _BreathingDotsPainter oldDelegate) {
    return oldDelegate.currentTimeMs != currentTimeMs ||
        oldDelegate.startTimeMs != startTimeMs ||
        oldDelegate.endTimeMs != endTimeMs ||
        oldDelegate.color != color;
  }
}
