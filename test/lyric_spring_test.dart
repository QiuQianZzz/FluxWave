import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/lyric_spring.dart';

void main() {
  group('LyricSpringPreset 档位排序', () {
    test('轻弹 < 标准 < 强弹（过冲量递增）', () {
      final soft = springOvershoot(LyricSpringPreset.soft.spring);
      final standard = springOvershoot(LyricSpringPreset.standard.spring);
      final bouncy = springOvershoot(LyricSpringPreset.bouncy.spring);
      expect(standard, greaterThan(soft));
      expect(bouncy, greaterThan(standard));
    });

    test('标准档确实存在过冲（不是单调缓动）', () {
      final over = springOvershoot(LyricSpringPreset.standard.spring);
      expect(over, greaterThan(0));
      expect(over, lessThan(0.5));
    });
  });

  group('LyricSpring.spring / duration', () {
    test('名义时长取档位值且随档位单调不减', () {
      final soft = LyricSpring.duration(LyricSpringPreset.soft);
      final bouncy = LyricSpring.duration(LyricSpringPreset.bouncy);
      expect(soft, lessThanOrEqualTo(bouncy));
      expect(soft.inMilliseconds, greaterThan(200));
    });

    test('名义时长内曲线已接近目标值（余量交给结束帧吸附）', () {
      final sim = LyricSpring.spring(
        LyricSpringPreset.standard.spring,
        0,
        1,
      );
      final end = LyricSpring.duration(LyricSpringPreset.standard);
      final x = sim.x(end.inMilliseconds / 1000.0);
      expect((x - 1.0).abs(), lessThan(0.02));
    });

    test('逆向弹簧（聚焦→非聚焦）在名义时长内接近 0', () {
      final sim = LyricSpring.spring(
        LyricSpringPreset.standard.spring,
        1,
        0,
      );
      final end = LyricSpring.duration(LyricSpringPreset.standard);
      expect(sim.x(end.inMilliseconds / 1000.0).abs(), lessThan(0.02));
    });
  });
}