import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/lyric/line_lyric_reveal_mode.dart';
import '../../core/lyric/lyric_model.dart';
import '../../core/lyric/lyric_parser.dart';
import '../../core/lyric/lyric_spring.dart';
import 'breathing_dots.dart';
import 'lyric_engine.dart';
import 'lyric_layout.dart';
import 'lyric_line.dart';

/// 歌词列表视图（AMLL 布局引擎版）。
///
/// - 用 [LyricEngine]（对标 AMLL `calcLayout`）做"当前行驱动 + 每行独立
///   posY/scale 弹簧 + 级联延迟 + 动态弹簧参数"，[Stack] + [Transform.translate]
///   绝对定位渲染所有行（无 ListView/ScrollController）。
/// - 换句时每行错峰弹向新目标 → "不同行歌词上来时的不一致错落效果"。
/// - 交互保留：点行 seek、长按、手动拖动（跟手 + 3 秒抑制窗口 + 自动回正）、
///   鼠标滚轮浏览、景深（模糊 + 淡出）。
/// - 视口安全：每行按像素位置在视口顶/底边缘淡出，配合外层硬裁剪，歌词
///   绝不会画到歌词面板之外（封面/标题区、控件区）。
/// - [lyricOffsetMs] 歌词整体时间偏移（正 = 提前，负 = 延后）
class LyricView extends StatefulWidget {
  final List<LyricLine> lines;
  final int currentTimeMs;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;

  /// 歌词时间偏移毫秒（正 = 提前，负 = 延后）。
  final int lyricOffsetMs;

  /// 是否显示翻译（关闭时连罗马音回退也不显示）。
  final bool showTranslation;

  /// 点击行回调：传入被点击行的起始毫秒
  final ValueChanged<int>? onSeekLine;

  /// 长按行回调：传入被长按行的起始毫秒（null = 降级为 seek）
  final ValueChanged<int>? onLyricLongPress;

  /// 行级歌词（LRC）的揭示方式；逐字 YRC 不受影响。
  final LineLyricRevealMode lineLyricRevealMode;

  /// 是否启用歌词景深模糊：开启时按"距当前行的行数"曲线计算模糊（与视口
  /// 尺寸/字号无关），相邻行即有可见模糊、越远越糊；滑动/拖动期间自动解除
  /// 模糊（仅保留视口边缘淡出）。
  final bool lyricDepthBlur;

  /// 是否启用歌词弹簧动画（行切换时每行独立 posY/scale 弹簧 + 级联延迟）。
  final bool lyricSpringEnabled;

  /// 歌词弹簧强度档位（仅 [lyricSpringEnabled] 开启时生效）。
  final LyricSpringPreset lyricSpringPreset;

