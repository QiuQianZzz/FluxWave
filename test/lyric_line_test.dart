import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/line_lyric_reveal_mode.dart';
import 'package:fluxwave/core/lyric/lyric_model.dart';
import 'package:fluxwave/widgets/lyric/lyric_layout.dart';
import 'package:fluxwave/widgets/lyric/lyric_line.dart';
import 'package:fluxwave/widgets/lyric/lyric_line_painter.dart';

/// 行渲染器与视觉包装的确定性测试。
void main() {
  const style = TextStyle(fontSize: 18, fontWeight: FontWeight.bold);
  const activeColor = Colors.white;
  const inactiveColor = Colors.black54;

  group('LyricLinePainter', () {
    test('shouldRepaint 在时间变化时返回 true', () {
      const line = LyricLine(text: '测试歌词', startTimeMs: 0, endTimeMs: 2000);
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 300,
        glowColor: activeColor,
      );
      final p1 = LyricLinePainter(
        layout: layout,
        currentTimeMs: 0,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        isFocused: true,
      );
      final p2 = LyricLinePainter(
        layout: layout,
        currentTimeMs: 1000,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        isFocused: true,
      );
      expect(p1.shouldRepaint(p2), isTrue);
      expect(p1.shouldRepaint(p1), isFalse);
    });

    test('时间无变化时不重绘', () {
      const line = LyricLine(text: '测试歌词', startTimeMs: 0, endTimeMs: 2000);
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 300,
        glowColor: activeColor,
      );
      final p1 = LyricLinePainter(
        layout: layout,
        currentTimeMs: 500,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        isFocused: false,
      );
      final p2 = LyricLinePainter(
        layout: layout,
        currentTimeMs: 500,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        isFocused: false,
      );
      expect(p1.shouldRepaint(p2), isFalse);
    });

    test('LRC 揭示方式变化时重绘（静态 ↔ 线性扫过）', () {
      const line = LyricLine(text: '测试歌词', startTimeMs: 0, endTimeMs: 2000);
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 300,
        glowColor: activeColor,
      );
      final sweep = LyricLinePainter(
        layout: layout,
        currentTimeMs: 500,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        isFocused: true,
        lineLyricRevealMode: LineLyricRevealMode.linearSweep,
      );
      final staticPainter = LyricLinePainter(
        layout: layout,
        currentTimeMs: 500,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        isFocused: true,
        lineLyricRevealMode: LineLyricRevealMode.staticLine,
      );
      expect(sweep.shouldRepaint(staticPainter), isTrue);
      expect(sweep.shouldRepaint(sweep), isFalse);
    });

    test('safeShiftXForScale：缓冲墙内不平移，超过缓冲才整词右移', () {
      // 词中心 x=100、行首词首字符 x=0，放大 1.1 → 左缘 -10。
      // 缓冲 24：-10 在墙(-24)内，无需平移（溢出进缓冲，不被裁掉）。
      expect(safeShiftXForScale(0, 100, 1.1, 24), 0);
      // 放大过猛超出缓冲（左缘 -60 < -24）→ 平移 36 拉回墙边。
      expect(safeShiftXForScale(0, 100, 1.6, 24), closeTo(36, 0.001));
      // 无缓冲（墙=0）时保持旧行为：左溢出即平移。
      expect(safeShiftXForScale(0, 100, 1.1, 0), closeTo(10, 0.001));
      // 锚点处/右侧字符不偏移。
      expect(safeShiftXForScale(100, 100, 1.6, 24), 0);
      // scale=1 不动。
      expect(safeShiftXForScale(0, 100, 1.0, 24), 0);
    });

    test('LineLyricRevealMode 枚举标签', () {
      expect(LineLyricRevealMode.linearSweep.label, '线性扫过');
      expect(LineLyricRevealMode.staticLine.label, contains('纯静态'));
    });
  });

  group('LyricLineView', () {
    Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: child)),
      ),
    );

    testWidgets('聚焦行正常渲染 Canvas', (tester) async {
      const line = LyricLine(
        text: '难 以',
        startTimeMs: 0,
        endTimeMs: 2000,
        words: [
          LyricWord(text: '难', startTimeMs: 0, endTimeMs: 1000),
          LyricWord(text: ' ', startTimeMs: 1000, endTimeMs: 1010),
          LyricWord(text: '以', startTimeMs: 1010, endTimeMs: 2000),
        ],
      );
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 252,
        glowColor: activeColor,
      );
      await tester.pumpWidget(
        wrap(
          LyricLineView(
            line: line,
            layout: layout,
            isActive: true,
            currentTimeMs: 500,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            fontSize: 18,
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LyricLinePainter,
        ),
        findsOneWidget,
      );
    });

    testWidgets('翻译行渲染（假名原文额外间距）', (tester) async {
      const line = LyricLine(
        text: 'さくら',
        startTimeMs: 0,
        endTimeMs: 2000,
        translation: '樱花',
      );
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 252,
        glowColor: activeColor,
      );
      await tester.pumpWidget(
        wrap(
          LyricLineView(
            line: line,
            layout: layout,
            isActive: true,
            currentTimeMs: 500,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            fontSize: 18,
            showTranslation: true,
          ),
        ),
      );
      expect(find.text('樱花'), findsOneWidget);
    });

    testWidgets('showTranslation=false 隐藏翻译', (tester) async {
      const line = LyricLine(
        text: 'hello',
        startTimeMs: 0,
        endTimeMs: 2000,
        translation: '你好',
      );
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 252,
        glowColor: activeColor,
      );
      await tester.pumpWidget(
        wrap(
          LyricLineView(
            line: line,
            layout: layout,
            isActive: false,
            currentTimeMs: 500,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            fontSize: 18,
            showTranslation: false,
          ),
        ),
      );
      expect(find.text('你好'), findsNothing);
    });

    testWidgets('点击行触发 onTapLine', (tester) async {
      const line = LyricLine(text: '测试歌词', startTimeMs: 0, endTimeMs: 2000);
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 252,
        glowColor: activeColor,
      );
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          LyricLineView(
            line: line,
            layout: layout,
            isActive: true,
            currentTimeMs: 0,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            fontSize: 18,
            onTapLine: () => tapped = true,
          ),
        ),
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LyricLinePainter,
        ),
      );
      expect(tapped, isTrue);
    });

    testWidgets('长按行触发 onLongPressLine', (tester) async {
      const line = LyricLine(text: '测试歌词', startTimeMs: 0, endTimeMs: 2000);
      final layout = measureLyricLine(
        line: line,
        style: style,
        availableWidth: 252,
        glowColor: activeColor,
      );
      var longPressed = false;
      await tester.pumpWidget(
        wrap(
          LyricLineView(
            line: line,
            layout: layout,
            isActive: true,
            currentTimeMs: 0,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            fontSize: 18,
            onLongPressLine: () => longPressed = true,
          ),
        ),
      );
      await tester.longPress(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LyricLinePainter,
        ),
      );
      expect(longPressed, isTrue);
    });
  });

  group('LyricLineVisual', () {
    testWidgets('应用引擎喂入的位移/缩放/透明度', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricLineVisual(
              translateY: 12,
              scale: 0.97,
              alpha: 0.35,
              blurSigma: 0,
              child: const Text('x'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final visual = tester.widget<LyricLineVisual>(
        find.byType(LyricLineVisual),
      );
      expect(visual.translateY, 12);
      expect(visual.scale, closeTo(0.97, 1e-9));
      expect(visual.alpha, closeTo(0.35, 1e-9));

      // 渲染层面确实套用了位移/缩放变换。
      final transform = tester.widget<Transform>(
        find
            .ancestor(of: find.text('x'), matching: find.byType(Transform))
            .first,
      );
      expect(transform.transform, isNot(isNull));
    });

    testWidgets('blurSigma 有效时套用高斯模糊', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricLineVisual(
              blurSigma: 1.2,
              child: const Text('x'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.ancestor(of: find.text('x'), matching: find.byType(ImageFiltered)),
        findsOneWidget,
      );
    });
  });
}
