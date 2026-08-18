import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fluxwave/core/lyric/line_lyric_reveal_mode.dart';
import 'package:fluxwave/core/lyric/lyric_model.dart';
import 'package:fluxwave/widgets/lyric/lyric_line.dart';
import 'package:fluxwave/widgets/lyric/lyric_line_painter.dart';
import 'package:fluxwave/widgets/lyric/lyric_view.dart';

/// 构造 20 行、每行 2s 的 LRC 歌词。
List<LyricLine> buildLines() => List.generate(
  20,
  (i) => LyricLine(
    text: 'line $i',
    startTimeMs: i * 2000,
    endTimeMs: (i + 1) * 2000,
  ),
);

Widget wrap(List<LyricLine> lines, int currentTimeMs) =>
    wrapWithHeight(lines, currentTimeMs, 600);

Widget wrapWithHeight(
  List<LyricLine> lines,
  int currentTimeMs,
  double height,
) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 300,
      height: height,
      child: LyricView(
        lines: lines,
        currentTimeMs: currentTimeMs,
        activeColor: Colors.white,
        inactiveColor: Colors.black54,
      ),
    ),
  ),
);

Widget wrapWithLyricBlur(
  List<LyricLine> lines,
  int currentTimeMs,
  bool depthBlur,
) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 300,
      height: 600,
      child: LyricView(
        lines: lines,
        currentTimeMs: currentTimeMs,
        activeColor: Colors.white,
        inactiveColor: Colors.black54,
        lyricDepthBlur: depthBlur,
      ),
    ),
  ),
);

/// 激活行的 LyricLineVisual（外层包装）。
LyricLineVisual activeVisual(WidgetTester tester) => tester.widget<
  LyricLineVisual
>(
  find.ancestor(
    of: find.byWidgetPredicate((w) => w is LyricLineView && w.isActive),
    matching: find.byType(LyricLineVisual),
  ),
);

/// 第 [index] 行的 LyricLineVisual。
LyricLineVisual visualOf(WidgetTester tester, int index) => tester.widget<
  LyricLineVisual
>(
  find.ancestor(
    of: find.byWidgetPredicate(
      (w) => w is LyricLineView && w.line.text == 'line $index',
    ),
    matching: find.byType(LyricLineVisual),
  ),
);

/// 激活行的行文本（判断高亮/跟随是否切换到了目标句）。
String activeLineText(WidgetTester tester) {
  final view = tester.widget<LyricLineView>(
    find.byWidgetPredicate((w) => w is LyricLineView && w.isActive),
  );
  return view.line.text;
}

/// 激活行顶边相对歌词可视区顶边的距离（px）。包含 transform 位移。
double activeLineTopInViewport(WidgetTester tester) {
  final activeLine = find.byWidgetPredicate(
    (w) => w is LyricLineView && w.isActive,
  );
  final box = tester.renderObject<RenderBox>(activeLine);
  final viewportBox = tester.renderObject<RenderBox>(find.byType(LyricView));
  return box.localToGlobal(Offset.zero).dy -
      viewportBox.localToGlobal(Offset.zero).dy;
}