  const LyricView({
    super.key,
    required this.lines,
    required this.currentTimeMs,
    required this.activeColor,
    required this.inactiveColor,
    this.fontSize = 20,
    this.lyricOffsetMs = 0,
    this.showTranslation = true,
    this.lineLyricRevealMode = LineLyricRevealMode.linearSweep,
    this.lyricDepthBlur = true,
    this.lyricSpringEnabled = true,
    this.lyricSpringPreset = LyricSpringPreset.standard,
    this.onSeekLine,
    this.onLyricLongPress,
  });

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView>
    with SingleTickerProviderStateMixin {
  late LyricEngine _engine;

  int _currentIndex = -1;

  // ── 帧循环 ──
  late final Ticker _ticker;
  Duration? _lastTickerElapsed;

  /// 指针/拖动跟踪（raw Listener 观察，不与手势竞技场冲突）。
  bool _pointerDown = false;
  final Map<int, Offset> _pointerDownPositions = {};
  bool _pointerDragged = false;
  double _dragStartY = 0;
  double _dragStartScrollOffset = 0;

  /// 手动浏览抑制窗口（非 null = 抑制中，松手/滚轮后 3 秒）。
  Timer? _userScrollHoldTimer;

  /// 首帧/视口变化/换歌后需要强制落位。
  bool _needsJump = false;

  double _lastViewportHeight = 0;

  // ── 测量缓存 ──
  double _measuredWidth = double.infinity;
  int? _measuredDotsLine;
  bool _measurementsDirty = false;
  bool _heightsChanged = false;
  List<LyricLineLayout?> _layouts = [];
  List<double> _baseHeights = [];
  List<double> _itemHeights = [];

  // ── 圆点动画锚定 ──
  // 进入/切换间奏或 seek（时间回跳/大幅前跳）时，以当前时间重新锚定，
  // 动画各阶段按「锚点 → 下一句开始」的剩余时长分配（对齐 AMLL）。
  int _dotsAnchorMs = 0;
  int? _lastDotsIndex;
  int _lastDotsDisplayMs = 0;

  static const _kMinScrollHeight = 100.0;
  static const _kUserScrollHold = Duration(seconds: 3);

  // ── 当前行定位 ──
  // 当前行顶边约落在"第 3 句"位置：上方只保留约 2 行已播歌词，把更多可视区
  // 留给后续歌词；小屏下用绝对下限兜底，保证前奏/上一句始终可见。
  static const _kPlayedLyricViewportFraction = 0.20;
  static const _kPlayedFractionMin = 0.18;
  static const _kPlayedFractionMax = 0.35;
  static const _kMinPlayedSpace = 64.0;
  static const _kAnchorSafePadding = 12.0;
  static const _kKeepAliveZone = 40.0;
  static const _kMinimumOffset = 48.0;

  // ── 歌词景深（模糊 + 边缘淡出）──
  // 模糊按"距当前行的行数"指数增长，与视口尺寸/字号无关（窄屏/宽屏表现
  // 一致）：相邻行即有可见模糊，约 [_kBlurHalfRow] 行距达一半最大模糊，
  // 远处趋近 [_kBlurMaxSigma]。视口顶/底用像素淡出（_edgeFadeOf）溶解，
  // 配合外层硬裁剪保证不画到面板之外。
  static const _kBlurMaxSigma = 2.0;
  static const _kBlurHalfRow = 1.5;

  // 视口边缘淡出长度：行目标顶边进入顶/底 [_kEdgeFadeLength] 后线性淡出到
  // 全透明。配合外层 ClipRect，保证歌词绝不会画到歌词面板之外
  // （封面/标题区、控件区）；拖动/浏览期间同样生效。
  static const _kEdgeFadeLength = 48.0;

  /// 前奏圆点阈值（首行 >5s 视为前奏）。
  static const _kIntroThresholdMs = 5000;

  /// 间奏圆点阈值（两句间隔 >5s）。
  static const _kInterludeThresholdMs = 5000;

  @override
  void initState() {
    super.initState();
    _engine = _createEngine();
    _ticker = createTicker(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _needsJump = true;
      _updateCurrent();
    });
  }

  LyricEngine _createEngine() => LyricEngine(
    lineCount: widget.lines.length,
    lineHeights: List.filled(widget.lines.length, 0),
    lineStartMs: widget.lines.map((l) => l.startTimeMs).toList(),
    preset: widget.lyricSpringPreset,
    springEnabled: widget.lyricSpringEnabled,
  );

  @override
  void didUpdateWidget(covariant LyricView old) {
    super.didUpdateWidget(old);
    if (old.lines != widget.lines) {
      _currentIndex = -1;
      _needsJump = true;
      _engine = _createEngine();
      _layouts = [];
      _baseHeights = [];
      _itemHeights = [];
      _measuredWidth = double.infinity;
      _measuredDotsLine = null;
      _dotsAnchorMs = 0;
      _lastDotsIndex = null;
      _lastDotsDisplayMs = 0;
      _updateCurrent();
    } else {
      final metricsChanged =
          old.fontSize != widget.fontSize ||
          old.activeColor != widget.activeColor ||
          old.showTranslation != widget.showTranslation;
      if (metricsChanged) {
        _measuredWidth = double.infinity;
        _measuredDotsLine = -999;
      }
      if (old.lyricSpringPreset != widget.lyricSpringPreset) {
        _engine.setPreset(widget.lyricSpringPreset);
      }
      if (old.lyricSpringEnabled != widget.lyricSpringEnabled) {
        // 弹簧/缓动模式是引擎内部状态，切换需重建引擎并重新落位。
        _engine = _createEngine();
        _needsJump = true;
        _lastDotsIndex = null;
      }
      if (old.currentTimeMs != widget.currentTimeMs) {
        _updateCurrent();
      }
    }
  }

