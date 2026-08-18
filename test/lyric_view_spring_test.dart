import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/lyric_model.dart';
import 'package:fluxwave/core/lyric/lyric_spring.dart';
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

Widget wrap(
  List<LyricLine> lines,
  int currentTimeMs, {
  LyricSpringPreset preset = LyricSpringPreset.standard,
  bool springEnabled = true,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 300,
      height: 600,
      child: LyricView(
        lines: lines,
        currentTimeMs: currentTimeMs,
        activeColor: Colors.white,
        inactiveColor: Colors.black54,
        lyricSpringPreset: preset,
        lyricSpringEnabled: springEnabled,
      ),
    ),
  ),
);

/// 激活行（LyricLineView.isActive）所在 LyricLineVisual。
LyricLineVisual visualOf(WidgetTester tester, int index) => tester
    .widgetList<LyricLineVisual>(find.byType(LyricLineVisual))
    .toList()[index];

LyricLineVisual activeVisual(WidgetTester tester) => tester.widget<
  LyricLineVisual
>(
  find.ancestor(
    of: find.byWidgetPredicate((w) => w is LyricLineView && w.isActive),
    matching: find.byType(LyricLineVisual),
  ),
);

/// 激活行行文本。
String activeLineText(WidgetTester tester) {
  final view = tester.widget<LyricLineView>(
    find.byWidgetPredicate((w) => w is LyricLineView && w.isActive),
  );
  return view.line.text;
}

/// 逐帧采样激活行 translateY 路径（每步 [stepMs] 毫秒）。
/// 复用同一份 [lines]，模拟生产环境"lines 引用稳定、只有 currentTimeMs 变化"。
Future<List<double>> sampleActivePath(
  WidgetTester tester,
  List<LyricLine> lines,
  int toMs, {
  LyricSpringPreset preset = LyricSpringPreset.standard,
  int stepMs = 8,
  int frames = 160,
}) async {
  await tester.pumpWidget(wrap(lines, toMs, preset: preset));
  final path = <double>[];
  for (var i = 0; i < frames; i++) {
    await tester.pump(Duration(milliseconds: stepMs));
    path.add(activeVisual(tester).translateY);
  }
  return path;
}

