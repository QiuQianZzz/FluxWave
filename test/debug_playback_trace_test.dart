// 该文件为调试追踪脚本，print 输出是用途本身。
// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/lyric_model.dart';
import 'package:fluxwave/widgets/lyric/lyric_line.dart';
import 'package:fluxwave/widgets/lyric/lyric_view.dart';

List<LyricLine> buildLines() => List.generate(
  20,
  (i) => LyricLine(
    text: 'line $i',
    startTimeMs: i * 2000,
    endTimeMs: (i + 1) * 2000,
  ),
);

Widget wrap(List<LyricLine> lines, int currentTimeMs) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 300,
      height: 600,
      child: LyricView(
        lines: lines,
        currentTimeMs: currentTimeMs,
        activeColor: Colors.white,
        inactiveColor: Colors.black54,
      ),
    ),
  ),
);

/// 激活行的 translateY（引擎驱动的可视位置）。
double activeTranslateY(WidgetTester tester) => tester
    .widget<LyricLineVisual>(
      find.ancestor(
        of: find.byWidgetPredicate((w) => w is LyricLineView && w.isActive),
        matching: find.byType(LyricLineVisual),
      ),
    )
    .translateY;

void main() {
  testWidgets('真实播放节奏：连续切句帧级追踪', (tester) async {
    await tester.pumpWidget(wrap(buildLines(), 0));
    await tester.pump();
    await tester.pumpAndSettle();
    print('INITIAL: y=${activeTranslateY(tester)}');

    // 生产环境 lines 引用稳定，只有 currentTimeMs 变化；这里复用同一份 lines。
    final lines = buildLines();
    // 模拟播放：每 100ms 推进一次 currentTimeMs，跨第 5→6→7 句。
    for (var t = 100; t <= 14 * 2000; t += 100) {
      await tester.pumpWidget(wrap(lines, t));
      // 用 pump 推进一帧，观察动画是否在跑。
      await tester.pump(const Duration(milliseconds: 16));
      if (t > 5 * 2000 && t < 7 * 2000) {
        print('T=$t y=${activeTranslateY(tester)}');
      }
    }
    await tester.pumpAndSettle();
    print('FINAL: y=${activeTranslateY(tester)}');

    final visuals = tester
        .widgetList<LyricLineVisual>(find.byType(LyricLineVisual))
        .toList();
    print('VISUAL COUNT: ${visuals.length}');
  });
}