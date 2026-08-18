import 'dart:math' as math;

import '../../core/lyric/lyric_spring.dart';
import 'lyric_spring_state.dart';

/// AMLL 式歌词布局/动画引擎。
///
/// 核心模型（对标 AMLL core `calcLayout` / SPlayer-Next physics 引擎）：
/// - **当前行驱动列表对齐**：由 `scrollToIndex`（= 当前行，手动浏览时冻结为
///   `heldScrollIndex`）推导出每行目标 Y（顶边 = 视口对齐点 − 上方行高和）。
/// - **每行自己的 placement spring**：每行独立的 [SpringState]（posY + scale）
///   以"级联延迟"错峰启动，向目标弹去。
/// - **动态弹簧参数**：按相邻两句间隔重算 stiffness/damping（间隔短→硬，
///   长→软），换句时广播给所有行 → 每一句上来的"手感"都不同。
/// - **alpha 指数平滑**：激活行快速变亮、取消激活缓慢变暗。
///
/// 纯 Dart、无 Widget，便于单测。渲染层每帧调 [tick] 后读取各行
/// [yOf]/[scaleOf]/[alphaOf]。
class LyricEngine {
  List<double> lineHeights;
  final List<int> lineStartMs;
  final bool springEnabled;

  /// 非激活行的透明度（指数平滑的目标）。
  final double inactiveAlpha;

  /// 当前行（驱动激活高亮/卡拉 OK/缩放/透明度目标）。
  int currentIndex = -1;

  /// 弹簧强度档位。
  LyricSpringPreset preset;

  /// 手动浏览期间冻结的对齐行（null = 跟随当前行）。
  int? heldScrollIndex;

  /// 手动滚动偏移（px）：改变它会让所有行整体平移，拖动跟手用。
  double userScrollOffset = 0;

  /// 当前行顶边应落在视口的比例（≈"第 3 句"锚点）。
  double alignFraction = 0.28;

  double viewportHeight = 0;

  late final List<SpringState> _posY;
  late final List<SpringState> _scale;
  final List<double> _alpha;

  bool _alphaMoving = false;

  LyricEngine({
    required int lineCount,
    required this.lineHeights,
    required this.lineStartMs,
    required this.preset,
    required this.springEnabled,
    this.inactiveAlpha = 0.35,
  }) : _alpha = List.filled(lineCount, 0.0) {
    _posY = List.generate(
      lineCount,
      (_) => SpringState(
        const SpringParams(mass: 0.9, stiffness: 90, damping: 15),
        0,
        useEase: !springEnabled,
        easeDurationMs: 340,
        settleDistance: 0.5,
        settleVelocity: 15,
      ),
    );
    _scale = List.generate(
      lineCount,
      (_) => SpringState(
        const SpringParams(mass: 2, stiffness: 100, damping: 25),
        0.97,
        useEase: !springEnabled,
        easeDurationMs: 300,
        settleDistance: 0.0005,
        settleVelocity: 0.01,
      ),
    );
  }

  int get scrollToIndex => heldScrollIndex ?? currentIndex;

  bool get anyMoving {
    for (final s in _posY) {
      if (s.busy) return true;
    }
    for (final s in _scale) {
      if (s.busy) return true;
    }
    return _alphaMoving;
  }

  double yOf(int i) => _posY[i].position;
  double scaleOf(int i) => _scale[i].position;
  double alphaOf(int i) => _alpha[i];

  void setPreset(LyricSpringPreset p) {
    if (p == preset) return;
    preset = p;
    _recomputeTargets(force: false);
  }

  void setViewportHeight(double h) {
    viewportHeight = h;
  }

  void setAlignFraction(double f) {
    alignFraction = f;
  }

  /// 当前行变化（播放推进/点击 seek）。[force] = true 直接落位（首帧/远跳）。
  void setCurrent(int index, {bool force = false}) {
    if (index == currentIndex && !force) return;
    currentIndex = index;
    _recomputeTargets(force: force);
  }

  /// 布局数据（行高/视口/对齐点）变化后重算目标。
  ///
  /// 不同于 [setCurrent]：不因"索引未变"提前返回。圆点出现/消失、宽度变化
  /// 会改行高，索引不变但所有行目标都该用新行高重算。
  void reposition({bool force = false}) {
    _recomputeTargets(force: force);
  }

