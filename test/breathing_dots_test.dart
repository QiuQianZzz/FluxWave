import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/widgets/lyric/breathing_dots.dart';

void main() {
  group('computeBreathingDotsFrame', () {
    test('前 500ms 隐藏：透明度为 0（缩放可已开始）', () {
      for (final t in [0, 250, 499]) {
        final f = computeBreathingDotsFrame(
          anchorTimeMs: 0,
          endTimeMs: 8000,
          currentTimeMs: t,
          dotCount: 3,
        );
        expect(f.dotAlphas, everyElement(0), reason: 't=$t');
      }
      // t=0 时 easeOutExpo(0)=0，缩放也为 0。
      expect(
        computeBreathingDotsFrame(
          anchorTimeMs: 0,
          endTimeMs: 8000,
          currentTimeMs: 0,
          dotCount: 3,
        ).scale,
        0,
      );
    });

    test('入场：500–1000ms 渐入，缩放随 easeOutExpo 增大', () {
      final f = computeBreathingDotsFrame(
        anchorTimeMs: 0,
        endTimeMs: 8000,
        currentTimeMs: 750,
        dotCount: 3,
      );
      expect(f.scale, inInclusiveRange(0.4, 0.8));
      expect(f.dotAlphas, everyElement(inInclusiveRange(0.05, 0.2)));
    });

    test('入场完成：缩放≈基准×1.05（呼吸峰值）', () {
      final f = computeBreathingDotsFrame(
        anchorTimeMs: 0,
        endTimeMs: 8000,
        currentTimeMs: 2000,
        dotCount: 3,
      );
      expect(f.scale, closeTo(0.7 * 1.05, 0.005));
    });

    test('稳态呼吸（入场后至退场前）：缩放保持在基准 ±5% 内', () {
      for (var t = 2100; t <= 7240; t += 100) {
        final f = computeBreathingDotsFrame(
          anchorTimeMs: 0,
          endTimeMs: 8000,
          currentTimeMs: t,
          dotCount: 3,
        );
        expect(f.scale, inInclusiveRange(0.7 * 0.95 - 1e-9, 0.7 * 1.05 + 1e-9),
            reason: 't=$t');
      }
    });

    test('逐点点亮：随进度依次从 0.25 升到 1，三圆点错开', () {
      // t=2000：第 1 个点亮，后两个仍 0.25。
      final f1 = computeBreathingDotsFrame(
        anchorTimeMs: 0,
        endTimeMs: 8000,
        currentTimeMs: 2000,
        dotCount: 3,
      );
      expect(f1.dotAlphas[0], inInclusiveRange(0.6, 0.65));
      expect(f1.dotAlphas[1], 0.25);
      expect(f1.dotAlphas[2], 0.25);

      // t=5500：前两个 >0.25 且递减，最后一个刚好升到 0.25。
      final f2 = computeBreathingDotsFrame(
        anchorTimeMs: 0,
        endTimeMs: 8000,
        currentTimeMs: 5500,
        dotCount: 3,
      );
      expect(f2.dotAlphas[0], 1.0);
      expect(f2.dotAlphas[1], inInclusiveRange(0.9, 1.0));
      expect(f2.dotAlphas[2], 0.25);
    });

    test('退场：最后 750ms 收缩回弹，最后 375ms 渐隐（无 POOF）', () {
      // 退场中段（t=7900，剩余 100ms）：整体透明度已被 100/375 衰减。
      final f = computeBreathingDotsFrame(
        anchorTimeMs: 0,
        endTimeMs: 8000,
        currentTimeMs: 7900,
        dotCount: 3,
      );
      expect(f.scale, inInclusiveRange(0.45, 0.65));
      expect(f.dotAlphas[0], lessThan(0.3));
      expect(f.dotAlphas[0], greaterThan(0.15));

      // 临近结束（t=7999，剩余 1ms）：仍在、仅极淡（汇入下一句，非整组瞬灭）。
      final f2 = computeBreathingDotsFrame(
        anchorTimeMs: 0,
        endTimeMs: 8000,
        currentTimeMs: 7999,
        dotCount: 3,
      );
      expect(f2.scale, lessThan(0.55));
      expect(f2.dotAlphas[0], greaterThan(0));
    });

    test('结束（含超出）即隐藏，退场在 endTime 前收敛', () {
      for (final t in [8000, 8500]) {
        final f = computeBreathingDotsFrame(
          anchorTimeMs: 0,
          endTimeMs: 8000,
          currentTimeMs: t,
          dotCount: 3,
        );
        expect(f.scale, 0, reason: 't=$t');
        expect(f.dotAlphas, everyElement(0), reason: 't=$t');
      }
    });

    test('重锚定：按「锚点→结束」剩余时长自适应呼吸周期', () {
      // total=5000 → breatheDuration=2500，与 8000 段（4000）不同；
      // t=2000 处呼吸相位与 0.735 峰值不同（此处 ≈0.689）。
      final f = computeBreathingDotsFrame(
        anchorTimeMs: 3000,
        endTimeMs: 8000,
        currentTimeMs: 5000,
        dotCount: 3,
      );
      expect(f.scale, inInclusiveRange(0.6, 0.72));
      expect(f.dotAlphas, isNotEmpty);
    });

    test('无效区间（end<=anchor）返回空帧', () {
      for (final (a, e) in [(8000, 8000), (9000, 8000)]) {
        final f = computeBreathingDotsFrame(
          anchorTimeMs: a,
          endTimeMs: e,
          currentTimeMs: a,
          dotCount: 3,
        );
        expect(f.scale, 0);
        expect(f.dotAlphas, everyElement(0));
      }
    });
  });

  group('BreathingDots widget', () {
    testWidgets('按时间驱动重绘', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SizedBox(
          width: 100,
          height: 20,
          child: BreathingDots(
            anchorTimeMs: 0,
            endTimeMs: 8000,
            currentTimeMs: 2000,
            color: Colors.white,
          ),
        ),
      ));
      expect(find.byType(BreathingDots), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}