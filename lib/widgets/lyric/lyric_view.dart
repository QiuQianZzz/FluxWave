import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/lyric/line_lyric_reveal_mode.dart';
import '../../core/lyric/lyric_model.dart';
import '../../core/lyric/lyric_parser.dart';
import 'breathing_dots.dart';
import 'lyric_layout.dart';
import 'lyric_line.dart';

/// 歌词列表视图。
///
/// - `ListView.builder` + 上下 padding = maxHeight/2.5（首末行可居中）
/// - 当前行变化时自动滚动（保留既有的手动滚动抑制状态机）
/// - 每行 Canvas 预测量渲染：逐字 awesome 动画 / 简单浮动 + 行内渐变揭示
/// - 非当前行缩放/压暗/模糊；前奏与长间奏显示呼吸圆点；上下边缘渐隐
/// - 点击行 seek；长按触发 [onLyricLongPress]
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

  /// 是否启用歌词景深模糊：开启时按"距当前行的归一化距离"曲线计算模糊，
  /// 靠近当前行几乎清晰、往可视区顶部/底部边缘渐强；滑动/自动滚动期间自动
  /// 解除模糊。
  final bool lyricDepthBlur;

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
    this.onSeekLine,
    this.onLyricLongPress,
  });

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  final _scrollController = ScrollController();

  /// 当前行 GlobalKey，用于 ensureVisible 精确滚动到指定对齐位置
  final _activeKey = GlobalKey();
  int _currentIndex = -1;
  bool _autoScrolling = false;

  /// 滚动动画期间冻结的当前时间：避免位置流持续推送导致逐字揭示进度跳变。
  int? _frozenTimeMs;

  /// 手指是否正按在歌词列表上（raw Listener 跟踪，不与手势竞技场冲突）。
  bool _pointerDown = false;

  /// 当前按下的指针（pointer → 按下位置）。用于区分"真拖动"与"惯性期间
  /// 的轻点"：惯性时滚动在动但指针没动，不应误判为拖动而打开 3 秒窗口。
  final Map<int, Offset> _pointerDownPositions = {};

  /// 本次按下是否真的拖动过（指针位移超过触摸阈值）：抬手时据它决定是否
  /// 进入 3 秒窗口。
  bool _pointerDragged = false;

  /// 用户松手后禁止自动回正的定时器（非 null = 抑制中）。
  Timer? _userScrollHoldTimer;

  /// 待滚动标志：当前行变化或初始化时设为 true，build 阶段高度足够后执行。
  bool _needsJump = false;

  static const _kMinScrollHeight = 100.0;
  static const _kUserScrollHold = Duration(seconds: 3);

  // ── 当前行定位 ──
  // 当前行顶边约落在"第 3 句"位置：上方只保留约 2 行已播歌词，把更多可视区
  // 留给后续歌词；小屏下用绝对下限兜底，保证前奏/上一句始终可见。
  static const _kPlayedLyricViewportFraction = 0.20;
  static const _kPlayedFractionMin = 0.18;
  static const _kPlayedFractionMax = 0.35;
  static const _kTopFadeLength = 64.0;
  static const _kBottomFadeLength = 160.0;
  static const _kFocusedLyricMaskSafePadding = 12.0;
  static const _kKeepAliveZone = 40.0;
  static const _kMinimumOffset = 48.0;
  static const _kFocusedVisualCompensationRatio = 0.42;
  static const _kLineHeightFactor = 1.18;

  // ── 歌词景深模糊（柔和梯度版）──
  // 模糊度按"距当前行的归一化距离"二次曲线计算：靠近当前行几乎清晰，
  // 越往可视区顶部/底部边缘越模糊，边缘（最顶/最底）达 [_kBlurMaxSigma]。
  // 滑动/拖动/自动滚动期间全部清晰，方便浏览其它歌词。
  static const _kBlurMaxSigma = 1.8;

  /// 行排版缓存：index → 布局。lines/fontSize/测量宽度变化时失效。
  List<LyricLineLayout?> _layoutCache = [];
  double _measuredWidth = 0;

  /// 最近一次布局视口高度：检测歌词面板高度变化（如切歌词页的过渡动画、
  /// 重新进入歌词页）并重新定位当前行，避免在过渡中途的小视口定位后不再校正。
  double _lastViewportHeight = 0;

  /// 前奏圆点阈值（首行 >5s 视为前奏）。
  static const _kIntroThresholdMs = 5000;

  /// 间奏圆点阈值（两句间隔 >5s）。
  static const _kInterludeThresholdMs = 5000;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollPositionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _needsJump = true;
      _updateCurrent();
    });
  }

  @override
  void didUpdateWidget(covariant LyricView old) {
    super.didUpdateWidget(old);
    final metricsChanged =
        old.fontSize != widget.fontSize ||
        old.activeColor != widget.activeColor;
    if (old.lines != widget.lines) {
      _currentIndex = -1;
      _needsJump = true;
      _layoutCache = List<LyricLineLayout?>.filled(widget.lines.length, null);
      _measuredWidth = 0;
      _updateCurrent();
    } else if (metricsChanged) {
      _layoutCache = List<LyricLineLayout?>.filled(widget.lines.length, null);
      _measuredWidth = 0;
    } else if (old.currentTimeMs != widget.currentTimeMs) {
      _updateCurrent();
    }
  }

  void _onScrollPositionChanged() {
    if (_autoScrolling) return;
    if (_pointerDown) return;
    _startUserScrollHold();
  }

  void _startUserScrollHold() {
    final wasHolding = _userScrollHoldTimer != null;
    _userScrollHoldTimer?.cancel();
    _userScrollHoldTimer = Timer(_kUserScrollHold, _onUserScrollHoldEnd);
    // 进入/保持抑制窗口会改变"是否滚动中"，需触发重建让 itemBuilder 重算模糊
    // （已建 item 不会自动重建）。仅首次进入时重建，滚动通知期间避免刷屏。
    if (!wasHolding && mounted) setState(() {});
  }

  void _onUserScrollHoldEnd() {
    if (_userScrollHoldTimer == null) return;
    _userScrollHoldTimer = null;
    if (mounted) setState(() {});
  }

  void _updateCurrent() {
    if (widget.lines.isEmpty) {
      if (_currentIndex != -1) _currentIndex = -1;
      return;
    }
    final newIndex = LyricParser.findCurrentLineIndex(
      widget.lines,
      _effectiveTimeMs(widget.currentTimeMs),
    );
    if (newIndex != _currentIndex) {
      _currentIndex = newIndex;
      if (_pointerDown || _userScrollHoldTimer != null) {
        return;
      }
      _userScrollHoldTimer?.cancel();
      _userScrollHoldTimer = null;
      _needsJump = true;
      _frozenTimeMs = _effectiveTimeMs(widget.currentTimeMs);
      _scrollToCurrent();
    }
  }

  /// 点击行 seek：这是用户的显式意图，不受 3 秒抑制窗口约束——
  /// 先清掉抑制/拖动标记，立即把当前行切到目标行并滚动，不依赖位置流回传
  /// （否则惯性滑动的尾部通知会重新打开窗口，导致"惯性期间点击定位失效"）。
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
    if (targetIndex != _currentIndex) {
      _currentIndex = targetIndex;
      setState(() {});
    }
    _needsJump = true;
    _scrollToCurrent();
  }

  int _effectiveTimeMs(int raw) =>
      (raw + widget.lyricOffsetMs).clamp(0, 1 << 31);

  /// 解析当前行滚动锚点。
  ///
  /// 返回 (内容上 padding, 内容下 padding, ensureVisible alignment)。
  /// 当前行顶边落在 `topPad` 处，上方为"第 3 句"锚点（约 2 行已播歌词）。
  /// 下 padding 比上 padding 大：保证末行也能滚到同一锚点（滚动范围 =
  /// 上下 padding + 内容 - 视口，末行需 (N-1)*行高 的滚动量）。
  (double, double, double) _scrollGeometry(double viewportHeight) {
    final lineHeight = widget.fontSize * _kLineHeightFactor;
    final fraction = _kPlayedLyricViewportFraction
        .clamp(_kPlayedFractionMin, _kPlayedFractionMax)
        .toDouble();
    final desiredPlayedSpace = viewportHeight * fraction;
    final minimumVisibleSpace =
        _kTopFadeLength + _kFocusedLyricMaskSafePadding + _kKeepAliveZone;
    final resolvedPlayedSpace = desiredPlayedSpace > minimumVisibleSpace
        ? desiredPlayedSpace
        : minimumVisibleSpace;
    final compensation = lineHeight * _kFocusedVisualCompensationRatio;
    final effectiveOffset =
        (resolvedPlayedSpace + compensation - _kKeepAliveZone)
            .clamp(_kMinimumOffset, double.infinity)
            .toDouble();
    final verticalPad = effectiveOffset + _kKeepAliveZone;
    final alignment = (verticalPad / viewportHeight).clamp(0.0, 1.0).toDouble();
    // 末行可达锚点需 bottomPad >= viewportH - topPad - itemHeight。
    // itemHeight 保守取小（fontSize*2）：真实行高更大时只会更可达。
    final bottomPad = math.max(
      verticalPad,
      viewportHeight - verticalPad - widget.fontSize * 2.0,
    );
    return (verticalPad, bottomPad, alignment);
  }

  Future<void> _scrollToCurrent() async {
    if (!_scrollController.hasClients || _currentIndex < 0) return;
    if (_autoScrolling) return;
    _autoScrolling = true;
    // 自动滚动期间景深模糊应解除：触发重建让 itemBuilder 重算 blurSigma。
    if (mounted) setState(() {});
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _currentIndex < 0) return;

      for (int attempt = 0; attempt < 8; attempt++) {
        if (!mounted || _currentIndex < 0) return;
        if (!_scrollController.hasClients) return;

        final ctx = _activeKey.currentContext;
        if (ctx != null && ctx.mounted) {
          final viewportH = _scrollController.position.viewportDimension;
          final (_, _, alignment) = _scrollGeometry(viewportH);
          await Scrollable.ensureVisible(
            ctx,
            alignment: alignment,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          );
          if (!mounted) return;
          // 歌词面板过渡动画期间视口高度仍在变化：本次 ensureVisible 是按中途
          // 小视口计算的，必须保留 _needsJump 让重试循环在视口稳定后重新定位，
          // 否则切歌词页首帧会把当前行停在错误位置。
          final stable =
              _scrollController.hasClients &&
              (_scrollController.position.viewportDimension - viewportH)
                      .abs() <=
                  1.0;
          if (stable) _needsJump = false;
          return;
        }

        _jumpToEstimated(attempt);
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      _autoScrolling = false;
      _frozenTimeMs = null;
      if (mounted) setState(() {});
      if (_needsJump &&
          mounted &&
          !_pointerDown &&
          _userScrollHoldTimer == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _needsJump &&
              !_autoScrolling &&
              !_pointerDown &&
              _userScrollHoldTimer == null) {
            _scrollToCurrent();
          }
        });
      }
    }
  }

  void _jumpToEstimated(int attempt) {
    final pos = _scrollController.position;
    final viewportH = pos.viewportDimension;
    if (viewportH <= 0) return;

    final (topPad, bottomPad, alignment) = _scrollGeometry(viewportH);
    // 用已布局行的高度均值估算当前行偏移：SliverList 的 maxScrollExtent 基于
    // 实际已建行 + 平均估计，比固定字号倍数更贴近真实行高（含翻译/换行/圆点）。
    final itemCount = widget.lines.length;
    final estimatedContentHeight =
        pos.maxScrollExtent + viewportH - topPad - bottomPad;
    final estimatedLineH = itemCount > 0
        ? estimatedContentHeight / itemCount
        : widget.fontSize * 2.5;
    final baseTarget =
        topPad +
        _currentIndex * estimatedLineH +
        estimatedLineH / 2 -
        viewportH * alignment;

    final offset = (attempt ~/ 2 + 1) * 20.0 * (attempt.isEven ? 1 : -1);
    final target = baseTarget + offset;
    final clamped = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    pos.jumpTo(clamped);
  }

  @override
  void dispose() {
    _userScrollHoldTimer?.cancel();
    _scrollController.removeListener(_onScrollPositionChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// 取行排版（按当前测量宽度 + 字号缓存，失效后重建）。
  LyricLineLayout _layoutFor(int index, double width, TextStyle style) {
    if (index >= _layoutCache.length) {
      _layoutCache = List<LyricLineLayout?>.filled(widget.lines.length, null);
      _measuredWidth = 0;
    }
    if ((width - _measuredWidth).abs() > 0.5 || _layoutCache[index] == null) {
      if ((width - _measuredWidth).abs() > 0.5) {
        _layoutCache.fillRange(0, _layoutCache.length, null);
        _measuredWidth = width;
      }
      _layoutCache[index] = measureLyricLine(
        line: widget.lines[index],
        style: style,
        availableWidth: width,
        glowColor: widget.activeColor,
      );
    }
    return _layoutCache[index]!;
  }

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

  /// 景深模糊 sigma（柔和梯度）：按"距当前行的归一化距离"二次曲线计算。
  /// 距离 = 行距数 / 可视区该方向的可见行数（当前行上方可见行数 / 下方可见
  /// 行数），归一化到 0..1；t² 曲线让靠近当前行的行几乎清晰、顶部/底部边缘
  /// 最模糊，避免旧版"上下两三行外全糊"与硬性清晰带的突兀。
  double _blurForIndex(int index, int aboveVisible, int belowVisible) {
    final d = index - _currentIndex;
    if (d == 0) return 0;
    final span = d < 0 ? math.max(1, aboveVisible) : math.max(1, belowVisible);
    final t = math.min(1.0, d.abs().toDouble() / span);
    return t * t * _kBlurMaxSigma;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: widget.inactiveColor),
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

    return NotificationListener<ScrollNotification>(
      onNotification: (notif) => false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxHeight = constraints.maxHeight;
          if ((maxHeight - _lastViewportHeight).abs() > 1.0) {
            _lastViewportHeight = maxHeight;
            // 视口高度变化（歌词面板过渡/重新进入歌词页）：当前行锚点已失效，
            // 重新定位，不依赖位置流回传（暂停/换句未变时位置流不会触发滚动）。
            if (maxHeight >= _kMinScrollHeight &&
                !_pointerDown &&
                _userScrollHoldTimer == null) {
              _needsJump = true;
            }
          }
          final (topPad, bottomPad, _) = _scrollGeometry(maxHeight);
          if (_needsJump &&
              maxHeight >= _kMinScrollHeight &&
              !_autoScrolling &&
              !_pointerDown &&
              _userScrollHoldTimer == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_needsJump &&
                  !_autoScrolling &&
                  !_pointerDown &&
                  _userScrollHoldTimer == null) {
                _scrollToCurrent();
              }
            });
          }

          final displayTimeMs =
              _frozenTimeMs ?? _effectiveTimeMs(widget.currentTimeMs);
          final introDots = _showIntroDots(displayTimeMs);
          final interludeIndex = _interludeIndex(displayTimeMs);

          // 景深模糊梯度：以"距当前行的归一化距离"为自变量，靠近当前行几乎
          // 清晰，往可视区顶部/底部边缘渐强。滑动/拖动/自动滚动期间全部清晰。
          final itemH = widget.fontSize * _kLineHeightFactor + 16;
          final belowVisible = math.max(
            1,
            ((maxHeight - topPad) / itemH).floor(),
          );
          final aboveVisible = math.max(1, (topPad / itemH).floor());
          final scrolling =
              _autoScrolling || _pointerDown || _userScrollHoldTimer != null;

          return Listener(
            onPointerDown: (e) {
              _pointerDownPositions[e.pointer] = e.position;
              if (_pointerDownPositions.length == 1) {
                // 仅当从"无指针"到"第一个指针"时才重置拖动标记；
                // 第二根手指按下不抹掉首指的拖动状态。
                _pointerDragged = false;
                _pointerDown = true;
                _userScrollHoldTimer?.cancel();
                _userScrollHoldTimer = null;
                // 手指按下 → scrolling 变 true（解除景深模糊），触发重建
                // 让 itemBuilder 重算 blurSigma（已建 item 不会自动重建）。
                setState(() {});
              }
            },
            onPointerMove: (e) {
              final start = _pointerDownPositions[e.pointer];
              if (start != null && (e.position - start).distance > kTouchSlop) {
                _pointerDragged = true;
              }
            },
            onPointerUp: (e) {
              _pointerDownPositions.remove(e.pointer);
              if (_pointerDownPositions.isEmpty) {
                final wasDown = _pointerDown;
                _pointerDown = false;
                if (_pointerDragged) {
                  // 进入浏览抑制窗口（scrolling 保持 true），_startUserScrollHold
                  // 内部已按需 setState。
                  _pointerDragged = false;
                  _startUserScrollHold();
                } else if (wasDown) {
                  // 纯轻点：scrolling true→false，需重建恢复模糊。
                  setState(() {});
                }
              }
            },
            onPointerCancel: (e) {
              _pointerDownPositions.remove(e.pointer);
              if (_pointerDownPositions.isEmpty) {
                final wasDown = _pointerDown;
                _pointerDown = false;
                _pointerDragged = false;
                if (wasDown) setState(() {});
              }
            },
            child: MouseRegion(
              onExit: (_) {
                final wasHolding = _userScrollHoldTimer != null;
                _userScrollHoldTimer?.cancel();
                _userScrollHoldTimer = null;
                if (wasHolding) setState(() {});
              },
              child: ShaderMask(
                shaderCallback: (bounds) {
                  final topFade = (_kTopFadeLength / bounds.height).clamp(
                    0.0,
                    0.48,
                  );
                  final bottomFade = (_kBottomFadeLength / bounds.height).clamp(
                    0.0,
                    0.48,
                  );
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [
                      0.0,
                      topFade,
                      (1 - bottomFade).clamp(0.0, 1.0),
                      1.0,
                    ],
                  ).createShader(bounds);
                },
                blendMode: BlendMode.dstIn,
                child: ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.only(
                    top: topPad,
                    bottom: bottomPad,
                    left: kLyricLeftBuffer,
                  ),
                  itemCount: widget.lines.length,
                  itemBuilder: (context, i) {
                    final line = widget.lines[i];
                    final isActive = i == _currentIndex;
                    final layout = _layoutFor(
                      i,
                      constraints.maxWidth - kLyricLeftBuffer - 48,
                      textStyle,
                    );
                    final blurSigma = (widget.lyricDepthBlur && !scrolling)
                        ? _blurForIndex(i, aboveVisible, belowVisible)
                        : 0.0;
                    final showDots =
                        (introDots && i == 0) || i == interludeIndex;

                    Widget leadingDots;
                    if (showDots) {
                      final start = i == 0 ? 0 : widget.lines[i - 1].endTimeMs;
                      final end = i == 0
                          ? widget.lines[0].startTimeMs
                          : line.startTimeMs;
                      leadingDots = Padding(
                        padding: const EdgeInsets.only(bottom: 8, left: 24),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: BreathingDots(
                            startTimeMs: start,
                            endTimeMs: end,
                            currentTimeMs: displayTimeMs,
                            color: widget.activeColor,
                          ),
                        ),
                      );
                    } else {
                      leadingDots = const SizedBox.shrink();
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: LyricLineVisual(
                        isFocused: isActive,
                        blurSigma: blurSigma,
                        child: LyricLineView(
                          key: isActive ? _activeKey : null,
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
                          leadingDots: showDots ? leadingDots : null,
                          onTapLine: widget.onSeekLine == null
                              ? null
                              : () => _handleLineTap(line.startTimeMs),
                          onLongPressLine: widget.onLyricLongPress == null
                              ? (widget.onSeekLine == null
                                    ? null
                                    : () =>
                                          widget.onSeekLine!(line.startTimeMs))
                              : () =>
                                    widget.onLyricLongPress!(line.startTimeMs),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
