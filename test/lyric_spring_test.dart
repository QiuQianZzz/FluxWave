import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/lyric_spring.dart';
import 'package:fluxwave/widgets/lyric/lyric_spring_state.dart';

/// 阻尼比 = damping / (2·√(stiffness·mass))：>1 过阻尼（无回弹），<1 欠阻尼
/// （有回弹，越小过冲越大）。
double _dampingRatio(SpringParams p) =>
    p.damping / (2 * math.sqrt(p.stiffness * p.mass));

/// 欠阻尼振荡的理论最大过冲比例 ≈ e^(-πζ/√(1-ζ²))。
double _overshoot(SpringParams p) {
  final z = _dampingRatio(p);
  if (z >= 1) return 0;
  return math.exp(-math.pi * z / math.sqrt(1 - z * z));
}

void main() {
  group('computeLinePosYSpringParams 档位物理', () {
    SpringParams paramsOf(LyricSpringPreset preset) =>
        computeLinePosYSpringParams(
          prevStartMs: 0,
          curStartMs: 3000,
          preset: preset,
        );

    test('soft/standard 过阻尼（无回弹），bouncy 欠阻尼（有过冲）', () {
      expect(_overshoot(paramsOf(LyricSpringPreset.soft)), 0);
      expect(_overshoot(paramsOf(LyricSpringPreset.standard)), 0);
      final bouncy = _overshoot(paramsOf(LyricSpringPreset.bouncy));
      expect(bouncy, greaterThan(0.05), reason: 'bouncy 应有可见回弹');
      expect(bouncy, lessThan(0.5), reason: '回弹不应过大');
    });

    test('过冲量排序：soft == standard < bouncy', () {
      final soft = _overshoot(paramsOf(LyricSpringPreset.soft));
      final standard = _overshoot(paramsOf(LyricSpringPreset.standard));
      final bouncy = _overshoot(paramsOf(LyricSpringPreset.bouncy));
      expect(soft, standard);
      expect(bouncy, greaterThan(standard));
    });

    test('seek 用固定稳定参数（90/15·档位系数），即使 bouncy 也几乎无过冲', () {
      final p = computeLinePosYSpringParams(
        prevStartMs: 0,
        curStartMs: 0,
        preset: LyricSpringPreset.bouncy,
        isSeek: true,
      );
      expect(p.stiffness, 90);
      expect(p.damping, closeTo(15 * 1.1, 1e-9));
      expect(_overshoot(p), lessThan(0.05));
    });
  });
}