void main() {
  testWidgets('bouncy 档换句：激活行位置弹簧存在可见过冲（不是单调缓动）', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(
      wrap(lines, 0, preset: LyricSpringPreset.bouncy),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    // 切句前第 6 行的位置（激活行接下来要从这里弹到锚点）。
    final startY = visualOf(tester, 6).translateY;

    await tester.pumpWidget(
      wrap(lines, 6 * 2000, preset: LyricSpringPreset.bouncy),
    );
    final path = await sampleActivePath(
      tester,
      lines,
      6 * 2000,
      preset: LyricSpringPreset.bouncy,
    );
    await tester.pumpAndSettle();
    final settle = activeVisual(tester).translateY;
    final min = path.reduce(math.min);

    expect(settle, lessThan(startY), reason: '切句后激活行确实上移了');
    expect(
      min,
      lessThan(settle - 2.0),
      reason: 'bouncy 档应有可见过冲（过冲后弹回目标），弹簧才可见',
    );
  });

  testWidgets('标准档换句：级联错落——近处行先动、远处行延迟后动', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();
    final before = List.generate(20, (i) => visualOf(tester, i).translateY);

    await tester.pumpWidget(wrap(lines, 6 * 2000));
    // 首帧 dt=0（ticker 刚启动），随后一帧 8ms 让近处行真正动起来。
    await tester.pump(const Duration(milliseconds: 8));
    await tester.pump(const Duration(milliseconds: 8));

    int movedCount() {
      var n = 0;
      for (var i = 0; i < 20; i++) {
        if ((visualOf(tester, i).translateY - before[i]).abs() > 0.01) n++;
      }
      return n;
    }

    final movedEarly = movedCount();
    expect(movedEarly, greaterThan(0), reason: '近处行应已开始移动');
    expect(movedEarly, lessThan(20), reason: '远处行应仍在级联延迟中等待');

    // 500ms 后：延迟耗尽，更多行已开始移动 → 波浪错落持续推进。
    await tester.pump(const Duration(milliseconds: 500));
    expect(movedCount(), greaterThan(movedEarly), reason: '级联延迟让远处行逐批启动');

    // 全部收敛后吸附到 calcLayout 精确目标（无残余漂移）。
    await tester.pumpAndSettle();
    final settled = activeVisual(tester).translateY;
    await tester.pump(const Duration(milliseconds: 200));
    expect(activeVisual(tester).translateY, settled, reason: '结束后不得有残余漂移');
  });

  testWidgets('弹簧结束帧吸附到精确目标：结束后位置不再漂移', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();

    await sampleActivePath(tester, lines, 6 * 2000);
    final settled = activeVisual(tester).translateY;
    await tester.pump(const Duration(milliseconds: 200));
    expect(activeVisual(tester).translateY, settled, reason: '结束后不得有残余漂移');

    // 再次定位到同一行：终点应一致（无估算偏差累积）。
    await tester.pumpWidget(wrap(lines, 6 * 2000));
    await tester.pumpAndSettle();
    expect(
      (activeVisual(tester).translateY - settled).abs(),
      lessThan(0.001),
      reason: '再次定位到同一行终点应一致',
    );
  });

  testWidgets('聚焦行缩放弹簧：非瞬间切换，且结束帧精确停在 1.0', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(activeVisual(tester).scale, closeTo(1.0, 0.001));

    await tester.pumpWidget(wrap(lines, 3 * 2000));
    // 新激活行 scale 弹簧经过级联延迟后启动，过渡期内既不是 0.97 也不是 1.0。
    var started = false;
    var maxScale = 0.0;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      final s = activeVisual(tester).scale;
      if (s > 0.9701) started = true;
      maxScale = math.max(maxScale, s);
    }
    expect(started, isTrue, reason: '缩放弹簧应已启动');
    expect(maxScale, lessThan(1.0), reason: '换句瞬间激活行仍处于缩放过渡中');

    await tester.pumpAndSettle();
    expect(
      activeVisual(tester).scale,
      closeTo(1.0, 0.001),
      reason: '结束后精确停在 1.0，不能回落造成"同一句播两次"',
    );
    // 非激活行停在 0.97。
    expect(visualOf(tester, 4).scale, closeTo(0.97, 0.001));
    expect(visualOf(tester, 2).scale, closeTo(0.97, 0.001));
  });

  testWidgets('远跳（懒加载未布局行）：落点与就近定位一致，无估算偏差', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();

    // 远跳第 18 行：各行走弹簧动画后落到 calcLayout 目标。
    await tester.pumpWidget(wrap(lines, 18 * 2000));
    await tester.pumpAndSettle();
    final farJump = activeVisual(tester).translateY;
    final box = tester.renderObject<RenderBox>(
      find.byWidgetPredicate((w) => w is LyricLineView && w.isActive),
    );
    final viewportBox = tester.renderObject<RenderBox>(find.byType(LyricView));
    final top = box.localToGlobal(Offset.zero).dy -
        viewportBox.localToGlobal(Offset.zero).dy;
    expect(top, inInclusiveRange(60, 220), reason: '远跳后当前行仍应约在第 3 句');

    // 就近来回后再次定位同一行：两次终点应一致（无估算偏差累积）。
    await tester.pumpWidget(wrap(lines, 2 * 2000));
    await tester.pumpAndSettle();
    await tester.pumpWidget(wrap(lines, 18 * 2000));
    await tester.pumpAndSettle();
    expect(
      (activeVisual(tester).translateY - farJump).abs(),
      lessThan(0.001),
      reason: '远跳与就近定位终点应一致',
    );
  });
}