  int _effectiveTimeMs(int raw) =>
      (raw + widget.lyricOffsetMs).clamp(0, 1 << 31);

  /// 当前行变化（播放推进 / 点击 seek）。手动浏览时锚点冻结在
  /// `heldScrollIndex`，这里只更新高亮/卡拉 OK/缩放/透明度的目标。
  void _updateCurrent() {
    if (widget.lines.isEmpty) {
      if (_currentIndex != -1) {
        _currentIndex = -1;
        _engine.setCurrent(-1, force: true);
      }
      return;
    }
    final newIndex = LyricParser.findCurrentLineIndex(
      widget.lines,
      _effectiveTimeMs(widget.currentTimeMs),
    );
    if (newIndex != _currentIndex) {
      _currentIndex = newIndex;
      _engine.setCurrent(newIndex, force: _needsJump);
      _scheduleTicks();
    }
  }

  /// 点击行 seek：这是用户的显式意图，不受 3 秒抑制窗口约束。
  void _handleLineTap(int startTimeMs) {
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = null;
    _pointerDownPositions.clear();
    _pointerDown = false;
    _pointerDragged = false;
    widget.onSeekLine?.call(startTimeMs);
    final targetIndex = LyricParser.findCurrentLineIndex(
      widget.lines,
      _effectiveTimeMs(startTimeMs),
    );
    if (targetIndex < 0) return;
    _currentIndex = targetIndex;
    _engine.resumeFollow();
    _engine.setCurrent(targetIndex, force: false);
    _scheduleTicks();
  }

  // ── 帧循环 ──