  /// 手动拖动：跟手（直接落位，不弹）。
  void setUserScrollOffset(double v, {bool force = true}) {
    userScrollOffset = v;
    _recomputeTargets(force: force);
  }

  void setHeldScrollIndex(int? index) {
    heldScrollIndex = index;
  }

  /// 手动浏览结束后恢复跟随：对齐回当前行并归零浏览偏移（用弹簧弹回，保留错落）。
  void resumeFollow() {
    heldScrollIndex = null;
    userScrollOffset = 0;
    _recomputeTargets(force: false);
  }

  /// 手动滚动偏移的合理范围：保证任意行都能拖进可视区。
  (double, double) userScrollBounds() {
    final n = lineHeights.length;
    if (n == 0 || viewportHeight <= 0) return (0, 0);
    final anchor = scrollToIndex.clamp(0, n - 1);
    var above = 0.0;
    for (var i = 0; i < anchor; i++) {
      above += lineHeights[i];
    }
    var below = 0.0;
    for (var i = anchor; i < n; i++) {
      below += lineHeights[i];
    }
    return (-(above + viewportHeight * alignFraction), below + viewportHeight * (1 - alignFraction));
  }

  /// 更新所有行目标并写入各自弹簧（含级联延迟与动态参数）。
  void _recomputeTargets({required bool force}) {
    final n = lineHeights.length;
    if (n == 0 || viewportHeight <= 0) return;
    final anchor = scrollToIndex.clamp(0, n - 1);

    // 动态弹簧参数：按"当前行的上一句 → 当前句"间隔计算，广播给所有 posY。
    final posParams = anchor <= 0
        ? const SpringParams(stiffness: 90, damping: 15)
        : computeLinePosYSpringParams(
            prevStartMs: lineStartMs[anchor - 1],
            curStartMs: lineStartMs[anchor],
            preset: preset,
          );
    for (final s in _posY) {
      s.params = posParams;
    }

    var y = viewportHeight * alignFraction - userScrollOffset;
    for (var i = 0; i < anchor; i++) {
      y -= lineHeights[i];
    }

    // 级联延迟：进入视口的行每行 +50ms，过了对齐行后增量递减（÷1.05），
    // 形成"近处先动、越远越慢且间距收窄"的波浪错落。
    var delayMs = 0.0;
    var baseDelay = 50.0;
    for (var i = 0; i < n; i++) {
      final isActive = i == currentIndex;
      final scaleTarget = isActive ? 1.0 : 0.97;
      final d = force ? 0.0 : delayMs;
      _posY[i].setTarget(y, d, force: force);
      _scale[i].setTarget(scaleTarget, d, force: force);
      if (force) {
        _alpha[i] = isActive ? 1.0 : inactiveAlpha;
        _alphaMoving = false;
      }
      y += lineHeights[i];
      if (i < n - 1 && !force && y >= 0) {
        delayMs += baseDelay;
        if (i >= anchor) baseDelay /= 1.05;
      }
    }
  }

  /// 推进一帧（毫秒）。
  void tick(double dtMs) {
    for (final s in _posY) {
      s.tick(dtMs);
    }
    for (final s in _scale) {
      s.tick(dtMs);
    }
    _stepAlpha(dtMs);
  }

  void _stepAlpha(double dtMs) {
    if (dtMs <= 0) return;
    final dtSec = dtMs / 1000.0;
    var moving = false;
    for (var i = 0; i < _alpha.length; i++) {
      final isActive = i == currentIndex;
      final target = isActive ? 1.0 : inactiveAlpha;
      // 指数逼近：激活行快速变亮（attack），取消激活缓慢变暗（release）。
      final speed = isActive ? 50.0 : 7.0;
      final factor = 1 - math.exp(-speed * dtSec);
      _alpha[i] += (target - _alpha[i]) * factor;
      if ((_alpha[i] - target).abs() < 0.0005) {
        _alpha[i] = target;
      } else {
        moving = true;
      }
    }
    _alphaMoving = moving;
  }
}