void main() {
  testWidgets('手指按住滚动期间切句：不回退（修"手指"没松也滚回来）', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();

    // 手动往下拖若干行，手指不松开。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LyricView)),
    );
    await gesture.moveBy(const Offset(0, -250));
    await tester.pump();
    final scrolled = activeVisual(tester).translateY;
    expect(scrolled, isNot(0), reason: '拖动后激活行应偏离锚点');

    // 播放推进到第 6 行（当前播放行变化）——手指仍按着，不得滚动回正。
    await tester.pumpWidget(wrap(lines, 6 * 2000));
    await tester.pump();
    expect(activeLineText(tester), 'line 6', reason: '高亮跟随播放推进');
    expect(
      visualOf(tester, 0).translateY,
      closeTo(scrolled, 0.001),
      reason: '手指按着时列表不得回正',
    );
    await gesture.up();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('无手动介入：切句正常跟随', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();
    final initial = activeVisual(tester).translateY;

    // 没有任何手动交互，播放直接推进到第 6 行 → 高亮跟随到第 6 行并回锚点。
    await tester.pumpWidget(wrap(lines, 6 * 2000));
    await tester.pumpAndSettle();
    expect(activeLineText(tester), 'line 6', reason: '高亮应切到第 6 行');
    expect(activeVisual(tester).translateY, closeTo(initial, 0.001), reason: '锚点行顶边不变');
    expect(visualOf(tester, 0).translateY, lessThan(0), reason: '第 0 行应被顶出可视区上方');
  });

  testWidgets('鼠标滚轮：离开歌词区即时解除抑制（无需等 3 秒）', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();

    // 滚轮把歌词滚离播放行 → 进入抑制窗口（定时器非空）。
    final beforeScroll = activeVisual(tester).translateY;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(LyricView)),
        scrollDelta: const Offset(0, -120),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    final scrolled = activeVisual(tester).translateY;
    expect(scrolled, isNot(equals(beforeScroll)), reason: '滚轮应产生滚动');

    // 鼠标离开歌词区：触发 MouseRegion.onExit，抑制窗口应立即清除。
    final mouseRegions = find.descendant(
      of: find.byType(LyricView),
      matching: find.byType(MouseRegion),
    );
    final mouseRegion = tester.widget<MouseRegion>(mouseRegions.first);
    mouseRegion.onExit!(
      PointerExitEvent(
        device: 1,
        kind: PointerDeviceKind.mouse,
        position: Offset.zero,
      ),
    );
    await tester.pump();

    // 切句 → 应恢复跟随（若 onExit 未清除抑制，位置将保持滚轮后的值）。
    await tester.pumpWidget(wrap(lines, 6 * 2000));
    await tester.pumpAndSettle();
    expect(activeLineText(tester), 'line 6');
    expect(activeVisual(tester).translateY, isNot(equals(scrolled)));
  });

  testWidgets('鼠标滚轮连续滚动：每次滚轮都应累加偏移（修只滚一次的回归）', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();

    Future<void> wheel(double dy) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(LyricView)),
          scrollDelta: Offset(0, dy),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
    }

    await wheel(120);
    final first = activeVisual(tester).translateY;
    await wheel(120);
    final second = activeVisual(tester).translateY;
    expect(second, isNot(equals(first)), reason: '第二次滚轮必须继续滚动（回归：只滚一次）');
    await wheel(120);
    final third = activeVisual(tester).translateY;
    expect(third, isNot(equals(second)), reason: '第三次滚轮仍应继续滚动');
    expect(
      (third - first).abs(),
      greaterThan((second - first).abs()),
      reason: '连续滚动应累加偏移，而非覆盖',
    );
  });

  testWidgets('Android 慢拖松手（无惯性）：抬手即进 3 秒窗口，切句不回正，窗口过后恢复', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LyricView)),
    );
    await gesture.moveBy(const Offset(0, -250));
    await tester.pump();
    final scrolled = activeVisual(tester).translateY;
    await gesture.up();
    await tester.pump();

    // 松手后窗口仍有效：切句不得回正。
    await tester.pumpWidget(wrap(lines, 6 * 2000));
    await tester.pump();
    expect(
      visualOf(tester, 0).translateY,
      closeTo(scrolled, 0.001),
      reason: '3 秒窗口内列表位置不回正',
    );

    // 超过 3 秒窗口后再切句 → 恢复跟随。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(wrap(lines, 8 * 2000));
    await tester.pumpAndSettle();
    expect(activeLineText(tester), 'line 8');
    expect(activeVisual(tester).translateY, isNot(equals(scrolled)));
  });

  testWidgets('拖动 + 第二根手指轻轻点按离开：拖根抬手的窗口仍生效', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();

    // 手指 A 拖动。
    final a = await tester.startGesture(
      tester.getCenter(find.byType(LyricView)),
      pointer: 10,
    );
    await a.moveBy(const Offset(0, -250));
    await tester.pump();
    final scrolled = activeVisual(tester).translateY;

    // 手指 B 在不拖动的情况下按一下就走——不得抹掉 A 的拖拽标记。
    final b = await tester.startGesture(Offset.zero, pointer: 11);
    await b.up();
    await tester.pump();
    // A 随后抬手。
    await a.up();
    await tester.pump();

    // 窗口仍应有效：切句不回正。
    await tester.pumpWidget(wrap(lines, 6 * 2000));
    await tester.pump();
    expect(
      visualOf(tester, 0).translateY,
      closeTo(scrolled, 0.001),
      reason: '第二根手指不抹掉拖拽窗口，切句列表不回正',
    );

    // 窗口过后：恢复跟随。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(wrap(lines, 8 * 2000));
    await tester.pumpAndSettle();
    expect(activeVisual(tester).translateY, isNot(equals(scrolled)));
  });

  testWidgets('惯性/手动滚动抑制期间点击行：立即 seek 并定位，不被 3 秒窗口压住', (tester) async {
    int? seeked;
    final lines = buildLines();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 600,
            child: LyricView(
              lines: lines,
              currentTimeMs: 0,
              activeColor: Colors.white,
              inactiveColor: Colors.black54,
              onSeekLine: (ms) => seeked = ms,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    final before = activeVisual(tester).translateY;

    // 手动滚动到别处 → 打开 3 秒抑制窗口（模拟惯性滑动的尾部状态）。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LyricView)),
    );
    await gesture.moveBy(const Offset(0, 250));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // 点击列表里某一行的 InkWell：应清掉窗口并 seek + 跟回目标行。
    final inkWells = find.descendant(
      of: find.byType(LyricView),
      matching: find.byType(InkWell),
    );
    expect(inkWells, findsWidgets);
    await tester.tap(inkWells.at(1));
    await tester.pumpAndSettle();

    expect(seeked, 2000, reason: '点击应触发第 1 行 seek');
    expect(activeLineText(tester), 'line 1', reason: '点击后高亮应切到目标行');
    expect(activeVisual(tester).translateY, closeTo(before, 0.001), reason: '点击后应回锚点');
  });

  testWidgets('只轻点（没有任何拖动痕迹）：不误开窗口，换句照常跟随', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrap(lines, 0));
    await tester.pump();
    await tester.pumpAndSettle();
    final initial = activeVisual(tester).translateY;

    // 两根手指都是"按下即抬"，谁也没拖。
    final b = await tester.startGesture(Offset.zero, pointer: 20);
    await b.up();
    await tester.pump();
    final c = await tester.startGesture(Offset.zero, pointer: 21);
    await c.up();
    await tester.pump();

    // 若误开了窗口，换句会被压住（高亮不跟随）；正确则应照常跟随。
    await tester.pumpWidget(wrap(lines, 6 * 2000));
    await tester.pumpAndSettle();
    expect(activeLineText(tester), 'line 6', reason: '换句应照常跟随');
    expect(activeVisual(tester).translateY, closeTo(initial, 0.001));
  });

  testWidgets('lineLyricRevealMode 参数传入后 painter 同步接收（静态/扫过）', (tester) async {
    for (final mode in LineLyricRevealMode.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 600,
              child: LyricView(
                lines: buildLines(),
                currentTimeMs: 0,
                activeColor: Colors.white,
                inactiveColor: Colors.black54,
                lineLyricRevealMode: mode,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final painter = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(LyricView),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((w) => w.painter)
          .whereType<LyricLinePainter>()
          .first;
      expect(painter.lineLyricRevealMode, mode);
    }
  });

  testWidgets('播放中首次挂载：当前行顶边上移到约第 3 句位置（不是停在底部）', (tester) async {
    // 播放进行到第 16 行，首次挂载即应把当前行定位到视口上部，而非贴近底部。
    await tester.pumpWidget(wrap(buildLines(), 15 * 2000));
    await tester.pump();
    await tester.pumpAndSettle();

    final activeLine = find.byWidgetPredicate(
      (w) => w is LyricLineView && w.isActive,
    );
    expect(activeLine, findsOneWidget);
    final top = activeLineTopInViewport(tester);
    // 约第 3 句 = 距视口顶边约 2 行行高。Ahem 下行高约 40px，取 60..220 容差带。
    expect(top, inInclusiveRange(60, 220), reason: '当前行应上移到约第 3 句');
    final box = tester.renderObject<RenderBox>(activeLine);
    expect(top + box.size.height, lessThan(600), reason: '当前行不应超出可视区底部');
  });

  testWidgets('歌词面板从收起过渡到全高后：当前行回到可视区且约在第 3 句（修切歌词页首帧错位）', (tester) async {
    // 复现切歌词页时序：LyricView 在面板高度从 0 渐变到全高的过程中定位，
    // 若只按中途小视口算锚点，最终视口长高后当前行会停错位置。
    await tester.pumpWidget(wrapWithHeight(buildLines(), 15 * 2000, 60));
    await tester.pump();
    await tester.pumpWidget(wrapWithHeight(buildLines(), 15 * 2000, 300));
    await tester.pumpAndSettle();
    await tester.pumpWidget(wrapWithHeight(buildLines(), 15 * 2000, 600));
    await tester.pumpAndSettle();

    final activeLine = find.byWidgetPredicate(
      (w) => w is LyricLineView && w.isActive,
    );
    expect(activeLine, findsOneWidget);
    final top = activeLineTopInViewport(tester);
    expect(top, inInclusiveRange(60, 220), reason: '过渡结束后当前行应约在第 3 句');
    final box = tester.renderObject<RenderBox>(activeLine);
    expect(top + box.size.height, lessThan(600), reason: '当前行不应超出可视区底部');
    expect(top, greaterThan(0), reason: '当前行不应被顶出可视区顶部');
  });

  testWidgets('景深模糊梯度：当前行不模糊，相邻行即有可见模糊且随距离递增', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrapWithLyricBlur(lines, 3 * 2000, true));
    await tester.pump();
    await tester.pumpAndSettle();

    final visuals = tester
        .widgetList<LyricLineVisual>(find.byType(LyricLineVisual))
        .toList();
    double blurOf(int index) => visuals[index].blurSigma;

    expect(blurOf(3), 0, reason: '当前行不模糊');
    // 下方按指数曲线递增：相邻行已有明显模糊，越远越糊。
    expect(blurOf(4), greaterThan(0.8), reason: '当前行下一句应有可见模糊');
    expect(blurOf(4), lessThan(blurOf(6)), reason: '下方模糊应随距离递增');
    expect(blurOf(6), lessThan(blurOf(8)), reason: '下方模糊应随距离递增');
    expect(
      blurOf(8),
      lessThan(blurOf(visuals.length - 1)),
      reason: '远处行最模糊',
    );
    // 上方同样递增，且已播区顶部更模糊。
    expect(blurOf(2), greaterThan(0.8), reason: '当前行上一句也应有可见模糊');
    expect(blurOf(0), greaterThan(blurOf(2)), reason: '越往视口顶部越模糊');
  });

  testWidgets('景深淡出：越远行越透明（视口外溶解），当前行不透明', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrapWithLyricBlur(lines, 3 * 2000, true));
    await tester.pump();
    await tester.pumpAndSettle();

    final visuals = tester
        .widgetList<LyricLineVisual>(find.byType(LyricLineVisual))
        .toList();
    double alphaOf(int index) => visuals[index].alpha;

    expect(alphaOf(3), closeTo(1.0, 1e-9), reason: '当前行不淡出');
    expect(alphaOf(4), closeTo(0.35, 1e-9), reason: '近处行保持引擎透明度');
    expect(alphaOf(19), lessThan(alphaOf(4)), reason: '远处行因景深淡出更透明');
    expect(alphaOf(19), lessThan(0.2), reason: '视口外行应接近溶解');
  });

  testWidgets('关闭景深模糊开关：所有行 blurSigma 为 0', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrapWithLyricBlur(lines, 3 * 2000, false));
    await tester.pump();
    await tester.pumpAndSettle();

    for (final w in tester.widgetList<LyricLineVisual>(
      find.byType(LyricLineVisual),
    )) {
      expect(w.blurSigma, 0);
    }
  });

  testWidgets('滑动（手指按住）期间景深模糊解除，松手后恢复', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrapWithLyricBlur(lines, 3 * 2000, true));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      tester
          .widgetList<LyricLineVisual>(find.byType(LyricLineVisual))
          .any((w) => w.blurSigma > 0),
      isTrue,
      reason: '初始应有模糊',
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LyricView)),
    );
    await gesture.moveBy(const Offset(0, -250));
    await tester.pump();
    for (final w in tester.widgetList<LyricLineVisual>(
      find.byType(LyricLineVisual),
    )) {
      expect(w.blurSigma, 0, reason: '拖动期间全部清晰');
    }
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('拖动滚出视口顶的行淡出到全透明（回归：不会画到封面/标题区）', (tester) async {
    final lines = buildLines();
    await tester.pumpWidget(wrapWithLyricBlur(lines, 3 * 2000, true));
    await tester.pump();
    await tester.pumpAndSettle();

    // 向上拖：歌词整体上移，部分行滚出视口顶。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LyricView)),
    );
    await gesture.moveBy(const Offset(0, -250));
    await tester.pump();

    final visuals = tester
        .widgetList<LyricLineVisual>(find.byType(LyricLineVisual))
        .toList();
    var hasOutOfTop = false;
    for (final w in visuals) {
      if (w.translateY < -48) {
        hasOutOfTop = true;
        expect(w.alpha, 0, reason: '滚出视口顶的行必须完全透明（不画到封面/标题区）');
      }
    }
    expect(hasOutOfTop, isTrue, reason: '拖动应让部分行滚出视口顶');

    // 视口内（非边缘）的行保持引擎透明度，不被景深索引淡出压低。
    for (final w in visuals) {
      if (w.translateY >= 60 && w.translateY <= 540) {
        expect(
          w.alpha,
          anyOf(closeTo(1.0, 1e-9), closeTo(0.35, 1e-9)),
          reason: '视口内行保持引擎透明度',
        );
      }
    }
    await gesture.up();
    await tester.pumpAndSettle();
  });
}