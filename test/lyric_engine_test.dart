import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/lyric_spring.dart';
import 'package:fluxwave/widgets/lyric/lyric_engine.dart';
import 'package:fluxwave/widgets/lyric/lyric_spring_state.dart';

/// 构造 20 行、每行高 40px、每行 2s 的引擎。
LyricEngine makeEngine({
  LyricSpringPreset preset = LyricSpringPreset.standard,
  bool springEnabled = true,
}) => LyricEngine(
  lineCount: 20,
  lineHeights: List.filled(20, 40),
  lineStartMs: List<int>.generate(20, (i) => i * 2000),
  preset: preset,
  springEnabled: springEnabled,
);

void main() {
  group('calcLayout（当前行驱动对齐）', () {
    test('激活行顶边落在 alignFraction*viewportH，上方行依次上移', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(3, force: true);

      expect(e.yOf(3), closeTo(0.2 * 600, 1e-6), reason: '激活行顶边=锚点');
      expect(e.yOf(2), closeTo(0.2 * 600 - 40, 1e-6));
      expect(e.yOf(0), closeTo(0.2 * 600 - 3 * 40, 1e-6));
      expect(e.yOf(4), closeTo(0.2 * 600 + 40, 1e-6));
    });

    test('force 落位后无动画：anyMoving 为 false，且位置精确', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(5, force: true);
      expect(e.anyMoving, isFalse);
      expect(e.yOf(5), closeTo(0.2 * 600, 1e-6));
      expect(e.yOf(4), closeTo(0.2 * 600 - 40, 1e-6));
      expect(e.alphaOf(5), 1.0);
      expect(e.alphaOf(4), closeTo(0.35, 1e-6), reason: '非激活行压暗');
      expect(e.scaleOf(5), 1.0, reason: '激活行缩放目标 1.0');
      expect(e.scaleOf(4), closeTo(0.97, 1e-6), reason: '非激活行缩放目标 0.97');
    });

    test('换句后弹簧动画启动（非 force），推进后各行目标不同', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(3, force: true);
      final y0 = e.yOf(3);
      expect(e.anyMoving, isFalse);

      e.setCurrent(4); // 换到下一句
      expect(e.anyMoving, isTrue, reason: '换句应启动弹簧动画');

      // 推进足够久后收敛到新目标。
      for (var i = 0; i < 300; i++) {
        e.tick(16);
      }
      expect(e.anyMoving, isFalse);
      expect(e.yOf(4), closeTo(0.2 * 600, 1e-6), reason: '新激活行顶边=锚点');
      expect(e.yOf(3), closeTo(0.2 * 600 - 40, 1e-6));
      expect(e.yOf(3), isNot(closeTo(y0, 1e-6)), reason: '上方行也随对齐移动');
    });
  });

  group('级联延迟', () {
    test('换句时进入视口的行先动、更下方的行延迟后动（错落）', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(6, force: true);
      final before = List.generate(20, (i) => e.yOf(i));

      e.setCurrent(3); // 切回更早的句：所有行目标下移 3*40
      // 先推进一帧（8ms）：近处行（y>=0 的行）已开始移动，远处行仍在延迟。
      e.tick(8);
      var moved = 0;
      var waiting = 0;
      for (var i = 0; i < 20; i++) {
        if ((e.yOf(i) - before[i]).abs() > 0.01) {
          moved++;
        } else {
          waiting++;
        }
      }
      expect(moved, greaterThan(0), reason: '应有行已经开始移动');
      expect(waiting, greaterThan(0), reason: '级联延迟让远处行仍在等待');

      // 延迟过后所有行收敛到同一目标布局：y(i) = align*viewportH + (i-3)*40。
      for (var i = 0; i < 500; i++) {
        e.tick(16);
      }
      for (var i = 0; i < 20; i++) {
        expect(e.yOf(i), closeTo(0.2 * 600 + (i - 3) * 40, 1e-6), reason: '行 $i 收敛到 calcLayout 目标');
      }
    });
  });

  group('动态弹簧参数（AMLL computeLinePosYSpringParams）', () {
    test('间隔越短刚度越大：100ms 比 800ms 硬', () {
      final short = computeLinePosYSpringParams(
        prevStartMs: 0,
        curStartMs: 100,
        preset: LyricSpringPreset.standard,
      );
      final long = computeLinePosYSpringParams(
        prevStartMs: 0,
        curStartMs: 800,
        preset: LyricSpringPreset.standard,
      );
      expect(short.stiffness, greaterThan(long.stiffness));
      expect(short.stiffness, closeTo(220, 1e-6), reason: '最短间隔取上限刚度');
      expect(long.stiffness, closeTo(170, 1e-6), reason: '最长间隔取下限刚度');
    });

    test('标准档阻尼 = √stiffness × 2.2（贴合 AMLL 基准）', () {
      final p = computeLinePosYSpringParams(
        prevStartMs: 0,
        curStartMs: 400,
        preset: LyricSpringPreset.standard,
      );
      expect(p.damping, closeTo(math.sqrt(p.stiffness) * 2.2, 1e-9));
    });

    test('seek 参数稳定（90/15），不随间隔变化', () {
      final p = computeLinePosYSpringParams(
        prevStartMs: 0,
        curStartMs: 800,
        preset: LyricSpringPreset.soft,
        isSeek: true,
      );
      expect(p.stiffness, 90);
      expect(p.damping, closeTo(15 * 2.8, 1e-9));
    });
  });

  group('手动滚动', () {
    test('setUserScrollOffset 平移所有行，force 落位', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(3, force: true);
      final before = List.generate(20, (i) => e.yOf(i));

      e.setUserScrollOffset(120, force: true);
      expect(e.anyMoving, isFalse);
      for (var i = 0; i < 20; i++) {
        expect(e.yOf(i), closeTo(before[i] - 120, 1e-6), reason: '行 $i 整体上移 120px');
      }
    });

    test('userScrollBounds 覆盖全部内容（任何行都能拖进可视区）', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(3, force: true);
      final (min, max) = e.userScrollBounds();
      expect(min, lessThan(0));
      expect(max, greaterThan(0));
      // 拖到最大偏移后，最后一行应仍能从顶部看到。
      e.setUserScrollOffset(max, force: true);
      expect(e.yOf(19), lessThan(600), reason: '最大上滚后末行仍可见');
    });

    test('resumeFollow 归零偏移并弹簧回正', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(3, force: true)
        ..setHeldScrollIndex(3)
        ..setUserScrollOffset(150, force: true);
      expect(e.userScrollOffset, 150);

      e.resumeFollow();
      expect(e.heldScrollIndex, isNull);
      expect(e.userScrollOffset, 0);
      expect(e.anyMoving, isTrue, reason: '回正应走弹簧动画');
      for (var i = 0; i < 500; i++) {
        e.tick(16);
      }
      expect(e.yOf(3), closeTo(0.2 * 600, 1e-6), reason: '回正后回到锚点');
    });

    test('手动浏览期间换句：锚点冻结在 heldScrollIndex，位置不回正', () {
      final e = makeEngine()
        ..setViewportHeight(600)
        ..setAlignFraction(0.2)
        ..setCurrent(3, force: true)
        ..setHeldScrollIndex(3)
        ..setUserScrollOffset(150, force: true);
      final held = List.generate(20, (i) => e.yOf(i));

      e.setCurrent(6); // 播放推进，但用户仍在浏览
      for (var i = 0; i < 600; i++) {
        e.tick(16);
      }
      for (var i = 0; i < 20; i++) {
        expect(e.yOf(i), closeTo(held[i], 1e-6), reason: '行 $i 位置应保持不变');
      }
      expect(e.currentIndex, 6, reason: '高亮仍跟随播放推进');
    });
  });
}