  void _scheduleTicks() {
    if (!_engine.anyMoving) return;
    if (!_ticker.isActive) {
      _lastTickerElapsed = null;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final last = _lastTickerElapsed;
    _lastTickerElapsed = elapsed;
    final dtMs = last == null ? 0.0 : (elapsed - last).inMicroseconds / 1000.0;
    _engine.tick(dtMs);
    if (mounted) setState(() {});
    if (!_engine.anyMoving) {
      _lastTickerElapsed = null;
      _ticker.stop();
    }
  }

  // ── 手动浏览 ──

  void _startUserScrollHold() {
    final wasHolding = _userScrollHoldTimer != null;
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = Timer(_kUserScrollHold, _onUserScrollHoldEnd);
    if (!wasHolding && mounted) setState(() {});
  }

  void _onUserScrollHoldEnd() {
    if (_userScrollHoldTimer == null) return;
    _userScrollHoldTimer = null;
    if (!mounted) return;
    _engine.resumeFollow();
    _scheduleTicks();
    setState(() {});
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointerDownPositions[e.pointer] = e.position;
    if (_pointerDownPositions.length != 1) return;
    // 仅当从"无指针"到"第一个指针"时才重置拖动标记；第二根手指按下不抹掉
    // 首指的拖动状态。
    _pointerDragged = false;
    _pointerDown = true;
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = null;
    _dragStartY = e.position.dy;
    _dragStartScrollOffset = _engine.userScrollOffset;
    // 手动浏览期间冻结对齐行：切句不打扰用户浏览。
    _engine.setHeldScrollIndex(_currentIndex);
    // 手指按下 → scrolling 变 true（解除景深模糊）。
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent e) {
    final start = _pointerDownPositions[e.pointer];
    if (start == null) return;
    if (!_pointerDragged && (e.position - start).distance > kTouchSlop) {
      _pointerDragged = true;
      _dragStartY = start.dy;
      _dragStartScrollOffset = _engine.userScrollOffset;
    }
    if (!_pointerDragged) return;
    final (min, max) = _engine.userScrollBounds();
    final v = (_dragStartScrollOffset - (e.position.dy - _dragStartY)).clamp(
      min,
      max,
    );
    _engine.setUserScrollOffset(v, force: true);
    setState(() {});
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointerDownPositions.remove(e.pointer);
    if (_pointerDownPositions.isNotEmpty) return;
    final wasDown = _pointerDown;
    _pointerDown = false;
    if (_pointerDragged) {
      _pointerDragged = false;
      _startUserScrollHold();
    } else if (wasDown) {
      // 纯轻点：解除按下时冻结的对齐锚点，恢复跟随（不弹回，只是让
      // 后续切句能正常跟）。scrolling true→false，需重建恢复模糊。
      _engine.resumeFollow();
      _scheduleTicks();
      setState(() {});
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointerDownPositions.remove(e.pointer);
    if (_pointerDownPositions.isNotEmpty) return;
    final wasDown = _pointerDown;
    _pointerDown = false;
    _pointerDragged = false;
    if (wasDown) setState(() {});
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || e.scrollDelta.dy == 0) return;
    _pointerDown = false;
    _pointerDragged = false;
    _pointerDownPositions.clear();
    _engine.setHeldScrollIndex(_currentIndex);
    final (min, max) = _engine.userScrollBounds();
    final v = (_engine.userScrollOffset + e.scrollDelta.dy).clamp(min, max);
    _engine.setUserScrollOffset(v, force: true);
    _startUserScrollHold();
    // 每次滚轮都要重建：第二次起 _startUserScrollHold 不再触发 setState。
    setState(() {});
  }

  void _onMouseExit() {
    final wasHolding = _userScrollHoldTimer != null;
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = null;
    if (wasHolding) {
      _engine.resumeFollow();
      _scheduleTicks();
      setState(() {});
    }
  }

  // ── 测量 ──

  /// 当前行顶边应落在视口的比例（≈"第 3 句"锚点）。
  double _alignFraction(double viewportHeight) {
    final fraction = _kPlayedLyricViewportFraction
        .clamp(_kPlayedFractionMin, _kPlayedFractionMax)
        .toDouble();
    final desiredPlayedSpace = viewportHeight * fraction;
    final minimumVisibleSpace =
        _kMinPlayedSpace + _kAnchorSafePadding + _kKeepAliveZone;
    final resolvedPlayedSpace = desiredPlayedSpace > minimumVisibleSpace
        ? desiredPlayedSpace
        : minimumVisibleSpace;
    final effectiveOffset =
        (resolvedPlayedSpace - _kKeepAliveZone)
            .clamp(_kMinimumOffset, double.infinity)
            .toDouble();
    final verticalPad = effectiveOffset + _kKeepAliveZone;
    return (verticalPad / viewportHeight).clamp(0.0, 1.0).toDouble();
  }

  String? _translationTextFor(LyricLine line) {
    if (!widget.showTranslation) return null;
    if ((line.translation ?? '').isNotEmpty) return line.translation;
    if ((line.roman ?? '').isNotEmpty) return line.roman;
    return null;
  }

  /// 行内容高度：画布 + 翻译（假名原文额外留间距）。不含行间 padding 与圆点槽。
  double _contentHeightOf(
    int index,
    LyricLineLayout layout,
    double width,
    TextStyle translationStyle,
  ) {
    final line = widget.lines[index];
    double h = layout.totalHeight;
    final translation = _translationTextFor(line);
    if (translation != null) {
      final painter = TextPainter(
        text: TextSpan(text: translation, style: translationStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      h += (containsJapaneseKana(line.text) ? 7 : 4) + painter.height;
    }
    return h;
  }

  /// 测量全部行的排版与高度（按宽度 + 圆点行缓存）。
  void _ensureMeasurements(
    double width,
    TextStyle textStyle,
    TextStyle translationStyle,
    int? dotLineIndex,
  ) {
    final n = widget.lines.length;
    if (_layouts.length != n) {
      _layouts = List.generate(n, (_) => null);
      _baseHeights = List.filled(n, 0);
      _itemHeights = List.filled(n, 0);
      _measuredWidth = double.infinity;
      _measuredDotsLine = null;
    }
    final widthChanged = (width - _measuredWidth).abs() > 0.5;
    final dotsChanged = dotLineIndex != _measuredDotsLine;
    if (!widthChanged && !dotsChanged) return;
    if (widthChanged) {
      _measuredWidth = width;
      for (var i = 0; i < n; i++) {
        final layout = measureLyricLine(
          line: widget.lines[i],
          style: textStyle,
          availableWidth: width,
          glowColor: widget.activeColor,
        );
        _layouts[i] = layout;
        _baseHeights[i] = _contentHeightOf(i, layout, width, translationStyle);
      }
    }
    _measuredDotsLine = dotLineIndex;
    for (var i = 0; i < n; i++) {
      // 16 = 行间上下 padding；28 = 圆点槽（4 顶部留白 + 16 圆点 + 8 底部留白）。
      _itemHeights[i] = _baseHeights[i] + 16 + (i == dotLineIndex ? 28 : 0);
    }
    _measurementsDirty = true;
  }

  // ── 圆点 ──

  /// 前奏圆点：首行 start >5s 且当前时间在首行之前。
  bool _showIntroDots(int currentTimeMs) {
    final first = widget.lines.firstOrNull;
    if (first == null) return false;
    return first.startTimeMs > _kIntroThresholdMs &&
        currentTimeMs < first.startTimeMs;
  }

  /// 间奏圆点索引：与上一句间隔 >5s 且当前时间落在间隔内。
  int? _interludeIndex(int currentTimeMs) {
    for (var i = 0; i < widget.lines.length; i++) {
      if (i == 0) continue;
      final prev = widget.lines[i - 1];
      final cur = widget.lines[i];
      if (cur.startTimeMs - prev.endTimeMs > _kInterludeThresholdMs &&
          currentTimeMs >= prev.endTimeMs &&
          currentTimeMs < cur.startTimeMs) {
        return i;
      }
    }
    return null;
  }

  // ── 景深模糊 ──

  /// 景深模糊 sigma：按"距当前行的行数"指数增长，与视口尺寸/字号无关
  /// （窄屏/宽屏表现一致）。相邻行即有可见模糊，越远越糊、趋近
  /// [_kBlurMaxSigma]；当前行恒 0。
  double _blurSigmaFor(int index) {
    final d = (index - _currentIndex).abs();
    if (d == 0) return 0;
    return _kBlurMaxSigma * (1 - math.exp(-d / _kBlurHalfRow));
  }

/// 视口边缘淡出：按行中心与视口顶/底的距离线性淡出到全透明（区间
  /// = 半行高 + [_kEdgeFadeLength]），高行（带翻译）不会在仍有一半可
  /// 见时就整行消失。配合外层 [ClipRect] 保证歌词绝不会画到歌词面板
  /// （封面/标题/控件）之外；拖动/浏览期间同样生效。
  double _edgeFadeOf(int index) {
    final h = _engine.viewportHeight;
    if (h <= 0) return 1.0;
    final y = _engine.yOf(index);
    final itemH = _itemHeights[index];
    final zone = itemH / 2 + _kEdgeFadeLength;
    final center = y + itemH / 2;
    var f = 1.0;
    if (center < zone) {
      f = math.min(f, math.max(0.0, center / zone));
    }
    final bottomGap = h - center;
    if (bottomGap < zone) {
      f = math.min(f, math.max(0.0, bottomGap / zone));
    }
    return f;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(
            color: widget.inactiveColor,
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    // 跟随系统字体缩放（用 sp 的行为；否则设备调大系统字体后
    // 歌词仍固定 20px，看起来比其他播放器的字细/小）。
    final textScaler = MediaQuery.textScalerOf(context);
    final textStyle =
        theme.textTheme.titleMedium?.copyWith(
          fontSize: textScaler.scale(widget.fontSize),
          fontWeight: FontWeight.bold,
        ) ??
        TextStyle(fontSize: textScaler.scale(18));
    final translationStyle =
        theme.textTheme.bodyMedium?.copyWith(
          fontSize: widget.fontSize * 0.7,
          fontWeight: FontWeight.w400,
        ) ??
        TextStyle(fontSize: widget.fontSize * 0.7);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight;
        final maxWidth = constraints.maxWidth;

        if ((maxHeight - _lastViewportHeight).abs() > 1.0) {
          _lastViewportHeight = maxHeight;
          // 视口高度变化（歌词面板过渡/重新进入歌词页）：当前行锚点已失效，
          // 重新定位（引擎里 force 落位）。
          if (maxHeight >= _kMinScrollHeight &&
              !_pointerDown &&
              _userScrollHoldTimer == null) {
            _needsJump = true;
          }
        }

        final displayTimeMs = _effectiveTimeMs(widget.currentTimeMs);
        final introDots = _showIntroDots(displayTimeMs);
        final interludeIndex = _interludeIndex(displayTimeMs);
        final dotLineIndex = introDots ? 0 : interludeIndex;

        // 圆点动画锚定：进入/切换间奏或 seek 时以当前时间重新锚定，让各
        // 阶段按剩余时长分配。正常播放推进（~200ms 一报）不触发。
        if (dotLineIndex != _lastDotsIndex) {
          _lastDotsIndex = dotLineIndex;
          _dotsAnchorMs = displayTimeMs;
          _lastDotsDisplayMs = displayTimeMs;
        } else if (dotLineIndex != null) {
          final dt = displayTimeMs - _lastDotsDisplayMs;
          if (dt < -100 || dt > 1500) {
            _dotsAnchorMs = displayTimeMs;
          }
          _lastDotsDisplayMs = displayTimeMs;
        }

        var ready = false;
        if (maxHeight >= _kMinScrollHeight) {
          final width = math.max(0.0, maxWidth - kLyricLeftBuffer - 48);
          _ensureMeasurements(width, textStyle, translationStyle, dotLineIndex);
          ready = _layouts.isNotEmpty && _layouts.first != null;
          if (_measurementsDirty) {
            _measurementsDirty = false;
            _engine.lineHeights = List.of(_itemHeights);
            _heightsChanged = true;
          }
          if (ready) {
            _engine.setViewportHeight(maxHeight);
            _engine.setAlignFraction(_alignFraction(maxHeight));
          }
        }

        if ((_needsJump || _heightsChanged) &&
            !_pointerDown &&
            _userScrollHoldTimer == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_pointerDown || _userScrollHoldTimer != null) return;
            final force = _needsJump;
            _needsJump = false;
            final heightsChanged = _heightsChanged;
            _heightsChanged = false;
            if (heightsChanged) {
              _engine.reposition(force: force);
            } else {
              _engine.setCurrent(_currentIndex, force: force);
            }
            _scheduleTicks();
            setState(() {});
          });
        }

        // 景深模糊：滑动/拖动/浏览抑制期间全部清晰（仅保留视口边缘淡出）。
        final scrolling = _pointerDown || _userScrollHoldTimer != null;

        final children = <Widget>[
          const SizedBox.expand(),
          if (ready)
            for (var i = 0; i < widget.lines.length; i++)
              _buildLine(
                context,
                i,
                maxWidth,
                displayTimeMs,
                scrolling,
                dotLineIndex,
              ),
          if (ready && dotLineIndex != null)
            _buildDots(dotLineIndex, displayTimeMs),
        ];

        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          onPointerSignal: _onPointerSignal,
          child: MouseRegion(
            onExit: (_) => _onMouseExit(),
            child: SizedBox(
              width: maxWidth,
              height: maxHeight,
              child: Stack(
                // 视口裁剪兜底：配合每行视口边缘淡出，歌词绝不会画到
                // 歌词面板之外（封面/标题区、控件区）。抗锯齿避免模糊
                // 像素正好切在盒边时出现毛边。
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.topLeft,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLine(
    BuildContext context,
    int i,
    double maxWidth,
    int displayTimeMs,
    bool scrolling,
    int? dotLineIndex,
  ) {
    final line = widget.lines[i];
    final isActive = i == _currentIndex;
    final layout = _layouts[i];
    if (layout == null) return const SizedBox.shrink();

    final dofEnabled = widget.lyricDepthBlur && !scrolling;
    final blurSigma = dofEnabled ? _blurSigmaFor(i) : 0.0;
    final edgeFade = _edgeFadeOf(i);
    // 圆点槽在行盒内顶部：行盒保持引擎认为的位置（yOf..yOf+itemH），把
    // 歌词内容在盒内下推 28（4 顶部留白 + 16 圆点 + 8 底部留白），让圆点
    // 浮在文字上方而不叠字。下推放在 SizedBox 内侧，避免把整个行盒往下
    // 推 28 导致悬停盒变高、盒底多出空白。
    final dotsSlotTop = i == dotLineIndex ? 28.0 : 0.0;

    return LyricLineVisual(
      translateY: _engine.yOf(i),
      scale: _engine.scaleOf(i),
      alpha: _engine.alphaOf(i) * edgeFade,
      blurSigma: blurSigma,
      child: Padding(
        padding: const EdgeInsets.only(left: kLyricLeftBuffer),
        child: SizedBox(
          width: maxWidth - kLyricLeftBuffer,
          height: _itemHeights[i],
          child: Padding(
            padding: EdgeInsets.only(top: dotsSlotTop),
            child: LyricLineView(
            line: line,
            layout: layout,
            isActive: isActive,
            currentTimeMs: displayTimeMs,
            activeColor: widget.activeColor,
            inactiveColor: widget.inactiveColor,
            fontSize: widget.fontSize,
            translationFontSize: widget.fontSize * 0.7,
            showTranslation: widget.showTranslation,
            lineLyricRevealMode: widget.lineLyricRevealMode,
            onTapLine: widget.onSeekLine == null
                ? null
                : () => _handleLineTap(line.startTimeMs),
            onLongPressLine: widget.onLyricLongPress == null
                ? (widget.onSeekLine == null
                      ? null
                      : () => widget.onSeekLine!(line.startTimeMs))
                : () => widget.onLyricLongPress!(line.startTimeMs),
          ),
          ),
        ),
      ),
    );
  }

  /// 前奏/间奏呼吸圆点：独立于行内歌词渲染，走自己的变换。
  ///
  /// 不继承行的 DOF（景深模糊 / 非激活压暗 / 缩放），始终保持清晰醒目；
  /// 只随行一起做视口边缘淡出。位置 = 行内原圆点槽（顶部留白 4 + 左侧
  /// 24），由 [_engine.yOf] 驱动，与歌词行同位移动画同步。
  Widget _buildDots(int i, int displayTimeMs) {
    final line = widget.lines[i];
    final end = i == 0 ? widget.lines[0].startTimeMs : line.startTimeMs;
    return Transform.translate(
      offset: Offset(kLyricLeftBuffer + 24, _engine.yOf(i) + 4),
      child: Opacity(
        opacity: _edgeFadeOf(i).clamp(0.0, 1.0),
        child: BreathingDots(
          anchorTimeMs: _dotsAnchorMs,
          endTimeMs: end,
          currentTimeMs: displayTimeMs,
          color: widget.activeColor,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _userScrollHoldTimer?.cancel();
    super.dispose();
  }
}